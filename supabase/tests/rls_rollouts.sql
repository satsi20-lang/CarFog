-- ============================================================
-- Проверка прав R3 (раскатки по кольцам) на РЕАЛЬНОЙ схеме
-- (org_members + is_org_member). По образцу rls_app_releases.sql.
-- НЕ применять к рабочей базе: запускать на копии/тестовом проекте под
-- полными правами (SQL Editor). Всё в одной транзакции, в конце rollback.
--
-- Что подставить (UUID — из auth.users):
--   <MEMBER_UUID>     пользователь, который состоит РОВНО в одной организации
--                     (строка в org_members) — владелец устройства <DEVICE_ID>
--   <NONMEMBER_UUID>  пользователь БЕЗ членства в этой организации (другая
--                     организация или вообще без org_members)
--   <RELEASE_UUID>    id любой строки app_releases
--   <DEVICE_ID>       id устройства организации участника
-- Каждая проверка пишет в «Messages» строку ok или ОШИБКА.
-- ============================================================
begin;

-- ---------- участник: прямая запись в таблицы запрещена ----------
select set_config('request.jwt.claims',
  '{"sub":"<MEMBER_UUID>","role":"authenticated"}', true);
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
  insert into public.rollout_log(kind) values ('x');
  raise notice 'ОШИБКА: authenticated смог писать в rollout_log';
exception when insufficient_privilege then
  raise notice 'ok: запись в rollout_log запрещена';
end $$;

-- ---------- участник: функции работают для своей организации ----------
do $$
declare r jsonb;
begin
  r := public.rollout_create('<RELEASE_UUID>', 'test');
  if (r->>'ok')::boolean then
    perform set_config('rt.rollout', r->>'id', true);
    raise notice 'ok: участник создал раскатку, статус %', r->>'status';
  else
    raise notice 'ОШИБКА: rollout_create участника отказал: %', r;
  end if;
end $$;

do $$
declare r jsonb;
begin
  r := public.rollout_create('<RELEASE_UUID>', 'test', '03:00', '03:00');
  if r->>'error' = 'bad_request' then raise notice 'ok: окно start = end отклонено (bad_request)';
  else raise notice 'ОШИБКА: окно start = end принято или другой ответ: %', r; end if;
  r := public.rollout_create('<RELEASE_UUID>', 'all', '22:00', '03:00');
  if (r->>'ok')::boolean then raise notice 'ok: окно через полночь 22:00–03:00 допустимо';
  else raise notice 'ОШИБКА: окно через полночь отклонено: %', r; end if;
end $$;

do $$
declare r jsonb; v uuid := nullif(current_setting('rt.rollout', true), '')::uuid; v_res timestamptz;
begin
  select resumed_at into v_res from public.rollouts where id = v;
  if v_res is null then raise notice 'ok: resumed_at пуст до первого запуска';
  else raise notice 'ОШИБКА: resumed_at заполнен до запуска'; end if;
  r := public.rollout_set_status(v, 'active');
  if (r->>'ok')::boolean then raise notice 'ok: paused -> active'; else raise notice 'ОШИБКА: %', r; end if;
  select resumed_at into v_res from public.rollouts where id = v;
  if v_res is not null then raise notice 'ok: resumed_at заполнен после active (%)', v_res;
  else raise notice 'ОШИБКА: resumed_at не заполнен после active'; end if;
  r := public.rollout_set_status(v, 'paused');
  if (r->>'ok')::boolean then raise notice 'ok: active -> paused'; else raise notice 'ОШИБКА: %', r; end if;
  r := public.rollout_set_status(v, 'done');
  if r->>'error' = 'bad_transition' then raise notice 'ok: paused -> done запрещён'; else raise notice 'ОШИБКА: %', r; end if;
end $$;

do $$
declare r jsonb;
begin
  r := public.device_set_ring_tz('<DEVICE_ID>', 'early', 'Europe/Tallinn');
  if (r->>'ok')::boolean then raise notice 'ok: участник назначил кольцо и пояс'; else raise notice 'ОШИБКА: %', r; end if;
  r := public.device_set_ring_tz('<DEVICE_ID>', 'early', 'Nowhere/Nothing');
  if r->>'error' = 'bad_timezone' then raise notice 'ok: неверный пояс отклонён'; else raise notice 'ОШИБКА: %', r; end if;
end $$;

do $$
declare n int;
begin
  select count(*) into n from public.rollouts;
  if n >= 1 then raise notice 'ok: участник видит свои раскатки (%)', n; else raise notice 'ОШИБКА: участник не видит свою раскатку'; end if;
  select count(*) into n from public.rollout_log;
  if n >= 1 then raise notice 'ok: участник видит журнал (%)', n; else raise notice 'ОШИБКА: журнал пуст для участника'; end if;
end $$;

