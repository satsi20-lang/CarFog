-- ============================================================
-- Проверка RD1 (удалённая диагностика): права и квоты.
-- По образцу rls_rollouts.sql и carfog-portal/supabase/tests/supervisor_updates.sql.
-- НЕ применять к рабочей базе: запускать на копии/тестовом проекте под
-- полными правами (SQL Editor) ПОСЛЕ миграций 20261104000000_rd1_remote_diag.sql
-- и 20261105000000_rd1b_health_supervisor.sql (светофор супервайзеру с 2FA).
-- Всё в одной транзакции, в конце rollback — данные не остаются.
--
-- Что подставить:
--   <SUPERVISOR_UUID>  пользователь, для которого is_portal_supervisor() = true
--                      (и без device_access к <DEVICE_ID> — иначе проверка
--                      светофора «без 2FA» пройдёт как клиентская)
--   <CUSTOMER_UUID>    клиент с доступом к <DEVICE_ID> (device_access)
--   <DEVICE_ID>        аппарат клиента
--   <OTHER_DEVICE_ID>  другой аппарат (к нему у клиента доступа нет)
--   <DEVICE_TOKEN>     токен <DEVICE_ID> (только на тестовом проекте!)
-- Каждая проверка пишет в «Messages» строку ok или ОШИБКА.
-- ============================================================
begin;

-- Тестовые данные: пакет диагностики и снимок <DEVICE_ID>.
insert into public.device_diagnostics (device_id, bundle_id, part, parts, data)
values ('<DEVICE_ID>', 'diag-test', 1, 1, '{"test":true}');
insert into public.device_screenshots (device_id, shot_id, path, bytes)
values ('<DEVICE_ID>', 'shot-1000000000000', '<DEVICE_ID>/shot-1000000000000.jpg', 1000);

