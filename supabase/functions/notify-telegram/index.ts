// Edge Function notify-telegram: сообщения о событиях аппаратов в Telegram.
//
//   POST /functions/v1/notify-telegram   заголовок x-notify-secret: <NOTIFY_WEBHOOK_SECRET>
//   тело Database Webhook (INSERT в events)  → режим event
//   {"mode":"offline_check"}                 → «нет связи» / «связь восстановлена» (по расписанию)
//   {"mode":"whoami"}                        → {"ok":true,"chats":[{id,title,type}]}
//   {"mode":"test","org_id":"<uuid>"}        → «Проверка связи» в канал организации
//
//   401 → {"ok":false,"error":"auth"}  (секрет не совпал; ничего не делается)
//   200 → {"ok":true,"status":"<кратко>"}  (в том числе при ошибке Telegram)
//
// Секреты (задаёт владелец): TELEGRAM_BOT_TOKEN, NOTIFY_WEBHOOK_SECRET.
// SUPABASE_URL и SUPABASE_SERVICE_ROLE_KEY Supabase подставляет сам.
// Токен бота и секреты НЕ пишутся ни в журнал, ни в ответы.
//
// Развёртывание — с флагом --no-verify-jwt: подлинность вызова проверяет
// сама функция по x-notify-secret. Инструкция — docs/telegram_alerts.md.
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type DeviceRow,
  dedupAllows,
  dedupKey,
  deviceName,
  type EventRecord,
  eventMessage,
  extractChats,
  isNotifiableType,
  offlineMessage,
  onlineMessage,
  parseRequest,
  planOffline,
  redact,
  secretMatches,
  TEST_MESSAGE,
} from "./logic.ts";

const JSON_HEADERS = { "Content-Type": "application/json" };

function reply(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

const ok = (status: string, extra: Record<string, unknown> = {}) =>
  reply(200, { ok: true, status, ...extra });

function secrets(): (string | undefined)[] {
  return [
    Deno.env.get("TELEGRAM_BOT_TOKEN"),
    Deno.env.get("NOTIFY_WEBHOOK_SECRET"),
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  ];
}

function logError(where: string, e: unknown) {
  const text = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
  console.error(`notify-telegram ${where}: ${redact(text, secrets())}`);
}

// ---------- Telegram ----------

async function telegram(
  method: string,
  payload: Record<string, unknown>,
): Promise<{ ok: boolean; result?: unknown }> {
  const token = Deno.env.get("TELEGRAM_BOT_TOKEN");
  if (!token) {
    console.error("notify-telegram: TELEGRAM_BOT_TOKEN не задан");
    return { ok: false };
  }
  try {
    const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
      method: "POST",
      headers: JSON_HEADERS,
      body: JSON.stringify(payload),
    });
    const body = await res.json().catch(() => null) as
      | { ok?: boolean; result?: unknown; description?: string }
      | null;
    if (!res.ok || body?.ok !== true) {
      logError(`${method} ${res.status}`, body?.description ?? "нет описания");
      return { ok: false };
    }
    return { ok: true, result: body.result };
  } catch (e) {
    logError(method, e);
    return { ok: false };
  }
}

async function send(chatId: string, text: string): Promise<boolean> {
  const r = await telegram("sendMessage", {
    chat_id: chatId,
    text,
    parse_mode: "HTML",
    disable_web_page_preview: true,
  });
  return r.ok;
}

// ---------- База ----------

// Канал организации; null — нет записи или выключен.
async function chatFor(sb: SupabaseClient, orgId: string | null): Promise<string | null> {
  if (!orgId) return null;
  const { data, error } = await sb
    .from("notify_channels")
    .select("chat_id")
    .eq("org_id", orgId)
    .eq("enabled", true)
    .maybeSingle();
  if (error) logError("notify_channels", error.message);
  return data?.chat_id ?? null;
}

// Забрать право на отправку по ключу (не чаще раза в DEDUP_WINDOW_MS).
// Запись меняется только при совпадении прежнего sent_at, поэтому из двух
// одновременных вызовов отправит один.
async function claimDedup(sb: SupabaseClient, key: string, nowMs: number): Promise<boolean> {
  const nowIso = new Date(nowMs).toISOString();
  const { data: row, error } = await sb
    .from("notify_dedup")
    .select("sent_at")
    .eq("key", key)
    .maybeSingle();
  if (error) {
    logError("notify_dedup", error.message);
    return false;
  }
  if (!row) {
    const { data: ins } = await sb
      .from("notify_dedup")
      .upsert({ key, sent_at: nowIso }, { onConflict: "key", ignoreDuplicates: true })
      .select("key");
    return (ins?.length ?? 0) > 0;
  }
  if (!dedupAllows(Date.parse(row.sent_at), nowMs)) return false;
  const { data: upd } = await sb
    .from("notify_dedup")
    .update({ sent_at: nowIso })
    .eq("key", key)
    .eq("sent_at", row.sent_at)
    .select("key");
  return (upd?.length ?? 0) > 0;
}

// ---------- Режимы ----------

