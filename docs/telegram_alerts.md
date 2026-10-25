# Уведомления в Telegram (простыми словами)

Когда у аппарата заканчивается жидкость, жидкость пополнили, аппарат выведен
из обслуживания или пропала связь, в Telegram-канал организации приходит
короткое сообщение. Сообщения шлёт Edge Function `notify-telegram`;
приложение на аппарате для этого не менялось — функция читает события,
которые аппарат и так отправляет в таблицу `events`.

## Как это устроено

```
аппарат ──событие──▶ events ──Database Webhook (INSERT)──▶ notify-telegram ──▶ Telegram
                     devices ◀──Cron каждые 5 мин {"mode":"offline_check"}──┘
```

| Что случилось | Откуда известно | Сообщение |
|---|---|---|
| закончилась жидкость | событие `low_liquid` | ⚠️ Мойка: закончилась жидкость «Ваниль» |
| жидкость пополнена | событие `liquid_restored` | ✅ Мойка: жидкость «Ваниль» пополнена |
| выведен из обслуживания: перегрев | `out_of_service`, код `overheat` | 🔥 Мойка: аппарат выведен из обслуживания: перегрев |
| выведен из обслуживания: другое | `out_of_service`, прочие коды | ⛔ Мойка: аппарат выведен из обслуживания: прогрев не достиг цели за 180 с |
| нет связи | `devices.last_seen_at` старше 10 минут | 📴 Мойка: нет связи уже 12 мин |
| связь вернулась | `last_seen_at` снова свежий | ✅ Мойка: связь восстановлена |
| нужен ручной возврат по карте (с 1.11.0) | событие `payment_manual_refund_needed` | 💳 Мойка: нужен ручной возврат по карте 2,50 € — «Ваниль», оплата 22.10 14:05. Вернуть через кабинет Nayax |
| терминал оплаты картой недоступен (с 1.11.0) | событие `terminal_offline` | 💳 Мойка: оплата картой недоступна: терминал не отвечает |

* **Имя аппарата** — `devices.name`; если пусто — номер аппарата (`CARFOG-100`).
* **Причины** вывода из обслуживания — те же тексты, что в сервисном меню.
* **Повторы.** Одно и то же сообщение (аппарат + вид события + канал жидкости)
  — не чаще раза в 5 минут; лишние молча пропускаются. Исключение — ручной
  возврат по карте: ключ включает время одобрения платежа, поэтому каждый
  сорвавшийся платёж сообщается отдельно.
* **Оплата картой (1.11.0).** Время оплаты показывается по Таллину. Остальные
  события оплаты (`payment_card_*`, `payment_refunded_auto`,
  `terminal_recovered`, `terminal_unexpected_frame`, с 1.11.1
  `payment_client_cancelled_no_refund`, с 1.11.2 `terminal_reset`, с 1.11.5
  `terminal_frame_fragments`) идут только в облако.
  Частоту `terminal_offline` ограничивает и само приложение: не чаще раза в
  5 минут и только при смене статуса. **Эти два вида есть в исходниках
  функции, но работают только после повторного развёртывания
  `notify-telegram`** (развёртывание — отдельно, после проверки).
* **Нет связи** сообщается один раз; следующее сообщение по этому аппарату —
  только «связь восстановлена». Аппараты, которые ни разу не выходили на
  связь, не проверяются. Проверка идёт раз в 5 минут, поэтому сообщение
  приходит через 10–15 минут после пропадания связи.
* **Кому.** Канал задаётся на организацию (таблица `notify_channels`). Нет
  записи или она выключена — сообщений по аппаратам этой организации нет.
* Прочие события (оплаты, запуски, обновления и т. д.) функция пропускает.

### Таблицы (миграция `supabase/migrations/20261011000000_notify_telegram.sql`)

| Таблица | Что хранит |
|---|---|
| `notify_channels` | `org_id` → `chat_id` канала, `enabled` |
| `notify_offline_state` | аппараты, о которых уже отправлено «нет связи» |
| `notify_dedup` | время последней отправки по каждому виду сообщения (защита от повторов) |

Во всех трёх включена защита строк (RLS) без правил доступа: из приложения и
панели под обычным входом их не видно, читает и пишет только функция.
Записи в `notify_channels` владелец добавляет в SQL Editor.

### Секреты

Заданы владельцем в Edge Functions → Secrets:

* `TELEGRAM_BOT_TOKEN` — токен бота от @BotFather;
* `NOTIFY_WEBHOOK_SECRET` — длинная случайная строка; её же вызывающий
  передаёт в заголовке `x-notify-secret`. Без верного заголовка функция
  отвечает 401 и ничего не делает.

`SUPABASE_URL` и `SUPABASE_SERVICE_ROLE_KEY` Supabase подставляет сам. Токен и
секреты нигде не пишутся — ни в журнал функции, ни в её ответы. Ошибки
Telegram попадают в журнал функции без токена; функция при этом отвечает 200
с кратким статусом (`telegram_error`).

## Один раз: подготовка

1. **Таблицы.** Supabase → SQL Editor → выполнить целиком
   `supabase/migrations/20261011000000_notify_telegram.sql` (можно повторно).
2. **Функция.**
   * Через панель: Edge Functions → *Deploy a new function* → имя
     `notify-telegram` → два файла: `index.ts` и `logic.ts` из
     `supabase/functions/notify-telegram/` → **выключить** «Verify JWT» → Deploy.
   * Или из папки проекта: `supabase functions deploy notify-telegram --no-verify-jwt`

   «Verify JWT» выключается, потому что вызов проверяет сама функция по
   заголовку `x-notify-secret`.

   Адрес функции: `https://<проект>.supabase.co/functions/v1/notify-telegram`.

