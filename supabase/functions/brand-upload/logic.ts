// Чистая логика Edge Function brand-upload: разбор запроса, чтение zip в
// памяти с защитой от zip-бомбы, проверка пакета бренда по правилам из
// ../_shared/brand_rules.ts. Сети и Deno API здесь нет — проверяется
// обычными тестами (logic_test.ts).
//
// Используются только общие для Deno и Node веб-стандарты: atob,
// crypto.subtle, DecompressionStream.
import {
  ALLOWED_ZIP_NAMES,
  BRAND_ID_RE,
  checkContrast,
  checkImage,
  type ContrastFailure,
  type Manifest,
  MAX_LOGO_BYTES,
  MAX_UNPACKED_BYTES,
  MAX_ZIP_BYTES,
  MAX_ZIP_ENTRIES,
  validateManifest,
} from "../_shared/brand_rules.ts";

export {
  ALLOWED_ZIP_NAMES,
  MAX_UNPACKED_BYTES,
  MAX_ZIP_BYTES,
  MAX_ZIP_ENTRIES,
} from "../_shared/brand_rules.ts";

/** base64 архива длиннее этого даже не раскодируем (1 МБ ≈ 1,4 МБ base64). */
export const MAX_B64_LEN = 1_400_000;
/** Заметка о согласии: кто, когда, где лежит документ. */
export const MIN_NOTE_LEN = 3;
export const MAX_NOTE_LEN = 500;

// ---------- Вход ----------

export interface Input {
  brand: string;
  version: number;
  consent: boolean;
  consent_note: string;
  zip: Uint8Array;
}

export type InputError =
  | "bad_brand"
  | "builtin_brand"
  | "bad_version"
  | "consent_required"
  | "bad_zip"
  | "zip_too_big";

export type ParsedInput =
  | { ok: true; input: Input }
  | { ok: false; error: InputError };

function decodeBase64(s: string): Uint8Array | null {
  try {
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

/**
 * Разбор тела запроса. Согласие проверяется здесь же: без него архив даже
 * не раскодируется и в бакет ничего не попадает.
 */
export function parseInput(body: unknown): ParsedInput {
  if (typeof body !== "object" || body === null) return { ok: false, error: "bad_zip" };
  const b = body as Record<string, unknown>;

  if (typeof b.brand !== "string" || !BRAND_ID_RE.test(b.brand)) {
    return { ok: false, error: "bad_brand" };
  }
  // Встроенный бренд живёт в сборке приложения, версиями не обновляется.
  if (b.brand === "carfog") return { ok: false, error: "builtin_brand" };

  if (typeof b.version !== "number" || !Number.isInteger(b.version) ||
      b.version < 1 || b.version > 1_000_000) {
    return { ok: false, error: "bad_version" };
  }

  const note = typeof b.consent_note === "string" ? b.consent_note.trim() : "";
  if (b.consent !== true || note.length < MIN_NOTE_LEN || note.length > MAX_NOTE_LEN) {
    return { ok: false, error: "consent_required" };
  }

  if (typeof b.zip_base64 !== "string" || b.zip_base64.length === 0) {
    return { ok: false, error: "bad_zip" };
  }
  if (b.zip_base64.length > MAX_B64_LEN) return { ok: false, error: "zip_too_big" };
  const zip = decodeBase64(b.zip_base64);
  if (zip === null || zip.length === 0) return { ok: false, error: "bad_zip" };
  if (zip.length > MAX_ZIP_BYTES) return { ok: false, error: "zip_too_big" };

  return {
    ok: true,
    input: { brand: b.brand, version: b.version, consent: true, consent_note: note, zip },
  };
}

/** sha256 архива считаем САМИ: присланному клиентом значению не верим. */
export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as unknown as ArrayBuffer);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Путь архива в бакете brand-packs. Другого вида путей не бывает. */
export function storagePath(brand: string, version: number): string {
  return `${brand}/v${version}.zip`;
}

// ---------- Чтение zip ----------

export type ZipError =
  | "not_zip"
  | "too_many_files"
  | "unknown_file"
  | "path_in_name"
  | "duplicate_file"
  | "encrypted"
  | "unsupported_method"
  | "zip64_unsupported"
  | "unpacked_too_big"
  | "broken_entry";

export type ZipResult =
  | { ok: true; files: Map<string, Uint8Array> }
  | { ok: false; error: ZipError; details?: string };

const u16 = (b: Uint8Array, o: number): number => b[o]! | (b[o + 1]! << 8);
const u32 = (b: Uint8Array, o: number): number =>
  (b[o]! | (b[o + 1]! << 8) | (b[o + 2]! << 16) | (b[o + 3]! << 24)) >>> 0;

const EOCD_SIG = 0x06054b50;
const CD_SIG = 0x02014b50;
const LFH_SIG = 0x04034b50;

/** Поиск конца центрального каталога (с конца, с учётом комментария). */
function findEocd(b: Uint8Array): number {
  const min = Math.max(0, b.length - 65557 - 22);
  for (let i = b.length - 22; i >= min; i--) {
    if (u32(b, i) === EOCD_SIG) return i;
  }
  return -1;
}

async function inflateRaw(data: Uint8Array, maxBytes: number): Promise<Uint8Array | null> {
  let ds: DecompressionStream;
  try {
    ds = new DecompressionStream("deflate-raw");
  } catch {
    return null;
  }
  const writer = ds.writable.getWriter();
  // Ошибку записи глотаем: её увидит чтение ниже.
  // Приведение нужно только типам: Uint8Array поверх ArrayBufferLike против
  // BufferSource. Байты те же.
  void writer.write(data as unknown as BufferSource).then(() => writer.close()).catch(() => {});
  const reader = ds.readable.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      // Жёсткий предел на РАСПАКОВАННЫЙ размер: zip-бомба обрывается здесь,
      // а не после того, как съест память.
      if (total > maxBytes) {
        await reader.cancel().catch(() => {});
        return null;
      }
      chunks.push(value);
    }
  } catch {
    return null;
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.byteLength;
  }
  return out;
}

