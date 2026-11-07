// Запуск: node --test functions/brand-url/logic_test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  errorResponse,
  isBrandRow,
  parseInput,
  readBrandGet,
  readBrandPath,
  SIGNED_URL_TTL_S,
  successBody,
} from "./logic.ts";

const SHA = "a".repeat(64);
const BRAND = { id: "acme", version: 3, sha256: SHA, size_bytes: 12345 };

test("срок подписанной ссылки — 5 минут (ТЗ)", () => {
  assert.equal(SIGNED_URL_TTL_S, 300);
});

test("годный вход разбирается", () => {
  assert.deepEqual(parseInput({ device: "CARFOG-001", token: "t".repeat(32) }), {
    device: "CARFOG-001",
    token: "t".repeat(32),
  });
});

test("плохой вход отклоняется", () => {
  assert.equal(parseInput(null), null);
  assert.equal(parseInput("CARFOG-001"), null);
  assert.equal(parseInput({ device: "CARFOG-001" }), null);
  assert.equal(parseInput({ device: "", token: "t".repeat(32) }), null);
  assert.equal(parseInput({ device: "x".repeat(65), token: "t".repeat(32) }), null);
  assert.equal(parseInput({ device: "CARFOG-001", token: "short" }), null);
  assert.equal(parseInput({ device: "CARFOG-001", token: "t".repeat(257) }), null);
  assert.equal(parseInput({ device: 1, token: "t".repeat(32) }), null);
});

test("ответы device_brand_get: бренд, его отсутствие, отказы", () => {
  assert.deepEqual(readBrandGet({ ok: true, brand: BRAND }), { kind: "brand", brand: BRAND });
  assert.deepEqual(readBrandGet({ ok: true, brand: null }), { kind: "none" });
  assert.deepEqual(readBrandGet({ ok: true }), { kind: "none" });
  assert.deepEqual(readBrandGet({ ok: false, error: "auth" }), { kind: "error", code: "auth" });
  assert.deepEqual(readBrandGet({ ok: false, error: "rate_limited" }), {
    kind: "error",
    code: "rate_limited",
  });
  // Незнакомая и битая форма — внутренняя ошибка, наружу причин не даём.
  assert.deepEqual(readBrandGet({ ok: false, error: "что-то новое" }), { kind: "error", code: "internal" });
  assert.deepEqual(readBrandGet(null), { kind: "error", code: "internal" });
  assert.deepEqual(readBrandGet({ ok: true, brand: { id: "acme" } }), { kind: "error", code: "internal" });
});

test("форма записи бренда проверяется строго", () => {
  assert.equal(isBrandRow(BRAND), true);
  assert.equal(isBrandRow({ ...BRAND, sha256: "zz" }), false);
  assert.equal(isBrandRow({ ...BRAND, version: 0 }), false);
  assert.equal(isBrandRow({ ...BRAND, version: 1.5 }), false);
  assert.equal(isBrandRow({ ...BRAND, size_bytes: 0 }), false);
  assert.equal(isBrandRow({ ...BRAND, id: "" }), false);
  assert.equal(isBrandRow(null), false);
});

test("путь архива: подписываем только '<бренд>/v<версия>.zip'", () => {
  assert.equal(readBrandPath({ ok: true, path: "acme/v3.zip" }), "acme/v3.zip");
  assert.equal(readBrandPath({ ok: true, path: "../releases/app.apk" }), null);
  assert.equal(readBrandPath({ ok: true, path: "acme/v3.apk" }), null);
  assert.equal(readBrandPath({ ok: true, path: "ACME/v3.zip" }), null);
  assert.equal(readBrandPath({ ok: true, path: "acme/sub/v3.zip" }), null);
  assert.equal(readBrandPath({ ok: false, error: "not_found" }), null);
  assert.equal(readBrandPath(null), null);
});

test("успешный ответ: ссылка есть, путь в бакете наружу не уходит", () => {
  const body = successBody(BRAND, "https://example.test/signed?token=X");
  assert.equal(body.ok, true);
  assert.equal(body.brand!.url, "https://example.test/signed?token=X");
  assert.equal(body.brand!.sha256, SHA);
  assert.equal(body.expires_in_s, 300);
  assert.ok(!JSON.stringify(body).includes("acme/v3.zip"));
});

test("бренда нет — ok:true и brand:null, без ссылки", () => {
  assert.deepEqual(successBody(null, null), { ok: true, brand: null });
  assert.deepEqual(successBody(BRAND, null), { ok: true, brand: null });
});

test("коды ошибок и их статусы", () => {
  assert.deepEqual(errorResponse("auth"), { status: 401, body: { ok: false, error: "auth" } });
  assert.equal(errorResponse("rate_limited").status, 429);
  assert.equal(errorResponse("not_found").status, 404);
  assert.equal(errorResponse("bad_request").status, 400);
  assert.equal(errorResponse("method").status, 405);
  assert.equal(errorResponse("internal").status, 500);
});
