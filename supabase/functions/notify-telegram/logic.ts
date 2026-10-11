// Чистая логика Edge Function notify-telegram (без сети и без Deno API), чтобы
// её можно было проверять обычными тестами (logic_test.ts).

// Аппарат считается без связи, если last_seen_at старше 10 минут. ЗАДАНО
// владельцем.
export const OFFLINE_AFTER_MS = 10 * 60_000;

// Не чаще одного сообщения одного вида на аппарат в 5 минут. ЗАДАНО
// владельцем.
export const DEDUP_WINDOW_MS = 5 * 60_000;

// ---------- Проверка секрета ----------

// Сравнение с постоянным временем: время не зависит от того, в каком месте
// строки первое расхождение. Длина ожидаемого секрета не скрывается (это не
// требуется), но цикл идёт по большей из длин. Пустой ожидаемый секрет —
// всегда отказ (функция без настроенного секрета не должна быть открыта).
export function secretMatches(
  given: string | null | undefined,
  expected: string | null | undefined,
): boolean {
  if (!expected) return false;
  const enc = new TextEncoder();
  const a = enc.encode(given ?? "");
  const b = enc.encode(expected);
  const n = Math.max(a.length, b.length);
  let diff = a.length ^ b.length;
  for (let i = 0; i < n; i++) {
    diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  }
  return diff === 0;
}

// ---------- Разбор входа ----------

export interface EventRecord {
  id?: unknown;
  device_id: string;
  org_id: string | null;
  type: string;
  data: Record<string, unknown>;
}

export type NotifyRequest =
  | { mode: "event"; record: EventRecord }
  | { mode: "offline_check" }
  | { mode: "whoami" }
  | { mode: "test"; org_id: string }
  // Запись вебхука не о вставке (UPDATE/DELETE) — ответить 200 и ничего не
  // делать.
  | { mode: "ignore" };

// Режим берётся из поля mode; тело Database Webhook (type/table/record) без
// mode считается режимом event. null — вход неверный.
export function parseRequest(body: unknown): NotifyRequest | null {
  if (typeof body !== "object" || body === null) return null;
  const b = body as Record<string, unknown>;
  const mode = b.mode ?? (b.table === "events" && "record" in b ? "event" : undefined);
  switch (mode) {
    case "offline_check":
      return { mode: "offline_check" };
    case "whoami":
      return { mode: "whoami" };
    case "test":
      return typeof b.org_id === "string" && b.org_id.length > 0
        ? { mode: "test", org_id: b.org_id }
        : null;
    case "event": {
      if (b.type !== undefined && b.type !== "INSERT") return { mode: "ignore" };
      const r = b.record;
      if (typeof r !== "object" || r === null) return null;
      const rec = r as Record<string, unknown>;
      if (typeof rec.device_id !== "string" || rec.device_id.length === 0) return null;
      if (typeof rec.type !== "string") return null;
      const data = typeof rec.data === "object" && rec.data !== null && !Array.isArray(rec.data)
        ? rec.data as Record<string, unknown>
        : {};
      return {
        mode: "event",
        record: {
          id: rec.id,
          device_id: rec.device_id,
          org_id: typeof rec.org_id === "string" ? rec.org_id : null,
          type: rec.type,
          data,
        },
      };
    }
    default:
      return null;
  }
}

// ---------- Тексты ----------

