# Видео заставки через портал (плейлист с галочками)

ТЗ — `docs/video_playlist_tz.md`. Опись текущего видео — `docs/inventory/video_inventory.md`.
Состояние: **файлы готовы, НЕ применено и НЕ развёрнуто.** Применяет ассистент после отдельного «да» владельца.

## 1. Как устроено, в двух словах
1. Клиент (свои аппараты) или супервайзер с 2FA (любой аппарат) выбирает mp4 в портале. Браузер считает sha256, вызывает `video_upload_begin`, получает от `video-upload-url` одноразовую ссылку и грузит файл прямо в закрытый бакет `device-videos`.
2. Портал вызывает `video-validate`: функция читает файл диапазонами (заголовки и moov, не весь файл), проверяет H.264 и разрешение под профиль планшета. Не подошло — файл удаляется, статус `rejected` с причиной. Подошло — `ready`, `videos_rev++`.
3. Аппарат видит новый `videos_rev` в `device_poll`, вызывает `device_videos_get`, скачивает недостающее по ссылке от `video-url`, проверяет и сообщает `device_video_report`.
4. Галочка «Проигрывать» — `video_set_play` (`videos_rev++`). Аппарат играет отмеченные по кругу в порядке даты добавления; если ничего не отмечено — встроенное видео.
5. Удаление — `video_delete`: если файл мог быть на аппарате, статус `delete_requested`, аппарат удаляет и отчитывается; иначе сразу `deleted`. Файлы из бакета раз в сутки убирает `video-purge`.

## 2. Что где лежит
| Что | Файл |
|---|---|
| Миграция (бакет, таблица, функции, `device_poll`) | `supabase/migrations/20261109000000_video1_playlist.sql` |
| Расписание уборки (pg_cron) | `supabase/migrations/20261109000100_video1_cron.sql` |
| Проверка прав | `supabase/tests/rls_videos.sql` |
| Загрузочная ссылка | `supabase/functions/video-upload-url/` |
| Проверка содержимого | `supabase/functions/video-validate/` (`logic.ts` — разбор MP4, `fixtures/` + `make_fixtures.mjs`) |
| Ссылка на скачивание аппарату | `supabase/functions/video-url/` |
| Уборка бакета | `supabase/functions/video-purge/` |
| Общее | `supabase/functions/_shared/video_rules.ts`, `_shared/cors.ts` |

## 3. Функции базы
| Функция | Кто | Что делает |
|---|---|---|
| `video_list(device)` | клиент / супервайзер(2FA) | список для портала, без пути в бакете |
| `video_upload_begin(device, title, size, sha256)` | то же | строка `pending_upload`; пределы: ≤ 5 ожидающих, ≤ 100 живых видео на аппарат |
| `video_set_play(video, play)` | то же | галочка; только для `ready`/`on_device` |
| `video_delete(video)` | то же | см. п. 1.5; файл, который Android не даёт удалить, — `not_deletable` |
| `video_access_check(video)` | то же, из Edge Functions под JWT | права + данные для проверки файла |
| `_video_mark_validating / validated / rejected / failed`, `_video_purge_pick / done`, `device_video_path` | только `service_role` | Edge Functions |
| `device_videos_get(device, token)` | аппарат (anon) | желаемое состояние; не чаще раза в 30 с |
| `device_video_report(device, token, items)` | аппарат (anon) | полный снимок; ≤ 200 элементов |
| `device_poll` | аппарат | то же тело, что в BRAND1, + поле `videos_rev` |

Формат `items` отчёта:
```
{"kind":"upload","id":"<uuid>","state":"downloading|present|missing|failed:<причина>"}
{"kind":"local","local_name":"a.mp4","size_bytes":N,"width":W,"height":H,"duration_ms":D,"deletable":true,"mtime_ms":T}
```

