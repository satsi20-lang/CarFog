// Общие правила видео (VIDEO1) для Edge Functions video-upload-url и
// video-validate: разбор запроса, ответ базы video_access_check, путь в
// бакете, коды ошибок. Чистая логика, без сети и Deno API — проверяется
// обычными тестами (video_rules_test.ts: node --test).

export const BUCKET = "device-videos";

/** uuid в нижнем регистре, как отдаёт база. */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** id аппарата: те же пределы, что у device в других функциях (1–64 знака). */
const DEVICE_RE = /^[A-Za-z0-9_-]{1,64}$/;

export function isUuid(v: unknown): v is string {
  return typeof v === "string" && UUID_RE.test(v);
}

/** Путь в бакете: <device_id>/<video_id>.mp4 (ТЗ 3.1). null — вход неверный. */
export function storagePath(deviceId: unknown, videoId: unknown): string | null {
  if (typeof deviceId !== "string" || !DEVICE_RE.test(deviceId)) return null;
  if (!isUuid(videoId)) return null;
  return `${deviceId}/${videoId}.mp4`;
}

/** Тело запроса портала: {"video_id":"<uuid>"}. null — неверно. */
export function parseVideoId(body: unknown): string | null {
  if (typeof body !== "object" || body === null) return null;
  const id = (body as Record<string, unknown>).video_id;
  return isUuid(id) ? id : null;
}

export type ErrorCode =
  | "method"
  | "bad_request"
  | "auth"
  | "forbidden"
  | "mfa_required"
  | "not_found"
  | "bad_status"
  | "not_uploaded"
  | "rejected"
  | "unavailable"
  | "internal";

const STATUS: Record<ErrorCode, number> = {
  method: 405,
  bad_request: 400,
  auth: 401,
  forbidden: 403,
  mfa_required: 403,
  not_found: 404,
  bad_status: 409,
  not_uploaded: 409,
  rejected: 422,
  unavailable: 503,
  internal: 500,
};

/** Ответ об ошибке: короткий код и, где нужно, безопасные подробности. */
export function errorResponse(code: ErrorCode, details?: unknown): {
  status: number;
  body: { ok: false; error: ErrorCode; details?: unknown };
} {
  const body: { ok: false; error: ErrorCode; details?: unknown } = { ok: false, error: code };
  if (details !== undefined) body.details = details;
  return { status: STATUS[code], body };
}

export type Role = "customer" | "supervisor";

export interface Access {
  actor: string;
  role: Role;
  videoId: string;
  deviceId: string;
  status: string;
  sizeBytes: number;
  hardwareProfile: string;
}

export type AccessOutcome =
  | { ok: true; access: Access }
  | { ok: false; code: ErrorCode };

/** Разбор ответа video_access_check. Чужие и битые ответы = 'internal'. */
export function readAccess(raw: unknown): AccessOutcome {
  if (typeof raw !== "object" || raw === null) return { ok: false, code: "internal" };
  const r = raw as Record<string, unknown>;
  if (r.ok !== true) {
    switch (r.error) {
      case "forbidden": return { ok: false, code: "forbidden" };
      case "mfa_required": return { ok: false, code: "mfa_required" };
      case "not_found": return { ok: false, code: "not_found" };
      case "bad_status": return { ok: false, code: "bad_status" };
      default: return { ok: false, code: "internal" };
    }
  }
  const role = r.role;
  if (role !== "customer" && role !== "supervisor") return { ok: false, code: "internal" };
  if (!isUuid(r.actor) || !isUuid(r.video_id)) return { ok: false, code: "internal" };
  if (typeof r.device_id !== "string" || !DEVICE_RE.test(r.device_id)) {
    return { ok: false, code: "internal" };
  }
  if (typeof r.status !== "string") return { ok: false, code: "internal" };
  const size = typeof r.size_bytes === "number" ? r.size_bytes
    : typeof r.size_bytes === "string" ? Number(r.size_bytes) : NaN;
  if (!Number.isSafeInteger(size) || size < 1) return { ok: false, code: "internal" };
  const profile = typeof r.hardware_profile === "string" ? r.hardware_profile : "";
  return {
    ok: true,
    access: {
      actor: r.actor,
      role,
      videoId: r.video_id,
      deviceId: r.device_id,
      status: r.status,
      sizeBytes: size,
      hardwareProfile: profile,
    },
  };
}

/** Разбор простого ответа функции базы {ok:true} / {ok:false,error}. */
export function readOk(raw: unknown): boolean {
  return typeof raw === "object" && raw !== null && (raw as Record<string, unknown>).ok === true;
}
