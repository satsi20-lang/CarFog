// Запуск: node --test functions/brand-upload/logic_test.ts
//
// Архивы для проверок собираются здесь же настоящим мини-записывателем zip
// (локальные записи, центральный каталог, EOCD), поэтому проверяется именно
// чтение формата, а не заготовленные байты.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  checkPack,
  errorResponse,
  MAX_UNPACKED_BYTES,
  MAX_ZIP_ENTRIES,
  parseInput,
  readRegister,
  readSupervisorCheck,
  readZip,
  sha256Hex,
  storagePath,
} from "./logic.ts";
import { CARFOG_COLORS } from "../_shared/brand_rules.ts";

// ---------- сборка zip ----------

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = (c & 1) !== 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[i] = c >>> 0;
  }
  return t;
})();

function crc32(b: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < b.length; i++) c = CRC_TABLE[(c ^ b[i]!) & 255]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

async function deflateRaw(data: Uint8Array): Promise<Uint8Array> {
  const cs = new CompressionStream("deflate-raw");
  const w = cs.writable.getWriter();
  void w.write(data).then(() => w.close());
  const parts: Uint8Array[] = [];
  const r = cs.readable.getReader();
  for (;;) {
    const { done, value } = await r.read();
    if (done) break;
    parts.push(value);
  }
  const total = parts.reduce((n, p) => n + p.byteLength, 0);
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.byteLength; }
  return out;
}

interface Entry {
  name: string;
  data: Uint8Array;
  /** 0 — как есть, 8 — deflate (по умолчанию). */
  method?: 0 | 8;
  /** Заявить в архиве другой распакованный размер (для проверки обмана). */
  rawSizeOverride?: number;
  /** Биты общих флагов (1 — «зашифровано»). */
  flags?: number;
  /** Подменить числа на признак zip64. */
  zip64?: boolean;
  /** Испортить сжатые данные. */
  corrupt?: boolean;
}

function push16(a: number[], n: number): void {
  a.push(n & 255, (n >>> 8) & 255);
}
function push32(a: number[], n: number): void {
  a.push(n & 255, (n >>> 8) & 255, (n >>> 16) & 255, (n >>> 24) & 255);
}

/** Собрать zip. countOverride — соврать в EOCD о числе файлов. */
async function makeZip(entries: Entry[], countOverride?: number): Promise<Uint8Array> {
  const out: number[] = [];
  const central: { name: Uint8Array; e: Entry; comp: Uint8Array; crc: number; offset: number }[] = [];
  const enc = new TextEncoder();

  for (const e of entries) {
    const method = e.method ?? 8;
    let comp = method === 0 ? e.data : await deflateRaw(e.data);
    if (e.corrupt === true) {
      comp = new Uint8Array(comp);
      for (let i = 0; i < comp.length; i++) comp[i] = (comp[i]! ^ 0xa5) & 255;
    }
    const name = enc.encode(e.name);
    const crc = crc32(e.data);
    const rawSize = e.zip64 === true ? 0xffffffff : (e.rawSizeOverride ?? e.data.length);
    const offset = out.length;

    push32(out, 0x04034b50);
    push16(out, 20);
    push16(out, e.flags ?? 0);
    push16(out, method);
    push16(out, 0);
    push16(out, 0);
    push32(out, crc);
    push32(out, comp.length);
    push32(out, rawSize);
    push16(out, name.length);
    push16(out, 0);
    out.push(...name);
    out.push(...comp);

    central.push({ name, e, comp, crc, offset });
  }

  const cdOffset = out.length;
  for (const c of central) {
    const method = c.e.method ?? 8;
    const rawSize = c.e.zip64 === true ? 0xffffffff : (c.e.rawSizeOverride ?? c.e.data.length);
    push32(out, 0x02014b50);
    push16(out, 20);
    push16(out, 20);
    push16(out, c.e.flags ?? 0);
    push16(out, method);
    push16(out, 0);
    push16(out, 0);
    push32(out, c.crc);
    push32(out, c.comp.length);
    push32(out, rawSize);
    push16(out, c.name.length);
    push16(out, 0);
    push16(out, 0);
    push16(out, 0);
    push16(out, 0);
    push32(out, 0);
    push32(out, c.e.zip64 === true ? 0xffffffff : c.offset);
    out.push(...c.name);
  }
  const cdSize = out.length - cdOffset;

  const count = countOverride ?? central.length;
  push32(out, 0x06054b50);
  push16(out, 0);
  push16(out, 0);
  push16(out, count);
  push16(out, count);
  push32(out, cdSize);
  push32(out, cdOffset);
  push16(out, 0);

  return new Uint8Array(out);
}

