// Edge Function release-url (R2.0, п. D): выдаёт устройству короткоживущую
// подписанную ссылку на APK из ЗАКРЫТОГО бакета releases.
//
//   POST /functions/v1/release-url   {"device": "...", "token": "...", "release": "<uuid>"}
//   200 → {"ok":true,"url","sha256","size_bytes","version_code","version_name","expires_in_s"}
//   4xx/5xx → {"ok":false,"error":"<короткий код>"}   (без подробностей)
//
// Токен проверяется через device_token_valid (RPC под сервисным ключом;
// из-за закрытой от anon функции подобрать токен снаружи нельзя). Сервисный
// ключ берётся из переменной окружения функции (Supabase подставляет
// SUPABASE_SERVICE_ROLE_KEY сам) — в коде и в репозитории ключей нет.
// Токен и ключи НЕ пишутся ни в журнал, ни в ответы.
//
// Развёртывание — с флагом --no-verify-jwt: приложение вызывает функцию с
// публичным ключом (sb_publishable_…), это не JWT; подлинность устройства
// проверяет сама функция по токену. Инструкция — docs/releases.md.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  errorResponse,
  isUsableRelease,
  MIN_INTERVAL_MS,
  parseInput,
  rateDecision,
  SIGNED_URL_TTL_S,
  successBody,
} from "./logic.ts";

const JSON_HEADERS = { "Content-Type": "application/json" };

function reply(status: number, body: unknown, extra: HeadersInit = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...JSON_HEADERS, ...extra },
  });
}

function fail(code: Parameters<typeof errorResponse>[0], extra: HeadersInit = {}) {
  const e = errorResponse(code);
  return reply(e.status, e.body, extra);
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return fail("method");

  try {
    let raw: unknown;
    try {
      raw = await req.json();
    } catch {
      return fail("bad_request");
    }
    const input = parseInput(raw);
    if (input === null) return fail("bad_request");

    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) return fail("internal");
    const sb = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // 1. Токен устройства. Любая ошибка проверки = 'auth' (не раскрываем
    //    причину и не различаем «нет такого устройства» и «неверный токен»).
    const { data: valid, error: tokenErr } = await sb.rpc("device_token_valid", {
      p_device: input.device,
      p_token: input.token,
    });
    if (tokenErr || valid !== true) return fail("auth");

    // 2. Частота: не чаще раза в минуту на устройство.
    const { data: last } = await sb
      .from("release_url_requests")
      .select("last_at")
      .eq("device_id", input.device)
      .maybeSingle();
    const now = Date.now();
    const decision = rateDecision(
      last?.last_at ? Date.parse(last.last_at as string) : null,
      now,
      MIN_INTERVAL_MS,
    );
    if (!decision.allowed) {
      return fail("rate_limited", { "Retry-After": String(decision.retryAfterS) });
    }
    await sb.from("release_url_requests").upsert({
      device_id: input.device,
      last_at: new Date(now).toISOString(),
    });

    // 3. Запись о релизе.
    const { data: rel, error: relErr } = await sb.rpc("device_release_get", {
      p_device: input.device,
      p_token: input.token,
      p_release: input.release,
    });
    if (relErr || !isUsableRelease(rel)) return fail("not_found");

    // 4. Подписанная ссылка на 10 минут (закрытый бакет).
    const { data: signed, error: signErr } = await sb.storage
      .from("releases")
      .createSignedUrl(rel.file_path, SIGNED_URL_TTL_S);
    if (signErr || !signed?.signedUrl) return fail("internal");

    return reply(200, successBody(rel, signed.signedUrl));
  } catch (_e) {
    // Текст исключения наружу и в журнал не пишем (мог бы содержать
    // фрагменты запроса).
    return fail("internal");
  }
});
