// Edge Function brand-upload (BRAND1): супервайзер с 2FA загружает архив
// пакета бренда в ЗАКРЫТЫЙ бакет brand-packs и регистрирует новую версию.
//
//   OPTIONS /functions/v1/brand-upload  → 204 (предзапрос браузера, CORS)
//   POST /functions/v1/brand-upload
//        Authorization: Bearer <JWT супервайзера, aal2>
//        {"brand":"acme","version":3,"consent":true,
//         "consent_note":"кто, когда, где лежит документ",
//         "zip_base64":"<архив до 1 МБ в base64>"}
//   200 → {"ok":true,"version":3,"sha256":"<64 hex>","size_bytes":N}
//   4xx → {"ok":false,"error":"<код>","details":...}
//
// CORS: функцию вызывает БРАУЗЕР портала через supabase.functions.invoke,
// поэтому нужен ответ на предзапрос OPTIONS и заголовки CORS на всех
// ответах, включая ошибки (иначе портал увидит «ошибка сети» вместо
// причины). Разрешённые адреса — ../_shared/cors.ts, звёздочки нет.
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
// файл удаляется — но только когда в базе этой версии действительно нет
// (см. cleanupDecision в logic.ts): иначе можно стереть архив, на который
// уже ссылается чужая запись.
//
// Развёртывание БЕЗ --no-verify-jwt: платформа сама отклоняет вызовы без
// JWT, а функция дополнительно спрашивает базу под JWT вызывающего, что
// это супервайзер портала с aal2 (supervisor_brand_check). Сервисный ключ
// берётся из окружения функции; ключей в репозитории нет. Токены, ключи и
// JWT НЕ пишутся ни в журнал, ни в ответы.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { jsonResponse, preflightResponse } from "../_shared/cors.ts";
import {
  checkPack,
  cleanupDecision,
  errorResponse,
  parseInput,
  readRegister,
  readSupervisorCheck,
  readVersionProbe,
  readZip,
  sha256Hex,
  storagePath,
  uploadRetryDecision,
} from "./logic.ts";

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");

  // Предзапрос браузера — до всякой проверки прав: иначе портал не узнает,
  // что ему вообще можно обращаться к функции.
  if (req.method === "OPTIONS") return preflightResponse(origin);

  const reply = (status: number, body: unknown): Response =>
    jsonResponse(status, body, origin);
  const fail = (
    code: Parameters<typeof errorResponse>[0],
    details?: unknown,
  ): Response => {
    const e = errorResponse(code, details);
    return reply(e.status, e.body);
  };

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

    // 6. Только теперь работа с хранилищем. Сервисный ключ — у бакета нет
    //    политик, больше его никто не трогает.
    const sb = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const path = storagePath(input.brand, input.version);

    /** Есть ли такая версия в базе (строка в brand_versions). */
    const probeVersion = async () => {
      const { data, error } = await sb.rpc("device_brand_path", {
        p_brand: input.brand,
        p_version: input.version,
      });
      return error ? readVersionProbe(null) : readVersionProbe(data);
    };

    // 6a. Повтор уже существующей версии виден сразу и дёшево, до загрузки.
    if (await probeVersion() === "exists") {
      return fail("conflict", "version_exists");
    }

    // 6b. Загрузка без перезаписи.
    let { error: upErr } = await sb.storage
      .from("brand-packs")
      .upload(path, input.zip, { contentType: "application/zip", upsert: false });

    if (upErr) {
      // Файл уже лежит, а версии в базе нет — это «сирота» от прошлой
      // неудачной попытки. Только в этом случае перезаписываем, иначе
      // можно затереть архив, который аппараты уже скачивают.
      const probe = await probeVersion();
      if (uploadRetryDecision(probe) === "conflict") {
        return fail("conflict", probe === "exists" ? "version_exists" : "busy");
      }
      ({ error: upErr } = await sb.storage
        .from("brand-packs")
        .upload(path, input.zip, { contentType: "application/zip", upsert: true }));
      if (upErr) return fail("conflict", "already_uploaded");
    }

    // 7. Запись версии. Не прошла — файл убираем, но только если версию
    //    никто не записал (cleanupDecision): иначе запись в базе осталась
    //    бы без архива.
    const cleanup = async () => {
      if (cleanupDecision(await probeVersion()) === "remove") {
        await sb.storage.from("brand-packs").remove([path]);
      }
    };

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
      await cleanup();
      return fail("internal");
    }
    const reg = readRegister(regRaw);
    if (!reg.ok) {
      await cleanup();
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
