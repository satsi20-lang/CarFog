-- ============================================================
-- Проверка хеширования токенов аппаратов и прав на функции
-- (20261018000000_token_hash_phase_a.sql, 20261018000100_token_hash_phase_b.sql,
-- 20261018000200_function_grants_hardening.sql).
-- НЕ применять к рабочей базе: запускать на копии/тестовом проекте под
-- полными правами (SQL Editor). Всё в одной транзакции, в конце rollback.
--
-- Что подставить:
--   <ORG_ID>  организация, в которую временно заводится тестовый аппарат
-- Токен тестового аппарата заведомо вымышленный (YOUR_TOKEN_HERE); в базу
-- пишется только его хеш, как при заведении настоящего аппарата.
-- Каждая проверка пишет в «Messages» строку ok или ОШИБКА.
-- ============================================================
begin;

-- ---------- схема: token пуст, token_hash обязателен и уникален ----------
do $$
declare n int; nn text;
begin
  select count(*) into n from public.devices where token is not null;
  if n = 0 then raise notice 'ok: открытых токенов в devices нет'; else raise notice 'ОШИБКА: открытых токенов: %', n; end if;

  select is_nullable into nn from information_schema.columns
   where table_schema = 'public' and table_name = 'devices' and column_name = 'token_hash';
  if nn = 'NO' then raise notice 'ok: token_hash NOT NULL'; else raise notice 'ОШИБКА: token_hash допускает NULL'; end if;
  select is_nullable into nn from information_schema.columns
   where table_schema = 'public' and table_name = 'devices' and column_name = 'token';
  if nn = 'YES' then raise notice 'ok: token допускает NULL'; else raise notice 'ОШИБКА: token NOT NULL'; end if;

  select count(*) into n from public.devices where token_hash !~ '^[0-9a-f]{64}$';
  if n = 0 then raise notice 'ok: все token_hash — 64 hex'; else raise notice 'ОШИБКА: token_hash не sha256 hex: %', n; end if;

  if exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'devices'
              and indexname = 'devices_token_hash_key' and indexdef ilike '%unique%') then
    raise notice 'ok: уникальный индекс devices_token_hash_key';
  else raise notice 'ОШИБКА: нет уникального индекса по token_hash'; end if;
end $$;

-- ---------- тестовый аппарат: только хеш (как в batch.sql генератора) ----------
insert into public.devices (id, org_id, name, token_hash, ring)
values ('TOKEN-HASH-TEST', '<ORG_ID>', 'TOKEN-HASH-TEST',
        encode(sha256(convert_to('YOUR_TOKEN_HERE', 'UTF8')), 'hex'), 'test');

-- без token_hash вставка падает (старые скрипты с token ломаются явно)
do $$ begin
  insert into public.devices (id, org_id, name, token, ring)
  values ('TOKEN-HASH-OLD', '<ORG_ID>', 'TOKEN-HASH-OLD', 'YOUR_TOKEN_HERE', 'test');
  raise notice 'ОШИБКА: аппарат без token_hash вставлен';
exception when not_null_violation then
  raise notice 'ok: вставка без token_hash отклонена (NOT NULL)';
end $$;

