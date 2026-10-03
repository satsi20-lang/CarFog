-- ============================================================
-- Проверка RLS app_releases двумя пользователями РАЗНЫХ организаций.
-- НЕ применять к рабочей базе: запускать на копии/тестовом проекте.
-- Всё в одной транзакции и откатывается (rollback в конце).
-- Перед запуском заменить <USER_A_UUID> и <USER_B_UUID> на uuid двух
-- пользователей из auth.users, у которых в devices РАЗНЫЕ организации
-- (у A есть хотя бы одно своё устройство, у B — тоже).
-- ============================================================
begin;

-- запись о релизе создаёт A
select set_config('request.jwt.claims',
  '{"sub":"<USER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;
insert into public.app_releases(version_name, version_code, file_path, sha256, size_bytes)
values ('test', 999999, 'test.apk', repeat('a', 64), 1);
select 'A видит релизов' as check, count(*) from public.app_releases;   -- ожидается 1

-- B (другая организация) — должен ли он видеть релиз A?
reset role;
select set_config('request.jwt.claims',
  '{"sub":"<USER_B_UUID>","role":"authenticated"}', true);
set local role authenticated;
select 'B видит релизов' as check, count(*) from public.app_releases;
-- Если B видит 1 — релизы ОБЩИЕ для всех организаций (в таблице нет
-- organization_id; политика лишь требует «видеть хоть одно устройство»).
-- Если организации должны быть изолированы — нужна колонка владельца.

-- anon не имеет прав вовсе
reset role;
set local role anon;
do $$ begin
  perform 1 from public.app_releases;
  raise notice 'ОШИБКА: anon смог читать app_releases';
exception when insufficient_privilege then
  raise notice 'ok: anon не имеет доступа';
end $$;

rollback;
