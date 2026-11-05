// Edge Function brand-upload (BRAND1): супервайзер с 2FA загружает архив
// пакета бренда в ЗАКРЫТЫЙ бакет brand-packs и регистрирует новую версию.
//
//   POST /functions/v1/brand-upload
//        Authorization: Bearer <JWT супервайзера, aal2>
//        {"brand":"acme","version":3,"consent":true,
//         "consent_note":"кто, когда, где лежит документ",
//         "zip_base64":"<архив до 1 МБ в base64>"}
//   200 → {"ok":true,"version":3,"sha256":"<64 hex>","size_bytes":N}
//   4xx → {"ok":false,"error":"<код>","details":...}
//
// ПОЧЕМУ ТЕЛО JSON С base64, А НЕ ПОДПИСАННАЯ ССЫЛКА НА ЗАГРУЗКУ:
// подписанная ссылка дала бы браузеру право ПИСАТЬ в бакет до того, как
// кто-либо проверил содержимое. Тогда zip-бомба, чужой логотип или пакет
// без согласия уже лежали бы в хранилище, и их пришлось бы убирать.
// Здесь архив не попадает в бакет, пока функция сама не посчитала sha256,
// не распаковала его в памяти с пределами, не проверила схему, картинки,
// контраст и согласие. Браузер супервайзера прав на Storage не получает
// вообще (у бакета нет ни одной политики). Цена — тело запроса около
// 1,4 МБ, что для Edge Function не предел.
//
// Порядок, при котором в бакете не остаётся мусора: сначала ВСЕ проверки,
// потом загрузка файла, потом запись версии в базу. Если запись не прошла,
// файл сразу удаляется (п. 7 задания).
//
// Развёртывание БЕЗ --no-verify-jwt: платформа сама отклоняет вызовы без
// JWT, а функция дополнительно спрашивает базу под JWT вызывающего, что
// это супервайзер портала с aal2 (supervisor_brand_check). Сервисный ключ
// берётся из окружения функции; ключей в репозитории нет. Токены, ключи и
// JWT НЕ пишутся ни в журнал, ни в ответы.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  checkPack,
  errorResponse,
  parseInput,
  readRegister,
  readSupervisorCheck,
  sha256Hex,
  storagePath,
  readZip,
} from "./logic.ts";

const JSON_HEADERS = { "Content-Type": "application/json" };

function reply(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function fail(code: Parameters<typeof errorResponse>[0], details?: unknown) {
  const e = errorResponse(code, details);
  return reply(e.status, e.body);
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return fail("method");

  try {
    const auth = req.headers.get("Authorization") ?? "";
    if (!auth.toLowerCase().startsWith("bearer ")) return fail("auth");

    const url = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !anonKey || !serviceKey) return fail("internal");

    // 1. Кто вызвал: проверку делает БАЗА под JWT вызывающего, а не мы по
    //    содержимому токена. Возвращает uuid актора для аудита.
    const asCaller = createClient(url, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: auth } },
    });
    const { data: checkRaw, error: checkErr } = await asCaller.rpc("supervisor_brand_check");
    if (checkErr) return fail("auth");
    const who = readSupervisorCheck(checkRaw);
    if (!who.ok) return fail(who.code);

    // 2. Тело запроса и согласие.
    let raw: unknown;
    try {
      raw = await req.json();
    } catch {
      return fail("bad_request", "bad_json");
    }
    const parsed = parseInput(raw);
    if (!parsed.ok) return fail("bad_request", parsed.error);
    const input = parsed.input;

    // 3. sha256 считаем сами; размер уже проверен при разборе.
    const sha256 = await sha256Hex(input.zip);

    // 4. Распаковка в памяти с пределами (zip-бомба, лишние файлы, пути).
    const zip = await readZip(input.zip);
    if (!zip.ok) {
      return fail("rejected", { zip: zip.error, name: zip.details ?? null });
    }

    // 5. Схема brand.json, PNG-картинки, контраст.
    const pack = checkPack(zip.files, { brand: input.brand, version: input.version });
    if (!pack.ok) {
      return fail("rejected", { errors: pack.errors, contrast: pack.contrast ?? null });
    }

    // 6. Только теперь файл в бакет. Сервисный ключ — у бакета нет политик,
    //    больше его никто не трогает.
    const sb = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const path = storagePath(input.brand, input.version);
    const { error: upErr } = await sb.storage
      .from("brand-packs")
      .upload(path, input.zip, { contentType: "application/zip", upsert: false });
    if (upErr) {
      // upsert:false — если файл этой версии уже есть, это конфликт, а не
      // ошибка сервера: версию уже загрузили.
      return fail("conflict", "already_uploaded");
    }

    // 7. Запись версии. Не прошла — файл убираем, в бакете не остаётся
    //    ничего (п. 7 задания).
    const { data: regRaw, error: regErr } = await sb.rpc("_brand_version_register", {
      p_brand: input.brand,
      p_name: pack.manifest.name,
      p_version: input.version,
      p_sha256: sha256,
      p_size: input.zip.length,
      p_path: path,
      p_manifest: pack.manifest,
      p_consent: input.consent,
      p_note: input.consent_note,
      p_contrast_ok: true,
      p_actor: who.actor,
    });
    if (regErr) {
      await sb.storage.from("brand-packs").remove([path]);
      return fail("internal");
    }
    const reg = readRegister(regRaw);
    if (!reg.ok) {
      await sb.storage.from("brand-packs").remove([path]);
      return fail(reg.code, reg.details);
    }

    return reply(200, {
      ok: true,
      brand: input.brand,
      version: reg.version,
      sha256,
      size_bytes: input.zip.length,
      images: pack.images,
    });
  } catch (_e) {
    // Текст исключения наружу и в журнал не пишем.
    return fail("internal");
  }
});