/**
 * Чтение архива в памяти. Защита: не больше MAX_ZIP_ENTRIES файлов, имена
 * только из белого списка (значит, ни каталогов, ни '..', ни абсолютных
 * путей), суммарный распакованный размер не больше MAX_UNPACKED_BYTES —
 * и по заявленным в архиве числам, и по фактически распакованным байтам.
 * На диск ничего не пишется.
 */
export async function readZip(bytes: Uint8Array): Promise<ZipResult> {
  if (bytes.length < 22) return { ok: false, error: "not_zip" };
  const eocd = findEocd(bytes);
  if (eocd < 0) return { ok: false, error: "not_zip" };

  const count = u16(bytes, eocd + 10);
  const cdSize = u32(bytes, eocd + 12);
  const cdOffset = u32(bytes, eocd + 16);
  if (count > MAX_ZIP_ENTRIES) {
    return { ok: false, error: "too_many_files", details: String(count) };
  }
  if (cdOffset + cdSize > bytes.length) return { ok: false, error: "not_zip" };

  const files = new Map<string, Uint8Array>();
  let declared = 0;
  let unpacked = 0;
  let at = cdOffset;

  for (let i = 0; i < count; i++) {
    if (at + 46 > bytes.length || u32(bytes, at) !== CD_SIG) {
      return { ok: false, error: "not_zip" };
    }
    const flags = u16(bytes, at + 8);
    const method = u16(bytes, at + 10);
    const compSize = u32(bytes, at + 20);
    const rawSize = u32(bytes, at + 24);
    const nameLen = u16(bytes, at + 28);
    const extraLen = u16(bytes, at + 30);
    const commentLen = u16(bytes, at + 32);
    const localOffset = u32(bytes, at + 42);
    const nameBytes = bytes.subarray(at + 46, at + 46 + nameLen);
    const name = new TextDecoder("utf-8", { fatal: false }).decode(nameBytes);
    at += 46 + nameLen + extraLen + commentLen;

    // Зашифрованный архив не читаем (бит 0 общих флагов).
    if ((flags & 0x1) !== 0) return { ok: false, error: "encrypted" };
    if (compSize === 0xffffffff || rawSize === 0xffffffff || localOffset === 0xffffffff) {
      return { ok: false, error: "zip64_unsupported" };
    }
    // Имя с путём — отказ с понятной причиной (а не просто «не из списка»).
    if (name.includes("/") || name.includes("\\") || name.includes("..") ||
        name.startsWith(".") || name.length === 0 || name.length > 64) {
      return { ok: false, error: "path_in_name", details: name };
    }
    if (!(ALLOWED_ZIP_NAMES as readonly string[]).includes(name)) {
      return { ok: false, error: "unknown_file", details: name };
    }
    if (files.has(name)) return { ok: false, error: "duplicate_file", details: name };
    if (method !== 0 && method !== 8) {
      return { ok: false, error: "unsupported_method", details: String(method) };
    }

    // Предел по ЗАЯВЛЕННЫМ размерам — до всякой распаковки.
    declared += rawSize;
    if (declared > MAX_UNPACKED_BYTES) {
      return { ok: false, error: "unpacked_too_big", details: String(declared) };
    }

    // Данные: смещение берём из локальной записи (её extra бывает другим).
    if (localOffset + 30 > bytes.length || u32(bytes, localOffset) !== LFH_SIG) {
      return { ok: false, error: "broken_entry", details: name };
    }
    const lNameLen = u16(bytes, localOffset + 26);
    const lExtraLen = u16(bytes, localOffset + 28);
    const dataAt = localOffset + 30 + lNameLen + lExtraLen;
    if (dataAt + compSize > bytes.length) {
      return { ok: false, error: "broken_entry", details: name };
    }
    const comp = bytes.subarray(dataAt, dataAt + compSize);

    const left = MAX_UNPACKED_BYTES - unpacked;
    let data: Uint8Array | null;
    if (method === 0) {
      data = comp.length > left ? null : new Uint8Array(comp);
    } else {
      data = await inflateRaw(comp, left);
    }
    if (data === null) {
      // Либо битые данные, либо распаковалось больше предела (zip-бомба).
      return { ok: false, error: "unpacked_too_big", details: name };
    }
    unpacked += data.length;
    files.set(name, data);
  }

  if (!files.has("brand.json")) return { ok: false, error: "unknown_file", details: "brand.json" };
  return { ok: true, files };
}