// parse_mode HTML: экранировать нужно &, <, > (кавычка — на случай
// атрибутов, вреда нет).
export function escapeHtml(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

// Имя аппарата: devices.name, если пусто — id.
export function deviceName(id: string, name: string | null | undefined): string {
  const n = typeof name === "string" ? name.trim() : "";
  return n.length > 0 ? n : id;
}

// Причины вывода из обслуживания — тексты из сервисного меню (oos_code_*,
// русский, lib/screens/service/service_menu.dart). Неизвестный код
// показывается как есть.
export const OOS_REASON_RU: Record<string, string> = {
  heater_no_power: "отказ нагрева (ТЭН не дал мощности)",
  temp_sensor_fault: "отказ датчика температуры / убегающий нагрев",
  heat_timeout: "прогрев не достиг цели за 180 с",
  heater_off_unconfirmed: "выключение ТЭНа не подтверждено (возможно, залипло реле)",
  overheat: "перегрев (ТЭН не выключается или не работает термостат)",
  output_stuck_on: "выход остаётся включённым после аварийного выключения",
  state_unreadable: "состояние не читается (fail-closed при старте)",
  bus_down: "шина не отвечает (снимется само, когда ответы вернутся)",
};

export const EVENT_TYPES = ["low_liquid", "liquid_restored", "out_of_service"] as const;

export function isNotifiableType(t: string): boolean {
  return (EVENT_TYPES as readonly string[]).includes(t);
}

function channelOf(data: Record<string, unknown>): number | null {
  const c = data.channel;
  return typeof c === "number" && Number.isInteger(c) ? c : null;
}

// Название жидкости: flavor, если пусто — «канал N» (channel с нуля, людям
// показываем с единицы).
function flavorOf(data: Record<string, unknown>): string {
  const f = typeof data.flavor === "string" ? data.flavor.trim() : "";
  if (f.length > 0) return f;
  const c = channelOf(data);
  return c !== null ? `канал ${c + 1}` : "?";
}

// Текст сообщения о событии; null — о таком событии не сообщаем. name —
// уже выбранное имя (deviceName), экранируется здесь.
export function eventMessage(
  type: string,
  name: string,
  data: Record<string, unknown>,
): string | null {
  const n = escapeHtml(name);
  switch (type) {
    case "low_liquid":
      return `⚠️ ${n}: закончилась жидкость «${escapeHtml(flavorOf(data))}»`;
    case "liquid_restored":
      return `✅ ${n}: жидкость «${escapeHtml(flavorOf(data))}» пополнена`;
    case "out_of_service": {
      const code = typeof data.code === "string" ? data.code : "";
      if (code === "overheat") {
        return `🔥 ${n}: аппарат выведен из обслуживания: перегрев`;
      }
      const reason = OOS_REASON_RU[code] ?? (code || "причина не указана");
      return `⛔ ${n}: аппарат выведен из обслуживания: ${escapeHtml(reason)}`;
    }
    default:
      return null;
  }
}

export function offlineMessage(name: string, minutes: number): string {
  return `📴 ${escapeHtml(name)}: нет связи уже ${minutes} мин`;
}

export function onlineMessage(name: string): string {
  return `✅ ${escapeHtml(name)}: связь восстановлена`;
}

export const TEST_MESSAGE = "Проверка связи";

// ---------- Защита от повторов ----------

// Ключ вида сообщения: аппарат + тип + канал (у out_of_service канала нет).
export function dedupKey(deviceId: string, type: string, data: Record<string, unknown>): string {
  const c = channelOf(data);
  return `${deviceId}|${type}|${c ?? ""}`;
}

// Можно ли слать: lastSentMs — время прошлой отправки по этому ключу.
export function dedupAllows(
  lastSentMs: number | null,
  nowMs: number,
  windowMs: number = DEDUP_WINDOW_MS,
): boolean {
  if (lastSentMs === null || Number.isNaN(lastSentMs)) return true;
  const elapsed = nowMs - lastSentMs;
  // elapsed < 0 — часы сервера ушли назад: не молчим навсегда.
  return elapsed >= windowMs || elapsed < 0;
}

// ---------- «Нет связи» / «связь восстановлена» ----------

export interface DeviceRow {
  id: string;
  org_id: string | null;
  name: string | null;
  last_seen_at: string | null;
}

export interface OfflinePlan {
  // Новые «нет связи»: аппарат молчит дольше порога, сообщения ещё не было.
  wentOffline: { device: DeviceRow; minutes: number }[];
  // Связь вернулась после сообщения «нет связи».
  cameBack: DeviceRow[];
}

// stateIds — аппараты с записью в notify_offline_state. Аппараты без
// last_seen_at (ни разу не выходили на связь) пропускаются. Записи о
// неизвестных (удалённых) аппаратах не трогаем.
export function planOffline(
  devices: DeviceRow[],
  stateIds: Set<string>,
  nowMs: number,
  offlineAfterMs: number = OFFLINE_AFTER_MS,
): OfflinePlan {
  const plan: OfflinePlan = { wentOffline: [], cameBack: [] };
  for (const d of devices) {
    if (!d.last_seen_at) continue;
    const seen = Date.parse(d.last_seen_at);
    if (Number.isNaN(seen)) continue;
    const silentMs = nowMs - seen;
    const offline = silentMs > offlineAfterMs;
    const notified = stateIds.has(d.id);
    if (offline && !notified) {
      plan.wentOffline.push({ device: d, minutes: Math.floor(silentMs / 60_000) });
    } else if (!offline && notified) {
      plan.cameBack.push(d);
    }
  }
  return plan;
}

// ---------- whoami ----------

export interface ChatInfo {
  id: number | string;
  title: string | null;
  type: string;
}

// Чаты из ответа getUpdates (result[]): из сообщений, постов каналов и
// событий о добавлении бота. Только id, название и тип, без повторов.
export function extractChats(updates: unknown): ChatInfo[] {
  if (!Array.isArray(updates)) return [];
  const seen = new Map<string, ChatInfo>();
  for (const u of updates) {
    if (typeof u !== "object" || u === null) continue;
    const upd = u as Record<string, unknown>;
    const holders = [
      upd.message,
      upd.edited_message,
      upd.channel_post,
      upd.edited_channel_post,
      upd.my_chat_member,
      upd.chat_member,
      upd.chat_join_request,
      (upd.callback_query as Record<string, unknown> | undefined)?.message,
    ];
    for (const h of holders) {
      if (typeof h !== "object" || h === null) continue;
      const chat = (h as Record<string, unknown>).chat;
      if (typeof chat !== "object" || chat === null) continue;
      const c = chat as Record<string, unknown>;
      if (typeof c.id !== "number" && typeof c.id !== "string") continue;
      const title = typeof c.title === "string"
        ? c.title
        : typeof c.username === "string"
        ? c.username
        : null;
      seen.set(String(c.id), {
        id: c.id,
        title,
        type: typeof c.type === "string" ? c.type : "unknown",
      });
    }
  }
  return [...seen.values()];
}

// ---------- Журнал ----------

// Вырезает известные секреты из любого текста (ошибка fetch может содержать
// адрес запроса с токеном бота).
export function redact(text: string, secrets: (string | undefined)[]): string {
  let out = text;
  for (const s of secrets) {
    if (s && s.length >= 6) out = out.split(s).join("***");
  }
  return out;
}
