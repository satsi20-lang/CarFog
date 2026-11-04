# Удалённая диагностика, уровень 1 (RD1)

Супервизор портала (с 2FA) видит пакет диагностики и снимок экрана аппарата
без сетевого ADB. Клиенту — только светофор. ТЗ: TZ_Remote_Diagnostics_v1
(разделы 4, 5, 10), опись — `docs/inventory/remote_diag_inventory.md`.

## Что в приложении

* `collect_diagnostics` (параметр `log_minutes` 1…60, по умолчанию 15) —
  пакет версии 2 (`lib/services/diagnostics_service.dart`):
  * время сбора в UTC с «Z», отдельно местное время, пояс и смещение;
  * профиль, киоск (Lock Task), сторож панелей (только `ixp101m1`);
  * сводка `health`, последние годные показания датчиков со временем;
  * статус терминала (без сырых кадров), температура планшета
    (`thermal_max_c`, если прошивка даёт читать);
  * 100 событий, журнал за N минут, но не меньше 300 строк;
  * потолок 200 КБ: сначала обрезаются старые строки журнала, потом
    старые события (поле `truncated`).
* `capture_screen` (`lib/services/screenshot_service.dart`): снимок корня
  Flutter, 800 px по длинной стороне, JPEG 70 (сжатие в Kotlin), отправка в
  Edge Function `diag-shot-upload`. Запрет: экран PIN, всё сервисное меню,
  открытый диалог ввода PIN — ответ `{"refused":…,"message":"снимок
  запрещён: …"}`. Лимит, как у `collect_diagnostics`: раз в минуту, 3 в час.
* Очистка (`AppLog.redact`): токены, PIN, ключи, пароли, `master_code`,
  `claim_code`, JWT, Bearer, номера карт (13–19 цифр, первая 2–6, Luhn),
  мастер-код при выдаче (`AppLog.addSecret`). Коды привязки приложению
  неизвестны (они только на сервере).
* Облачная сводка настроек: `kiosk_lock` {device_owner, lock_enabled,
  lock_task_active} и `health` {bus_ok, thermo, meter, terminal}. Старый
  `kiosk_mode_enabled` — про домашний экран, не менялся.

## Что применить в облаке (делает владелец, по порядку)

1. Миграция `supabase/migrations/20261104000000_rd1_remote_diag.sql`.
2. Функции (с `--no-verify-jwt`, как `release-url`):
   ```
   supabase functions deploy diag-shot-upload --no-verify-jwt
   supabase functions deploy diag-shot-purge --no-verify-jwt
   ```
3. Секрет очистки: придумать длинный случайный (40+ символов), положить в
   Vault (`diag_purge_secret`) и в переменную функции:
   `supabase secrets set DIAG_PURGE_SECRET=<секрет>`. Значение в репозиторий
   и чаты не класть.
4. Расписание: `supabase/migrations/20261104000100_rd1_cron.sql`, заменив
   `<PROJECT_REF>`.
5. Проверка прав на копии базы: `supabase/tests/rls_remote_diag.sql`.

## Решения и почему

* **Загрузка снимка — base64 через Edge Function, а не подписанная ссылка на
  загрузку.** Аппарат не получает прав на Storage и ссылки, по которой можно
  положить любой файл. Функция проверяет JPEG (сигнатура, до 400 КБ), токен
  и частоту проверяет база (`device_shot_register`).
* **Удаление файлов — через Edge Function.** Прямое удаление строк
  `storage.objects` в Supabase запрещено и самих файлов не стирает.
* **`supervisor_request_diag` — отдельная функция.** Тела
  `supervisor_send_command` в репозиториях нет; переписать его вслепую —
  риск сломать `update_config`. Если владелец даст текст, оба действия можно
  добавить туда.
* **Чтение снимка супервизором** — `supervisor_shot_latest` даёт путь,
  портал берёт `createSignedUrl` на 60 с; файл читается по политике бакета
  (только супервизор с aal2).