3. **Database Webhook** (события → функция): Database → Webhooks →
   *Create a new hook*:
   * Name: `notify_telegram`
   * Table: `events`, Events: только **Insert**
   * Type: **HTTP Request**, Method: `POST`,
     URL: адрес функции (см. выше)
   * HTTP Headers: `Content-Type: application/json` и
     `x-notify-secret: <значение NOTIFY_WEBHOOK_SECRET>`
   * Timeout: **5000** мс (по умолчанию 1000 — функции может не хватить:
     она читает базу и ждёт Telegram).

   Фильтр по типам событий не нужен: лишние функция пропускает сама (ответ
   `ignored`). Учтите, что вызов идёт на **каждую** вставку в `events`.

4. **Расписание** (проверка связи): Integrations → Cron → *Create job*:
   * Name: `notify_offline_check`
   * Schedule: `*/5 * * * *` (каждые 5 минут)
   * Type: **HTTP Request** (или Supabase Edge Function → `notify-telegram`),
     Method: `POST`, URL: адрес функции
   * Headers — **оба обязательны**:
     * `Content-Type: application/json`;
     * `x-notify-secret: <значение секрета NOTIFY_WEBHOOK_SECRET>`.
   * Заголовок `Authorization` **не нужен**: «Verify JWT» у функции выключен,
     вызов проверяется только по `x-notify-secret`.
   * Body: `{"mode":"offline_check"}`

   Если в Integrations нет Cron — включить расширения `pg_cron` и `pg_net`
   (Database → Extensions), пункт появится.

   **Статус «success» у Cron не значит, что функция приняла запрос** — только
   что запрос отправлен. Без заголовка `x-notify-secret` (или с неверным
   значением) функция отвечает `{"ok":false,"error":"auth"}` и ничего не
   делает, а Cron всё равно показывает «success». Ответ функции смотреть в
   её журнале: Edge Functions → notify-telegram → Logs.

   **Проверка Cron.** Взять аппарат, который молчит дольше 10 минут и о
   котором уже было «нет связи», сбросить для него запись (SQL Editor):
   ```sql
   delete from notify_offline_state where device_id = '<id молчащего аппарата>';
   ```
   и дождаться ближайшей пятиминутки: в канал должно прийти «нет связи».
   Не пришло — проверить заголовки задачи Cron (см. выше) и журнал функции.

## Подключить канал организации

1. Создать канал (или группу) в Telegram, добавить туда бота
   **администратором** с правом публиковать сообщения.
2. Написать в канал любое сообщение (чтобы бот получил обновление).
3. Узнать номер канала (режим `whoami`):
   ```
   curl -s -X POST https://<проект>.supabase.co/functions/v1/notify-telegram \
     -H 'Content-Type: application/json' \
     -H 'x-notify-secret: <секрет>' \
     -d '{"mode":"whoami"}'
   ```
   Ответ — список чатов из последних обновлений бота:
   `{"ok":true,"status":"done","chats":[{"id":-1001234567890,"title":"Аппараты","type":"channel"}]}`.
   Нужен `id` вашего канала (у каналов — отрицательный, начинается с `-100`).
   Если список пуст — напишите в канал ещё раз и повторите; обновления
   Telegram хранит около суток. Если `status` — `telegram_error`, проверьте,
   не назначен ли боту webhook (при нём `getUpdates` не работает).
4. Добавить запись (SQL Editor):
   ```sql
   insert into notify_channels (org_id, chat_id)
   values ('<org_id организации>', '-1001234567890')
   on conflict (org_id) do update set chat_id = excluded.chat_id, enabled = true;
   ```
   `org_id` организации видно по её аппаратам: `select id, name, org_id from devices;`.
   Временно выключить уведомления: `update notify_channels set enabled = false where org_id = '…';`.
5. Проверить (режим `test`):
   ```
   curl -s -X POST https://<проект>.supabase.co/functions/v1/notify-telegram \
     -H 'Content-Type: application/json' \
     -H 'x-notify-secret: <секрет>' \
     -d '{"mode":"test","org_id":"<org_id>"}'
   ```
   В канал придёт «Проверка связи». Ответ `{"ok":true,"status":"sent"}`;
   `no_channel` — нет включённой записи для этой организации;
   `telegram_error` — Telegram отказал (подробность — в журнале функции:
   Edge Functions → notify-telegram → Logs).

## Ответы функции

| Статус | Значение |
|---|---|
| 401 `auth` | нет или неверный `x-notify-secret` |
| 400 `bad_request` | тело не JSON или неизвестный режим |
| 200 `sent` | сообщение отправлено |
| 200 `ignored` | событие не из тех, о которых сообщаем |
| 200 `no_channel` | у организации нет включённого канала |
| 200 `duplicate` | такое же сообщение уже было меньше 5 минут назад |
| 200 `telegram_error` | Telegram не принял сообщение (см. журнал) |
| 200 `done` | `offline_check` / `whoami` выполнены; у `offline_check` — счётчики `offline`, `online`, `failed` |

## Тесты

Чистая логика (проверка секрета, тексты, экранирование, имя, повторы,
«нет связи / восстановлена», разбор `whoami`) — в
`supabase/functions/notify-telegram/logic_test.ts`:

```
cd supabase && node --test functions/notify-telegram/logic_test.ts
# или: deno test functions/notify-telegram/logic_test.ts
```