### Журнал
Пишется в `staff_audit`, а не в отдельную таблицу (один журнал). Действие называется по роли — `supervisor_video_*` или `customer_video_*` (`upload_begin`, `validated`, `rejected`, `play_on`, `play_off`, `delete`); в `details`: `role`, `video_id`, `title`, `size_bytes`, `source`. Актор — `auth.uid()` (для записей из Edge Functions актор передаётся явно). Читает журнал персонал организации; клиент свои записи не видит, но они сохраняются.

### Решение по ручным файлам
Новый файл с карты (`sd_local`) создаётся с `play = true`: до обновления все ручные видео играли, и после него заставка не должна замолчать. Загруженные через портал начинаются с `play = false`.

## 4. Протокол загрузки для портала
1. `video_upload_begin` → `video_id`.
2. `POST video-upload-url {"video_id"}` с JWT → `{path, signed_url, token}`.
3. Загрузка в Storage по `signed_url`: `PUT` с `multipart/form-data` — поля `cacheControl` = `3600` и файл (как делает `uploadToSignedUrl` в supabase-js; для полосы прогресса — тот же запрос через `XMLHttpRequest`).
4. `POST video-validate {"video_id"}` с JWT → `ready` или отказ.

Предел размера: у бакета `file_size_limit` не задан, действует **глобальный предел проекта** (Storage → Settings; на бесплатном тарифе Supabase — 50 МБ, на платном настраивается до 500 ГБ). Если файл больше, Storage ответит 413 — портал показывает понятное сообщение. Загрузка по подписанной ссылке — обычная (не возобновляемая): для очень больших файлов стоит проверить предел при приёмке.

### Причины отказа (`reject_reason`: `код` или `код:подробности`)
`size_mismatch` (размер в хранилище ≠ объявленному), `empty`, `not_mp4`, `truncated`, `no_moov`, `moov_too_large`, `bad_structure`, `no_video`, `not_h264:<кодек>`, `wrong_resolution:<ШxВ> need <ШxВ>`, `unknown_profile:<профиль>`. Портал переводит по коду (EN/RU/ET).

Профили: `ixp101m1` — 1280×800; `sy156-a510` — 1080×1920. Видео с поворотом на 90/270° в метаданных считается с учётом поворота. Новый профиль добавляется в `PROFILES` (`video-validate/logic.ts`).

Звук в файле допустим: аппарат играет по настройке «Звук видео ожидания» (по умолчанию без звука).

## 5. Решения исполнителя
- **Срок ссылки на скачивание — 6 часов.** Файл без лимита размера, связь 4G: 2 ГБ при 1 Мбит/с ≈ 4,5 ч. Ссылка привязана к одному файлу и выдаётся только по токену аппарата для его же готового видео. Истекла — приложение берёт новую и докачивает по Range.
- **Ссылка на загрузку — одноразовая** (без upsert), токен живёт 2 часа (платформа).
- **Уборка — раз в сутки** (`video-purge`), ссылки на `deleted` не выдаются сразу. Сразу удалять из базы нельзя: файл в Storage остался бы. Брошенные загрузки старше 2 суток и запросы удаления старше 30 дней (аппарат так и не ответил) закрываются сами.
- **sha256 сервер не проверяет** — это потребовало бы скачать файл целиком. Хеш считает браузер, сверяет аппарат (несовпадение = `failed:sha256` на аппарате).
- **Структура фикстур.** Тестовые mp4 собраны побайтно по ISO 14496-12 (настоящие боксы), но кадры — заполнитель: ffmpeg на машине нет. Реальный декодируемый файл нужен для живой проверки на аппарате.

## 5а. Приложение (ветка `video-playlist`)
| Что | Файл |
|---|---|
| Сервис синхронизации, скачивание, проверки, отчёт | `lib/video/video_service.dart` |
| Обмен с облаком (набор, ссылка, Range, отчёт) | `lib/video/video_api.dart` |
| Android: папки на SD, свободное место, кадр, право удаления | `lib/video/video_platform.dart` + `MainActivity.kt` (канал `storage`: `videoDirs`, `freeBytes`, `probeVideo`, `canDelete`) |
| Модель, порядок проигрывания, элементы отчёта | `lib/video/video_model.dart` |
| Набор для заставки | `lib/video/video_playlist.dart`, `lib/screens/standby.dart` |