// ---------- Проверка пакета ----------

export interface PackOk {
  ok: true;
  manifest: Manifest;
  /** Размеры картинок — для отчёта в портал и аудита. */
  images: { logo: { bytes: number; width: number; height: number }; qr?: { bytes: number; width: number; height: number } };
}

export interface PackBad {
  ok: false;
  /** Короткие коды причин: их показывает портал. */
  errors: string[];
  /** Непрошедшие пары контраста с числами. */
  contrast?: ContrastFailure[];
}

export type PackCheck = PackOk | PackBad;

/**
 * Полная проверка распакованного пакета: brand.json по схеме 1, PNG
 * логотипа и необязательного QR, контраст по WCAG. Все причины отказа
 * собираются в один список, чтобы супервайзер исправил всё сразу.
 */
export function checkPack(
  files: Map<string, Uint8Array>,
  want: { brand: string; version: number },
): PackCheck {
  const errors: string[] = [];

  const brandJson = files.get("brand.json");
  if (brandJson === undefined) return { ok: false, errors: ["no_brand_json"] };
  let raw: unknown;
  try {
    raw = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(brandJson));
  } catch {
    return { ok: false, errors: ["brand_json_not_json"] };
  }
  const man = validateManifest(raw, want);
  if (!man.ok) return { ok: false, errors: man.errors };
  const manifest = man.manifest;

  const logo = files.get("logo.png");
  const logoCheck = logo === undefined ? null : checkImage(logo, MAX_LOGO_BYTES);
  if (logo === undefined) errors.push("no_logo");
  else if (!logoCheck!.ok) errors.push(`logo:${logoCheck!.error}`);

  const qr = files.get("qr_default.png");
  const qrCheck = qr === undefined ? null : checkImage(qr, MAX_LOGO_BYTES);
  if (manifest.qr_default !== undefined && qr === undefined) errors.push("no_qr_default");
  if (qr !== undefined) {
    if (manifest.qr_default === undefined) errors.push("qr_not_in_manifest");
    if (!qrCheck!.ok) errors.push(`qr_default:${qrCheck!.error}`);
  }

  const contrast = checkContrast(manifest.colors);
  if (!contrast.ok) errors.push("contrast_failed");

  if (errors.length > 0) {
    return contrast.ok
      ? { ok: false, errors }
      : { ok: false, errors, contrast: contrast.failures };
  }

  // Сюда попадаем только когда обе картинки прошли проверку.
  const l = logoCheck as { ok: true; width: number; height: number };
  const images: PackOk["images"] = {
    logo: { bytes: logo!.length, width: l.width, height: l.height },
  };
  if (qr !== undefined && qrCheck !== null && qrCheck.ok) {
    images.qr = { bytes: qr.length, width: qrCheck.width, height: qrCheck.height };
  }
  return { ok: true, manifest, images };
}