// ---------- содержимое пакета ----------

function u32be(n: number): number[] {
  return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
}

/** Минимальный настоящий PNG заданного размера. */
function png(width: number, height: number, pad = 0): Uint8Array {
  return new Uint8Array([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ...u32be(13), 0x49, 0x48, 0x44, 0x52,
    ...u32be(width), ...u32be(height), 8, 6, 0, 0, 0, ...u32be(0),
    ...u32be(0), 0x49, 0x45, 0x4e, 0x44, ...u32be(0),
    ...new Array(pad).fill(0),
  ]);
}

const WANT = { brand: "acme", version: 3 };

function manifest(over: Record<string, unknown> = {}): Uint8Array {
  const m = {
    schema: 1,
    id: "acme",
    version: 3,
    name: "ACME Clean",
    colors: { ...CARFOG_COLORS },
    slogan: "English slogan",
    logo: "logo.png",
    ...over,
  };
  return new TextEncoder().encode(JSON.stringify(m));
}

const goodEntries = (over: Record<string, unknown> = {}): Entry[] => [
  { name: "brand.json", data: manifest(over) },
  { name: "logo.png", data: png(512, 512) },
];

// ---------- вход ----------

test("годный вход: архив раскодирован, заметка обрезана по краям", () => {
  const r = parseInput({
    brand: "acme",
    version: 3,
    consent: true,
    consent_note: "  Иванов, 03.11.2026, папка Договоры  ",
    zip_base64: btoa("PK\u0003\u0004not-a-real-zip"),
  });
  assert.equal(r.ok, true);
  assert.equal(r.input.consent_note, "Иванов, 03.11.2026, папка Договоры");
  assert.ok(r.input.zip.length > 0);
});

test("НЕТ СОГЛАСИЯ или пустая заметка — отказ до всякой распаковки", () => {
  const base = { brand: "acme", version: 3, zip_base64: btoa("PK") };
  assert.deepEqual(parseInput({ ...base, consent: false, consent_note: "кто, когда" }), {
    ok: false,
    error: "consent_required",
  });
  assert.deepEqual(parseInput({ ...base, consent: true, consent_note: "" }), {
    ok: false,
    error: "consent_required",
  });
  assert.deepEqual(parseInput({ ...base, consent: true, consent_note: "  " }), {
    ok: false,
    error: "consent_required",
  });
  assert.deepEqual(parseInput({ ...base, consent: true }), { ok: false, error: "consent_required" });
  assert.deepEqual(parseInput({ ...base, consent: "yes", consent_note: "кто, когда" }), {
    ok: false,
    error: "consent_required",
  });
});

test("плохой бренд и версия; встроенный carfog не обновляется", () => {
  const ok = { consent: true, consent_note: "кто, когда", zip_base64: btoa("PK") };
  assert.equal(parseInput({ ...ok, brand: "ACME", version: 1 }).error, "bad_brand");
  assert.equal(parseInput({ ...ok, brand: "a", version: 1 }).error, "bad_brand");
  assert.equal(parseInput({ ...ok, brand: "carfog", version: 1 }).error, "builtin_brand");
  assert.equal(parseInput({ ...ok, brand: "acme", version: 0 }).error, "bad_version");
  assert.equal(parseInput({ ...ok, brand: "acme", version: 1.5 }).error, "bad_version");
  assert.equal(parseInput({ ...ok, brand: "acme", version: "3" }).error, "bad_version");
});

