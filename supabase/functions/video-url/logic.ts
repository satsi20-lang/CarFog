// Чистая логика Edge Function video-url (VIDEO1): ссылка на скачивание
// видео аппаратом. По образцу functions/brand-url/logic.ts.
import { isUuid } from "../_shared/video_rules.ts";

/**
 * Срок подписанной ссылки на скачивание, с: 6 часов. Обоснование: видео
 * не ограничено по размеру (ТЗ 2.3), а связь у аппарата — мобильная 4G;
 * 2 ГБ при 1 Мбит/с — около 4,5 часа. Ссылка привязана к одному файлу,
 * выдаётся только по токену аппарата и только для его же готового видео,
 * поэтому длинный срок мало что открывает. Если срок всё же вышел,
 * приложение запрашивает новую ссылку и докачивает с места обрыва.
 */
export const SIGNED_URL_TTL_S = 6 * 60 * 60;

export interface Input {
  device: string;
  token: string;
  video: string;
}

/** Разбор тела запроса. null — вход неверный. */
export function parseInput(body: unknown): Input | null {
  if (typeof body !== "object" || body === null) return null;
  const { device, token, video } = body as Record<string, unknown>;
  if (typeof device !== "string" || device.length < 1 || device.length > 64) return null;
  if (typeof token !== "string" || token.length < 8 || token.length > 256) return null;
  if (!isUuid(video)) return null;
  return { device, token, video };
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

/** Ответ об ошибке: только короткий код (неверный токен и чужое видео не различаем по тексту). */
export function errorResponse(code: ErrorCode): {
  status: number;
  body: { ok: false; error: ErrorCode };
} {
  return { status: STATUS[code], body: { ok: false, error: code } };
}

export interface PathRow {
  path: string;
  sha256: string;
  size_bytes: number;
}

export type PathOutcome =
  | { kind: "error"; code: ErrorCode }
  | { kind: "path"; row: PathRow };

/** Разбор ответа device_video_path. Путь — только вида <device>/<uuid>.mp4. */
export function readPath(raw: unknown): PathOutcome {
  if (typeof raw !== "object" || raw === null) return { kind: "error", code: "internal" };
  const r = raw as Record<string, unknown>;
  if (r.ok !== true) {
    switch (r.error) {
      case "auth": return { kind: "error", code: "auth" };
      case "rate_limited": return { kind: "error", code: "rate_limited" };
      case "not_found": return { kind: "error", code: "not_found" };
      default: return { kind: "error", code: "internal" };
    }
  }
  if (typeof r.path !== "string" ||
      !/^[A-Za-z0-9_-]{1,64}\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.mp4$/.test(r.path)) {
    return { kind: "error", code: "internal" };
  }
  if (typeof r.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(r.sha256)) {
    return { kind: "error", code: "internal" };
  }
  const size = typeof r.size_bytes === "number" ? r.size_bytes
    : typeof r.size_bytes === "string" ? Number(r.size_bytes) : NaN;
  if (!Number.isSafeInteger(size) || size < 1) return { kind: "error", code: "internal" };
  return { kind: "path", row: { path: r.path, sha256: r.sha256, size_bytes: size } };
}

/** Успешный ответ. Путь в бакете наружу НЕ отдаётся. */
export function successBody(row: PathRow, url: string, id: string, ttlS: number = SIGNED_URL_TTL_S) {
  return {
    ok: true as const,
    video: { id, sha256: row.sha256, size_bytes: row.size_bytes, url },
    expires_in_s: ttlS,
  };
}