Как работает:
- `device_poll` отдаёт `videos_rev`. Изменился (или отчёта ещё не было, или прошли сутки, или есть недоделанная работа) — в фоне идёт проход: `device_videos_get` → удаление помеченного → скачивание недостающего по одному → `device_video_report`. Опрос облака проход не ждёт.
- **Папка**: `СЪЁМНЫЙ_ТОМ/Android/data/ee.carfog.dryfog/files/videos/<id>.mp4`. Новых разрешений нет (своя папка приложения; `MANAGE_EXTERNAL_STORAGE` уже было и нужно только для ручных файлов). Нет карты — `failed:no_sd`, встроенную память не занимаем.
- **Скачивание**: проверка места (остаток файла + запас 256 МБ) ДО начала; ссылка от `video-url` на каждую попытку; файл `<id>.part` с докачкой по `Range` (до 5 попыток, паузы 12/24/36… с); проверка размера → sha256 → кадр через `MediaMetadataRetriever`; затем атомарное переименование. Любая ошибка проверки — файл удаляется, в отчёт `failed:<причина>` (`no_space`, `no_sd`, `network`, `http_NNN`, `auth`, `sha256`, `size`, `probe`, `io`, `ticket`). Исключение: при обрыве связи недокачанный `.part` остаётся и докачается по Range. Неудача того же видео повторяется не раньше, чем через 30 с, 1, 2… до 15 мин.
- **Приоритет**: качаем, хешируем и проверяем только пока аппарат на заставке. Пришёл клиент — загрузка встаёт на паузу (остаток сохраняется), после возврата на заставку идёт дальше. Так диск, процессор и связь не мешают оплате и циклу.
- **Проигрывание**: отмеченные и присутствующие на карте — по кругу в порядке даты добавления (у файлов с карты — время изменения). Набор меняется на границе ролика, без перезапуска; один ролик крутится плеером по кругу, и при смене набора зацикливание снимается. Набор сохраняется в `filesDir/videos_state.json`, поэтому после включения без сети играет последний набор.
- **Звук**: прежняя настройка «Звук видео ожидания» (по умолчанию без звука) — она применяется к каждому ролику, откуда бы он ни был.
- **Ничего не отмечено**: встроенного видео CaRFog в приложении нет (в `assets/` только логотип и QR), поэтому играет обычная заставка с логотипом и QR. См. вопрос владельцу.
- **Набор от облака ни разу не получен** (нет связи после обновления): заставка играет файлы папки `vid` по-старому.
- **Файлы с карты**: сервер заводит их с галочкой, и до первого отчёта они тоже играют — заставка после обновления не замолкает. «Удалить» доступно, если Android позволяет (`MANAGE_EXTERNAL_STORAGE` выдано).
- **Уборка**: в папке приложения удаляются файлы `<uuid>.mp4/.part`, которых сервер не знает (если он вернул пустой набор — не трогаем: подозрительный ответ). Чужие имена не трогаем никогда.
- **Диагностика**: блок `app.videos` — `rev`, `state` (idle/syncing/paused), `sd_present`, `free_bytes`, число видео и играющих, `failed` (id → причина), `last_error`, времена; без ссылок и токенов.