test("архив слишком велик или не раскодируется", () => {
  const ok = { brand: "acme", version: 3, consent: true, consent_note: "кто, когда" };
  assert.equal(parseInput({ ...ok, zip_base64: "A".repeat(1_400_001) }).error, "zip_too_big");
  assert.equal(parseInput({ ...ok, zip_base64: "не base64!!!" }).error, "bad_zip");
  assert.equal(parseInput({ ...ok, zip_base64: "" }).error, "bad_zip");
  assert.equal(parseInput(null).error, "bad_zip");
});

test("sha256 считается по байтам архива, а не берётся у клиента", async () => {
  // Известное значение: sha256 пустой строки.
  assert.equal(
    await sha256Hex(new Uint8Array(0)),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  );
  const a = await sha256Hex(new Uint8Array([1, 2, 3]));
  const b = await sha256Hex(new Uint8Array([1, 2, 4]));
  assert.match(a, /^[0-9a-f]{64}$/);
  assert.notEqual(a, b);
});

test("путь в бакете всегда '<бренд>/v<версия>.zip'", () => {
  assert.equal(storagePath("acme", 3), "acme/v3.zip");
});

// ---------- чтение архива ----------

test("ХОРОШИЙ АРХИВ читается: оба файла на месте", async () => {
  const zip = await readZip(await makeZip(goodEntries()));
  assert.equal(zip.ok, true);
  assert.deepEqual([...zip.files.keys()].sort(), ["brand.json", "logo.png"]);
  assert.equal(JSON.parse(new TextDecoder().decode(zip.files.get("brand.json")!)).id, "acme");
});

test("файлы без сжатия (method 0) тоже читаются", async () => {
  const zip = await readZip(await makeZip([
    { name: "brand.json", data: manifest(), method: 0 },
    { name: "logo.png", data: png(64, 64), method: 0 },
  ]));
  assert.equal(zip.ok, true);
  assert.equal(zip.files.size, 2);
});

test("ZIP-БОМБА: честно заявленный огромный размер — отказ до распаковки", async () => {
  const big = new Uint8Array(4 * 1024 * 1024); // 4 МБ нулей сжимаются в байты
  const zip = await readZip(await makeZip([
    { name: "brand.json", data: manifest() },
    { name: "logo.png", data: big },
  ]));
  assert.equal(zip.ok, false);
  assert.equal(zip.error, "unpacked_too_big");
});

test("ZIP-БОМБА: архив врёт о размере — ловится на самой распаковке", async () => {
  const big = new Uint8Array(4 * 1024 * 1024);
  const zip = await readZip(await makeZip([
    { name: "brand.json", data: manifest() },
    { name: "logo.png", data: big, rawSizeOverride: 1000 },
  ]));
  assert.equal(zip.ok, false);
  assert.equal(zip.error, "unpacked_too_big");
  assert.ok(MAX_UNPACKED_BYTES < big.length);
});

test("ЛИШНИЕ ФАЙЛЫ: имя не из белого списка — отказ с именем", async () => {
  const zip = await readZip(await makeZip([
    ...goodEntries(),
    { name: "readme.txt", data: new TextEncoder().encode("hi") },
  ]));
  assert.equal(zip.ok, false);
  assert.equal(zip.error, "unknown_file");
  assert.equal(zip.details, "readme.txt");
});

test("СЛИШКОМ МНОГО ФАЙЛОВ: больше 8 — отказ", async () => {
  const many: Entry[] = [];
  for (let i = 0; i < MAX_ZIP_ENTRIES + 1; i++) {
    many.push({ name: `f${i}.bin`, data: new Uint8Array([i]) });
  }
  const zip = await readZip(await makeZip(many));
  assert.equal(zip.ok, false);
  assert.equal(zip.error, "too_many_files");
});

test("ПУТЬ В ИМЕНИ: '../x', каталоги, обратный слэш — отказ path_in_name", async () => {
  for (const name of ["../x", "../../etc/passwd", "sub/logo.png", "a\\b", ".hidden", "/abs"]) {
    const zip = await readZip(await makeZip([
      { name: "brand.json", data: manifest() },
      { name, data: png(8, 8) },
    ]));
    assert.equal(zip.ok, false, name);
    assert.equal(zip.error, "path_in_name", name);
  }
});

