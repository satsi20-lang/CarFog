-- ============================================================
-- Проверка прав на app_releases (решение владельца 04.10.2026):
--   * authenticated (вошедший пользователь) — только чтение;
--   * insert / update / delete для authenticated запрещены;
--   * anon не видит ничего.
-- НЕ применять к рабочей базе: запускать на копии/тестовом проекте под
-- полными правами (SQL Editor). Всё в одной транзакции, в конце rollback.
-- Перед запуском заменить <USER_UUID> на uuid пользователя из auth.users,
-- у которого в devices есть хотя бы одно своё устройство.
-- Каждая проверка пишет в «Messages» строку ok или ОШИБКА.
-- ============================================================
begin;

-- Тестовая запись создаётся под полными правами (как это делает владелец).
insert into public.app_releases(version_name, version_code, file_path, sha256, size_bytes)
values ('rls-test', 2147483000, 'rls-test.apk', repeat('a', 64), 1);

-- ---------- authenticated: чтение разрешено ----------
select set_config('request.jwt.claims',
  '{"sub":"<USER_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare n int;
begin
  select count(*) into n from public.app_releases where version_code = 2147483000;
  if n = 1 then raise notice 'ok: authenticated читает релизы';
  else raise notice 'ОШИБКА: authenticated видит % строк (ожидалась 1)', n; end if;
end $$;

-- ---------- authenticated: запись запрещена ----------
do $$
begin
  insert into public.app_releases(version_name, version_code, file_path, sha256, size_bytes)
  values ('hack', 2147483001, 'x.apk', repeat('b', 64), 1);
  raise notice 'ОШИБКА: authenticated смог сделать insert';
exception when insufficient_privilege then
  raise notice 'ok: insert запрещён';
end $$;

do $$
begin
  update public.app_releases set notes = 'hack' where version_code = 2147483000;
  raise notice 'ОШИБКА: authenticated смог сделать update';
exception when insufficient_privilege then
  raise notice 'ok: update запрещён';
end $$;

do $$
begin
  delete from public.app_releases where version_code = 2147483000;
  raise notice 'ОШИБКА: authenticated смог сделать delete';
exception when insufficient_privilege then
  raise notice 'ok: delete запрещён';
end $$;

-- ---------- anon: не видит ничего ----------
reset role;
set local role anon;

do $$
declare n int;
begin
  select count(*) into n from public.app_releases;
  raise notice 'ОШИБКА: anon прочитал таблицу (% строк)', n;
exception when insufficient_privilege then
  raise notice 'ok: anon не имеет доступа к app_releases';
end $$;

-- ---------- storage: политик для бакета releases нет ----------
reset role;
do $$
declare n int;
begin
  select count(*) into n from pg_policies
  where schemaname = 'storage' and tablename = 'objects'
    and (policyname like 'releases\_%' or qual like '%releases%' or with_check like '%releases%');
  if n = 0 then raise notice 'ok: на storage.objects нет политик для бакета releases';
  else raise notice 'ОШИБКА: найдено % политик для бакета releases', n; end if;
end $$;

rollback;
