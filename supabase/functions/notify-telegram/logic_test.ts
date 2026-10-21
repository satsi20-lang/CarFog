// Запуск: node --test functions/notify-telegram/logic_test.ts
//         (или deno test functions/notify-telegram/logic_test.ts)
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  DEDUP_WINDOW_MS,
  dedupAllows,
  dedupKey,
  type DeviceRow,
  deviceName,
  escapeHtml,
  euroFromCents,
  eventMessage,
  extractChats,
  isNotifiableType,
  OFFLINE_AFTER_MS,
  offlineMessage,
  onlineMessage,
  OOS_REASON_RU,
  parseRequest,
  planOffline,
  redact,
  secretMatches,
  tallinnTime,
} from "./logic.ts";

// ---------- секрет ----------

test("секрет: совпадает", () => {
  assert.equal(secretMatches("s3cret-value", "s3cret-value"), true);
});

test("секрет: не совпадает, другая длина, пусто, нет заголовка", () => {
  assert.equal(secretMatches("s3cret-valuX", "s3cret-value"), false);
  assert.equal(secretMatches("s3cret-valu", "s3cret-value"), false);
  assert.equal(secretMatches("s3cret-value-", "s3cret-value"), false);
  assert.equal(secretMatches("", "s3cret-value"), false);
  assert.equal(secretMatches(null, "s3cret-value"), false);
  assert.equal(secretMatches(undefined, "s3cret-value"), false);
});

test("секрет: не настроен на сервере — отказ всегда", () => {
  assert.equal(secretMatches("", ""), false);
  assert.equal(secretMatches("anything", undefined), false);
  assert.equal(secretMatches(null, null), false);
});

test("секрет: не-ASCII сравнивается по байтам", () => {
  assert.equal(secretMatches("ключ-ё", "ключ-ё"), true);
  assert.equal(secretMatches("ключ-е", "ключ-ё"), false);
});

// ---------- разбор входа ----------

const WEBHOOK = {
  type: "INSERT",
  table: "events",
  schema: "public",
  record: {
    id: 1,
    device_id: "CARFOG-100",
    org_id: "11111111-1111-1111-1111-111111111111",
    type: "low_liquid",
    ts: "2026-10-11T10:00:00Z",
    received_at: "2026-10-11T10:00:01Z",
    data: { channel: 2, flavor: "Ваниль" },
  },
  old_record: null,
};

test("вход: тело Database Webhook — режим event", () => {
  const r = parseRequest(WEBHOOK);
  assert.ok(r && r.mode === "event");
  assert.equal(r.record.device_id, "CARFOG-100");
  assert.equal(r.record.type, "low_liquid");
  assert.deepEqual(r.record.data, { channel: 2, flavor: "Ваниль" });
});

test("вход: вебхук не о вставке — игнорировать", () => {
  assert.deepEqual(parseRequest({ ...WEBHOOK, type: "UPDATE" }), { mode: "ignore" });
});

test("вход: прочие режимы", () => {
  assert.deepEqual(parseRequest({ mode: "offline_check" }), { mode: "offline_check" });
  assert.deepEqual(parseRequest({ mode: "whoami" }), { mode: "whoami" });
  assert.deepEqual(parseRequest({ mode: "test", org_id: "o" }), { mode: "test", org_id: "o" });
});

test("вход: негодные", () => {
  for (const bad of [
    null, 5, "x", {}, { mode: "nope" }, { mode: "test" },
    { table: "events", record: { type: "low_liquid" } },
    { table: "events", record: null },
    { mode: "event", record: { device_id: "D" } },
  ]) {
    assert.equal(parseRequest(bad), null, JSON.stringify(bad));
  }
});

test("вход: data не объект — пустой объект", () => {
  const r = parseRequest({ ...WEBHOOK, record: { ...WEBHOOK.record, data: null } });
  assert.ok(r && r.mode === "event");
  assert.deepEqual(r.record.data, {});
});

test("типы: о прочих событиях не сообщаем", () => {
  assert.equal(isNotifiableType("low_liquid"), true);
  assert.equal(isNotifiableType("liquid_restored"), true);
  assert.equal(isNotifiableType("out_of_service"), true);
  for (const t of ["app_started", "energy_reading", "out_of_service_cleared", "out_of_service_restored"]) {
    assert.equal(isNotifiableType(t), false);
    assert.equal(eventMessage(t, "A", {}), null);
  }
});