test("повтор имени, шифрование, zip64, битые данные, не zip", async () => {
  const dup = await readZip(await makeZip([
    { name: "brand.json", data: manifest() },
    { name: "logo.png", data: png(8, 8) },
    { name: "logo.png", data: png(9, 9) },
  ]));
  assert.equal(dup.error, "duplicate_file");

  const enc = await readZip(await makeZip([{ name: "brand.json", data: manifest(), flags: 1 }]));
  assert.equal(enc.error, "encrypted");

  const z64 = await readZip(await makeZip([{ name: "brand.json", data: manifest(), zip64: true }]));
  assert.equal(z64.error, "zip64_unsupported");

  const broken = await readZip(await makeZip([
    { name: "brand.json", data: manifest(), corrupt: true },
  ]));
  assert.equal(broken.ok, false);

  assert.equal((await readZip(new Uint8Array(0))).error, "not_zip");
  assert.equal((await readZip(new TextEncoder().encode("это не архив, а просто текст"))).error, "not_zip");
});

test("без brand.json архив не принимается", async () => {
  const zip = await readZip(await makeZip([{ name: "logo.png", data: png(8, 8) }]));
  assert.equal(zip.ok, false);
  assert.equal(zip.error, "unknown_file");
  assert.equal(zip.details, "brand.json");
});

// ---------- проверка пакета ----------

async function pack(entries: Entry[], want = WANT) {
  const zip = await readZip(await makeZip(entries));
  assert.equal(zip.ok, true, `архив не прочитан: ${JSON.stringify(zip)}`);
  return checkPack(zip.files, want);
}

test("ХОРОШИЙ ПАКЕТ проходит: манифест и размеры картинок", async () => {
  const r = await pack(goodEntries());
  assert.equal(r.ok, true);
  assert.equal(r.manifest.id, "acme");
  assert.equal(r.manifest.version, 3);
  assert.deepEqual(r.images.logo, { bytes: png(512, 512).length, width: 512, height: 512 });
  assert.equal("qr" in r.images, false);
});

test("необязательный qr_default: с объявлением в манифесте", async () => {
  const r = await pack([
    { name: "brand.json", data: manifest({ qr_default: "qr_default.png" }) },
    { name: "logo.png", data: png(256, 256) },
    { name: "qr_default.png", data: png(1000, 1000) },
  ]);
  assert.equal(r.ok, true);
  assert.deepEqual(r.images.qr, { bytes: png(1000, 1000).length, width: 1000, height: 1000 });
});

test("qr_default в архиве, но не в манифесте (и наоборот) — отказ", async () => {
  const extra = await pack([...goodEntries(), { name: "qr_default.png", data: png(10, 10) }]);
  assert.equal(extra.ok, false);
  assert.ok(extra.errors.includes("qr_not_in_manifest"));

  const missing = await pack([
    { name: "brand.json", data: manifest({ qr_default: "qr_default.png" }) },
    { name: "logo.png", data: png(10, 10) },
  ]);
  assert.equal(missing.ok, false);
  assert.ok(missing.errors.includes("no_qr_default"));
});

test("НЕ PNG: логотип — подделка", async () => {
  const r = await pack([
    { name: "brand.json", data: manifest() },
    { name: "logo.png", data: new TextEncoder().encode("<html>не картинка</html>") },
  ]);
  assert.equal(r.ok, false);
  assert.deepEqual(r.errors, ["logo:not_png"]);
});

test("ЛОГОТИП СЛИШКОМ БОЛЬШОЙ: по файлу (300 КБ) и по стороне (1000 px)", async () => {
  const heavy = await pack([
    { name: "brand.json", data: manifest() },
    { name: "logo.png", data: png(100, 100, 320_000) },
  ]);
  assert.equal(heavy.ok, false);
  assert.deepEqual(heavy.errors, ["logo:too_big"]);

  const wide = await pack([
    { name: "brand.json", data: manifest() },
    { name: "logo.png", data: png(1001, 100) },
  ]);
  assert.equal(wide.ok, false);
  assert.deepEqual(wide.errors, ["logo:side_too_large"]);
});

