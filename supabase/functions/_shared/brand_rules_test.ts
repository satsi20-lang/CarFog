// Запуск: node --test functions/_shared/brand_rules_test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  BRAND_ID_RE,
  CARFOG_COLORS,
  checkContrast,
  checkImage,
  COLOR_TOKENS,
  contrastRatio,
  CONTRAST_RULES,
  isPng,
  MAX_LOGO_BYTES,
  parseHexColor,
  pngSize,
  relativeLuminance,
  validateManifest,
} from "./brand_rules.ts";

// ---------- PNG для проверок ----------

function u32be(n: number): number[] {
  return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
}

/** Минимальный настоящий PNG заданного размера (подпись, IHDR, IEND). */
function png(width: number, height: number, pad = 0): Uint8Array {
  const ihdr = [
    ...u32be(width), ...u32be(height),
    8, 6, 0, 0, 0, // глубина, тип цвета RGBA, сжатие, фильтр, развёртка
  ];
  const bytes = [
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ...u32be(13), 0x49, 0x48, 0x44, 0x52, ...ihdr, ...u32be(0),
    ...u32be(0), 0x49, 0x45, 0x4e, 0x44, ...u32be(0),
    ...new Array(pad).fill(0),
  ];
  return new Uint8Array(bytes);
}

// ---------- Цвет и контраст ----------

test("разбор цвета: только #RRGGBB", () => {
  assert.deepEqual(parseHexColor("#2EC4B6"), [0x2e, 0xc4, 0xb6]);
  assert.deepEqual(parseHexColor("#2ec4b6"), [0x2e, 0xc4, 0xb6]);
  assert.equal(parseHexColor("#2EC4B"), null);
  assert.equal(parseHexColor("#2EC4B6B6"), null);
  assert.equal(parseHexColor("2EC4B6"), null);
  assert.equal(parseHexColor("rgb(1,2,3)"), null);
  assert.equal(parseHexColor(null), null);
  assert.equal(parseHexColor(123), null);
});

test("яркость и контраст по WCAG: известные значения", () => {
  assert.equal(relativeLuminance([0, 0, 0]), 0);
  assert.equal(relativeLuminance([255, 255, 255]), 1);
  // Чёрный и белый — предельный контраст 21.
  assert.equal(Math.round(contrastRatio("#000000", "#FFFFFF")! * 100) / 100, 21);
  // Одинаковые цвета — 1.
  assert.equal(contrastRatio("#2EC4B6", "#2EC4B6"), 1);
  // Порядок цветов не важен.
  assert.equal(
    contrastRatio("#FFFFFF", "#1A1A1A"),
    contrastRatio("#1A1A1A", "#FFFFFF"),
  );
  assert.equal(contrastRatio("#FFFFFF", "мусор"), null);
});

test("ВСТРОЕННЫЙ бренд CaRFog проходит наши же пороги контраста", () => {
  // Если эта проверка упала — пороги отвергают наш собственный вид, и
  // менять нужно пороги, а не бренд.
  const r = checkContrast(CARFOG_COLORS);
  assert.deepEqual(r.failures, []);
  assert.equal(r.ok, true);
  for (const rule of CONTRAST_RULES) {
    const ratio = contrastRatio(CARFOG_COLORS[rule.fg], CARFOG_COLORS[rule.bg])!;
    assert.ok(ratio >= rule.min, `${rule.fg} к ${rule.bg}: ${ratio.toFixed(2)}`);
  }
});

test("плохой контраст: называет пары и числа", () => {
  const bad = { ...CARFOG_COLORS, textPrimary: "#1B1B1B", textSecondary: "#1C1C1C" };
  const r = checkContrast(bad);
  assert.equal(r.ok, false);
  const pairs = r.failures.map((f) => `${f.fg}/${f.bg}`);
  assert.ok(pairs.includes("textPrimary/background"));
  assert.ok(pairs.includes("textPrimary/surface"));
  assert.ok(pairs.includes("textSecondary/background"));
  for (const f of r.failures) {
    assert.equal(typeof f.ratio, "number");
    assert.ok(f.ratio! < f.min);
  }
});

test("нет цвета вовсе — пара не проходит, ratio null", () => {
  const r = checkContrast({ textPrimary: "#FFFFFF" });
  assert.equal(r.ok, false);
  assert.ok(r.failures.some((f) => f.ratio === null));
});

// ---------- PNG ----------

test("PNG: подпись и IHDR, размеры, подделки", () => {
  const p = png(1000, 1000);
  assert.equal(isPng(p), true);
  assert.deepEqual(pngSize(p), { width: 1000, height: 1000 });

  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, ...new Array(30).fill(1)]);
  assert.equal(isPng(jpeg), false);
  assert.equal(pngSize(jpeg), null);
  // Подпись PNG, но IHDR не на месте — не PNG.
  const faked = png(10, 10);
  faked[13] = 0x58;
  assert.equal(isPng(faked), false);
  assert.equal(isPng(new Uint8Array([0x89, 0x50])), false);
});

