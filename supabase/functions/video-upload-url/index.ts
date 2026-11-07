// Edge Function video-upload-url (VIDEO1): выдаёт браузеру ОДНОРАЗОВУЮ
// подписанную ссылку на загрузку видео в закрытый бакет device-videos.
//
//   OPTIONS /functions/v1/video-upload-url  → 204 (предзапрос браузера, CORS)
//   POST /functions/v1/video-upload-url
//        Authorization: Bearer <JWT клиента или супервайзера>
//        {"video_id":"<uuid строки pending_upload>"}
//   200 → {"ok":true,"path":"<device>/<video>.mp4","signed_url":"https://…","token":"…"}
//   4xx → {"ok":false,"error":"<код>"}
//
// Права проверяет БАЗА под JWT вызывающего (video_access_check): клиент —
// только свой аппарат, супервайзер — любой, но с 2FA. Файл браузер грузит
// сам по этой ссылке; пока функция video-validate не проверит содержимое,
// видео в статусе pending_upload/validating и аппарату не выдаётся.
//
// Ссылка одноразовая: createSignedUploadUrl без upsert, повторная загрузка
// в тот же путь не пройдёт. Срок токена задаёт Storage (2 часа).
//
// Развёртывание БЕЗ --no-verify-jwt. CORS — ../_shared/cors.ts. Ключи и
// токены в журнал и ответы не пишутся (кроме токена загрузки в ответе
// самому вызвавшему).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { jsonResponse, preflightResponse } from "../_shared/cors.ts";
import {
  BUCKET,
  errorResponse,
  parseVideoId,
  readAccess,
  storagePath,
} from "../_shared/video_rules.ts";
import { readSigned, successBody, uploadBlocker } from "./logic.ts";

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  if (req.method === "OPTIONS") return preflightResponse(origin);

  const fail = (code: Parameters<typeof errorResponse>[0], details?: unknown): Response => {
    const e = errorResponse(code, details);
    return jsonResponse(e.status, e.body, origin);
  };
  if (req.method !== "POST") return fail("method");

  try {
    const auth = req.headers.get("Authorization") ?? "";
    if (!auth.toLowerCase().startsWith("bearer ")) return fail("auth");

    const url = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !anonKey || !serviceKey) return fail("internal");

    let raw: unknown;
    try {
      raw = await req.json();
    } catch {
      return fail("bad_request");
    }
    const videoId = parseVideoId(raw);
    if (videoId === null) return fail("bad_request");

    // 1. Права — в базе, под JWT вызывающего.
    const asCaller = createClient(url, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: auth } },
    });
    const { data: accRaw, error: accErr } = await asCaller.rpc("video_access_check", {
      p_video: videoId,
    });
    if (accErr) return fail("auth");
    const acc = readAccess(accRaw);
    if (!acc.ok) return fail(acc.code);
    const blocker = uploadBlocker(acc.access);
    if (blocker) return fail(blocker);

    const path = storagePath(acc.access.deviceId, acc.access.videoId);
    if (path === null) return fail("internal");

    // 2. Одноразовая ссылка на загрузку (без upsert).
    const sb = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await sb.storage.from(BUCKET).createSignedUploadUrl(path);
    const signed = error ? null : readSigned(data);
    if (!signed) return fail("unavailable");

    return jsonResponse(200, successBody(path, signed.signedUrl, signed.token), origin);
  } catch (_e) {
    return fail("internal");
  }
});