// ---------- имя и экранирование ----------

test("имя: devices.name, пусто — id", () => {
  assert.equal(deviceName("CARFOG-100", "Мойка на Ленина"), "Мойка на Ленина");
  assert.equal(deviceName("CARFOG-100", "  Мойка  "), "Мойка");
  assert.equal(deviceName("CARFOG-100", ""), "CARFOG-100");
  assert.equal(deviceName("CARFOG-100", "   "), "CARFOG-100");
  assert.equal(deviceName("CARFOG-100", null), "CARFOG-100");
  assert.equal(deviceName("CARFOG-100", undefined), "CARFOG-100");
});

test("экранирование HTML", () => {
  assert.equal(escapeHtml(`<b>A&B</b> "q"`), "&lt;b&gt;A&amp;B&lt;/b&gt; &quot;q&quot;");
  assert.equal(escapeHtml("&amp;"), "&amp;amp;");
});

test("экранирование: имя и вкус в сообщении", () => {
  const m = eventMessage("low_liquid", "<i>X</i>", { channel: 0, flavor: "A&B <script>" })!;
  assert.equal(m, "⚠️ &lt;i&gt;X&lt;/i&gt;: закончилась жидкость «A&amp;B &lt;script&gt;»");
  assert.equal(m.includes("<"), false);
  assert.equal(offlineMessage("<x>", 12).includes("<x>"), false);
  assert.equal(onlineMessage("<x>").includes("<x>"), false);
  const oos = eventMessage("out_of_service", "N", { code: "<weird>" })!;
  assert.equal(oos.includes("<weird>"), false);
});

// ---------- тексты ----------

test("тексты: жидкость", () => {
  assert.equal(
    eventMessage("low_liquid", "Мойка", { channel: 1, flavor: "Ваниль" }),
    "⚠️ Мойка: закончилась жидкость «Ваниль»",
  );
  assert.equal(
    eventMessage("liquid_restored", "Мойка", { channel: 1, flavor: "Ваниль" }),
    "✅ Мойка: жидкость «Ваниль» пополнена",
  );
});

test("тексты: вкус не указан — номер канала с единицы", () => {
  assert.equal(
    eventMessage("low_liquid", "M", { channel: 0, flavor: "" }),
    "⚠️ M: закончилась жидкость «канал 1»",
  );
  assert.equal(eventMessage("low_liquid", "M", {}), "⚠️ M: закончилась жидкость «?»");
});

test("тексты: перегрев", () => {
  assert.equal(
    eventMessage("out_of_service", "Мойка", { code: "overheat", since: "x", persisted: true }),
    "🔥 Мойка: аппарат выведен из обслуживания: перегрев",
  );
});

test("тексты: прочие причины — по-русски из сервисного меню", () => {
  assert.equal(
    eventMessage("out_of_service", "Мойка", { code: "heat_timeout" }),
    "⛔ Мойка: аппарат выведен из обслуживания: прогрев не достиг цели за 180 с",
  );
  for (const [code, reason] of Object.entries(OOS_REASON_RU)) {
    if (code === "overheat") continue;
    assert.equal(
      eventMessage("out_of_service", "N", { code }),
      `⛔ N: аппарат выведен из обслуживания: ${escapeHtml(reason)}`,
    );
  }
});

test("тексты: все коды из приложения имеют причину", () => {
  // lib/models/out_of_service.dart, OutOfServiceCode.
  for (const code of [
    "heater_no_power", "temp_sensor_fault", "heat_timeout", "heater_off_unconfirmed",
    "overheat", "output_stuck_on", "state_unreadable", "bus_down",
  ]) {
    assert.ok(OOS_REASON_RU[code], code);
  }
});

test("тексты: неизвестный и пустой код", () => {
  assert.equal(
    eventMessage("out_of_service", "N", { code: "new_code" }),
    "⛔ N: аппарат выведен из обслуживания: new_code",
  );
  assert.equal(
    eventMessage("out_of_service", "N", {}),
    "⛔ N: аппарат выведен из обслуживания: причина не указана",
  );
});

