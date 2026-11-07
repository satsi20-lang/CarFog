// Запуск: node --test functions/video-upload-url/logic_test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { readSigned, successBody, uploadBlocker } from "./logic.ts";

test("ссылка только для pending_upload", () => {
  assert.equal(uploadBlocker({ status: "pending_upload" }), null);
  for (const s of ["validating", "ready", "on_device", "rejected", "deleted", "failed"]) {
    assert.equal(uploadBlocker({ status: s }), "bad_status");
  }
});

test("readSigned: принимает https и токен, остальное — null", () => {
  assert.deepEqual(readSigned({ signedUrl: "https://x.supabase.co/a?token=abcdefghijk", token: "abcdefghijk" }),
    { signedUrl: "https://x.supabase.co/a?token=abcdefghijk", token: "abcdefghijk" });
  assert.equal(readSigned({ signedUrl: "http://x/a", token: "abcdefghijk" }), null);
  assert.equal(readSigned({ signedUrl: "https://x/a", token: "short" }), null);
  assert.equal(readSigned(null), null);
  assert.equal(readSigned({}), null);
});

test("successBody", () => {
  assert.deepEqual(successBody("d/v.mp4", "https://u", "t"),
    { ok: true, path: "d/v.mp4", signed_url: "https://u", token: "t" });
});