test("картинка пакета: предел по размеру файла и по стороне", () => {
  assert.deepEqual(checkImage(png(200, 200), MAX_LOGO_BYTES), { ok: true, width: 200, height: 200 });
  assert.deepEqual(checkImage(png(1001, 200), MAX_LOGO_BYTES), { ok: false, error: "side_too_large" });
  assert.deepEqual(checkImage(png(200, 1001), MAX_LOGO_BYTES), { ok: false, error: "side_too_large" });
  assert.deepEqual(checkImage(png(10, 10, 100), 50), { ok: false, error: "too_big" });
  assert.deepEqual(checkImage(new Uint8Array(40), MAX_LOGO_BYTES), { ok: false, error: "not_png" });
});

// ---------- brand.json ----------

const COLORS = { ...CARFOG_COLORS };
const GOOD = {
  schema: 1,
  id: "acme",
  version: 3,
  name: "ACME Clean",
  colors: COLORS,
  slogan: "English slogan",
  logo: "logo.png",
};
const WANT = { brand: "acme", version: 3 };

test("brand.json: годный манифест, семь токенов, слоган необязателен", () => {
  const r = validateManifest(GOOD, WANT);
  assert.equal(r.ok, true);
  assert.equal(r.manifest.name, "ACME Clean");
  assert.equal(r.manifest.slogan, "English slogan");
  assert.equal(Object.keys(r.manifest.colors).length, COLOR_TOKENS.length);
  assert.equal(r.manifest.colors.primary, "#2EC4B6");
  assert.equal("qr_default" in r.manifest, false);

  const noSlogan = validateManifest({ ...GOOD, slogan: undefined }, WANT);
  assert.equal(noSlogan.ok, true);
  assert.equal(noSlogan.manifest.slogan, "");

  const withQr = validateManifest({ ...GOOD, qr_default: "qr_default.png" }, WANT);
  assert.equal(withQr.ok, true);
  assert.equal(withQr.manifest.qr_default, "qr_default.png");
});

test("brand.json: id и версия обязаны совпадать с запросом", () => {
  const other = validateManifest({ ...GOOD, id: "other" }, WANT);
  assert.equal(other.ok, false);
  assert.deepEqual(other.errors, ["id_mismatch"]);

  const ver = validateManifest({ ...GOOD, version: 4 }, WANT);
  assert.equal(ver.ok, false);
  assert.deepEqual(ver.errors, ["version_mismatch"]);
});

test("brand.json: схема, id по шаблону, название, слоган", () => {
  assert.deepEqual(validateManifest({ ...GOOD, schema: 2 }, WANT).errors, ["bad_schema"]);
  assert.deepEqual(validateManifest({ ...GOOD, id: "ACME" }, WANT).errors, ["bad_id"]);
  assert.deepEqual(validateManifest({ ...GOOD, id: "a" }, WANT).errors, ["bad_id"]);
  assert.deepEqual(validateManifest({ ...GOOD, name: "" }, WANT).errors, ["bad_name"]);
  assert.deepEqual(validateManifest({ ...GOOD, name: "x".repeat(41) }, WANT).errors, ["bad_name"]);
  assert.deepEqual(validateManifest({ ...GOOD, name: "ACME\u0007" }, WANT).errors, ["bad_name"]);
  assert.deepEqual(validateManifest({ ...GOOD, slogan: "x".repeat(81) }, WANT).errors, ["bad_slogan"]);
  assert.deepEqual(validateManifest({ ...GOOD, slogan: "a\nb" }, WANT).errors, ["bad_slogan"]);
  assert.deepEqual(validateManifest({ ...GOOD, logo: "my.png" }, WANT).errors, ["bad_logo_name"]);
  assert.deepEqual(validateManifest({ ...GOOD, qr_default: "x.png" }, WANT).errors, ["bad_qr_name"]);
  assert.deepEqual(validateManifest(null, WANT).errors, ["manifest_not_object"]);
  assert.deepEqual(validateManifest([1], WANT).errors, ["manifest_not_object"]);
});

test("brand.json: нет токена цвета, лишний токен, не цвет", () => {
  const { primaryAlt: _drop, ...short } = COLORS;
  assert.deepEqual(
    validateManifest({ ...GOOD, colors: short }, WANT).errors,
    ["bad_color:primaryAlt"],
  );
  assert.deepEqual(
    validateManifest({ ...GOOD, colors: { ...COLORS, accent: "#112233" } }, WANT).errors,
    ["unknown_color:accent"],
  );
  assert.deepEqual(
    validateManifest({ ...GOOD, colors: { ...COLORS, primary: "red" } }, WANT).errors,
    ["bad_color:primary"],
  );
  assert.deepEqual(validateManifest({ ...GOOD, colors: null }, WANT).errors, ["bad_colors"]);
});

test("шаблон id бренда — тот же, что в check-ограничении таблицы", () => {
  for (const good of ["acme", "a1", "acme-clean", "acme_1", "0a", "a".repeat(31)]) {
    assert.ok(BRAND_ID_RE.test(good), good);
  }
  for (const bad of ["a", "", "ACME", "-acme", "_a", "acme.clean", "a".repeat(32), "ac me"]) {
    assert.ok(!BRAND_ID_RE.test(bad), bad);
  }
});