-- ---------- функции проверяют токен по хешу ----------
do $$
declare r jsonb; cmd uuid;
begin
  if public.device_token_valid('TOKEN-HASH-TEST', 'YOUR_TOKEN_HERE') then
    raise notice 'ok: device_token_valid принимает верный токен';
  else raise notice 'ОШИБКА: device_token_valid отверг верный токен'; end if;
  if not public.device_token_valid('TOKEN-HASH-TEST', 'WRONG_TOKEN_HERE') then
    raise notice 'ok: device_token_valid отвергает неверный токен';
  else raise notice 'ОШИБКА: device_token_valid принял неверный токен'; end if;
  -- хеш вместо токена не подходит (иначе утечка token_hash = утечка токена)
  if not public.device_token_valid('TOKEN-HASH-TEST',
           encode(sha256(convert_to('YOUR_TOKEN_HERE', 'UTF8')), 'hex')) then
    raise notice 'ok: хеш вместо токена не принимается';
  else raise notice 'ОШИБКА: хеш принят как токен'; end if;

  r := public.device_poll('TOKEN-HASH-TEST', 'YOUR_TOKEN_HERE', 'test', null);
  if (r->>'ok')::boolean and r ? 'target' then raise notice 'ok: device_poll по хешу (поле target есть)';
  else raise notice 'ОШИБКА: device_poll: %', r; end if;
  r := public.device_poll('TOKEN-HASH-TEST', 'WRONG_TOKEN_HERE', 'test', null);
  if r->>'error' = 'auth' then raise notice 'ok: device_poll с неверным токеном — auth';
  else raise notice 'ОШИБКА: device_poll с неверным токеном: %', r; end if;

  r := public.device_report('TOKEN-HASH-TEST', 'YOUR_TOKEN_HERE',
                            '[{"type":"token_hash_test","data":{}}]'::jsonb);
  if (r->>'ok')::boolean then raise notice 'ok: device_report по хешу';
  else raise notice 'ОШИБКА: device_report: %', r; end if;
  r := public.device_report('TOKEN-HASH-TEST', 'WRONG_TOKEN_HERE', '[]'::jsonb);
  if r->>'error' = 'auth' then raise notice 'ok: device_report с неверным токеном — auth';
  else raise notice 'ОШИБКА: device_report с неверным токеном: %', r; end if;

  insert into public.commands (device_id, org_id, action, params)
  values ('TOKEN-HASH-TEST', '<ORG_ID>', 'ping', '{}'::jsonb) returning id into cmd;
  r := public.device_ack('TOKEN-HASH-TEST', 'WRONG_TOKEN_HERE', cmd, true, null);
  if r->>'error' = 'auth' then raise notice 'ok: device_ack с неверным токеном — auth';
  else raise notice 'ОШИБКА: device_ack с неверным токеном: %', r; end if;
  r := public.device_ack('TOKEN-HASH-TEST', 'YOUR_TOKEN_HERE', cmd, true, 'ok');
  if (r->>'ok')::boolean and (select status from public.commands where id = cmd) = 'done' then
    raise notice 'ok: device_ack по хешу';
  else raise notice 'ОШИБКА: device_ack: %', r; end if;
end $$;

-- ---------- столбцы token и token_hash закрыты для anon и authenticated ----------
do $$
declare bad text := ''; r text; c text; pr text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    foreach c in array array['token', 'token_hash'] loop
      foreach pr in array array['SELECT', 'INSERT', 'UPDATE', 'REFERENCES'] loop
        if has_column_privilege(r, 'public.devices', c, pr) then
          bad := bad || format(' %s:%s.%s', r, c, pr);
        end if;
      end loop;
    end loop;
  end loop;
  if bad = '' then raise notice 'ok: token и token_hash закрыты для anon и authenticated';
  else raise notice 'ОШИБКА: права на столбцы:%', bad; end if;
end $$;

-- ---------- права на функции ----------
do $$
declare bad text := ''; f text;
begin
  foreach f in array array[
    'public.device_poll(text,text,text,jsonb)',
    'public.device_report(text,text,jsonb)',
    'public.device_ack(text,text,uuid,boolean,text)',
    'public.device_diag_put(text,text,text,integer,integer,text)',
    'public.device_release_get(text,text,uuid)'
  ] loop
    if not has_function_privilege('anon', f, 'EXECUTE') then bad := bad || ' нет anon:' || f; end if;
    if not has_function_privilege('service_role', f, 'EXECUTE') then bad := bad || ' нет service_role:' || f; end if;
    if has_function_privilege('authenticated', f, 'EXECUTE') then bad := bad || ' authenticated:' || f; end if;
  end loop;
  -- проверка токена напрямую снаружи недоступна (подбор токена)
  if has_function_privilege('anon', 'public.device_token_valid(text,text)', 'EXECUTE') then bad := bad || ' anon:device_token_valid'; end if;
  if has_function_privilege('authenticated', 'public.device_token_valid(text,text)', 'EXECUTE') then bad := bad || ' authenticated:device_token_valid'; end if;
  foreach f in array array['public.is_org_member(uuid)', 'public.is_staff(uuid)'] loop
    if has_function_privilege('anon', f, 'EXECUTE') then bad := bad || ' anon:' || f; end if;
    if not has_function_privilege('authenticated', f, 'EXECUTE') then bad := bad || ' нет authenticated:' || f; end if;
  end loop;
  if bad = '' then raise notice 'ok: права на device_*, is_org_member, is_staff как задумано';
  else raise notice 'ОШИБКА: права на функции:%', bad; end if;

  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = '_claim_hash'
                and 'search_path=public' = any (p.proconfig)) then
    raise notice 'ok: _claim_hash с фиксированным search_path';
  else raise notice 'ОШИБКА: у _claim_hash не задан search_path'; end if;
end $$;

rollback;
