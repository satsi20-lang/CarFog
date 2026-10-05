# R2: живые проверки — файлы и SQL для владельца

Выполняет только владелец в панели Supabase (Storage и SQL Editor). Секретов
здесь нет. `<ID>` — id устройства из панели.

## 1. Файлы для загрузки в бакет `releases` (Storage → releases → Upload)

Лежат в домашней папке (`~`) на компьютере разработчика:

| Файл (загружать под этим именем) | Версия | SHA-256 | Размер, байт |
|---|---|---|---|
| `carfog-1.5.1-b9-55f80e25deb2.apk` | 1.5.1 (9) — копия A, для `not_newer` | `55f80e25deb25b7eb276713b6966d166c0e786ce29bf41a1702d040f18f436ed` | 19524769 |
| `carfog-1.5.2-b10-d94a89032578.apk` | 1.5.2 (10) — B | `d94a890325783da6b6de9d3b0926a96e2bb76dbdcc068b0d4bb7c8d18eb2e552` | 19524769 |
| `carfog-1.5.3-b11-3df8786bdfb8.apk` | 1.5.3 (11) — C, без сигнала здоровья (для проверки отката) | `3df8786bdfb8fad6d7b777a96cf4e0264ff6e92d1c96d9ebbac62b5cb770e741` | 19524769 |

Сборка A (1.5.1+9) ставится на планшет по `adb`, в бакет её нужно только
для проверки `not_newer`.

## 2. Записи о релизах (SQL Editor, по одной)

```sql
-- B: нормальное обновление
insert into app_releases (version_name, version_code, file_path, sha256, size_bytes, notes)
values ('1.5.2', 10, 'carfog-1.5.2-b10-d94a89032578.apk',
        'd94a890325783da6b6de9d3b0926a96e2bb76dbdcc068b0d4bb7c8d18eb2e552', 19524769, 'живая проверка B')
returning id;

-- C: сборка без сигнала здоровья (откат по таймауту)
insert into app_releases (version_name, version_code, file_path, sha256, size_bytes, notes)
values ('1.5.3', 11, 'carfog-1.5.3-b11-3df8786bdfb8.apk',
        '3df8786bdfb8fad6d7b777a96cf4e0264ff6e92d1c96d9ebbac62b5cb770e741', 19524769, 'живая проверка отката')
returning id;

-- sha_mismatch: файл B, но сумма с искажённой последней цифрой (2 -> 3)
insert into app_releases (version_name, version_code, file_path, sha256, size_bytes, notes)
values ('1.5.4', 12, 'carfog-1.5.2-b10-d94a89032578.apk',
        'd94a890325783da6b6de9d3b0926a96e2bb76dbdcc068b0d4bb7c8d18eb2e553', 19524769, 'проверка sha_mismatch')
returning id;

-- not_newer: версия 9 = как у установленной A
insert into app_releases (version_name, version_code, file_path, sha256, size_bytes, notes)
values ('1.5.1', 9, 'carfog-1.5.1-b9-55f80e25deb2.apk',
        '55f80e25deb25b7eb276713b6966d166c0e786ce29bf41a1702d040f18f436ed', 19524769, 'проверка not_newer')
returning id;
```

Пришлите мне четыре `id` (B, C, sha_mismatch, not_newer).

## 3. Команды устройству

```sql
-- update_app (подставьте id релиза)
insert into commands (device_id, org_id, action, params)
select id, org_id, 'update_app', jsonb_build_object('release_id', '<ID РЕЛИЗА>')
from devices where id = '<ID>';

-- rollback_app
insert into commands (device_id, org_id, action, params)
select id, org_id, 'rollback_app', '{}'::jsonb
from devices where id = '<ID>';
```

## 4. Просмотр исходов

```sql
select created_at, action, status, result
from commands where device_id = '<ID>' order by created_at desc limit 10;

select created_at, type, data
from events where device_id = '<ID>' order by created_at desc limit 20;
```

---

# Серия 2: проверка выживания скрипта (исправленная база 1.5.5+13)

Базу `carfog-1.5.5-b13-d3bb3b2e5c73.apk` ставит разработчик по `adb`, в бакет её
загружать не нужно. В бакет `releases` загрузить:

| Файл | Версия | SHA-256 | Размер, байт |
|---|---|---|---|
| `carfog-1.5.6-b14-c48165514b3b.apk` | 1.5.6 (14) — B' | `c48165514b3bf3f7cfeeacc6b13260ffc92754bfd39269b32825c1ece5354f9d` | 19524769 |
| `carfog-1.5.7-b15-f82ec18309dc.apk` | 1.5.7 (15) — C', без сигнала здоровья | `f82ec18309dcf02198a9028ea584ac7acfd8e2de22b3ff6e8275e6bd36e086a4` | 19524769 |

```sql
-- B'
insert into app_releases (version_name, version_code, file_path, sha256, size_bytes, notes)
values ('1.5.6', 14, 'carfog-1.5.6-b14-c48165514b3b.apk',
        'c48165514b3bf3f7cfeeacc6b13260ffc92754bfd39269b32825c1ece5354f9d', 19524769, 'серия 2: B')
returning id;

-- C' (откат по таймауту)
insert into app_releases (version_name, version_code, file_path, sha256, size_bytes, notes)
values ('1.5.7', 15, 'carfog-1.5.7-b15-f82ec18309dc.apk',
        'f82ec18309dcf02198a9028ea584ac7acfd8e2de22b3ff6e8275e6bd36e086a4', 19524769, 'серия 2: C без здоровья')
returning id;
```

Пришлите два `id` (B' и C').
