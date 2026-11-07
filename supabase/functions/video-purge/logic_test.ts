// Запуск: node --test functions/video-purge/logic_test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { batches, pickedItems, secretMatches } from "./logic.ts";

const A = "0f8fad5b-d9cb-469f-a165-70867728950e";

test("pickedItems: берёт только пути видео", () => {
  const ok = { id: A, path: `CARFOG-001/${A}.mp4` };
  assert.deepEqual(pickedItems([ok]), [ok]);
  assert.deepEqual(pickedItems([
    { id: A, path: "../etc/passwd" },
    { id: A, path: `a/${A}.zip` },
    { id: "x", path: `a/${A}.mp4` },
    { id: A },
    null, 5, "s",
  ]), []);
  assert.deepEqual(pickedItems(null), []);
  assert.deepEqual(pickedItems({}), []);
});

test("secretMatches и batches доступны", () => {
  const s = "s".repeat(40);
  assert.equal(secretMatches(s, s), true);
  assert.equal(secretMatches("x", s), false);
  assert.equal(secretMatches(null, s), false);
  assert.equal(secretMatches(s, undefined), false);
  assert.deepEqual(batches([1, 2, 3], 2), [[1, 2], [3]]);
});
