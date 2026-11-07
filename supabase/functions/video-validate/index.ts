// Edge Function video-validate (VIDEO1): проверяет загруженное в бакет
// видео ПО СОДЕРЖИМОМУ, не скачивая файл целиком.
//
//   OPTIONS /functions/v1/video-validate  → 204 (предзапрос браузера, CORS)
//   POST /functions/v1/video-validate
//        Authorization: Bearer <JWT клиента или супервайзера>
//        {"video_id":"<uuid>"}
//   200 → {"ok":true,"status":"ready","video":{"width","height","duration_ms","has_audio"}}
//   422 → {"ok":false,"error":"rejected","details":{"reason":"<код[:подробности]>"}}
//         файл удалён из бакета, строка помечена rejected
//   409 → {"ok":false,"error":"not_uploaded"}   файла в бакете ещё нет (строка не меняется)
//   4xx/5xx → {"ok":false,"error":"<код>"}
//
// Как читается файл: подписанная ссылка на 10 минут и запросы Range —
// заголовки боксов (по 16 байт) и целиком moov (logic.ts). Тело mdat
// (почти весь файл) не читается.
//
// Чего функция НЕ делает: не считает sha256 всего файла (для этого пришлось
// бы скачать его целиком, у Edge Function на это нет ни времени, ни памяти).
// sha256 считает браузер потоково и передаёт при video_upload_begin;
// сверяет его аппарат после скачивания. Неверный хеш приведёт только к
// failed:sha256 на аппарате — чужому файл не повредит.
//
// Права проверяет БАЗА под JWT вызывающего (video_access_check). Развёртывание
// БЕЗ --no-verify-jwt. CORS — ../_shared/cors.ts.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { jsonResponse, preflightResponse } from "../_shared/cors.ts";
import {
  BUCKET,
  errorResponse,
  parseVideoId,
  readAccess,
  readOk,
  storagePath,
} from "../_shared/video_rules.ts";
import {
  judge,
  parseMp4,
  rangeHeader,
  rejectReason,
  totalFromContentRange,
} from "./logic.ts";

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
    const a = acc.access;
    if (a.status !== "pending_upload" && a.status !== "validating") return fail("bad_status");

    const path = storagePath(a.deviceId, a.videoId);
    if (path === null) return fail("internal");

    const sb = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // 2. Ссылка для чтения диапазонов и размер объекта.
    const { data: signed, error: signErr } = await sb.storage.from(BUCKET).createSignedUrl(path, 600);
    if (signErr || !signed?.signedUrl) return fail("unavailable");
    const fileUrl = signed.signedUrl;

    const head = await fetch(fileUrl, { headers: { Range: rangeHeader(0, 1) } });
    if (head.status === 400 || head.status === 404) {
      await head.body?.cancel();
      return fail("not_uploaded");
    }
    if (head.status !== 206 && head.status !== 200) {
      await head.body?.cancel();
      return fail("unavailable");
    }
    // 206: размер — в Content-Range; 200 (Range проигнорирован): в Content-Length.
    const objectSize = head.status === 206
      ? totalFromContentRange(head.headers.get("content-range"))
      : Number(head.headers.get("content-length"));
    await head.body?.cancel();
    if (objectSize === null || !Number.isSafeInteger(objectSize)) return fail("unavailable");

    // Дальше работаем с файлом: помечаем «проверяется» (повтор допустим).
    const { data: markRaw, error: markErr } = await sb.rpc("_video_mark_validating", {
      p_video: a.videoId,
    });
    if (markErr || !readOk(markRaw)) return fail("bad_status");

    // 3. Чтение диапазонов и разбор.
    const read = async (start: number, end: number): Promise<Uint8Array> => {
      const r = await fetch(fileUrl, { headers: { Range: rangeHeader(start, end) } });
      if (r.status !== 206 && !(r.status === 200 && start === 0)) {
        await r.body?.cancel();
        throw new Error("range_failed");
      }
      const buf = new Uint8Array(await r.arrayBuffer());
      return r.status === 200 ? buf.subarray(start, end) : buf;
    };

    let verdict;
    try {
      const parsed = await parseMp4(objectSize, read);
      verdict = judge(a.sizeBytes, objectSize, parsed, a.hardwareProfile);
    } catch (_e) {
      // Хранилище не ответило на чтение — не вина файла.
      await sb.rpc("_video_mark_failed", { p_video: a.videoId, p_reason: "storage_read" });
      return fail("unavailable");
    }

    if (verdict.kind === "reject") {
      const reason = rejectReason(verdict.code, verdict.detail);
      // Файл убираем сразу; запись rejected остаётся с причиной.
      await sb.storage.from(BUCKET).remove([path]);
      const { data: rejRaw, error: rejErr } = await sb.rpc("_video_mark_rejected", {
        p_video: a.videoId, p_actor: a.actor, p_role: a.role, p_reason: reason,
      });
      if (rejErr || !readOk(rejRaw)) return fail("internal");
      return fail("rejected", { reason });
    }

    const info = verdict.info;
    const { data: okRaw, error: okErr } = await sb.rpc("_video_mark_validated", {
      p_video: a.videoId,
      p_actor: a.actor,
      p_role: a.role,
      p_width: info.width,
      p_height: info.height,
      p_duration_ms: info.durationMs,
      p_has_audio: info.hasAudio,
    });
    if (okErr || !readOk(okRaw)) return fail("internal");

    return jsonResponse(200, {
      ok: true,
      status: "ready",
      video: {
        width: info.width,
        height: info.height,
        duration_ms: info.durationMs,
        has_audio: info.hasAudio,
      },
    }, origin);
  } catch (_e) {
    return fail("internal");
  }
});
