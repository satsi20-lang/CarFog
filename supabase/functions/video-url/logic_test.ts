// Запуск: node --test functions/video-url/logic_test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { errorResponse, parseInput, readPath, SIGNED_URL_TTL_S, successBody } from "./logic.ts";

const VID = "0f8fad5b-d9cb-469f-a165-70867728950e";
const SHA = "a".repeat(64);

test("срок ссылки — 6 часов", () => assert.equal(SIGNED_URL_TTL_S, 21600));

test("parseInput", () => {
  assert.deepEqual(parseInput({ device: "CARFOG-001", token: "12345678", video: VID }),
    { device: "CARFOG-001", token: "12345678", video: VID });
  assert.equal(parseInput({ device: "", token: "12345678", video: VID }), null);
  assert.equal(parseInput({ device: "d", token: "short", video: VID }), null);
  assert.equal(parseInput({ device: "d", token: "12345678", video: "x" }), null);
  assert.equal(parseInput({ device: "d", token: "x".repeat(257), video: VID }), null);
  assert.equal(parseInput(null), null);
  assert.equal(parseInput("s"), null);
});

test("errorResponse: только код", () => {
  assert.deepEqual(errorResponse("auth"), { status: 401, body: { ok: false, error: "auth" } });
  assert.equal(errorResponse("rate_limited").status, 429);
  assert.equal(errorResponse("not_found").status, 404);
});

test("readPath: верный ответ", () => {
  const r = readPath({ ok: true, path: `CARFOG-001/${VID}.mp4`, sha256: SHA, size_bytes: 1000 });
  assert.equal(r.kind, "path");
  if (r.kind === "path") assert.equal(r.row.size_bytes, 1000);
  assert.equal(readPath({ ok: true, path: `CARFOG-001/${VID}.mp4`, sha256: SHA, size_bytes: "5000000000" }).kind, "path");
});

test("readPath: ошибки базы и мусор", () => {
  assert.deepEqual(readPath({ ok: false, error: "auth" }), { kind: "error", code: "auth" });
  assert.deepEqual(readPath({ ok: false, error: "rate_limited" }), { kind: "error", code: "rate_limited" });
  assert.deepEqual(readPath({ ok: false, error: "not_found" }), { kind: "error", code: "not_found" });
  assert.deepEqual(readPath({ ok: false, error: "?" }), { kind: "error", code: "internal" });
  for (const bad of [null, 1, {}, { ok: true },
    { ok: true, path: "../x.mp4", sha256: SHA, size_bytes: 1 },
    { ok: true, path: `a/${VID}.zip`, sha256: SHA, size_bytes: 1 },
    { ok: true, path: `a/${VID}.mp4`, sha256: "zz", size_bytes: 1 },
    { ok: true, path: `a/${VID}.mp4`, sha256: SHA, size_bytes: 0 }]) {
    assert.deepEqual(readPath(bad), { kind: "error", code: "internal" });
  }
});

test("successBody: без пути в бакете", () => {
  const b = successBody({ path: `d/${VID}.mp4`, sha256: SHA, size_bytes: 9 }, "https://u", VID);
  assert.ok(!JSON.stringify(b).includes(".mp4"));
  assert.equal(b.expires_in_s, 21600);
  assert.deepEqual(b.video, { id: VID, sha256: SHA, size_bytes: 9, url: "https://u" });
});
