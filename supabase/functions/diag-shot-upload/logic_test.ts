// Запуск: node --test functions/diag-shot-upload/logic_test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  errorResponse,
  isJpeg,
  MAX_BYTES,
  parseInput,
  registerError,
  removablePaths,
} from "./logic.ts";

function b64(bytes: number[]): string {
  return btoa(String.fromCharCode(...bytes));
}
const JPEG = [0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 0xff, 0xd9];
const GOOD = {
  device: "CARFOG-001",
  token: "t".repeat(32),
  shot: "shot-1730660000000",
  jpeg_b64: b64(JPEG),
};

test("годный вход разбирается, байты JPEG на месте", () => {
  const r = parseInput(GOOD);
  assert.ok(r);
  assert.equal(r!.jpeg.length, JPEG.length);
});

test("не JPEG (PNG, HTML) отклоняется", () => {
  assert.equal(parseInput({ ...GOOD, jpeg_b64: b64([0x89, 0x50, 0x4e, 0x47, 0, 0]) }), null);
  assert.equal(parseInput({ ...GOOD, jpeg_b64: btoa("<html>hi</html>") }), null);
});

test("плохие поля отклоняются", () => {
  assert.equal(parseInput(null), null);
  assert.equal(parseInput({ ...GOOD, shot: "../x" }), null);
  assert.equal(parseInput({ ...GOOD, shot: "shot-12" }), null);
  assert.equal(parseInput({ ...GOOD, token: "short" }), null);
  assert.equal(parseInput({ ...GOOD, device: "" }), null);
  assert.equal(parseInput({ ...GOOD, jpeg_b64: "@@@@@@@@" }), null);
});

test("больше 400 КБ — отказ до декодирования", () => {
  const big = "A".repeat(Math.ceil(MAX_BYTES / 3) * 4 + 4);
  assert.equal(parseInput({ ...GOOD, jpeg_b64: big }), null);
  const bytes = new Uint8Array(MAX_BYTES + 1);
  bytes.set([0xff, 0xd8, 0xff]);
  bytes.set([0xff, 0xd9], bytes.length - 2);
  assert.equal(isJpeg(bytes), false);
});

test("ответ базы → код ошибки", () => {
  assert.equal(registerError({ ok: true, path: "D/shot-1730660000000.jpg" }), null);
  assert.equal(registerError({ ok: false, error: "auth" }), "auth");
  assert.equal(registerError({ ok: false, error: "rate_limited" }), "rate_limited");
  assert.equal(registerError({ ok: false, error: "quota" }), "internal");
  assert.equal(registerError(null), "internal");
});

test("на удаление — только пути снимков, без ../", () => {
  assert.deepEqual(
    removablePaths({ remove: ["CARFOG-001/shot-1730660000000.jpg", "../etc/passwd", "x/y.png", 5] }),
    ["CARFOG-001/shot-1730660000000.jpg"],
  );
  assert.deepEqual(removablePaths({}), []);
});

test("ошибка — только короткий код", () => {
  assert.deepEqual(errorResponse("auth"), { status: 401, body: { ok: false, error: "auth" } });
  assert.equal(errorResponse("rate_limited").status, 429);
});