// ---------- Ответы ----------

export type ErrorCode =
  | "method"
  | "bad_request"
  | "auth"
  | "forbidden"
  | "mfa_required"
  | "rejected"
  | "conflict"
  | "internal";

const STATUS: Record<ErrorCode, number> = {
  method: 405,
  bad_request: 400,
  auth: 401,
  forbidden: 403,
  mfa_required: 403,
  rejected: 422,
  conflict: 409,
  internal: 500,
};

/**
 * Ответ об ошибке. В отличие от device-функций здесь подробности нужны:
 * отвечаем супервайзеру портала, и он должен понять, что исправить.
 * Ключей, токенов и путей в бакете в details нет.
 */
export function errorResponse(
  code: ErrorCode,
  details?: unknown,
): { status: number; body: Record<string, unknown> } {
  const body: Record<string, unknown> = { ok: false, error: code };
  if (details !== undefined) body.details = details;
  return { status: STATUS[code], body };
}

/** Разбор ответа supervisor_brand_check(): кто вызвал и можно ли ему. */
export type CheckOutcome =
  | { ok: true; actor: string }
  | { ok: false; code: ErrorCode };

export function readSupervisorCheck(raw: unknown): CheckOutcome {
  if (typeof raw !== "object" || raw === null) return { ok: false, code: "internal" };
  const r = raw as Record<string, unknown>;
  if (r.ok !== true) {
    const e = typeof r.error === "string" ? r.error : "";
    if (e === "forbidden") return { ok: false, code: "forbidden" };
    if (e === "mfa_required") return { ok: false, code: "mfa_required" };
    return { ok: false, code: "internal" };
  }
  if (typeof r.actor !== "string" || r.actor.length < 10) {
    return { ok: false, code: "internal" };
  }
  return { ok: true, actor: r.actor };
}

/** Разбор ответа _brand_version_register. */
export type RegisterOutcome =
  | { ok: true; version: number }
  | { ok: false; code: ErrorCode; details?: unknown };

export function readRegister(raw: unknown): RegisterOutcome {
  if (typeof raw !== "object" || raw === null) return { ok: false, code: "internal" };
  const r = raw as Record<string, unknown>;
  if (r.ok === true && typeof r.version === "number") {
    return { ok: true, version: r.version };
  }
  const e = typeof r.error === "string" ? r.error : "internal";
  // Версия не та, что ждёт база (кто-то загрузил раньше) — это конфликт,
  // а не ошибка сервера: портал покажет, какую версию ждали.
  if (e === "bad_version") {
    return { ok: false, code: "conflict", details: { expected: r.expected ?? null } };
  }
  if (e === "consent_required" || e === "contrast_failed" || e === "bad_brand" ||
      e === "builtin_brand" || e === "bad_request") {
    return { ok: false, code: "rejected", details: e };
  }
  return { ok: false, code: "internal" };
}