-- ---------- НЕ участник: не видит и не меняет ничего ----------
reset role;
select set_config('request.jwt.claims',
  '{"sub":"<NONMEMBER_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare n int;
begin
  select count(*) into n from public.rollouts;
  if n = 0 then raise notice 'ok: не участник не видит раскатки'; else raise notice 'ОШИБКА: не участник видит раскаток: %', n; end if;
  select count(*) into n from public.rollout_log;
  if n = 0 then raise notice 'ok: не участник не видит журнал'; else raise notice 'ОШИБКА: не участник видит записей журнала: %', n; end if;
  select count(*) into n from public.rollout_progress;
  if n = 0 then raise notice 'ok: не участник не видит rollout_progress'; else raise notice 'ОШИБКА: не участник видит строк прогресса: %', n; end if;
end $$;

do $$
declare r jsonb; v uuid := nullif(current_setting('rt.rollout', true), '')::uuid;
begin
  r := public.rollout_set_status(v, 'active');
  if r->>'error' = 'forbidden' then raise notice 'ok: не участник не меняет статус (forbidden)'; else raise notice 'ОШИБКА: %', r; end if;
  r := public.rollout_set_status(v, 'cancelled');
  if r->>'error' = 'forbidden' then raise notice 'ok: не участник не отменяет (forbidden)'; else raise notice 'ОШИБКА: %', r; end if;
end $$;

do $$
declare r jsonb;
begin
  r := public.device_set_ring_tz('<DEVICE_ID>', 'all', 'UTC');
  if r->>'error' = 'forbidden' then raise notice 'ok: не участник не меняет устройство (forbidden)'; else raise notice 'ОШИБКА: %', r; end if;
end $$;

do $$
declare r jsonb;
begin
  r := public.rollout_create('<RELEASE_UUID>', 'test');
  if r->>'error' in ('no_org', 'ambiguous_org') then
    raise notice 'ok: не участник не создаёт раскатку (%)', r->>'error';
  else
    raise notice 'ОШИБКА: не участник создал раскатку или получил другой ответ: %', r;
  end if;
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
  perform public.device_set_ring_tz('<DEVICE_ID>', 'all', 'UTC');
  raise notice 'ОШИБКА: anon вызвал device_set_ring_tz';
exception when insufficient_privilege then
  raise notice 'ok: anon не вызывает device_set_ring_tz';
end $$;

do $$ begin
  perform public.rollout_target('<DEVICE_ID>');
  raise notice 'ОШИБКА: anon вызвал rollout_target';
exception when insufficient_privilege then
  raise notice 'ok: anon не вызывает rollout_target';
end $$;

do $$ begin
  perform public.rollout_my_org();
  raise notice 'ОШИБКА: anon вызвал rollout_my_org';
exception when insufficient_privilege then
  raise notice 'ok: anon не вызывает rollout_my_org';
end $$;

do $$ begin
  perform 1 from public.rollouts;
  raise notice 'ОШИБКА: anon прочитал rollouts';
exception when insufficient_privilege then
  raise notice 'ok: anon не читает rollouts';
end $$;

do $$ begin
  perform 1 from public.rollout_log;
  raise notice 'ОШИБКА: anon прочитал rollout_log';
exception when insufficient_privilege then
  raise notice 'ok: anon не читает rollout_log';
end $$;

do $$ begin
  perform 1 from public.rollout_progress;
  raise notice 'ОШИБКА: anon прочитал rollout_progress';
exception when insufficient_privilege then
  raise notice 'ok: anon не читает rollout_progress';
end $$;

-- ---------- authenticated: внутренние функции напрямую недоступны ----------
reset role;
select set_config('request.jwt.claims',
  '{"sub":"<MEMBER_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$ begin
  perform public.rollout_target('<DEVICE_ID>');
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

-- ---------- общая проверка: ни одна функция R3 не доступна anon/PUBLIC ----------
reset role;
do $$
declare f record; bad int := 0;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('rollout_create', 'rollout_set_status', 'device_set_ring_tz',
                         'rollout_target', 'rollout_my_org', 'rollout_autopause')
  loop
    if has_function_privilege('anon', f.sig, 'execute')
       or has_function_privilege('public', f.sig, 'execute') then
      raise notice 'ОШИБКА: % доступна anon/PUBLIC', f.sig;
      bad := bad + 1;
    end if;
  end loop;
  if bad = 0 then raise notice 'ok: ни одна функция R3 не доступна anon/PUBLIC'; end if;
end $$;

-- ---------- триггер автопаузы (под полными правами) ----------
-- Проверка по received_at: два update_failed с разных устройств кольца
-- ставят активную раскатку на паузу, а busy/not_newer — нет.
-- Требует двух устройств в одной организации и кольце; подставьте их id и
-- раскомментируйте при необходимости:
--   insert into public.events(device_id, org_id, type, data)
--   values ('<DEVICE_ID>', '<ORG_ID>', 'update_failed', '{"reason":"sha_mismatch"}');
-- (events.ts / received_at имеют значения по умолчанию в вашей схеме — иначе
-- задайте их явно: ts => now(), received_at => now()).

rollback;
