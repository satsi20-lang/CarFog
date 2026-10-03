# Выпуск обновления и развёртывание доставки (простыми словами)

Файл сборки (APK) лежит в **закрытом** хранилище Supabase. Аппарат скачивает его
не по постоянному адресу, а по ссылке, которая действует **10 минут** и
выдаётся только после проверки токена аппарата.

## Один раз: подготовка сервера

1. В Supabase → SQL Editor выполните по порядку (каждый файл целиком):
   * `supabase/migrations/20261003000000_r1_server_token_poll.sql`
   * `supabase/migrations/20261003000100_r1_diagnostics.sql`
   * `supabase/migrations/20261003000200_r2_releases.sql`
   Перед этим прочитайте комментарии в начале каждого файла.
2. Разверните функцию выдачи ссылок:
   * **Через панель:** Edge Functions → *Deploy a new function* → имя
     `release-url` → вставьте содержимое `supabase/functions/release-url/index.ts`
     и `logic.ts` (как два файла) → **выключите** «Verify JWT» → Deploy.
   * **Через командную строку** (из папки проекта):
     `supabase functions deploy release-url --no-verify-jwt`
   «Verify JWT» выключается потому, что аппарат вызывает функцию публичным
   ключом, а подлинность аппарата проверяет сама функция по токену.
3. Сервисный ключ в функцию вставлять **не нужно** — Supabase подставляет
   `SUPABASE_SERVICE_ROLE_KEY` автоматически. Нигде в коде его нет.

## Каждый выпуск

1. Соберите релиз (нужен ваш ключ подписи, см. `docs/signing.md`):
   `flutter build apk --release`
   Номер сборки (`versionCode`, число после `+` в `pubspec.yaml`) должен быть
   **больше**, чем у установленной. Не сбрасывайте его.
2. Посчитайте контрольную сумму и размер:
   ```
   shasum -a 256 build/app/outputs/flutter-apk/app-release.apk
   stat -f%z build/app/outputs/flutter-apk/app-release.apk
   ```
3. Загрузите файл в бакет `releases` (Storage → releases → Upload). Имя с
   случайным хвостом: `carfog-1.6.0+10-a1b2c3d4e5f6.apk`.
4. Добавьте запись (SQL Editor):
   ```sql
   insert into app_releases (version_name, version_code, file_path, sha256, size_bytes, notes)
   values ('1.6.0', 10, 'carfog-1.6.0+10-a1b2c3d4e5f6.apk', '<sha256>', <размер>, 'что изменилось')
   returning id;
   ```
   Полученный `id` — идентификатор релиза для команды `update_app`.
5. Отправьте команду аппарату (не раньше, чем проверите её на тестовом):
   ```sql
   insert into commands (device_id, org_id, action, params)
   select id, org_id, 'update_app', jsonb_build_object('release_id', '<id релиза>')
   from devices where id = 'CARFOG-001';
   ```
