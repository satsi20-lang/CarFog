// Edge Function diag-shot-purge (RD1): ежесуточно удаляет снимки экрана
// старше 24 часов из закрытого бакета diag-shots. Вызывает pg_cron через
// pg_net (20261104000100_rd1_cron.sql) с секретом в заголовке
// x-purge-secret; секрет — переменная DIAG_PURGE_SECRET функции (и запись
// diag_purge_secret в Vault). Без верного секрета — 401, ничего не
// удаляется.
//
//   POST /functions/v1/diag-shot-purge   (заголовок x-purge-secret)
//   200 → {"ok":true,"removed":<число>}
//
// Развёртывание — с флагом --no-verify-jwt: вызывает база, не пользователь.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { batches, expiredPaths, secretMatches } from "./logic.ts";

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
    const { data, error } = await sb.rpc("device_shot_expired");
    if (error) return reply(500, { ok: false, error: "internal" });
    const paths = expiredPaths(data);
    let removed = 0;
    for (const part of batches(paths)) {
      const { error: rmErr } = await sb.storage.from("diag-shots").remove(part);
      if (!rmErr) removed += part.length;
    }
    return reply(200, { ok: true, removed });
  } catch (_e) {
    return reply(500, { ok: false, error: "internal" });
  }
});
