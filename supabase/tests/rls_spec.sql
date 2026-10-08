-- ============================================================
-- Проверка R5 (спецификация аппарата: device_set_spec и столбцы devices).
-- По образцу rls_tenancy.sql. НЕ применять к рабочей базе: запускать на
-- копии/тестовом проекте под полными правами. Одна транзакция, в конце rollback.
--
-- Что подставить:
--   <STAFF_UUID>       изготовитель: член организации <ORG_ID>
--   <CUSTOMER_A_UUID>  клиент (НЕ член ни одной организации)
--   <ORG_ID>           организация-изготовитель
--   <DEVICE_ID>        устройство организации <ORG_ID>
--   <OTHER_DEVICE_ID>  устройство ДРУГОЙ организации
-- Каждая проверка пишет в «Messages» строку ok или ОШИБКА.
-- ============================================================
begin;

-- ====================== 0. значения по умолчанию ======================
do $$
declare d public.devices%rowtype;
begin
  select * into d from public.devices where id = '<DEVICE_ID>';
  if d.spec_pumps = 4 and d.spec_langs = '{et,en,ru}' and d.spec_default_lang = 'et'
     and d.hardware_profile = 'sy156-a510' then
    raise notice 'ok: у существующего аппарата spec по умолчанию (4, et/en/ru, et, sy156-a510)';
  else
    raise notice 'ОШИБКА: spec по умолчанию отличается: % % % %', d.spec_pumps, d.spec_langs, d.spec_default_lang, d.hardware_profile;
  end if;
end $$;

-- ====================== 1. ограничения таблицы ======================
do $$
declare n int := 0;
begin
  begin update public.devices set spec_pumps = 3 where id = '<DEVICE_ID>'; exception when check_violation then n := n + 1; end;
  begin update public.devices set spec_pumps = 11 where id = '<DEVICE_ID>'; exception when check_violation then n := n + 1; end;
  begin update public.devices set spec_langs = '{}' where id = '<DEVICE_ID>'; exception when check_violation then n := n + 1; end;
  begin update public.devices set spec_langs = '{et,et}' where id = '<DEVICE_ID>'; exception when check_violation then n := n + 1; end;
  begin update public.devices set spec_langs = '{et,xx}' where id = '<DEVICE_ID>'; exception when check_violation then n := n + 1; end;
  begin update public.devices set spec_langs = '{ET}', spec_default_lang = 'ET' where id = '<DEVICE_ID>'; exception when check_violation then n := n + 1; end;
  begin update public.devices set spec_default_lang = 'de' where id = '<DEVICE_ID>'; exception when check_violation then n := n + 1; end;
  begin update public.devices set spec_langs = array_fill('et'::text, array[25]) where id = '<DEVICE_ID>'; exception when check_violation then n := n + 1; end;
  begin update public.devices set spec_langs = '{et,NULL}'::text[] where id = '<DEVICE_ID>'; exception when check_violation then n := n + 1; end;
  if n = 9 then raise notice 'ok: ограничения таблицы отклоняют 9 плохих значений (насосы, пустой/повтор/чужой/заглавный код, >24, default вне набора, NULL)';
  else raise notice 'ОШИБКА: ограничения сработали % из 9', n; end if;
end $$;

