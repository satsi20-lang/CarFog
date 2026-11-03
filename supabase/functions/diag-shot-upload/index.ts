// Edge Function diag-shot-upload (RD1): аппарат кладёт снимок своего экрана
// в ЗАКРЫТЫЙ бакет diag-shots.
//
//   POST /functions/v1/diag-shot-upload
//        {"device","token","shot":"shot-<мс>","jpeg_b64":"<JPEG base64>"}
//   200 → {"ok":true,"shot_id","bytes"}
//   4xx/5xx → {"ok":false,"error":"<короткий код>"}   (без подробностей)
//
// Почему приём base64, а не подписанная ссылка на загрузку: аппарат не
// получает никаких прав на Storage и ссылки, по которой можно было бы
// положить что угодно; функция сама проверяет, что это JPEG до 400 КБ, и
// пишет файл по пути, который выдала база. Токен проверяет
// device_shot_register (device_token_valid внутри), частоту и квоту — тоже
// она. Сервисный ключ — из окружения функции. Токен и ключи НЕ пишутся ни в
// журнал, ни в ответы.
//
// Развёртывание — с флагом --no-verify-jwt (как release-url): приложение
// вызывает функцию с публичным ключом, подлинность устройства проверяет
// токен.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  errorResponse,
  parseInput,
  registerError,
  removablePaths,
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

    // 1. Токен, форма, частота, квота — в базе.
    const { data: reg, error: regErr } = await sb.rpc("device_shot_register", {
      p_device: input.device,
      p_token: input.token,
      p_shot: input.shot,
      p_bytes: input.jpeg.length,
    });
    if (regErr) return fail("internal");
    const denied = registerError(reg);
    if (denied !== null) return fail(denied);
    const path = (reg as { path: string }).path;

    // 2. Файл в закрытый бакет.
    const { error: upErr } = await sb.storage
      .from("diag-shots")
      .upload(path, input.jpeg, { contentType: "image/jpeg", upsert: true });
    if (upErr) {
      await sb.rpc("device_shot_forget", { p_device: input.device, p_shot: input.shot });
      return fail("internal");
    }

    // 3. Старые файлы сверх квоты и просроченные (не страшно, если не
    //    удалятся: их подберёт ежесуточная diag-shot-purge).
    const old = removablePaths(reg);
    if (old.length > 0) await sb.storage.from("diag-shots").remove(old);

    return reply(200, { ok: true, shot_id: input.shot, bytes: input.jpeg.length });
  } catch (_e) {
    return fail("internal");
  }
});
