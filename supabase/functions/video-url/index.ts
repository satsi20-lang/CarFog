// Edge Function video-url (VIDEO1): выдаёт аппарату подписанную ссылку на
// скачивание видео из ЗАКРЫТОГО бакета device-videos. По образцу brand-url.
//
//   POST /functions/v1/video-url   {"device":"...","token":"...","video":"<uuid>"}
//   200 → {"ok":true,"video":{"id","sha256","size_bytes","url"},"expires_in_s":21600}
//   4xx/5xx → {"ok":false,"error":"<короткий код>"}
//
// Токен аппарата проверяет device_video_path (device_token_valid внутри);
// она же отдаёт путь только для готового видео ЭТОГО аппарата и держит
// лимит частоты (раз в 10 с на видео). Путь в бакете наружу не отдаётся.
// Токен и ключи не пишутся ни в журнал, ни в ответы.
//
// Развёртывание — с флагом --no-verify-jwt (как brand-url): приложение
// вызывает функцию публичным ключом (это не JWT), подлинность аппарата
// проверяет токен. CORS не нужен: вызывает аппарат, не браузер.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { BUCKET } from "../_shared/video_rules.ts";
import {
  errorResponse,
  parseInput,
  readPath,
  SIGNED_URL_TTL_S,
  successBody,
} from "./logic.ts";

const JSON_HEADERS = { "Content-Type": "application/json" };

function reply(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}
function fail(code: Parameters<typeof errorResponse>[0]) {
  const e = errorResponse(code);
  return reply(e.status, e.body);
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

    const { data, error } = await sb.rpc("device_video_path", {
      p_device: input.device,
      p_token: input.token,
      p_video: input.video,
    });
    if (error) return fail("internal");
    const out = readPath(data);
    if (out.kind === "error") return fail(out.code);

    const { data: signed, error: signErr } = await sb.storage
      .from(BUCKET)
      .createSignedUrl(out.row.path, SIGNED_URL_TTL_S);
    if (signErr || !signed?.signedUrl) return fail("internal");

    return reply(200, successBody(out.row, signed.signedUrl, input.video));
  } catch (_e) {
    return fail("internal");
  }
});
