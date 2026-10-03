// Запуск: node --test functions/release-url/logic_test.ts
//         (или deno test functions/release-url/logic_test.ts)
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  errorResponse,
  isUsableRelease,
  MIN_INTERVAL_MS,
  parseInput,
  rateDecision,
  redact,
  SIGNED_URL_TTL_S,
  successBody,
} from "./logic.ts";

const REL = "123e4567-e89b-12d3-a456-426614174000";
const GOOD = {
  ok: true,
  version_name: "1.6.0",
  version_code: 10,
  file_path: "carfog-1.6.0+10-a1b2c3d4e5f6.apk",
  sha256: "a".repeat(64),
  size_bytes: 55_000_000,
};

test("срок ссылки — 10 минут", () => {
  assert.equal(SIGNED_URL_TTL_S, 600);
});

test("разбор входа: годный", () => {
  assert.deepEqual(
    parseInput({ device: "CARFOG-001", token: "t".repeat(24), release: REL }),
    { device: "CARFOG-001", token: "t".repeat(24), release: REL },
  );
});

test("разбор входа: негодные", () => {
  for (const bad of [
    null, 5, "x", {}, { device: "", token: "t".repeat(24), release: REL },
    { device: "D", token: "short", release: REL },
    { device: "D", token: "t".repeat(24), release: "not-a-uuid" },
    { device: "D".repeat(65), token: "t".repeat(24), release: REL },
    { device: 1, token: "t".repeat(24), release: REL },
  ]) {
    assert.equal(parseInput(bad), null);
  }
});

test("частота: первый запрос и запрос через минуту проходят", () => {
  assert.equal(rateDecision(null, 1000).allowed, true);
  assert.equal(rateDecision(0, MIN_INTERVAL_MS).allowed, true);
});

test("частота: повтор раньше минуты — отказ с Retry-After", () => {
  const d = rateDecision(0, 20_000);
  assert.equal(d.allowed, false);
  assert.equal(d.retryAfterS, 40);
});

test("частота: часы сервера ушли назад — не блокируем навсегда", () => {
  assert.equal(rateDecision(100_000, 50_000).allowed, true);
});

test("ответ об ошибке — только код, без подробностей", () => {
  for (const code of ["method", "bad_request", "auth", "rate_limited", "not_found", "internal"] as const) {
    const e = errorResponse(code);
    assert.deepEqual(Object.keys(e.body).sort(), ["error", "ok"]);
    assert.equal(e.body.ok, false);
    assert.equal(e.body.error, code);
  }
  assert.equal(errorResponse("auth").status, 401);
  assert.equal(errorResponse("rate_limited").status, 429);
});

test("годная запись релиза распознаётся, негодные нет", () => {
  assert.equal(isUsableRelease(GOOD), true);
  assert.equal(isUsableRelease({ ...GOOD, ok: false }), false);
  assert.equal(isUsableRelease({ ...GOOD, sha256: "xyz" }), false);
  assert.equal(isUsableRelease({ ...GOOD, size_bytes: 0 }), false);
  assert.equal(isUsableRelease({ ...GOOD, file_path: "" }), false);
  assert.equal(isUsableRelease(null), false);
});

test("успешный ответ не раскрывает внутренний путь файла", () => {
  const b = successBody(GOOD, "https://x.example/signed?token=abc");
  assert.equal(b.url, "https://x.example/signed?token=abc");
  assert.equal(b.sha256, GOOD.sha256);
  assert.equal(b.size_bytes, GOOD.size_bytes);
  assert.equal(b.expires_in_s, 600);
  assert.equal(JSON.stringify(b).includes(GOOD.file_path), false);
});

test("журнал: секреты вырезаются", () => {
  const t = "tok-ABCDEF123456";
  const k = "service-KEY-987654";
  const out = redact(`err ${t} and ${k} end`, [t, k]);
  assert.equal(out.includes(t), false);
  assert.equal(out.includes(k), false);
});