test("нет логотипа вовсе — отказ", async () => {
  const r = await pack([{ name: "brand.json", data: manifest() }]);
  assert.equal(r.ok, false);
  assert.ok(r.errors.includes("no_logo"));
});

test("ПЛОХОЙ КОНТРАСТ: отказ со списком пар и чисел", async () => {
  const r = await pack(goodEntries({
    colors: { ...CARFOG_COLORS, textPrimary: "#1B1B1B", textSecondary: "#1C1C1C" },
  }));
  assert.equal(r.ok, false);
  assert.ok(r.errors.includes("contrast_failed"));
  assert.ok(Array.isArray(r.contrast));
  assert.ok(r.contrast!.length >= 3);
  for (const f of r.contrast!) assert.ok(f.ratio! < f.min);
});

test("ЧУЖАЯ ВЕРСИЯ и чужой бренд в манифесте — отказ", async () => {
  const v = await pack(goodEntries({ version: 4 }));
  assert.equal(v.ok, false);
  assert.deepEqual(v.errors, ["version_mismatch"]);

  const b = await pack(goodEntries({ id: "other" }));
  assert.equal(b.ok, false);
  assert.deepEqual(b.errors, ["id_mismatch"]);
});

test("brand.json не JSON — понятный отказ", async () => {
  const r = await pack([
    { name: "brand.json", data: new TextEncoder().encode("{сломано") },
    { name: "logo.png", data: png(10, 10) },
  ]);
  assert.equal(r.ok, false);
  assert.deepEqual(r.errors, ["brand_json_not_json"]);
});

// ---------- ответы базы ----------

test("НЕ СУПЕРВАЙЗЕР и БЕЗ 2FA — свои коды, без подробностей", () => {
  assert.deepEqual(readSupervisorCheck({ ok: false, error: "forbidden" }), {
    ok: false,
    code: "forbidden",
  });
  assert.deepEqual(readSupervisorCheck({ ok: false, error: "mfa_required" }), {
    ok: false,
    code: "mfa_required",
  });
  assert.equal(errorResponse("forbidden").status, 403);
  assert.equal(errorResponse("mfa_required").status, 403);
});

test("супервайзер опознан — есть актор для аудита", () => {
  const r = readSupervisorCheck({ ok: true, actor: "11111111-2222-3333-4444-555555555555" });
  assert.equal(r.ok, true);
  assert.equal(r.actor, "11111111-2222-3333-4444-555555555555");
  // Без актора писать версию нельзя: аудит остался бы без автора.
  assert.deepEqual(readSupervisorCheck({ ok: true }), { ok: false, code: "internal" });
  assert.deepEqual(readSupervisorCheck({ ok: true, actor: "x" }), { ok: false, code: "internal" });
  assert.deepEqual(readSupervisorCheck(null), { ok: false, code: "internal" });
});

test("ответ регистрации версии: успех, конфликт версии, отказы", () => {
  assert.deepEqual(readRegister({ ok: true, version: 3 }), { ok: true, version: 3 });
  assert.deepEqual(readRegister({ ok: false, error: "bad_version", expected: 4 }), {
    ok: false,
    code: "conflict",
    details: { expected: 4 },
  });
  assert.deepEqual(readRegister({ ok: false, error: "consent_required" }), {
    ok: false,
    code: "rejected",
    details: "consent_required",
  });
  assert.equal(readRegister({ ok: false, error: "contrast_failed" }).code, "rejected");
  assert.equal(readRegister({ ok: false, error: "builtin_brand" }).code, "rejected");
  assert.equal(readRegister({ ok: false, error: "что-то новое" }).code, "internal");
  assert.equal(readRegister(null).code, "internal");
});

test("статусы кодов ошибок", () => {
  assert.equal(errorResponse("bad_request", "bad_json").status, 400);
  assert.deepEqual(errorResponse("rejected", { errors: ["logo:not_png"] }).body, {
    ok: false,
    error: "rejected",
    details: { errors: ["logo:not_png"] },
  });
  assert.equal(errorResponse("conflict").status, 409);
  assert.equal(errorResponse("auth").status, 401);
  assert.equal(errorResponse("internal").status, 500);
  assert.equal(errorResponse("method").status, 405);
});
