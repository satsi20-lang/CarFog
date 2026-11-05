// Запуск: node --test functions/diag-shot-purge/logic_test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { batches, expiredPaths, secretMatches } from "./logic.ts";

const SECRET = "s".repeat(40);

test("секрет: только точное совпадение", () => {
  assert.equal(secretMatches(SECRET, SECRET), true);
  assert.equal(secretMatches(SECRET + "x", SECRET), false);
  assert.equal(secretMatches("", SECRET), false);
  assert.equal(secretMatches(null, SECRET), false);
});

test("секрет не настроен или короткий — отказ всем", () => {
  assert.equal(secretMatches("anything", undefined), false);
  assert.equal(secretMatches("short", "short"), false);
});

test("пути: только снимки", () => {
  assert.deepEqual(
    expiredPaths({ paths: ["A/shot-1730660000000.jpg", "A/other.txt", "../x"] }),
    ["A/shot-1730660000000.jpg"],
  );
  assert.deepEqual(expiredPaths(null), []);
});

test("пачки по 100", () => {
  const b = batches(Array.from({ length: 250 }, (_, i) => i));
  assert.deepEqual(b.map((x) => x.length), [100, 100, 50]);
});
