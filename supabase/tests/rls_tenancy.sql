-- ============================================================
-- Проверка прав R4 (изготовитель — клиент, привязка по коду) на РЕАЛЬНОЙ
-- схеме. По образцу rls_app_releases.sql / rls_rollouts.sql.
-- НЕ применять к рабочей базе: запускать на копии/тестовом проекте под
-- полными правами (SQL Editor). Всё в одной транзакции, в конце rollback.
--
-- Что подставить (UUID — из auth.users, три РАЗНЫХ пользователя):
--   <STAFF_UUID>       изготовитель: член организации <ORG_ID> (org_members)
--   <CUSTOMER_A_UUID>  клиент A (НЕ член ни одной организации)
--   <CUSTOMER_B_UUID>  клиент B (НЕ член ни одной организации)
--   <ORG_ID>           организация-изготовитель
--   <DEVICE_ID>        устройство организации <ORG_ID>
--   <OTHER_DEVICE_ID>  устройство ДРУГОЙ организации (для проверки дефекта A)
--   <RELEASE_ID>       id СУЩЕСТВУЮЩЕЙ строки app_releases (для rollout_create);
--                      изготовитель должен состоять ровно в одной организации
--                      (rollout_my_org), иначе rollout_create ответит no_org/ambiguous_org
-- Каждая проверка пишет в «Messages» строку ok или ОШИБКА.
-- Пока клиенты не привязаны, статусы связи/срока меняются прямо тут.
-- ============================================================
begin;

-- чистое начало (внутри транзакции, откатится)
delete from public.customer_command_log where device_id = '<DEVICE_ID>';
delete from public.claim_attempts where device_id in ('<DEVICE_ID>', 'NOPE-000');
delete from public.device_access where device_id = '<DEVICE_ID>';

-- хэш кода в БД = хэш заводского генератора (общий тестовый вектор из
-- tool/test_provision_devices.py)
do $$ begin
  if public._claim_hash('00112233445566778899aabbccddeeff', 'ABCDEFGHJKMN')
     = 'ccbfe6423b28c20b5c9adb7c81ca0b9eef6e6c54a84a085f36cfce6dcf45efda' then
    raise notice 'ok: хэш кода в БД совпадает с хэшем заводского генератора';
  else
    raise notice 'ОШИБКА: хэш в БД отличается от генератора';
  end if;
end $$;

