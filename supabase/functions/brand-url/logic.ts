// Чистая логика Edge Function brand-url (без сети и без Deno API), чтобы её
// можно было проверять обычными тестами (logic_test.ts).
// По образцу functions/release-url/logic.ts.

/** Срок жизни подписанной ссылки на архив бренда, с. ТЗ: 5 минут. */
export const SIGNED_URL_TTL_S = 300;

export interface Input {
  device: string;
  token: string;
}

/** Разбор тела запроса. null — вход неверный (подробности наружу не отдаём). */
export function parseInput(body: unknown): Input | null {
  if (typeof body !== "object" || body === null) return null;
  const b = body as Record<string, unknown>;
  const { device, token } = b;
  if (typeof device !== "string" || device.length < 1 || device.length > 64) {
    return null;
  }
  if (typeof token !== "string" || token.length < 8 || token.length > 256) {
    return null;
  }
  return { device, token };
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

/**
 * Ответ об ошибке: ТОЛЬКО короткий код. Для неверного токена и для
 * несуществующего аппарата — один и тот же 'auth'.
 */
export function errorResponse(code: ErrorCode): {
  status: number;
  body: { ok: false; error: ErrorCode };
} {
  return { status: STATUS[code], body: { ok: false, error: code } };
}

/** Что вернула device_brand_get. */
export interface BrandRow {
  id: string;
  version: number;
  sha256: string;
  size_bytes: number;
}

export type GetOutcome =
  | { kind: "error"; code: ErrorCode }
  | { kind: "none" }            // бренда нет: аппарат показывает встроенный CaRFog
  | { kind: "brand"; brand: BrandRow };

/** Разбор ответа device_brand_get. Чужие и битые ответы = 'internal'. */
export function readBrandGet(raw: unknown): GetOutcome {
  if (typeof raw !== "object" || raw === null) return { kind: "error", code: "internal" };
  const r = raw as Record<string, unknown>;
  if (r.ok !== true) {
    const e = typeof r.error === "string" ? r.error : "";
    if (e === "auth") return { kind: "error", code: "auth" };
    if (e === "rate_limited") return { kind: "error", code: "rate_limited" };
    return { kind: "error", code: "internal" };
  }
  const b = r.brand;
  if (b === null || b === undefined) return { kind: "none" };
  if (!isBrandRow(b)) return { kind: "error", code: "internal" };
  return { kind: "brand", brand: b };
}

export function isBrandRow(b: unknown): b is BrandRow {
  if (typeof b !== "object" || b === null) return false;
  const x = b as Record<string, unknown>;
  return typeof x.id === "string" && x.id.length > 0 &&
    typeof x.version === "number" && Number.isInteger(x.version) && x.version >= 1 &&
    typeof x.sha256 === "string" && /^[0-9a-f]{64}$/.test(x.sha256) &&
    typeof x.size_bytes === "number" && x.size_bytes > 0;
}

/** Разбор ответа device_brand_path. null — пути нет. */
export function readBrandPath(raw: unknown): string | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  if (r.ok !== true || typeof r.path !== "string" || r.path.length === 0) return null;
  // Путь в бакете всегда '<brand>/v<версия>.zip'. Ничего другого не
  // подписываем, даже если база когда-нибудь отдаст иное.
  return /^[a-z0-9][a-z0-9_-]{1,30}\/v[0-9]{1,9}\.zip$/.test(r.path) ? r.path : null;
}

/**
 * Успешный ответ. Путь в бакете наружу НЕ отдаётся — только подписанная
 * ссылка. brand: null — бренда у аппарата нет (встроенный CaRFog).
 */
export function successBody(
  brand: BrandRow | null,
  url: string | null,
  ttlS: number = SIGNED_URL_TTL_S,
) {
  if (brand === null || url === null) return { ok: true as const, brand: null };
  return {
    ok: true as const,
    brand: {
      id: brand.id,
      version: brand.version,
      sha256: brand.sha256,
      size_bytes: brand.size_bytes,
      url,
    },
    expires_in_s: ttlS,
  };
}