## 6. Порядок применения (для ассистента, после «да»)
1. **Миграция.** Выполнить `supabase/migrations/20261109000000_video1_playlist.sql` целиком. Проверить: таблица `device_videos`, колонка `devices.videos_rev`, бакет `device-videos` (**не публичный**, без политик), `device_poll` отдаёт `videos_rev`.
2. **Проверка прав** на тестовом проекте/копии: `supabase/tests/rls_videos.sql` (подставить `<SUPERVISOR_UUID>`, `<CUSTOMER_UUID>`, `<DEVICE_ID>`, `<OTHER_DEVICE_ID>`, `<DEVICE_TOKEN>`). В «Messages» — ни одной строки «ОШИБКА». На рабочей базе не запускать.
3. **Edge Functions** (из папки проекта):
   ```
   supabase functions deploy video-upload-url          # с JWT (портал)
   supabase functions deploy video-validate            # с JWT (портал)
   supabase functions deploy video-url --no-verify-jwt # аппарат, публичный ключ
   supabase functions deploy video-purge --no-verify-jwt # вызывает pg_cron
   ```
   Секретов задавать не нужно (`SUPABASE_*` подставляет платформа); `DIAG_PURGE_SECRET` уже есть, если настроена очистка диагностики. Адрес портала должен быть в `ALLOWED_ORIGINS` (`_shared/cors.ts`) — там уже `https://app.carfog.online` и `http://localhost:5173`.
4. **Расписание.** В `20261109000100_video1_cron.sql` заменить `<PROJECT_REF>`; выполнить. Проверка: `select jobname, schedule, active from cron.job;`.
5. Глобальный предел размера файла Storage — по решению владельца (см. п. 4).

## 7. Как откатить
По шагам, от меньшего к большему.
1. **Остановить показ**: `update public.device_videos set play = false;` и `update public.devices set videos_rev = videos_rev + 1;` — аппараты вернутся к встроенному видео. Приложения без поддержки поля `videos_rev` его просто не читают.
2. **Убрать поле из `device_poll`**: выполнить заново тело из `20261106000000_brand1_brands.sql` (раздел 7) и вернуть права из его конца.
3. **Выключить уборку и функции**:
   ```sql
   select cron.unschedule('device-video-purge');
   ```
   ```
   supabase functions delete video-upload-url
   supabase functions delete video-validate
   supabase functions delete video-url
   supabase functions delete video-purge
   ```
4. **Удалить объекты и таблицы** (только если решено отказаться; уничтожает записи о видео и журнал связей):
   ```sql
   drop function if exists public.video_list(text);
   drop function if exists public.video_upload_begin(text, text, bigint, text);
   drop function if exists public.video_set_play(uuid, boolean);
   drop function if exists public.video_delete(uuid);
   drop function if exists public.video_access_check(uuid);
   drop function if exists public._video_mark_validating(uuid);
   drop function if exists public._video_mark_validated(uuid, uuid, text, int, int, bigint, boolean);
   drop function if exists public._video_mark_rejected(uuid, uuid, text, text);
   drop function if exists public._video_mark_failed(uuid, text);
   drop function if exists public._video_purge_pick(int);
   drop function if exists public._video_purge_done(uuid[]);
   drop function if exists public.device_video_path(text, text, uuid);
   drop function if exists public.device_videos_get(text, text);
   drop function if exists public.device_video_report(text, text, jsonb);
   drop function if exists public._video_audit(text, text, public.device_videos, uuid);
   drop function if exists public._video_role(text);
   drop function if exists public._video_denied();
   drop function if exists public._video_bump(text);
   drop table if exists public.device_videos;
   drop table if exists public.video_get_requests;
   drop table if exists public.video_url_requests;
   alter table public.devices drop column if exists videos_rev;
   -- файлы бакета сначала удалить в Storage, затем:
   delete from storage.buckets where id = 'device-videos';
   ```
   Записи `staff_audit` с действиями `*_video_*` остаются (журнал не стирается).

## 8. Проверки кода
```
node --test supabase/functions/video-validate/logic_test.ts
node --test supabase/functions/video-upload-url/logic_test.ts
node --test supabase/functions/video-url/logic_test.ts
node --test supabase/functions/video-purge/logic_test.ts
node --test supabase/functions/_shared/video_rules_test.ts
```
SQL (`rls_videos.sql`) на этой машине не запускался: нет PostgreSQL. Его прогоняет ассистент на тестовом проекте перед применением.
