// Чистая логика Edge Function video-upload-url (VIDEO1).
import type { Access } from "../_shared/video_rules.ts";
import type { ErrorCode } from "../_shared/video_rules.ts";

/** Срок действия токена загрузки в Storage задаёт сама платформа (2 часа). */
export const UPLOAD_TOKEN_NOTE_S = 7200;

/** Ссылку на загрузку выдаём только пока видео ждёт файл. */
export function uploadBlocker(a: Pick<Access, "status">): ErrorCode | null {
  return a.status === "pending_upload" ? null : "bad_status";
}

/** Что отдаём порталу. Путь нужен ему для загрузки по подписанной ссылке. */
export function successBody(path: string, signedUrl: string, token: string) {
  return { ok: true as const, path, signed_url: signedUrl, token };
}

/** Достаём из ответа createSignedUploadUrl нужные поля. null — ответ негодный. */
export function readSigned(
  data: unknown,
): { signedUrl: string; token: string } | null {
  if (typeof data !== "object" || data === null) return null;
  const d = data as Record<string, unknown>;
  if (typeof d.signedUrl !== "string" || typeof d.token !== "string") return null;
  if (!/^https:\/\//.test(d.signedUrl) || d.token.length < 10) return null;
  return { signedUrl: d.signedUrl, token: d.token };
}