-- ---------- клиент: журнал, пакеты и снимки закрыты, светофор открыт ----------
select set_config('request.jwt.claims',
  '{"sub":"<CUSTOMER_UUID>","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;

do $$
declare r jsonb;
begin
  r := public.supervisor_diag_get('<DEVICE_ID>');
  if r->>'error' = 'forbidden' then raise notice 'ok: клиент не читает пакет';
  else raise notice 'ОШИБКА: клиент прочитал пакет'; end if;

  r := public.supervisor_diag_list('<DEVICE_ID>');
  if r->>'error' = 'forbidden' then raise notice 'ok: клиент не видит список пакетов';
  else raise notice 'ОШИБКА: клиент увидел список пакетов'; end if;

  r := public.supervisor_shot_latest('<DEVICE_ID>');
  if r->>'error' = 'forbidden' then raise notice 'ok: клиент не получает снимок';
  else raise notice 'ОШИБКА: клиент получил снимок'; end if;

  r := public.supervisor_request_diag('<DEVICE_ID>', 'capture_screen');
  if r->>'error' = 'forbidden' then raise notice 'ok: клиент не запрашивает снимок';
  else raise notice 'ОШИБКА: клиент запросил снимок: %', r; end if;

  r := public.customer_device_health('<DEVICE_ID>');
  if r->>'ok' = 'true' and r ? 'connection' and r ? 'kiosk'
     and not r ? 'data' and not r ? 'path' then
    raise notice 'ok: клиент видит только светофор: %', r;
  else raise notice 'ОШИБКА: светофор клиента: %', r; end if;

  r := public.customer_device_health('<OTHER_DEVICE_ID>');
  if r->>'error' = 'no_access' then raise notice 'ok: чужой аппарат — no_access';
  else raise notice 'ОШИБКА: клиент видит чужой аппарат'; end if;
end $$;

-- Прямой доступ к таблицам закрыт.
do $$ begin
  perform 1 from public.device_screenshots limit 1;
  raise notice 'ОШИБКА: клиент читает device_screenshots напрямую';
exception when insufficient_privilege then
  raise notice 'ok: device_screenshots закрыта для authenticated';
end $$;
do $$ begin
  perform 1 from public.device_diagnostics limit 1;
  raise notice 'ОШИБКА: клиент читает device_diagnostics напрямую';
exception when insufficient_privilege then
  raise notice 'ok: device_diagnostics закрыта для authenticated';
end $$;
-- Файлы бакета: политика пускает только супервизора с 2FA.
do $$
declare n int;
begin
  select count(*) into n from storage.objects where bucket_id = 'diag-shots';
  if n = 0 then raise notice 'ok: клиент не видит файлы diag-shots';
  else raise notice 'ОШИБКА: клиент видит % файлов diag-shots', n; end if;
end $$;
-- Функции для Edge Functions клиенту недоступны.
do $$ begin
  perform public.device_shot_register('<DEVICE_ID>', 'x', 'shot-1000000000001', 10);
  raise notice 'ОШИБКА: authenticated вызвал device_shot_register';
exception when insufficient_privilege then
  raise notice 'ok: device_shot_register закрыта для authenticated';
end $$;

reset role;

-- ---------- anon: ничего ----------
set local role anon;
do $$ begin
  perform public.customer_device_health('<DEVICE_ID>');
  raise notice 'ОШИБКА: anon вызвал customer_device_health';
exception when insufficient_privilege then
  raise notice 'ok: anon не вызывает customer_device_health';
end $$;
do $$ begin
  perform public.device_shot_register('<DEVICE_ID>', '<DEVICE_TOKEN>', 'shot-1000000000002', 10);
  raise notice 'ОШИБКА: anon вызвал device_shot_register (аппарат должен идти через Edge Function)';
exception when insufficient_privilege then
  raise notice 'ok: anon не вызывает device_shot_register';
end $$;
reset role;

-- ---------- супервизор без 2FA: mfa_required ----------
select set_config('request.jwt.claims',
  '{"sub":"<SUPERVISOR_UUID>","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
do $$
declare r jsonb; n int;
begin
  r := public.supervisor_diag_get('<DEVICE_ID>');
  if r->>'error' in ('mfa_required', 'forbidden') then
    raise notice 'ok: без 2FA пакет закрыт (%)', r->>'error';
  else raise notice 'ОШИБКА: без 2FA пакет открыт'; end if;

  r := public.supervisor_shot_latest('<DEVICE_ID>');
  if r->>'error' in ('mfa_required', 'forbidden') then
    raise notice 'ok: без 2FA снимок закрыт (%)', r->>'error';
  else raise notice 'ОШИБКА: без 2FA снимок открыт'; end if;

  r := public.customer_device_health('<DEVICE_ID>');
  if r->>'error' = 'no_access' then raise notice 'ok: без 2FA светофор супервайзеру закрыт';
  else raise notice 'ОШИБКА: без 2FA супервайзер видит светофор: %', r; end if;

  select count(*) into n from storage.objects where bucket_id = 'diag-shots';
  if n = 0 then raise notice 'ok: без 2FA файлы diag-shots не видны';
  else raise notice 'ОШИБКА: без 2FA видны файлы diag-shots'; end if;
end $$;
reset role;

-- ---------- супервизор с 2FA ----------
select set_config('request.jwt.claims',
  '{"sub":"<SUPERVISOR_UUID>","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
do $$
declare r jsonb;
begin
  r := public.supervisor_diag_get('<DEVICE_ID>');
  if r->>'ok' = 'true' and r->>'data' = '{"test":true}' then
    raise notice 'ok: супервизор читает пакет';
  else raise notice 'ОШИБКА: супервизор не прочитал пакет: %', r; end if;

  r := public.supervisor_diag_list('<DEVICE_ID>');
  if r->>'ok' = 'true' and jsonb_array_length(r->'bundles') >= 1 then
    raise notice 'ok: супервизор видит список пакетов';
  else raise notice 'ОШИБКА: список пакетов: %', r; end if;

  r := public.supervisor_shot_latest('<DEVICE_ID>');
  if r->>'ok' = 'true' and r->>'path' = '<DEVICE_ID>/shot-1000000000000.jpg' then
    raise notice 'ok: супервизор получает путь снимка';
  else raise notice 'ОШИБКА: снимок: %', r; end if;

  r := public.customer_device_health('<DEVICE_ID>');
  if r->>'ok' = 'true' and r ? 'connection' then raise notice 'ok: супервайзер с 2FA видит светофор';
  else raise notice 'ОШИБКА: светофор супервайзера: %', r; end if;

  r := public.customer_device_health('<OTHER_DEVICE_ID>');
  if r->>'ok' = 'true' then raise notice 'ok: супервайзер с 2FA видит светофор любого аппарата';
  else raise notice 'ОШИБКА: светофор супервайзера (другой аппарат): %', r; end if;

  r := public.supervisor_request_diag('<DEVICE_ID>', 'update_config', '{}');
  if r->>'error' = 'action_not_allowed' then raise notice 'ok: чужое действие не проходит';
  else raise notice 'ОШИБКА: прошло чужое действие: %', r; end if;

  r := public.supervisor_request_diag('<DEVICE_ID>', 'collect_diagnostics', '{"log_minutes":90}');
  if r->>'error' = 'bad_params' then raise notice 'ok: окно журнала больше 60 мин отклонено';
  else raise notice 'ОШИБКА: log_minutes=90 принят: %', r; end if;

  r := public.supervisor_request_diag('<DEVICE_ID>', 'collect_diagnostics', '{"log_minutes":30}');
  if r->>'ok' = 'true' then raise notice 'ok: collect_diagnostics отправлена';
  else raise notice 'ОШИБКА: collect_diagnostics: %', r; end if;

  r := public.supervisor_request_diag('<DEVICE_ID>', 'collect_diagnostics', '{}');
  if r->>'error' = 'rate_limited' then raise notice 'ok: второй запрос за минуту — rate_limited';
  else raise notice 'ОШИБКА: частота не ограничена: %', r; end if;

  r := public.supervisor_request_diag('<DEVICE_ID>', 'capture_screen', '{}');
  if r->>'ok' = 'true' then raise notice 'ok: capture_screen отправлена';
  else raise notice 'ОШИБКА: capture_screen: %', r; end if;
end $$;
reset role;

-- Каждое действие супервизора — в staff_audit.
do $$
declare n int;
begin
  select count(*) into n from public.staff_audit
   where device_id = '<DEVICE_ID>' and at > now() - interval '1 minute'
     and action in ('supervisor_collect_diagnostics', 'supervisor_capture_screen',
                    'supervisor_diag_read', 'supervisor_shot_read');
  if n >= 4 then raise notice 'ok: действия записаны в staff_audit (%)', n;
  else raise notice 'ОШИБКА: в staff_audit только % записей', n; end if;
end $$;

-- ---------- аппарат (через сервисный ключ Edge Function): квоты ----------
-- Неверный токен.
do $$
declare r jsonb;
begin
  r := public.device_shot_register('<DEVICE_ID>', 'неверный-токен', 'shot-1000000000003', 10);
  if r->>'error' = 'auth' then raise notice 'ok: неверный токен — auth';
  else raise notice 'ОШИБКА: неверный токен принят: %', r; end if;

  r := public.device_shot_register('<DEVICE_ID>', '<DEVICE_TOKEN>', 'shot-1000000000003', 500000);
  if r->>'error' = 'bad_request' then raise notice 'ok: больше 400 КБ — bad_request';
  else raise notice 'ОШИБКА: большой снимок принят: %', r; end if;

  r := public.device_shot_register('<OTHER_DEVICE_ID>', '<DEVICE_TOKEN>', 'shot-1000000000003', 10);
  if r->>'error' = 'auth' then raise notice 'ok: чужой токен для другого аппарата — auth';
  else raise notice 'ОШИБКА: токен подошёл к чужому аппарату: %', r; end if;
end $$;

-- Частота: тестовый снимок выше создан только что → следующий rate_limited.
do $$
declare r jsonb;
begin
  r := public.device_shot_register('<DEVICE_ID>', '<DEVICE_TOKEN>', 'shot-1000000000004', 10);
  if r->>'error' = 'rate_limited' then raise notice 'ok: второй снимок за минуту — rate_limited';
  else raise notice 'ОШИБКА: частота снимков не ограничена: %', r; end if;
end $$;

-- Квота 5: старые записи (сдвинутые на 2 часа назад) вытесняются.
update public.device_screenshots set created_at = now() - interval '2 hours'
 where device_id = '<DEVICE_ID>';
insert into public.device_screenshots (device_id, shot_id, path, bytes, created_at)
select '<DEVICE_ID>', 'shot-10000000000' || g, '<DEVICE_ID>/shot-10000000000' || g || '.jpg', 10,
       now() - interval '3 hours' - g * interval '1 minute'
  from generate_series(10, 15) g;
do $$
declare r jsonb; n int;
begin
  r := public.device_shot_register('<DEVICE_ID>', '<DEVICE_TOKEN>', 'shot-1000000000099', 10);
  select count(*) into n from public.device_screenshots where device_id = '<DEVICE_ID>';
  if r->>'ok' = 'true' and n = 5 and jsonb_array_length(r->'remove') >= 3 then
    raise notice 'ok: квота 5 соблюдена, на удаление % файлов', jsonb_array_length(r->'remove');
  else raise notice 'ОШИБКА: квота: снимков %, ответ %', n, r; end if;
end $$;

-- Срок 24 часа.
update public.device_screenshots set created_at = now() - interval '25 hours'
 where device_id = '<DEVICE_ID>';
do $$
declare r jsonb; n int;
begin
  r := public.device_shot_expired();
  select count(*) into n from public.device_screenshots where device_id = '<DEVICE_ID>';
  if r->>'ok' = 'true' and n = 0 then raise notice 'ok: снимки старше 24 ч сняты';
  else raise notice 'ОШИБКА: после очистки осталось %', n; end if;
end $$;

rollback;