async function handleEvent(sb: SupabaseClient, rec: EventRecord): Promise<Response> {
  if (!isNotifiableType(rec.type)) return ok("ignored");

  const { data: dev } = await sb
    .from("devices")
    .select("id, org_id, name")
    .eq("id", rec.device_id)
    .maybeSingle();
  const chat = await chatFor(sb, rec.org_id ?? dev?.org_id ?? null);
  if (!chat) return ok("no_channel");

  const text = eventMessage(rec.type, deviceName(rec.device_id, dev?.name), rec.data);
  if (!text) return ok("ignored");

  const key = dedupKey(rec.device_id, rec.type, rec.data);
  if (!await claimDedup(sb, key, Date.now())) return ok("duplicate");

  if (await send(chat, text)) return ok("sent");
  // Не дошло — освобождаем ключ, чтобы следующее событие не молчало.
  await sb.from("notify_dedup").delete().eq("key", key);
  return ok("telegram_error");
}

async function handleOfflineCheck(sb: SupabaseClient): Promise<Response> {
  const [devRes, stateRes, chanRes] = await Promise.all([
    sb.from("devices").select("id, org_id, name, last_seen_at"),
    sb.from("notify_offline_state").select("device_id, notified_at"),
    sb.from("notify_channels").select("org_id, chat_id").eq("enabled", true),
  ]);
  if (devRes.error || stateRes.error || chanRes.error) {
    logError("offline_check", devRes.error?.message ?? stateRes.error?.message ?? chanRes.error?.message);
    return ok("db_error");
  }
  const chats = new Map<string, string>(
    (chanRes.data ?? []).map((c) => [c.org_id as string, c.chat_id as string]),
  );
  const notifiedAt = new Map<string, string>(
    (stateRes.data ?? []).map((s) => [s.device_id as string, s.notified_at as string]),
  );
  const nowMs = Date.now();
  const plan = planOffline(devRes.data as DeviceRow[], new Set(notifiedAt.keys()), nowMs);

  let offline = 0, online = 0, failed = 0;

  for (const { device, minutes } of plan.wentOffline) {
    const chat = device.org_id ? chats.get(device.org_id) : undefined;
    // Нет канала — ни сообщения, ни записи: когда канал появится, о
    // молчащем аппарате сообщим.
    if (!chat) continue;
    // Сначала запись (из двух одновременных проверок отправит одна).
    const { data: ins } = await sb
      .from("notify_offline_state")
      .upsert(
        { device_id: device.id, notified_at: new Date(nowMs).toISOString() },
        { onConflict: "device_id", ignoreDuplicates: true },
      )
      .select("device_id");
    if ((ins?.length ?? 0) === 0) continue;
    if (await send(chat, offlineMessage(deviceName(device.id, device.name), minutes))) {
      offline++;
    } else {
      // Не дошло — убираем запись, следующая проверка попробует снова.
      await sb.from("notify_offline_state").delete().eq("device_id", device.id);
      failed++;
    }
  }

  for (const device of plan.cameBack) {
    const { data: del } = await sb
      .from("notify_offline_state")
      .delete()
      .eq("device_id", device.id)
      .select("device_id");
    if ((del?.length ?? 0) === 0) continue;
    const chat = device.org_id ? chats.get(device.org_id) : undefined;
    if (!chat) continue;
    if (await send(chat, onlineMessage(deviceName(device.id, device.name)))) {
      online++;
    } else {
      // Не дошло — возвращаем запись, следующая проверка попробует снова.
      await sb.from("notify_offline_state").upsert({
        device_id: device.id,
        notified_at: notifiedAt.get(device.id) ?? new Date(nowMs).toISOString(),
      });
      failed++;
    }
  }

  return ok(failed > 0 ? "telegram_error" : "done", { offline, online, failed });
}

async function handleWhoami(): Promise<Response> {
  // Без allowed_updates: этот параметр запоминается ботом и менял бы, какие
  // обновления он получает дальше.
  const r = await telegram("getUpdates", { limit: 100 });
  if (!r.ok) return ok("telegram_error", { chats: [] });
  return ok("done", { chats: extractChats(r.result) });
}

async function handleTest(sb: SupabaseClient, orgId: string): Promise<Response> {
  const chat = await chatFor(sb, orgId);
  if (!chat) return ok("no_channel");
  return ok(await send(chat, TEST_MESSAGE) ? "sent" : "telegram_error");
}

// ---------- Вход ----------

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply(405, { ok: false, error: "method" });
  if (!secretMatches(req.headers.get("x-notify-secret"), Deno.env.get("NOTIFY_WEBHOOK_SECRET"))) {
    return reply(401, { ok: false, error: "auth" });
  }

  try {
    let raw: unknown;
    try {
      raw = await req.json();
    } catch {
      return reply(400, { ok: false, error: "bad_request" });
    }
    const input = parseRequest(raw);
    if (input === null) return reply(400, { ok: false, error: "bad_request" });
    if (input.mode === "ignore") return ok("ignored");
    if (input.mode === "whoami") return await handleWhoami();

    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) return reply(500, { ok: false, error: "internal" });
    const sb = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    switch (input.mode) {
      case "event":
        return await handleEvent(sb, input.record);
      case "offline_check":
        return await handleOfflineCheck(sb);
      default:
        return await handleTest(sb, input.org_id);
    }
  } catch (e) {
    logError("internal", e);
    return reply(500, { ok: false, error: "internal" });
  }
});