test("тексты: связь", () => {
  assert.equal(offlineMessage("Мойка", 15), "📴 Мойка: нет связи уже 15 мин");
  assert.equal(onlineMessage("Мойка"), "✅ Мойка: связь восстановлена");
});

// ---------- защита от повторов ----------

test("повторы: окно 5 минут", () => {
  assert.equal(DEDUP_WINDOW_MS, 300_000);
  assert.equal(dedupAllows(null, 1000), true);
  assert.equal(dedupAllows(0, 60_000), false);
  assert.equal(dedupAllows(0, DEDUP_WINDOW_MS - 1), false);
  assert.equal(dedupAllows(0, DEDUP_WINDOW_MS), true);
  assert.equal(dedupAllows(Number.NaN, 0), true);
});

test("повторы: часы сервера ушли назад — не молчим навсегда", () => {
  assert.equal(dedupAllows(100_000, 50_000), true);
});

test("повторы: ключ — аппарат + тип + канал", () => {
  const a = dedupKey("D1", "low_liquid", { channel: 0, flavor: "A" });
  assert.equal(a, "D1|low_liquid|0");
  // Другой канал, другой тип, другой аппарат — другие ключи.
  assert.notEqual(a, dedupKey("D1", "low_liquid", { channel: 1 }));
  assert.notEqual(a, dedupKey("D1", "liquid_restored", { channel: 0 }));
  assert.notEqual(a, dedupKey("D2", "low_liquid", { channel: 0 }));
  // Тот же канал с другим названием вкуса — тот же ключ.
  assert.equal(a, dedupKey("D1", "low_liquid", { channel: 0, flavor: "B" }));
  // У вывода из обслуживания канала нет.
  assert.equal(dedupKey("D1", "out_of_service", { code: "overheat" }), "D1|out_of_service|");
});

// ---------- нет связи / восстановлена ----------

const NOW = Date.parse("2026-10-11T12:00:00Z");
const ago = (min: number) => new Date(NOW - min * 60_000).toISOString();
const dev = (id: string, last: string | null): DeviceRow => ({
  id, org_id: "o", name: null, last_seen_at: last,
});

test("связь: порог 10 минут", () => {
  assert.equal(OFFLINE_AFTER_MS, 600_000);
  const p = planOffline([dev("A", ago(10)), dev("B", ago(11))], new Set(), NOW);
  assert.deepEqual(p.wentOffline.map((x) => x.device.id), ["B"]);
  assert.equal(p.wentOffline[0].minutes, 11);
  assert.deepEqual(p.cameBack, []);
});

test("связь: уже сообщено — повторно не сообщаем", () => {
  const p = planOffline([dev("A", ago(60))], new Set(["A"]), NOW);
  assert.deepEqual(p.wentOffline, []);
  assert.deepEqual(p.cameBack, []);
});

test("связь: вернулась после сообщения — «восстановлена»", () => {
  const p = planOffline([dev("A", ago(1)), dev("B", ago(2))], new Set(["A"]), NOW);
  assert.deepEqual(p.cameBack.map((d) => d.id), ["A"]);
  assert.deepEqual(p.wentOffline, []);
});

test("связь: никогда не выходил на связь — пропускаем", () => {
  const p = planOffline([dev("A", null), dev("B", "не дата")], new Set(["A"]), NOW);
  assert.deepEqual(p.wentOffline, []);
  assert.deepEqual(p.cameBack, []);
});

test("связь: минуты округляются вниз", () => {
  const p = planOffline([dev("A", new Date(NOW - 754_000).toISOString())], new Set(), NOW);
  assert.equal(p.wentOffline[0].minutes, 12);
});

// ---------- whoami ----------

test("whoami: только id, название и тип, без повторов", () => {
  const chats = extractChats([
    { update_id: 1, channel_post: { chat: { id: -1001, title: "Аппараты", type: "channel" }, text: "hi" } },
    { update_id: 2, my_chat_member: { chat: { id: -1001, title: "Аппараты", type: "channel" } } },
    { update_id: 3, message: { chat: { id: 42, username: "owner", first_name: "O", type: "private" }, from: { id: 42 } } },
    { update_id: 4, message: { chat: { id: -5, title: "Группа", type: "group" } } },
    { update_id: 5, poll: {} },
    null,
  ]);
  assert.deepEqual(chats, [
    { id: -1001, title: "Аппараты", type: "channel" },
    { id: 42, title: "owner", type: "private" },
    { id: -5, title: "Группа", type: "group" },
  ]);
  assert.deepEqual(extractChats(undefined), []);
});