-- ====================== 2. изготовитель ======================
select set_config('request.jwt.claims', '{"sub":"<STAFF_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare r jsonb; d record;
begin
  r := public.device_set_spec('<DEVICE_ID>', 8, array['ru','en','de'], 'en');
  -- authenticated читает devices только по столбцам (token закрыт): без select *
  select spec_pumps, spec_langs, spec_default_lang into d from public.devices where id = '<DEVICE_ID>';
  if (r ->> 'ok')::boolean and d.spec_pumps = 8 and d.spec_langs = '{ru,en,de}' and d.spec_default_lang = 'en' then
    raise notice 'ok: изготовитель задал spec (8 насосов, ru/en/de, по умолчанию en); порядок языков сохранён';
  else raise notice 'ОШИБКА: device_set_spec не сработал: %', r; end if;
end $$;

do $$
declare n int; det jsonb;
begin
  select count(*), max(details::text)::jsonb into n, det from public.staff_audit
   where action = 'device_set_spec' and device_id = '<DEVICE_ID>';
  if n >= 1 and (det ->> 'pumps')::int = 8 and det ->> 'default_lang' = 'en' and (det ->> 'prev_pumps')::int = 4 then
    raise notice 'ok: device_set_spec записан в staff_audit (с прежними значениями, без секретов)';
  else raise notice 'ОШИБКА: нет/неверная запись staff_audit: % %', n, det; end if;
  if det::text ~* '(token|secret|key)' then raise notice 'ОШИБКА: в audit похоже на секрет'; else raise notice 'ok: в audit нет секретов'; end if;
end $$;

do $$
declare bad int := 0; r jsonb; i int := 0;
  cases jsonb := jsonb_build_array(
    jsonb_build_object('p', 3,  'l', array['et'], 'd', 'et'),
    jsonb_build_object('p', 11, 'l', array['et'], 'd', 'et'),
    jsonb_build_object('p', null, 'l', array['et'], 'd', 'et'),
    jsonb_build_object('p', 5,  'l', array[]::text[], 'd', 'et'),
    jsonb_build_object('p', 5,  'l', array['et','et'], 'd', 'et'),
    jsonb_build_object('p', 5,  'l', array['et','xx'], 'd', 'et'),
    jsonb_build_object('p', 5,  'l', array['ET'], 'd', 'ET'),
    jsonb_build_object('p', 5,  'l', array['et','en'], 'd', 'ru'),
    jsonb_build_object('p', 5,  'l', array['et'], 'd', null));
  c jsonb;
begin
  for c in select * from jsonb_array_elements(cases) loop
    r := public.device_set_spec('<DEVICE_ID>', (c ->> 'p')::int,
           array(select jsonb_array_elements_text(c -> 'l')), c ->> 'd');
    i := i + 1;
    if (r ->> 'ok')::boolean or r ->> 'error' <> 'bad_request' then
      bad := bad + 1; raise notice 'ОШИБКА: плохое значение №% принято/не bad_request: %', i, r;
    end if;
  end loop;
  r := public.device_set_spec('<DEVICE_ID>', 5, null, 'et');
  if (r ->> 'ok')::boolean or r ->> 'error' <> 'bad_request' then bad := bad + 1; raise notice 'ОШИБКА: NULL-набор принят: %', r; end if;
  r := public.device_set_spec('<DEVICE_ID>', 5, array(select 'et' from generate_series(1, 25)), 'et');
  if (r ->> 'ok')::boolean or r ->> 'error' <> 'bad_request' then bad := bad + 1; raise notice 'ОШИБКА: 25 языков приняты: %', r; end if;
  if bad = 0 then raise notice 'ok: плохие значения отклонены единым ответом bad_request (11 случаев)'; end if;
end $$;

do $$
declare d record;
begin
  select spec_pumps, spec_langs into d from public.devices where id = '<DEVICE_ID>';
  if d.spec_pumps = 8 and d.spec_langs = '{ru,en,de}' then
    raise notice 'ok: после отклонённых вызовов spec не изменился';
  else raise notice 'ОШИБКА: spec изменился после отказов: % %', d.spec_pumps, d.spec_langs; end if;
end $$;

do $$
declare r jsonb;
begin
  r := public.device_set_spec('NOPE-000', 5, array['et'], 'et');
  if r ->> 'error' = 'not_found' then raise notice 'ok: несуществующий аппарат → not_found (для изготовителя)';
  else raise notice 'ОШИБКА: ожидали not_found: %', r; end if;
  r := public.device_set_spec('<OTHER_DEVICE_ID>', 5, array['et'], 'et');
  if r ->> 'error' = 'forbidden' then raise notice 'ok: аппарат чужой организации → forbidden';
  else raise notice 'ОШИБКА: чужой аппарат: %', r; end if;
end $$;

do $$
begin
  perform 1 from public.devices where id = '<DEVICE_ID>' and spec_pumps = 8;
  if found then raise notice 'ok: изготовитель читает spec-столбцы devices'; else raise notice 'ОШИБКА: изготовитель не читает spec'; end if;
end $$;

-- прямая запись у authenticated закрыта (только через функцию)
do $$
declare ok boolean := false;
begin
  begin
    update public.devices set spec_pumps = 5 where id = '<DEVICE_ID>';
    if not found then ok := true; end if;   -- 0 строк (RLS) тоже запрет
  exception when insufficient_privilege then ok := true; end;
  if ok then raise notice 'ok: прямой update spec у authenticated запрещён'; else raise notice 'ОШИБКА: прямой update spec прошёл'; end if;
end $$;

-- ====================== 3. клиент ======================
reset role;
select set_config('request.jwt.claims', '{"sub":"<CUSTOMER_A_UUID>","role":"authenticated"}', true);
set local role authenticated;

do $$
declare r jsonb;
begin
  r := public.device_set_spec('<DEVICE_ID>', 5, array['et'], 'et');
  if not (r ->> 'ok')::boolean and r ->> 'error' = 'forbidden' then raise notice 'ok: клиент не может вызвать device_set_spec (forbidden)';
  else raise notice 'ОШИБКА: клиент вызвал device_set_spec: %', r; end if;
  r := public.device_set_spec('NOPE-000', 5, array['et'], 'et');
  if r ->> 'error' = 'forbidden' then raise notice 'ok: клиенту несуществующий аппарат тоже forbidden (не раскрываем существование)';
  else raise notice 'ОШИБКА: клиенту not_found: %', r; end if;
end $$;

do $$
declare n int;
begin
  select count(*) into n from public.devices where id = '<DEVICE_ID>';
  if n = 0 then raise notice 'ok: клиент (не член организации) не видит devices (и spec-столбцы)';
  else raise notice 'ОШИБКА: клиент видит devices: %', n; end if;
end $$;

do $$
declare n int;
begin
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name in
     ('customer_devices','customer_events','customer_commands','staff_device_access')
     and column_name in ('spec_pumps','spec_langs','spec_default_lang','hardware_profile');
  if n = 0 then raise notice 'ok: представления customer_*/staff_device_access не содержат spec-столбцов';
  else raise notice 'ОШИБКА: spec-столбцы видны в представлениях: %', n; end if;
end $$;

do $$
declare ok boolean := false;
begin
  begin perform 1 from public.device_claims limit 1; exception when insufficient_privilege then ok := true; end;
  if ok then raise notice 'ok: (контроль) клиент по-прежнему без доступа к базовым таблицам R4';
  else raise notice 'ОШИБКА: клиент читает device_claims'; end if;
end $$;

reset role;
rollback;
