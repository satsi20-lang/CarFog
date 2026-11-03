# Выпуск обновления и развёртывание доставки (простыми словами)

Файл сборки (APK) лежит в **закрытом** хранилище Supabase. Аппарат скачивает его
не по постоянному адресу, а по ссылке, которая действует **10 минут** и
выдаётся только после проверки токена аппарата (по хешу `devices.token_hash`, см.
«Безопасность токенов аппаратов» в [docs/tenancy.md](tenancy.md)).

## Один раз: подготовка сервера

1. В Supabase → SQL Editor выполните по порядку (каждый файл целиком):
   * `supabase/migrations/20261003000000_r1_server_token_poll.sql`
   * `supabase/migrations/20261003000100_r1_diagnostics.sql`
   * `supabase/migrations/20261003000200_r2_releases.sql`
   Перед этим прочитайте комментарии в начале каждого файла. Проверка токена в
   этих файлах — по открытому `devices.token`; её заменяют миграции
   `20261018000000_token_hash_phase_a.sql`, `20261018000100_token_hash_phase_b.sql`
   и `20261018000200_function_grants_hardening.sql` (выполнять после R3–R5: новое
   тело `device_poll` использует `rollout_target` из R3). В боевой базе они уже
   применены 18.10.2026.
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
3. Загрузите файл в бакет `releases` (Storage → releases → Upload) **только из
   панели Supabase под владельцем проекта**: никаких политик на запись для
   пользователей нет, из приложений и скриптов под обычным входом загрузить
   файл нельзя. Формат имени:
   `carfog-<версия>-b<код>-<12 символов sha>.apk`, например
   `carfog-1.6.0-b10-a1b2c3d4e5f6.apk`. Знак «+» в именах файлов не использовать.

   **Сборка только под arm64.** Бесплатный Supabase Storage принимает файлы до
   50 МБ, универсальный APK (~54 МБ) не проходит, поэтому релизы собираются так:
   `flutter build apk --release --target-platform android-arm64` (≈19,5 МБ).
   Перед серией убедитесь, что процессор серийного планшета (Syoung SY156-A510)
   — arm64-v8a (`adb shell getprop ro.product.cpu.abilist`). Не используйте
   `--split-per-abi`: он меняет `versionCode`, и обновление сломается.
4. Добавьте запись (SQL Editor, **только под владельцем проекта**: у
   обычного входа права на запись в `app_releases` отозваны, читать можно):
   ```sql
   insert into app_releases (version_name, version_code, file_path, sha256, size_bytes, notes)
   values ('1.6.0', 10, 'carfog-1.6.0-b10-a1b2c3d4e5f6.apk', '<sha256>', <размер>, 'что изменилось')
   returning id;
   ```
   Полученный `id` — идентификатор релиза для команды `update_app`.
5. Отправьте команду аппарату (не раньше, чем проверите её на тестовом):
   ```sql
   insert into commands (device_id, org_id, action, params)
   select id, org_id, 'update_app', jsonb_build_object('release_id', '<id релиза>')
   from devices where id = 'CARFOG-001';
   ```

## Универсальная сборка: SY156-A510 и IXP101M1 (портрет)

С 1.8.0 по 1.11.5 приложение собиралось только под **Syoung SY156-A510**
(15,6", 1080x1920, плотность 240, портрет). Начиная с ветки
`ixp101m1-profile` сборка снова **универсальная**: одна APK работает и на
SY156-A510, и на прежнем планшете CARFOG-001 **IXP101M1** (RK3568, 10,1",
800x1280, портрет).

- Профили описаны в одном месте: `lib/models/hardware_profile.dart`
  (`sy156-a510`, `ixp101m1`). Профиль выбирается при старте по реальному
  устройству (`HardwareProfile.detect`: чип `rk3562`/`rk3568` в
  board/device/model/hardware, затем длинная сторона экрана); не узнан —
  `sy156-a510`. В журнал пишется строка `Hw: профиль …`.
- `tool/build_release.sh` печатает «ПРИМЕЧАНИЕ: версия … универсальная:
  SY156-A510 и IXP101M1 (портрет) (профили ixp101m1,sy156-a510)» и кладёт
  рядом с APK файл `<имя>.apk.note.txt`. Имя APK не меняется. В поле `notes`
  записи `app_releases` указывайте ту же фразу.
- В слепок настроек уходит профиль этого запуска (`hardware_profile`) и
  `bus_port`.
- Порт шины — настройка (`busPort`). Значение по умолчанию зависит от
  профиля: `/dev/ttyS4` на SY156-A510, `/dev/ttyS5` на IXP101M1. Сохранённое
  значение важнее значения по умолчанию: если на аппарате уже записан другой
  порт, его меняют в сервисном меню. Подробности — в
  [docs/hardware.md](hardware.md).
- Раскатку на IXP101M1 начинайте только после проверки на CARFOG-001.
