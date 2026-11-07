// Запуск: node --test functions/_shared/video_rules_test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  errorResponse,
  isUuid,
  parseVideoId,
  readAccess,
  readOk,
  storagePath,
} from "./video_rules.ts";

const VID = "0f8fad5b-d9cb-469f-a165-70867728950e";
const ACTOR = "6ba7b810-9dad-11d1-80b4-00c04fd430c8";

const good = {
  ok: true, actor: ACTOR, role: "customer", video_id: VID, device_id: "CARFOG-001",
  status: "pending_upload", size_bytes: 123456, hardware_profile: "ixp101m1",
};

test("storagePath: <device>/<video>.mp4 и отказ на мусор", () => {
  assert.equal(storagePath("CARFOG-001", VID), `CARFOG-001/${VID}.mp4`);
  assert.equal(storagePath("../x", VID), null);
  assert.equal(storagePath("a/b", VID), null);
  assert.equal(storagePath("CARFOG-001", "not-a-uuid"), null);
  assert.equal(storagePath("", VID), null);
  assert.equal(storagePath(undefined, VID), null);
});

test("parseVideoId: только uuid", () => {
  assert.equal(parseVideoId({ video_id: VID }), VID);
  assert.equal(parseVideoId({ video_id: VID.toUpperCase() }), null);
  assert.equal(parseVideoId({ video_id: "x" }), null);
  assert.equal(parseVideoId({}), null);
  assert.equal(parseVideoId(null), null);
  assert.equal(parseVideoId("str"), null);
  assert.ok(isUuid(VID));
});

test("readAccess: верный ответ", () => {
  const r = readAccess(good);
  assert.equal(r.ok, true);
  if (r.ok) {
    assert.equal(r.access.role, "customer");
    assert.equal(r.access.deviceId, "CARFOG-001");
    assert.equal(r.access.sizeBytes, 123456);
    assert.equal(r.access.hardwareProfile, "ixp101m1");
  }
});

test("readAccess: размер bigint строкой принимается", () => {
  const r = readAccess({ ...good, size_bytes: "5000000000" });
  assert.equal(r.ok && r.access.sizeBytes, 5_000_000_000);
});

test("readAccess: коды отказа базы переходят в коды функции", () => {
  assert.deepEqual(readAccess({ ok: false, error: "forbidden" }), { ok: false, code: "forbidden" });
  assert.deepEqual(readAccess({ ok: false, error: "mfa_required" }), { ok: false, code: "mfa_required" });
  assert.deepEqual(readAccess({ ok: false, error: "not_found" }), { ok: false, code: "not_found" });
  assert.deepEqual(readAccess({ ok: false, error: "что-то" }), { ok: false, code: "internal" });
});

test("readAccess: битые ответы — internal", () => {
  for (const bad of [null, "x", 5, { ok: true }, { ...good, role: "root" },
    { ...good, actor: "x" }, { ...good, device_id: "a/b" }, { ...good, size_bytes: 0 },
    { ...good, size_bytes: -1 }, { ...good, size_bytes: 1.5 }, { ...good, status: 1 }]) {
    assert.deepEqual(readAccess(bad), { ok: false, code: "internal" });
  }
});

test("errorResponse: статусы и подробности", () => {
  assert.equal(errorResponse("auth").status, 401);
  assert.equal(errorResponse("mfa_required").status, 403);
  assert.equal(errorResponse("rejected", { reason: "x" }).status, 422);
  assert.deepEqual(errorResponse("rejected", { reason: "x" }).body,
    { ok: false, error: "rejected", details: { reason: "x" } });
  assert.deepEqual(errorResponse("internal").body, { ok: false, error: "internal" });
});

test("readOk", () => {
  assert.equal(readOk({ ok: true }), true);
  assert.equal(readOk({ ok: false }), false);
  assert.equal(readOk(null), false);
});
