// Edge Function brand-url (BRAND1): выдаёт аппарату короткоживущую
// подписанную ссылку на архив бренда из ЗАКРЫТОГО бакета brand-packs.
// По образцу functions/release-url.
//
//   POST /functions/v1/brand-url   {"device": "...", "token": "..."}
//   200 → {"ok":true,"brand":{"id","version","sha256","size_bytes","url"},
//          "expires_in_s":300}
//   200 → {"ok":true,"brand":null}        бренда нет: встроенный CaRFog
//   4xx/5xx → {"ok":false,"error":"<короткий код>"}   (без подробностей)
//
// Токен аппарата проверяет device_brand_get (device_token_valid внутри), она
// же держит лимит частоты — не чаще раза в 30 с на аппарат. Путь файла в
// бакете наружу не отдаётся. Сервисный ключ — из окружения функции
// (Supabase подставляет SUPABASE_SERVICE_ROLE_KEY сам); в коде и в
// репозитории ключей нет. Токен и ключи НЕ пишутся ни в журнал, ни в ответы.
//
// Развёртывание — с флагом --no-verify-jwt (как release-url): приложение
// вызывает функцию с публичным ключом (это не JWT), подлинность аппарата
// проверяет токен. Инструкция — docs/brands.md.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  errorResponse,
  parseInput,
  readBrandGet,
  readBrandPath,
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

    // 1. Токен аппарата, лимит частоты и какой бренд ему положен — в базе.
    const { data: got, error: getErr } = await sb.rpc("device_brand_get", {
      p_device: input.device,
      p_token: input.token,
    });
    if (getErr) return fail("internal");
    const outcome = readBrandGet(got);
    if (outcome.kind === "error") return fail(outcome.code);
    // Бренда нет — это не ошибка: аппарат останется на встроенном CaRFog.
    if (outcome.kind === "none") return reply(200, successBody(null, null));

    // 2. Путь архива в бакете (наружу не отдаётся).
    const { data: pathRow, error: pathErr } = await sb.rpc("device_brand_path", {
      p_brand: outcome.brand.id,
      p_version: outcome.brand.version,
    });
    if (pathErr) return fail("internal");
    const path = readBrandPath(pathRow);
    if (path === null) return fail("not_found");

    // 3. Подписанная ссылка на 5 минут (закрытый бакет).
    const { data: signed, error: signErr } = await sb.storage
      .from("brand-packs")
      .createSignedUrl(path, SIGNED_URL_TTL_S);
    if (signErr || !signed?.signedUrl) return fail("internal");

    return reply(200, successBody(outcome.brand, signed.signedUrl));
  } catch (_e) {
    // Текст исключения наружу и в журнал не пишем (мог бы содержать
    // фрагменты запроса, в том числе токен).
    return fail("internal");
  }
});
