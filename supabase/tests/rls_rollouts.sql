-- ============================================================
-- Проверка прав R3 (раскатки по кольцам), по образцу rls_app_releases.sql.
-- НЕ применять к рабочей базе: запускать на копии/тестовом проекте под
-- полными правами (SQL Editor). Всё в одной транзакции, в конце rollback.
--
-- Перед запуском заменить:
--   <USER_A_UUID>   пользователь организации A (у неё есть устройство)
--   <USER_B_UUID>   пользователь ДРУГОЙ организации B (тоже с устройством)
--   <RELEASE_UUID>  id любой строки app_releases
--   <DEVICE_A_ID>   id устройства организации A
-- Каждая проверка пишет в «Messages» строку ok или ОШИБКА.
-- ВАЖНО: пока в rollout_my_org() не подставлен настоящий запрос членства,
-- функции панели отвечают 'forbidden' — проверки «своя организация»
-- покажут ОШИБКА, это ожидаемо (см. комментарий в миграции).
-- ============================================================
begin;

-- ---------- authenticated: прямая запись в таблицы запрещена ----------
select set_config('request.jwt.claims',
  '{"sub":"<USER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$ begin
  insert into public.rollouts(org_id, release_id, ring)
  values (gen_random_uuid(), '<RELEASE_UUID>', 'test');
  raise notice 'ОШИБКА: authenticated смог сделать insert в rollouts';
exception when insufficient_privilege then
  raise notice 'ok: insert в rollouts запрещён';
end $$;

do $$ begin
  update public.rollouts set status = 'active';
  raise notice 'ОШИБКА: authenticated смог сделать update rollouts';
exception when insufficient_privilege then
  raise notice 'ok: update rollouts запрещён';
end $$;

do $$ begin
  delete from public.rollouts;
  raise notice 'ОШИБКА: authenticated смог сделать delete rollouts';
exception when insufficient_privilege then
  raise notice 'ok: delete rollouts запрещён';
end $$;

do $$ begin
  insert into public.rollout_log(rollout_id, kind) values (gen_random_uuid(), 'x');
  raise notice 'ОШИБКА: authenticated смог писать в rollout_log';
exception when insufficient_privilege then
  raise notice 'ok: запись в rollout_log запрещена';
end $$;

-- ---------- функции: своя организация работает ----------
do $$
declare r jsonb; v_id uuid;
begin
  r := public.rollout_create('<RELEASE_UUID>', 'test');
  if (r->>'ok')::boolean then
    v_id := (r->>'id')::uuid;
    raise notice 'ok: rollout_create отработал, статус %', r->>'status';
    r := public.rollout_set_status(v_id, 'active');
    raise notice 'rollout_set_status active: %', r;
    r := public.rollout_set_status(v_id, 'done');
    raise notice 'rollout_set_status done: %', r;
  else
    raise notice 'ОШИБКА: rollout_create отказал: % (если forbidden — не подставлен rollout_my_org)', r;
  end if;
end $$;

do $$
declare r jsonb;
begin
  r := public.device_set_ring_tz('<DEVICE_A_ID>', 'early', 'Europe/Tallinn');
  raise notice 'device_set_ring_tz своё устройство: %', r;
  r := public.device_set_ring_tz('<DEVICE_A_ID>', 'early', 'Nowhere/Nothing');
  if r->>'error' = 'bad_timezone' then raise notice 'ok: неверный пояс отклонён';
  else raise notice 'ОШИБКА: неверный пояс принят: %', r; end if;
end $$;

-- ---------- чужая организация: функции отказывают ----------
reset role;
select set_config('request.jwt.claims',
  '{"sub":"<USER_B_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare r jsonb;
begin
  r := public.device_set_ring_tz('<DEVICE_A_ID>', 'all', 'UTC');
  if (r->>'ok')::boolean then raise notice 'ОШИБКА: B изменил устройство организации A';
  else raise notice 'ok: B не может менять устройство A (%)', r->>'error'; end if;
end $$;

do $$
declare n int;
begin
  select count(*) into n from public.rollouts;   -- RLS: только своя организация
  raise notice 'B видит раскаток: % (раскаток A быть не должно)', n;
end $$;

-- ---------- anon: ничего ----------
reset role;
set local role anon;

do $$ begin
  perform public.rollout_create('<RELEASE_UUID>', 'test');
  raise notice 'ОШИБКА: anon вызвал rollout_create';
exception when insufficient_privilege then
  raise notice 'ok: anon не вызывает rollout_create';
end $$;

do $$ begin
  perform public.rollout_set_status(gen_random_uuid(), 'active');
  raise notice 'ОШИБКА: anon вызвал rollout_set_status';
exception when insufficient_privilege then
  raise notice 'ok: anon не вызывает rollout_set_status';
end $$;

do $$ begin
  perform public.device_set_ring_tz('x', 'all', 'UTC');
  raise notice 'ОШИБКА: anon вызвал device_set_ring_tz';
exception when insufficient_privilege then
  raise notice 'ok: anon не вызывает device_set_ring_tz';
end $$;

do $$ begin
  perform public.rollout_target('<DEVICE_A_ID>');
  raise notice 'ОШИБКА: anon вызвал rollout_target';
exception when insufficient_privilege then
  raise notice 'ok: anon не вызывает rollout_target';
end $$;

do $$ begin
  perform 1 from public.rollouts;
  raise notice 'ОШИБКА: anon прочитал rollouts';
exception when insufficient_privilege then
  raise notice 'ok: anon не читает rollouts';
end $$;

do $$ begin
  perform 1 from public.rollout_progress;
  raise notice 'ОШИБКА: anon прочитал rollout_progress';
exception when insufficient_privilege then
  raise notice 'ok: anon не читает rollout_progress';
end $$;

-- ---------- authenticated: rollout_target напрямую недоступен ----------
reset role;
select set_config('request.jwt.claims',
  '{"sub":"<USER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$ begin
  perform public.rollout_target('<DEVICE_A_ID>');
  raise notice 'ОШИБКА: authenticated вызвал rollout_target напрямую';
exception when insufficient_privilege then
  raise notice 'ok: authenticated не вызывает rollout_target';
end $$;

do $$ begin
  perform public.rollout_my_org();
  raise notice 'ОШИБКА: authenticated вызвал rollout_my_org напрямую';
exception when insufficient_privilege then
  raise notice 'ok: authenticated не вызывает rollout_my_org';
end $$;

-- ---------- триггер автопаузы и окно: логика (под полными правами) ----------
reset role;
do $$
declare t jsonb;
begin
  -- rollout_target для аппарата без активной раскатки → null
  t := public.rollout_target('<DEVICE_A_ID>');
  raise notice 'rollout_target без активной раскатки: % (ожидается null)', t;
end $$;

rollback;
