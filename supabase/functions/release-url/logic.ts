// Чистая логика Edge Function release-url (без сети и без Deno API), чтобы её
// можно было проверять обычными тестами (logic_test.ts).

// Срок жизни подписанной ссылки, с. ЗАДАНО владельцем: 10 минут.
export const SIGNED_URL_TTL_S = 600;

// Не чаще одного запроса ссылки в минуту на устройство. НЕ ИЗМЕРЕНО.
export const MIN_INTERVAL_MS = 60_000;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface Input {
  device: string;
  token: string;
  release: string;
}

// Разбор тела запроса. null — вход неверный (подробности наружу не отдаём).
export function parseInput(body: unknown): Input | null {
  if (typeof body !== "object" || body === null) return null;
  const b = body as Record<string, unknown>;
  const { device, token, release } = b;
  if (typeof device !== "string" || device.length < 1 || device.length > 64) {
    return null;
  }
  if (typeof token !== "string" || token.length < 8 || token.length > 256) {
    return null;
  }
  if (typeof release !== "string" || !UUID_RE.test(release)) return null;
  return { device, token, release };
}

export interface RateDecision {
  allowed: boolean;
  retryAfterS: number;
}

// Решение по частоте: lastAtMs — время прошлого запроса этого устройства.
export function rateDecision(
  lastAtMs: number | null,
  nowMs: number,
  minIntervalMs: number = MIN_INTERVAL_MS,
): RateDecision {
  if (lastAtMs === null) return { allowed: true, retryAfterS: 0 };
  const elapsed = nowMs - lastAtMs;
  if (elapsed >= minIntervalMs || elapsed < 0) {
    // elapsed < 0 — часы сервера ушли назад: не блокируем навсегда.
    return { allowed: true, retryAfterS: 0 };
  }
  return {
    allowed: false,
    retryAfterS: Math.ceil((minIntervalMs - elapsed) / 1000),
  };
}

export type ErrorCode =
  | "method"
  | "bad_request"
  | "auth"
  | "rate_limited"
  | "not_found"
  | "internal";

const STATUS: Record<ErrorCode, number> = {
  method: 405,
  bad_request: 400,
  auth: 401,
  rate_limited: 429,
  not_found: 404,
  internal: 500,
};

// Ответ об ошибке: ТОЛЬКО короткий код, без причин, токена, ключей и текста
// исключений. Для неверного токена и для несуществующего устройства — один
// и тот же ответ 'auth' (не раскрываем, какие устройства существуют).
export function errorResponse(code: ErrorCode): {
  status: number;
  body: { ok: false; error: ErrorCode };
} {
  return { status: STATUS[code], body: { ok: false, error: code } };
}

export interface ReleaseRow {
  ok: boolean;
  version_name?: string;
  version_code?: number;
  file_path?: string;
  sha256?: string;
  size_bytes?: number;
}

export function isUsableRelease(r: unknown): r is Required<ReleaseRow> {
  if (typeof r !== "object" || r === null) return false;
  const x = r as ReleaseRow;
  return x.ok === true &&
    typeof x.file_path === "string" && x.file_path.length > 0 &&
    typeof x.sha256 === "string" && /^[0-9a-f]{64}$/.test(x.sha256) &&
    typeof x.size_bytes === "number" && x.size_bytes > 0 &&
    typeof x.version_code === "number" &&
    typeof x.version_name === "string";
}

// Успешный ответ: ссылка, контрольная сумма и размер. file_path (внутреннее
// имя файла в бакете) наружу НЕ отдаётся.
export function successBody(
  rel: Required<ReleaseRow>,
  url: string,
  ttlS: number = SIGNED_URL_TTL_S,
) {
  return {
    ok: true as const,
    url,
    sha256: rel.sha256,
    size_bytes: rel.size_bytes,
    version_code: rel.version_code,
    version_name: rel.version_name,
    expires_in_s: ttlS,
  };
}

// Для журнала функции: вырезает известные секреты из любого текста.
export function redact(text: string, secrets: string[]): string {
  let out = text;
  for (const s of secrets) {
    if (s && s.length >= 6) out = out.split(s).join("***");
  }
  return out;
}
