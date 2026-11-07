// Edge Function video-purge (VIDEO1): ежесуточно убирает из закрытого
// бакета device-videos файлы удалённых, отклонённых и брошенных видео.
// Вызывает pg_cron через pg_net (20261109000100_video1_cron.sql) с секретом
// в заголовке x-purge-secret — ТЕМ ЖЕ, что у diag-shot-purge
// (переменная DIAG_PURGE_SECRET, запись diag_purge_secret в Vault).
// Без верного секрета — 401, ничего не удаляется.
//
//   POST /functions/v1/video-purge   (заголовок x-purge-secret)
//   200 → {"ok":true,"removed":<число>}
//
// Развёртывание — с флагом --no-verify-jwt: вызывает база, не пользователь.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { BUCKET } from "../_shared/video_rules.ts";
import { batches, pickedItems, secretMatches } from "./logic.ts";

const JSON_HEADERS = { "Content-Type": "application/json" };
function reply(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply(405, { ok: false, error: "method" });
  if (!secretMatches(req.headers.get("x-purge-secret"), Deno.env.get("DIAG_PURGE_SECRET"))) {
    return reply(401, { ok: false, error: "auth" });
  }
  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) return reply(500, { ok: false, error: "internal" });
    const sb = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await sb.rpc("_video_purge_pick", { p_limit: 200 });
    if (error) return reply(500, { ok: false, error: "internal" });
    const items = pickedItems(data);
    let removed = 0;
    const doneIds: string[] = [];
    for (const part of batches(items)) {
      const { error: rmErr } = await sb.storage.from(BUCKET).remove(part.map((x) => x.path));
      // Storage молча пропускает уже отсутствующие файлы, так что успех
      // можно отмечать для всей пачки.
      if (!rmErr) {
        removed += part.length;
        doneIds.push(...part.map((x) => x.id));
      }
    }
    if (doneIds.length > 0) {
      await sb.rpc("_video_purge_done", { p_ids: doneIds });
    }
    return reply(200, { ok: true, removed });
  } catch (_e) {
    return reply(500, { ok: false, error: "internal" });
  }
});
