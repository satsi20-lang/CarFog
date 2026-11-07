// Запуск: node --test functions/_shared/cors_test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ALLOW_HEADERS,
  ALLOW_METHODS,
  ALLOWED_ORIGINS,
  corsHeaders,
  isAllowedOrigin,
  jsonResponse,
  MAX_AGE_S,
  preflightResponse,
} from "./cors.ts";

const PORTAL = "https://app.carfog.online";
const DEV = "http://localhost:5173";
const STRANGER = "https://evil.example";

test("разрешены только наши адреса", () => {
  assert.deepEqual([...ALLOWED_ORIGINS], [PORTAL, DEV]);
  assert.equal(isAllowedOrigin(PORTAL), true);
  assert.equal(isAllowedOrigin(DEV), true);
  assert.equal(isAllowedOrigin(STRANGER), false);
  assert.equal(isAllowedOrigin(null), false);
  assert.equal(isAllowedOrigin(undefined), false);
  assert.equal(isAllowedOrigin(""), false);
  // Похожие, но чужие адреса не проходят.
  assert.equal(isAllowedOrigin("http://app.carfog.online"), false);
  assert.equal(isAllowedOrigin("https://app.carfog.online.evil.example"), false);
  assert.equal(isAllowedOrigin("https://app.carfog.online/"), false);
  assert.equal(isAllowedOrigin("https://APP.CARFOG.ONLINE"), false);
});

test("звёздочки в разрешённых адресах нет и быть не должно", () => {
  for (const o of ALLOWED_ORIGINS) assert.notEqual(o, "*");
  assert.notEqual(corsHeaders(PORTAL)["Access-Control-Allow-Origin"], "*");
  assert.equal(corsHeaders("*")["Access-Control-Allow-Origin"], undefined);
});

test("ПРЕДЗАПРОС со своего адреса: 204 и все нужные заголовки", async () => {
  const r = preflightResponse(PORTAL);
  assert.equal(r.status, 204);
  assert.equal(r.headers.get("Access-Control-Allow-Origin"), PORTAL);
  assert.equal(r.headers.get("Access-Control-Allow-Methods"), ALLOW_METHODS);
  assert.equal(r.headers.get("Access-Control-Allow-Headers"), ALLOW_HEADERS);
  assert.equal(r.headers.get("Access-Control-Max-Age"), String(MAX_AGE_S));
  assert.equal(r.headers.get("Vary"), "Origin");
  assert.equal(await r.text(), "", "у предзапроса нет тела");

  // Адрес разработки — тоже свой.
  assert.equal(preflightResponse(DEV).headers.get("Access-Control-Allow-Origin"), DEV);
});

test("ПРЕДЗАПРОС с чужого адреса: Allow-Origin НЕ выдаётся", () => {
  const r = preflightResponse(STRANGER);
  assert.equal(r.status, 204);
  assert.equal(r.headers.get("Access-Control-Allow-Origin"), null);
  // Остальное на месте: чужому ничего не раскрываем и не подтверждаем.
  assert.equal(r.headers.get("Vary"), "Origin");

  const noOrigin = preflightResponse(null);
  assert.equal(noOrigin.headers.get("Access-Control-Allow-Origin"), null);
});

test("заголовки, которые присылает supabase-js, разрешены", () => {
  for (const h of ["authorization", "apikey", "content-type", "x-client-info"]) {
    assert.ok(ALLOW_HEADERS.includes(h), h);
  }
  assert.equal(ALLOW_METHODS, "POST, OPTIONS");
});

test("ОТВЕТЫ ОБ ОШИБКАХ тоже несут заголовки CORS", async () => {
  for (const status of [400, 401, 403, 405, 409, 422, 500]) {
    const r = jsonResponse(status, { ok: false, error: "x" }, PORTAL);
    assert.equal(r.status, status);
    assert.equal(r.headers.get("Access-Control-Allow-Origin"), PORTAL, String(status));
    assert.equal(r.headers.get("Vary"), "Origin", String(status));
    // Тело остаётся читаемым JSON: портал должен показать причину.
    assert.deepEqual(await r.json(), { ok: false, error: "x" });
  }
});

test("обычный ответ POST не изменился: тот же JSON и тип содержимого", async () => {
  const body = { ok: true, brand: "acme", version: 3 };
  const r = jsonResponse(200, body, PORTAL);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("Content-Type"), "application/json");
  assert.deepEqual(await r.json(), body);
  assert.equal(r.headers.get("Access-Control-Allow-Origin"), PORTAL);
});

test("чужой адрес: ответ приходит, но без Allow-Origin — браузер его отбросит", async () => {
  const r = jsonResponse(200, { ok: true }, STRANGER);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("Access-Control-Allow-Origin"), null);
  assert.deepEqual(await r.json(), { ok: true });
});

test("Origin берётся из запроса как есть", () => {
  const req = new Request("https://x.test/functions/v1/brand-upload", {
    method: "OPTIONS",
    headers: { Origin: PORTAL },
  });
  assert.equal(req.headers.get("Origin"), PORTAL);
  assert.equal(preflightResponse(req.headers.get("Origin")).headers.get("Access-Control-Allow-Origin"), PORTAL);

  const bare = new Request("https://x.test/functions/v1/brand-upload", { method: "POST" });
  assert.equal(bare.headers.get("Origin"), null);
  assert.equal(jsonResponse(200, {}, bare.headers.get("Origin")).headers.get("Access-Control-Allow-Origin"), null);
});