-- ====================== 1. изготовитель выдаёт код ======================
select set_config('request.jwt.claims', '{"sub":"<STAFF_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare c text;
begin
  c := public.claim_regenerate('<DEVICE_ID>');
  perform set_config('rt.code', c, true);
  if c ~ '^[A-HJ-KM-NP-Z2-9]{4}-[A-HJ-KM-NP-Z2-9]{4}-[A-HJ-KM-NP-Z2-9]{4}$' then
    raise notice 'ok: код выдан в формате XXXX-XXXX-XXXX без 0/O/1/I/L';
  else
    raise notice 'ОШИБКА: неверный формат кода';
  end if;
end $$;

do $$
declare n int;
begin
  select count(*) into n from public.staff_audit where action = 'claim_regenerate' and device_id = '<DEVICE_ID>';
  if n >= 1 then raise notice 'ok: claim_regenerate записан в staff_audit'; else raise notice 'ОШИБКА: нет записи staff_audit'; end if;
end $$;

-- ====================== 2. привязка: перебор и блокировка ======================
reset role;
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare r1 jsonb; r2 jsonb; r3 jsonb; i int;
begin
  r1 := public.device_claim('<DEVICE_ID>', 'AAAA-BBBB-CCCC', 'х');
  r2 := public.device_claim('NOPE-000', 'AAAA-BBBB-CCCC', 'х');
  if r1 = r2 and r1->>'error' = 'invalid_claim' then
    raise notice 'ok: неверный код и неверный номер отвечают одинаково (invalid_claim)';
  else
    raise notice 'ОШИБКА: ответы различаются: % / %', r1, r2;
  end if;
  for i in 1..3 loop
    perform public.device_claim('<DEVICE_ID>', 'ZZZZ-ZZZZ-ZZZZ', 'х');
  end loop;
  -- 5 неудач набрано; теперь ВЕРНЫЙ код тоже отказывает
  r3 := public.device_claim('<DEVICE_ID>', current_setting('rt.code'), 'Мой аппарат');
  if r3->>'error' = 'too_many_attempts' then
    raise notice 'ok: после 5 неудач верный код отказывает (too_many_attempts)';
  else
    raise notice 'ОШИБКА: блокировки нет: %', r3;
  end if;
end $$;

-- блокировка по АППАРАТУ: порог 50 неудач в сутки (подбор кода невозможен,
-- низкий порог позволял бы блокировать привязку честному клиенту — DoS).
-- 49 чужих неудач ещё не блокируют, 50-я блокирует даже верный код.
reset role;
delete from public.claim_attempts where device_id = '<DEVICE_ID>';
insert into public.claim_attempts(user_id, device_id, ok)
select gen_random_uuid(), '<DEVICE_ID>', false from generate_series(1, 49);
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;
do $$
declare r jsonb;
begin
  r := public.device_claim('<DEVICE_ID>', 'ZZZZ-ZZZZ-ZZZZ', 'х');   -- 50-я неудача
  if r->>'error' = 'invalid_claim' then raise notice 'ok: при 49 неудачах на аппарат привязка ещё не заблокирована';
  else raise notice 'ОШИБКА: преждевременная блокировка по аппарату: %', r; end if;
  r := public.device_claim('<DEVICE_ID>', current_setting('rt.code'), 'х');
  if r->>'error' = 'too_many_attempts' then raise notice 'ok: после 50 неудач на аппарат верный код отказывает (too_many_attempts)';
  else raise notice 'ОШИБКА: блокировки по аппарату нет: %', r; end if;
end $$;
reset role;
delete from public.claim_attempts where device_id = '<DEVICE_ID>';
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;

-- окно блокировки «прошло» (под полными правами сдвигаем метки)
reset role;
update public.claim_attempts set at = at - interval '2 hours' where device_id in ('<DEVICE_ID>', 'NOPE-000');
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare r jsonb;
begin
  r := public.device_claim('<DEVICE_ID>', lower(current_setting('rt.code')), '  Мой аппарат  ');
  if (r->>'ok')::boolean then raise notice 'ok: после окна верный код (в нижнем регистре, с дефисами) привязал аппарат';
  else raise notice 'ОШИБКА: привязка не удалась: %', r; end if;
end $$;

-- повторная привязка тем же кодом — тот же общий отказ
do $$
declare r jsonb;
begin
  r := public.device_claim('<DEVICE_ID>', current_setting('rt.code'), 'х');
  if r->>'error' = 'invalid_claim' then raise notice 'ok: повторная привязка отклонена общим сообщением';
  else raise notice 'ОШИБКА: %', r; end if;
end $$;

-- ====================== 3. клиент B не привязывает занятый аппарат ======================
reset role;
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_B_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare r jsonb;
begin
  r := public.device_claim('<DEVICE_ID>', current_setting('rt.code'), 'Чужой');
  if r->>'error' = 'invalid_claim' then raise notice 'ok: второй клиент не привязывает аппарат, пока связь не закрыта';
  else raise notice 'ОШИБКА: второй клиент привязал занятый аппарат: %', r; end if;
end $$;

-- ====================== 4. срок подписки ещё не оплачен: доступа нет ======================
reset role;
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare n int;
begin
  select count(*) into n from public.customer_devices;
  if n = 0 then raise notice 'ok: до оплаты (valid_until = момент привязки) клиент ничего не видит';
  else raise notice 'ОШИБКА: клиент видит аппарат без активной подписки: %', n; end if;
end $$;

-- ====================== 5. клиент не вызывает функции изготовителя ======================
do $$
declare r jsonb; ok boolean := true;
begin
  r := public.access_set_valid_until('<DEVICE_ID>', now() + interval '1 year', 'manual', null);
  if r->>'error' <> 'forbidden' then ok := false; raise notice 'ОШИБКА: access_set_valid_until: %', r; end if;
  r := public.access_end('<DEVICE_ID>');
  if r->>'error' <> 'forbidden' then ok := false; raise notice 'ОШИБКА: access_end: %', r; end if;
  r := public.device_set_ring_tz('<DEVICE_ID>', 'all', 'UTC');
  if r->>'error' <> 'forbidden' then ok := false; raise notice 'ОШИБКА: device_set_ring_tz: %', r; end if;
  r := public.rollout_set_status(gen_random_uuid(), 'active');
  if r->>'error' <> 'forbidden' then ok := false; raise notice 'ОШИБКА: rollout_set_status: %', r; end if;
  r := public.rollout_create(gen_random_uuid(), 'test');
  if r->>'error' not in ('no_org', 'ambiguous_org') then ok := false; raise notice 'ОШИБКА: rollout_create: %', r; end if;
  begin
    perform public.claim_regenerate('<DEVICE_ID>');
    ok := false; raise notice 'ОШИБКА: клиент вызвал claim_regenerate';
  exception when others then
    if sqlerrm <> 'forbidden' then ok := false; raise notice 'ОШИБКА: claim_regenerate: %', sqlerrm; end if;
  end;
  if ok then raise notice 'ok: клиент не может вызывать функции изготовителя'; end if;
end $$;

-- ====================== 6. изготовитель задаёт срок подписки ======================
reset role;
select set_config('request.jwt.claims', '{"sub":"<STAFF_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare r jsonb;
begin
  r := public.access_set_valid_until('<DEVICE_ID>', now() + interval '30 days', 'manual', null);
  if (r->>'ok')::boolean then raise notice 'ok: изготовитель продлил подписку на 30 дней';
  else raise notice 'ОШИБКА: %', r; end if;
  r := public.access_set_valid_until('<DEVICE_ID>', now() + interval '10 years', 'manual', null);
  if r->>'error' = 'bad_request' then raise notice 'ok: срок дальше 3 лет отклонён';
  else raise notice 'ОШИБКА: %', r; end if;
end $$;

-- ====================== 6а. изготовитель: раскатка и журнал ======================
reset role;
select set_config('request.jwt.claims', '{"sub":"<STAFF_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare r jsonb; n int; v uuid;
begin
  r := public.rollout_create('<RELEASE_ID>', 'test');
  if (r->>'ok')::boolean then
    v := (r->>'id')::uuid;
    perform set_config('rt.rollout', v::text, true);
    raise notice 'ok: изготовитель создал раскатку (rollout_create)';
  else
    raise notice 'ОШИБКА: rollout_create изготовителя: % (нужен <RELEASE_ID> и ровно одна организация)', r;
    return;
  end if;

  select count(*) into n from public.staff_audit
   where action = 'rollout_create' and details ->> 'rollout' = v::text;
  if n = 1 then raise notice 'ok: rollout_create записан в staff_audit';
  else raise notice 'ОШИБКА: записей rollout_create в staff_audit: %', n; end if;

  r := public.rollout_create('<RELEASE_ID>', 'test', '03:00', '03:00');
  if r->>'error' = 'bad_request' then raise notice 'ok: rollout_create с p_start = p_end отклонён (bad_request)';
  else raise notice 'ОШИБКА: %', r; end if;

  r := public.rollout_set_status(v, 'active');
  if (r->>'ok')::boolean then
    select count(*) into n from public.rollout_log where rollout_id = v and kind = 'status';
    if n >= 1 then raise notice 'ok: rollout_set_status пишет в rollout_log'; else raise notice 'ОШИБКА: нет записи в rollout_log'; end if;
    select count(*) into n from public.staff_audit
     where action = 'rollout_status' and details ->> 'rollout' = v::text;
    if n >= 1 then raise notice 'ok: rollout_set_status пишет в staff_audit'; else raise notice 'ОШИБКА: нет записи в staff_audit'; end if;
    -- чтобы не оставлять активную раскатку
    perform public.rollout_set_status(v, 'cancelled');
  elsif r->>'error' = 'active_exists' then
    raise notice 'пропуск: в кольце test уже есть активная раскатка (active_exists) — проверка журнала смены статуса не выполнена';
  else
    raise notice 'ОШИБКА: rollout_set_status: %', r;
  end if;
end $$;

-- тестовые события (под полными правами): разрешённое с лишними ключами и неразрешённое
reset role;
insert into public.events(device_id, org_id, type, ts, received_at, data) values
  ('<DEVICE_ID>', '<ORG_ID>', 'session_complete', now(), now(),
   '{"price_cents":200,"paid_cents":200,"flavor":"Лимон","energy_wh":21.5,"grid_voltage_v":231,"session_id":"t1"}'::jsonb),
  ('<DEVICE_ID>', '<ORG_ID>', 'config_changed', now(), now(), '{"what":"service_pin"}'::jsonb),
  ('<DEVICE_ID>', '<ORG_ID>', 'update_installed', now(), now(), '{"to_version":"1.6.0"}'::jsonb);
update public.devices
   set reported_config = coalesce(reported_config, '{}'::jsonb)
       || '{"price_cents":200,"duration_s":40,"flavor_count":4,"out_of_service":false,"app_version":"x","rollback_available":true,"debug_modes":["a"],"adb_network":true}'::jsonb,
       last_seen_at = now()
 where id = '<DEVICE_ID>';

-- ====================== 7. клиент A видит ТОЛЬКО свой аппарат ======================
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare n int; bad text; d jsonb; cols text;
begin
  select count(*) into n from public.customer_devices;
  if n = 1 then raise notice 'ok: A видит ровно один аппарат'; else raise notice 'ОШИБКА: A видит аппаратов: %', n; end if;

  select string_agg(column_name, ',') into cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'customer_devices'
     and column_name in ('token','app_version','rollback_available','adb_network','debug_modes',
                         'last_update_result','skip_health_signal_build','ring','timezone','org_id',
                         'reported_config','rollout_target_code');
  if cols is null then raise notice 'ok: в customer_devices нет запрещённых полей';
  else raise notice 'ОШИБКА: в customer_devices запрещённые поля: %', cols; end if;

  select string_agg(column_name, ',') into cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'customer_events'
     and column_name in ('org_id','ts','received_at');
  if cols is null then raise notice 'ok: в customer_events нет служебных полей'; else raise notice 'ОШИБКА: %', cols; end if;

  select count(*) into n from public.customer_events where type = 'session_complete';
  if n = 1 then raise notice 'ok: разрешённое событие видно'; else raise notice 'ОШИБКА: session_complete видно: %', n; end if;
  select count(*) into n from public.customer_events where type in ('config_changed', 'update_installed');
  if n = 0 then raise notice 'ok: события вне списка (config_changed, update_installed) не видны';
  else raise notice 'ОШИБКА: клиент видит служебные события: %', n; end if;
  select data into d from public.customer_events where type = 'session_complete';
  if jsonb_exists(d, 'price_cents') and not jsonb_exists(d, 'energy_wh') and not jsonb_exists(d, 'grid_voltage_v') then
    raise notice 'ok: из data вырезано служебное (energy_wh, grid_voltage_v)';
  else raise notice 'ОШИБКА: фильтр ключей data: %', d; end if;
end $$;

-- ====================== 8. клиент B не видит ничего ======================
reset role;
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_B_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare n int;
begin
  select count(*) into n from public.customer_devices;
  if n = 0 then raise notice 'ok: B не видит чужой аппарат'; else raise notice 'ОШИБКА: B видит аппаратов: %', n; end if;
  select count(*) into n from public.customer_events;
  if n = 0 then raise notice 'ok: B не видит чужие события'; else raise notice 'ОШИБКА: B видит событий: %', n; end if;
  select count(*) into n from public.customer_commands;
  if n = 0 then raise notice 'ok: B не видит чужие команды'; else raise notice 'ОШИБКА: B видит команд: %', n; end if;
  if (public.customer_send_command('<DEVICE_ID>', 'ping', null))->>'error' = 'no_access'
     and (public.device_set_label('<DEVICE_ID>', 'взлом'))->>'error' = 'forbidden' then
    raise notice 'ok: B не управляет чужим аппаратом';
  else raise notice 'ОШИБКА: B управляет чужим аппаратом'; end if;
end $$;

-- ====================== 9. базовые таблицы клиентам недоступны ======================
do $$
declare t text; n int;
begin
  foreach t in array array['devices','events','commands','device_diagnostics','app_releases',
                           'rollouts','rollout_log','rollout_progress','staff_audit',
                           'device_claims','device_access','claim_attempts',
                           'customer_event_types','customer_command_log','staff_device_access'] loop
    begin
      execute format('select count(*) from public.%I', t) into n;
      if n = 0 then raise notice 'ok: B, % → 0 строк', t;
      else raise notice 'ОШИБКА: B видит строк в %: %', t, n; end if;
    exception when insufficient_privilege then
      raise notice 'ok: B, % → отказ в правах', t;
    end;
  end loop;
end $$;

reset role;
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare t text; n int;
begin
  foreach t in array array['devices','events','commands','device_diagnostics','app_releases',
                           'rollouts','rollout_log','rollout_progress','staff_audit',
                           'device_claims','device_access','claim_attempts',
                           'customer_event_types','customer_command_log','staff_device_access'] loop
    begin
      execute format('select count(*) from public.%I', t) into n;
      if n = 0 then raise notice 'ok: A, % → 0 строк', t;
      else raise notice 'ОШИБКА: A видит строк в %: %', t, n; end if;
    exception when insufficient_privilege then
      raise notice 'ok: A, % → отказ в правах', t;
    end;
  end loop;
end $$;

-- A не вставляет в commands напрямую
do $$ begin
  insert into public.commands(device_id, org_id, action, params)
  values ('<DEVICE_ID>', '<ORG_ID>', 'ping', '{}'::jsonb);
  raise notice 'ОШИБКА: клиент вставил в commands напрямую';
exception when insufficient_privilege then
  raise notice 'ok: прямая вставка в commands клиентом запрещена';
end $$;

-- ====================== 10. команды клиента ======================
do $$
declare r jsonb; a text; ok boolean := true;
begin
  foreach a in array array['ping', 'restart_app', 'reset_session'] loop
    r := public.customer_send_command('<DEVICE_ID>', a, null);
    if not (r->>'ok')::boolean then ok := false; raise notice 'ОШИБКА: % отклонена: %', a, r; end if;
  end loop;
  r := public.customer_send_command('<DEVICE_ID>', 'update_config',
         '{"treatmentPriceCents":300,"treatmentDurationS":40}'::jsonb);
  if not (r->>'ok')::boolean then ok := false; raise notice 'ОШИБКА: update_config (цена, длительность): %', r; end if;
  if ok then raise notice 'ok: ping, restart_app, reset_session, update_config(цена, длительность) разрешены'; end if;
end $$;

do $$
declare r jsonb; a text; ok boolean := true;
begin
  foreach a in array array['update_app','rollback_app','factory_reset','set_pin','collect_diagnostics','unlock','whatever'] loop
    r := public.customer_send_command('<DEVICE_ID>', a, '{}'::jsonb);
    if r->>'error' <> 'action_not_allowed' then ok := false; raise notice 'ОШИБКА: % не запрещена: %', a, r; end if;
  end loop;
  if ok then raise notice 'ok: update_app, rollback_app, factory_reset, set_pin, collect_diagnostics, unlock и прочее запрещены'; end if;

  r := public.customer_send_command('<DEVICE_ID>', 'update_config', '{"servicePin":"1234"}'::jsonb);
  if r->>'error' = 'bad_params' then raise notice 'ok: update_config с чужим ключом отклонён'; else raise notice 'ОШИБКА: %', r; end if;
  r := public.customer_send_command('<DEVICE_ID>', 'update_config', '{"treatmentPriceCents":300,"cloudToken":"x"}'::jsonb);
  if r->>'error' = 'bad_params' then raise notice 'ok: update_config со смешанными ключами отклонён целиком'; else raise notice 'ОШИБКА: %', r; end if;
  r := public.customer_send_command('<DEVICE_ID>', 'update_config', '{"treatmentPriceCents":49}'::jsonb);
  if r->>'error' = 'out_of_range' then raise notice 'ok: цена 49 центов (меньше 0.50 €) отклонена'; else raise notice 'ОШИБКА: %', r; end if;
  r := public.customer_send_command('<DEVICE_ID>', 'update_config', '{"treatmentPriceCents":2001}'::jsonb);
  if r->>'error' = 'out_of_range' then raise notice 'ok: цена 2001 отклонена'; else raise notice 'ОШИБКА: %', r; end if;
  r := public.customer_send_command('<DEVICE_ID>', 'update_config', '{"treatmentDurationS":9}'::jsonb);
  if r->>'error' = 'out_of_range' then raise notice 'ok: длительность 9 с отклонена'; else raise notice 'ОШИБКА: %', r; end if;
  r := public.customer_send_command('<DEVICE_ID>', 'update_config', '{"treatmentDurationS":121}'::jsonb);
  if r->>'error' = 'out_of_range' then raise notice 'ok: длительность 121 с отклонена'; else raise notice 'ОШИБКА: %', r; end if;
  r := public.customer_send_command('<DEVICE_ID>', 'update_config', '{"treatmentPriceCents":300.5}'::jsonb);
  if r->>'error' = 'bad_params' then raise notice 'ok: нецелая цена отклонена'; else raise notice 'ОШИБКА: %', r; end if;
  r := public.customer_send_command('<DEVICE_ID>', 'update_config', '{}'::jsonb);
  if r->>'error' = 'bad_request' then raise notice 'ok: пустой update_config отклонён'; else raise notice 'ОШИБКА: %', r; end if;
  r := public.customer_send_command('<DEVICE_ID>', 'ping', '{"x":1}'::jsonb);
  if r->>'error' = 'bad_params' then raise notice 'ok: ping с параметрами отклонён'; else raise notice 'ОШИБКА: %', r; end if;
end $$;

-- лимит: не более 20 команд в час на аппарат (уже отправлено 4)
do $$
declare r jsonb; i int; n_ok int := 4; got boolean := false;
begin
  for i in 1..25 loop
    r := public.customer_send_command('<DEVICE_ID>', 'ping', null);
    if (r->>'ok')::boolean then n_ok := n_ok + 1;
    elsif r->>'error' = 'rate_limited' then got := true; exit; end if;
  end loop;
  if got and n_ok = 20 then raise notice 'ok: лимит 20 команд в час сработал на 21-й';
  else raise notice 'ОШИБКА: лимит не сработал вовремя (принято %, got=%)', n_ok, got; end if;
end $$;

do $$
declare n int;
begin
  select count(*) into n from public.customer_commands;
  if n = 20 then raise notice 'ok: customer_commands показывает свои команды (20)';
  else raise notice 'ОШИБКА: customer_commands: %', n; end if;
  select count(*) into n from public.customer_commands where action in ('update_app','rollback_app','factory_reset','set_pin');
  if n = 0 then raise notice 'ok: запрещённых действий в customer_commands нет'; else raise notice 'ОШИБКА: %', n; end if;
end $$;

-- ====================== 11. изготовитель: видит всё, журнал, дефект A ======================
reset role;
select set_config('request.jwt.claims', '{"sub":"<STAFF_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare n int; c text;
begin
  select count(*) into n from public.devices;
  if n >= 1 then raise notice 'ok: изготовитель читает devices'; else raise notice 'ОШИБКА: devices пуст для изготовителя'; end if;
  perform id, name, app_version, last_seen_at, org_id, reported_config, reported_at, ring, timezone from public.devices limit 1;
  raise notice 'ok: изготовитель читает все разрешённые столбцы devices (включая ring, timezone)';
  begin
    perform token from public.devices limit 1;
    raise notice 'ОШИБКА: изготовитель смог прочитать token';
  exception when insufficient_privilege then
    raise notice 'ok: token для чтения закрыт (даже изготовителю)';
  end;
  select count(*) into n from public.events;
  if n >= 1 then raise notice 'ok: изготовитель читает events'; else raise notice 'ОШИБКА: events пуст'; end if;
  select count(*) into n from public.commands;
  if n >= 1 then raise notice 'ok: изготовитель читает commands'; else raise notice 'ОШИБКА: commands пуст'; end if;
  perform 1 from public.app_releases limit 1;
  perform 1 from public.rollouts limit 1;
  perform 1 from public.rollout_progress limit 1;
  perform 1 from public.rollout_log limit 1;
  perform 1 from public.device_diagnostics limit 1;
  raise notice 'ok: изготовитель читает app_releases, rollouts, rollout_progress, rollout_log, device_diagnostics';
  select count(*) into n from public.staff_device_access where device_id = '<DEVICE_ID>';
  if n = 1 then raise notice 'ok: staff_device_access показывает связь'; else raise notice 'ОШИБКА: staff_device_access: %', n; end if;
end $$;

-- панель изготовителя пишет в commands (политика commands_insert) — продолжает работать
do $$ begin
  insert into public.commands(device_id, org_id, action, params)
  values ('<DEVICE_ID>', '<ORG_ID>', 'ping', '{}'::jsonb);
  raise notice 'ok: изготовитель вставляет команду в свой аппарат (панель работает)';
exception when others then
  raise notice 'ОШИБКА: изготовитель не смог вставить команду: %', sqlerrm;
end $$;

-- ДЕФЕКТ A: команда с org_id своей организации для device_id чужой — запрещена
do $$ begin
  insert into public.commands(device_id, org_id, action, params)
  values ('<OTHER_DEVICE_ID>', '<ORG_ID>', 'ping', '{}'::jsonb);
  raise notice 'ОШИБКА (дефект A): вставлена команда для устройства чужой организации';
exception when insufficient_privilege or check_violation then
  raise notice 'ok: команда для device_id чужой организации отклонена (дефект A исправлен)';
end $$;

do $$
declare n int;
begin
  select count(*) into n from public.staff_audit where action = 'command' and device_id = '<DEVICE_ID>';
  if n >= 1 then raise notice 'ok: вставка команды изготовителем записана в staff_audit'; else raise notice 'ОШИБКА: нет записи о команде в staff_audit'; end if;
end $$;

-- права на таблицы и столбцы (второй рубеж)
reset role;
do $$
declare bad text := '';
begin
  if has_table_privilege('authenticated', 'public.devices', 'INSERT') then bad := bad || ' devices.INSERT'; end if;
  if has_table_privilege('authenticated', 'public.devices', 'UPDATE') then bad := bad || ' devices.UPDATE'; end if;
  if has_column_privilege('authenticated', 'public.devices', 'token', 'INSERT') then bad := bad || ' devices.token.INSERT'; end if;
  if has_column_privilege('authenticated', 'public.devices', 'token', 'UPDATE') then bad := bad || ' devices.token.UPDATE'; end if;
  if has_column_privilege('authenticated', 'public.devices', 'token', 'REFERENCES') then bad := bad || ' devices.token.REFERENCES'; end if;
  if has_column_privilege('authenticated', 'public.devices', 'token', 'SELECT') then bad := bad || ' devices.token.SELECT'; end if;
  if has_table_privilege('authenticated', 'public.commands', 'UPDATE') then bad := bad || ' commands.UPDATE'; end if;
  if has_table_privilege('authenticated', 'public.commands', 'DELETE') then bad := bad || ' commands.DELETE'; end if;
  if has_table_privilege('authenticated', 'public.events', 'INSERT') then bad := bad || ' events.INSERT'; end if;
  if has_table_privilege('authenticated', 'public.events', 'UPDATE') then bad := bad || ' events.UPDATE'; end if;
  if has_table_privilege('authenticated', 'public.device_diagnostics', 'INSERT') then bad := bad || ' device_diagnostics.INSERT'; end if;
  if not has_column_privilege('authenticated', 'public.devices', 'ring', 'SELECT') then bad := bad || ' нет select(ring)'; end if;
  if not has_column_privilege('authenticated', 'public.devices', 'timezone', 'SELECT') then bad := bad || ' нет select(timezone)'; end if;
  if not has_table_privilege('authenticated', 'public.commands', 'INSERT') then bad := bad || ' у панели нет commands.INSERT'; end if;
  if bad = '' then raise notice 'ok: права authenticated на devices/commands/events/device_diagnostics как задумано';
  else raise notice 'ОШИБКА: права:%', bad; end if;
end $$;

-- дополнительная жёсткость прав (раздел 9 миграции)
do $$
declare
  t    text;
  p    text;
  bad  text := '';
begin
  -- anon: никаких прав (ни на таблицу, ни на столбцы)
  foreach t in array array['organizations','org_members','devices','events','commands',
                           'device_diagnostics','app_releases','rollouts','rollout_log',
                           'rollout_progress','release_url_requests'] loop
    foreach p in array array['SELECT','INSERT','UPDATE','REFERENCES'] loop
      if has_any_column_privilege('anon', 'public.' || t, p) then bad := bad || ' anon.' || t || '.' || p; end if;
    end loop;
    foreach p in array array['DELETE','TRUNCATE','TRIGGER'] loop
      if has_table_privilege('anon', 'public.' || t, p) then bad := bad || ' anon.' || t || '.' || p; end if;
    end loop;
  end loop;
  if bad = '' then raise notice 'ok: у anon нет никаких прав на organizations, org_members, devices, events, commands, device_diagnostics и прочие таблицы R1–R4';
  else raise notice 'ОШИБКА: у anon остались права:%', bad; bad := ''; end if;

  -- authenticated: нет записи на organizations и org_members
  foreach t in array array['organizations','org_members'] loop
    foreach p in array array['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege('authenticated', 'public.' || t, p) then bad := bad || ' authenticated.' || t || '.' || p; end if;
    end loop;
  end loop;
  if bad = '' then raise notice 'ok: у authenticated нет записи на organizations и org_members (чтение остаётся)';
  else raise notice 'ОШИБКА: права authenticated:%', bad; bad := ''; end if;

  -- authenticated: rollout_progress, app_releases, rollouts, rollout_log — только SELECT
  foreach t in array array['rollout_progress','app_releases','rollouts','rollout_log'] loop
    if not has_table_privilege('authenticated', 'public.' || t, 'SELECT') then bad := bad || ' нет SELECT ' || t; end if;
    foreach p in array array['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege('authenticated', 'public.' || t, p) then bad := bad || ' authenticated.' || t || '.' || p; end if;
    end loop;
  end loop;
  if bad = '' then raise notice 'ok: у authenticated на rollout_progress, app_releases, rollouts, rollout_log только SELECT';
  else raise notice 'ОШИБКА: права authenticated:%', bad; bad := ''; end if;

  -- release_url_requests: ни у anon, ни у authenticated
  foreach p in array array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
    if has_table_privilege('authenticated', 'public.release_url_requests', p) then bad := bad || ' authenticated.' || p; end if;
  end loop;
  if bad = '' then raise notice 'ok: у authenticated нет прав на release_url_requests';
  else raise notice 'ОШИБКА: права на release_url_requests:%', bad; end if;
end $$;

-- ====================== 12. просрочка: доступ пропадает, после продления возвращается ======================
update public.device_access set valid_until = now() - interval '1 day'
 where device_id = '<DEVICE_ID>' and ended_at is null;
insert into public.events(device_id, org_id, type, ts, received_at, data) values
  ('<DEVICE_ID>', '<ORG_ID>', 'low_liquid', now(), now(), '{"channel":1,"flavor":"Вишня"}'::jsonb);

select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare n int; r jsonb;
begin
  select count(*) into n from public.customer_devices;
  if n = 0 then raise notice 'ok: после просрочки customer_devices пуст'; else raise notice 'ОШИБКА: %', n; end if;
  select count(*) into n from public.customer_events;
  if n = 0 then raise notice 'ok: после просрочки customer_events пуст'; else raise notice 'ОШИБКА: %', n; end if;
  select count(*) into n from public.customer_commands;
  if n = 0 then raise notice 'ok: после просрочки customer_commands пуст'; else raise notice 'ОШИБКА: %', n; end if;
  r := public.customer_send_command('<DEVICE_ID>', 'ping', null);
  if r->>'error' = 'no_access' then raise notice 'ok: после просрочки команды отклоняются'; else raise notice 'ОШИБКА: %', r; end if;
  r := public.device_set_label('<DEVICE_ID>', 'новое имя');
  if r->>'error' = 'forbidden' then raise notice 'ok: после просрочки переименование отклоняется'; else raise notice 'ОШИБКА: %', r; end if;
end $$;

reset role;
select set_config('request.jwt.claims', '{"sub":"<STAFF_UUID>","role":"authenticated"}', true);
set local role authenticated;
do $$
declare r jsonb;
begin
  r := public.access_set_valid_until('<DEVICE_ID>', now() + interval '365 days', 'stripe', 'sub_test');
  if (r->>'ok')::boolean then raise notice 'ok: подписка продлена (источник stripe, ссылка записана)'; else raise notice 'ОШИБКА: %', r; end if;
end $$;

reset role;
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int; r jsonb; ch jsonb;
begin
  select count(*) into n from public.customer_devices;
  if n = 1 then raise notice 'ok: после продления доступ вернулся'; else raise notice 'ОШИБКА: %', n; end if;
  select count(*) into n from public.customer_events where type = 'low_liquid';
  if n = 1 then raise notice 'ok: событие, пришедшее за время просрочки, видно (данные не удаляются)';
  else raise notice 'ОШИБКА: событие просрочки не видно: %', n; end if;
  select empty_channels into ch from public.customer_devices;
  if ch @> '[1]'::jsonb then raise notice 'ok: пустая канистра (канал 1) отражена в customer_devices';
  else raise notice 'ОШИБКА: empty_channels = %', ch; end if;
  r := public.device_set_label('<DEVICE_ID>', 'Кафе у входа');
  if (r->>'ok')::boolean then raise notice 'ok: клиент переименовал свой аппарат'; else raise notice 'ОШИБКА: %', r; end if;
  if (select label from public.customer_devices) = 'Кафе у входа' then raise notice 'ok: имя сохранено';
  else raise notice 'ОШИБКА: имя не сохранилось'; end if;
end $$;

-- ====================== 13. перепродажа: закрыть связь, новый код, второй клиент ======================
reset role;
select set_config('request.jwt.claims', '{"sub":"<STAFF_UUID>","role":"authenticated"}', true);
set local role authenticated;
do $$
declare r jsonb; c text;
begin
  begin
    perform public.claim_regenerate('<DEVICE_ID>');
    raise notice 'ОШИБКА: код выдан для привязанного аппарата';
  exception when others then
    if sqlerrm = 'device_bound' then raise notice 'ok: код для привязанного аппарата не выдаётся (device_bound)';
    else raise notice 'ОШИБКА: %', sqlerrm; end if;
  end;
  r := public.access_end('<DEVICE_ID>');
  if (r->>'ok')::boolean then raise notice 'ok: связь закрыта'; else raise notice 'ОШИБКА: %', r; end if;
  c := public.claim_regenerate('<DEVICE_ID>');
  perform set_config('rt.code2', c, true);
  raise notice 'ok: после закрытия связи выдан новый код';
end $$;

reset role;
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int;
begin
  select count(*) into n from public.customer_devices;
  if n = 0 then raise notice 'ok: A после закрытия связи ничего не видит'; else raise notice 'ОШИБКА: %', n; end if;
  if (public.device_claim('<DEVICE_ID>', current_setting('rt.code'), 'х'))->>'error' = 'invalid_claim' then
    raise notice 'ok: старый код недействителен';
  else raise notice 'ОШИБКА: старый код сработал'; end if;
end $$;

reset role;
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_B_UUID>","role":"authenticated"}', true);
set local role authenticated;
do $$
declare r jsonb; n int;
begin
  r := public.device_claim('<DEVICE_ID>', current_setting('rt.code2'), 'Новый хозяин');
  if (r->>'ok')::boolean then raise notice 'ok: B привязал аппарат новым кодом'; else raise notice 'ОШИБКА: %', r; end if;
end $$;

reset role;
-- now() в транзакции неизменен, поэтому «время привязки» второго клиента
-- выставляем позже событий вручную (в жизни это отдельные транзакции)
update public.device_access
   set valid_until = now() + interval '30 days', created_at = clock_timestamp()
 where device_id = '<DEVICE_ID>' and ended_at is null;
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_B_UUID>","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int;
begin
  select count(*) into n from public.customer_devices;
  if n = 1 then raise notice 'ok: B видит свой аппарат'; else raise notice 'ОШИБКА: %', n; end if;
  select count(*) into n from public.customer_events;
  if n = 0 then raise notice 'ok: B не видит события до своей привязки';
  else raise notice 'ОШИБКА: B видит события предыдущего владельца: %', n; end if;
end $$;

-- ====================== 14. anon не вызывает ничего ======================
reset role;
set local role anon;
do $$
declare f text; ok boolean := true;
begin
  begin perform public.device_claim('<DEVICE_ID>', 'AAAA-BBBB-CCCC', 'х'); ok := false; raise notice 'ОШИБКА: anon вызвал device_claim';
  exception when insufficient_privilege then null; end;
  begin perform public.device_set_label('<DEVICE_ID>', 'х'); ok := false; raise notice 'ОШИБКА: anon вызвал device_set_label';
  exception when insufficient_privilege then null; end;
  begin perform public.customer_send_command('<DEVICE_ID>', 'ping', null); ok := false; raise notice 'ОШИБКА: anon вызвал customer_send_command';
  exception when insufficient_privilege then null; end;
  begin perform public.access_set_valid_until('<DEVICE_ID>', now(), 'manual', null); ok := false; raise notice 'ОШИБКА: anon вызвал access_set_valid_until';
  exception when insufficient_privilege then null; end;
  begin perform public.access_end('<DEVICE_ID>'); ok := false; raise notice 'ОШИБКА: anon вызвал access_end';
  exception when insufficient_privilege then null; end;
  begin perform public.claim_regenerate('<DEVICE_ID>'); ok := false; raise notice 'ОШИБКА: anon вызвал claim_regenerate';
  exception when insufficient_privilege then null; end;
  begin perform public.rollout_set_status(gen_random_uuid(), 'active'); ok := false; raise notice 'ОШИБКА: anon вызвал rollout_set_status';
  exception when insufficient_privilege then null; end;
  begin perform public.device_set_ring_tz('<DEVICE_ID>', 'all', 'UTC'); ok := false; raise notice 'ОШИБКА: anon вызвал device_set_ring_tz';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.customer_devices; ok := false; raise notice 'ОШИБКА: anon читает customer_devices';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.customer_events; ok := false; raise notice 'ОШИБКА: anon читает customer_events';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.customer_commands; ok := false; raise notice 'ОШИБКА: anon читает customer_commands';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.devices; ok := false; raise notice 'ОШИБКА: anon читает devices';
  exception when insufficient_privilege then null; end;
  if ok then raise notice 'ok: anon не вызывает функции и не читает представления и таблицы R4'; end if;
end $$;

-- общая проверка: ни одна функция R4 не доступна anon/PUBLIC
reset role;
do $$
declare f record; bad int := 0;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('device_claim','device_set_label','customer_send_command',
                         'access_set_valid_until','access_end','claim_regenerate',
                         'rollout_set_status','device_set_ring_tz','is_staff',
                         'is_staff_or_service','customer_has_access','staff_audit_add',
                         'commands_device_org_check','commands_audit',
                         '_claim_new_code','_claim_hash')
  loop
    if has_function_privilege('anon', f.sig, 'execute') or has_function_privilege('public', f.sig, 'execute') then
      raise notice 'ОШИБКА: % доступна anon/PUBLIC', f.sig; bad := bad + 1;
    end if;
  end loop;
  if bad = 0 then raise notice 'ok: ни одна функция R4 не доступна anon/PUBLIC'; end if;
end $$;

-- ====================== 15. клиент не читает журнал изготовителя ======================
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_B_UUID>","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int;
begin
  select count(*) into n from public.staff_audit;
  if n = 0 then raise notice 'ok: клиент не видит staff_audit'; else raise notice 'ОШИБКА: клиент видит staff_audit: %', n; end if;
end $$;

rollback;