// ---------- журнал ----------

test("журнал: токен вырезается", () => {
  const tok = "123456:AAH-secret-token";
  const out = redact(`fetch https://api.telegram.org/bot${tok}/sendMessage failed`, [tok, undefined]);
  assert.equal(out.includes(tok), false);
});

// ---------- оплата картой (приложение 1.11.0) ----------

test("оплата картой: оба новых типа отправляются", () => {
  assert.equal(isNotifiableType("payment_manual_refund_needed"), true);
  assert.equal(isNotifiableType("terminal_offline"), true);
  // остальные события оплаты — только в облако, не в Telegram
  for (const t of ["payment_card_success", "payment_refunded_auto", "terminal_recovered", "payment_card_declined"]) {
    assert.equal(isNotifiableType(t), false, t);
  }
});

test("ручной возврат: сумма, запах, время по Таллину", () => {
  const text = eventMessage("payment_manual_refund_needed", "Мойка", {
    amount_cents: 250,
    flavor: "Ваниль",
    approved_at: "2026-10-22T11:05:30Z", // 14:05 по Таллину (UTC+3, летнее время)
    coins_cents: 0,
  });
  assert.equal(
    text,
    "💳 Мойка: нужен ручной возврат по карте 2,50 € — «Ваниль», оплата 22.10 14:05. Вернуть через кабинет Nayax",
  );
});

test("ручной возврат: без суммы и времени — без них, запах по каналу", () => {
  const text = eventMessage("payment_manual_refund_needed", "Мойка", { flavor_index: 2 });
  assert.equal(text, "💳 Мойка: нужен ручной возврат по карте — «?». Вернуть через кабинет Nayax");
});

test("ручной возврат: имя и запах экранируются", () => {
  const text = eventMessage("payment_manual_refund_needed", "<b>", { amount_cents: 100, flavor: "A&B" });
  assert.ok(text!.includes("&lt;b&gt;"));
  assert.ok(text!.includes("«A&amp;B»"));
});

test("терминал недоступен: причины по-русски, неизвестная — как есть", () => {
  assert.equal(
    eventMessage("terminal_offline", "Мойка", { reason: "no_device" }),
    "💳 Мойка: оплата картой недоступна: адаптер терминала не найден",
  );
  assert.equal(
    eventMessage("terminal_offline", "Мойка", { reason: "no_answer" }),
    "💳 Мойка: оплата картой недоступна: терминал не отвечает",
  );
  assert.equal(
    eventMessage("terminal_offline", "Мойка", { reason: "x" }),
    "💳 Мойка: оплата картой недоступна: x",
  );
  assert.equal(
    eventMessage("terminal_offline", "Мойка", {}),
    "💳 Мойка: оплата картой недоступна: причина не указана",
  );
});

test("ручной возврат: разные платежи не склеиваются защитой от повторов", () => {
  const a = dedupKey("CARFOG-100", "payment_manual_refund_needed", { approved_at: "2026-10-22T11:05:30Z" });
  const b = dedupKey("CARFOG-100", "payment_manual_refund_needed", { approved_at: "2026-10-22T11:07:10Z" });
  assert.notEqual(a, b);
  // один и тот же платёж (повтор доставки) — один ключ
  assert.equal(a, dedupKey("CARFOG-100", "payment_manual_refund_needed", { approved_at: "2026-10-22T11:05:30Z" }));
  // terminal_offline — как прочие: не чаще раза в 5 минут на аппарат
  assert.equal(dedupKey("CARFOG-100", "terminal_offline", { reason: "no_answer" }), "CARFOG-100|terminal_offline|");
});

test("сумма и время: форматы и мусор", () => {
  assert.equal(euroFromCents(1990), "19,90");
  assert.equal(euroFromCents("250"), null);
  assert.equal(tallinnTime("2026-01-15T10:00:00Z"), "15.01 12:00"); // зимой UTC+2
  assert.equal(tallinnTime("вчера"), null);
});
