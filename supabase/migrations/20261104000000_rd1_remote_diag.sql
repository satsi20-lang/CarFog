-- ============================================================
-- RD1: удалённая диагностика, уровень 1 (ТЗ TZ_Remote_Diagnostics_v1,
-- разделы 4, 5, 10). НЕ ПРИМЕНЕНО. SQL выполняет владелец после «да».
--
-- Применять ПОСЛЕ: R1 (device_token_valid, device_diagnostics,
-- device_diag_put/purge), R4 (devices.org_id, commands, staff_audit_add,
-- customer_has_access), функций портала (is_portal_supervisor).
--
-- Что здесь:
--  1. Закрытый бакет Storage diag-shots (public=false, только image/jpeg,
--     до 400 КБ). Писать и удалять файлы может только сервисный ключ
--     (Edge Functions diag-shot-upload / diag-shot-purge). Читать —
--     супервизор портала с 2FA (политика ниже; ссылку на файл портал
--     получает createSignedUrl на короткий срок).
--  2. Таблица device_screenshots — учёт снимков: квота 5 на аппарат, срок
--     24 часа, частота как у команды (1 в минуту, 3 в час).
--  3. device_shot_register / device_shot_expired — только для сервисного
--     ключа (их вызывает Edge Function после проверки токена аппарата).
--  4. supervisor_request_diag — ОТДЕЛЬНАЯ функция для команд
--     collect_diagnostics и capture_screen. supervisor_send_command НЕ
--     меняется: его тела в репозиториях нет, переписать вслепую — риск
--     сломать update_config (так же сделан откат в этапе G). Если владелец
--     даст текст supervisor_send_command, туда можно будет добавить оба
--     действия и вызывать их оттуда.
--  5. Чтение для супервизора: supervisor_diag_list / supervisor_diag_get /
--     supervisor_shot_latest. Каждое действие — staff_audit_add.
--  6. customer_device_health — сводка-светофор для клиента (связь, шина,
--     датчики, терминал, киоск) только из devices.last_seen_at и
--     reported_config. Журнала, пакетов и снимков клиенту нет.
--
-- Расписание очистки — отдельный файл 20261104000100_rd1_cron.sql.
-- ============================================================

-- ---------- 1. Бакет ----------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('diag-shots', 'diag-shots', false, 409600, array['image/jpeg'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Помощник доступа супервизора (копия _supervisor_denied из этапа G
-- портала — своя, чтобы эта миграция не зависела от порядка применения).
-- null — можно; иначе 'forbidden' / 'mfa_required'.
create or replace function public._diag_supervisor_denied() returns text
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not coalesce(public.is_portal_supervisor(), false) then
    return 'forbidden';
  end if;
  if coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then
    return 'mfa_required';
  end if;
  return null;
end;
$$;
revoke all on function public._diag_supervisor_denied() from public, anon;
-- authenticated нужен execute: функция вызывается из политики Storage ниже.
grant execute on function public._diag_supervisor_denied() to authenticated;

-- Чтение файлов бакета — только супервизор с 2FA. Политик на insert /
-- update / delete нет: для anon и authenticated запись закрыта, пишет
-- только сервисный ключ (он обходит RLS).
drop policy if exists diag_shots_supervisor_read on storage.objects;
create policy diag_shots_supervisor_read on storage.objects
  for select to authenticated
  using (bucket_id = 'diag-shots' and public._diag_supervisor_denied() is null);

-- ---------- 2. Учёт снимков ----------

create table if not exists public.device_screenshots (
  device_id  text        not null,
  shot_id    text        not null,
  path       text        not null,
  bytes      int         not null,
  created_at timestamptz not null default now(),
  primary key (device_id, shot_id)
);
create index if not exists device_screenshots_created_idx
  on public.device_screenshots (created_at);

alter table public.device_screenshots enable row level security;
revoke all on table public.device_screenshots from public, anon, authenticated;

-- ---------- 3. Для Edge Functions (только сервисный ключ) ----------

-- Регистрация снимка ДО загрузки файла. Проверяет токен, форму, частоту;
-- освобождает место под квоту 5. Возвращает путь, куда класть файл, и
-- пути старых файлов, которые Edge Function удаляет из бакета.
create or replace function public.device_shot_register(
  p_device text,
  p_token  text,
  p_shot   text,
  p_bytes  int
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_path   text;
  v_remove text[];
begin
  if not public.device_token_valid(p_device, p_token) then
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;
  if p_shot is null or p_shot !~ '^shot-[0-9]{10,16}$'
     or p_bytes is null or p_bytes < 1 or p_bytes > 409600 then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;

  -- Частота: не чаще раза в минуту и не больше 3 в час на аппарат.
  if exists (select 1 from public.device_screenshots
              where device_id = p_device
                and created_at > now() - interval '1 minute')
     or (select count(*) from public.device_screenshots
          where device_id = p_device
            and created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  -- Срок 24 часа (все аппараты) и квота: у этого аппарата остаётся не
  -- больше 4 прежних, вместе с новым — 5.
  with gone as (
    delete from public.device_screenshots s
     where s.created_at < now() - interval '24 hours'
        or (s.device_id = p_device and s.shot_id in (
              select shot_id from public.device_screenshots
               where device_id = p_device
               order by created_at desc
               offset 4))
    returning s.path
  )
  select coalesce(array_agg(path), '{}') into v_remove from gone;

  v_path := p_device || '/' || p_shot || '.jpg';
  insert into public.device_screenshots (device_id, shot_id, path, bytes)
  values (p_device, p_shot, v_path, p_bytes)
  on conflict (device_id, shot_id) do update
    set path = excluded.path, bytes = excluded.bytes, created_at = now();

  return jsonb_build_object('ok', true, 'path', v_path, 'remove', to_jsonb(v_remove));
end;
$$;
revoke all on function public.device_shot_register(text, text, text, int)
  from public, anon, authenticated;
grant execute on function public.device_shot_register(text, text, text, int)
  to service_role;

-- Загрузка файла не удалась — снять запись, чтобы не занимать квоту и
-- частоту зря.
create or replace function public.device_shot_forget(p_device text, p_shot text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.device_screenshots where device_id = p_device and shot_id = p_shot;
$$;
revoke all on function public.device_shot_forget(text, text) from public, anon, authenticated;
grant execute on function public.device_shot_forget(text, text) to service_role;

-- Ежесуточная очистка (diag-shot-purge): снимает просроченные записи и
-- отдаёт пути ВСЕХ файлов бакета старше 24 часов (в том числе «сирот»,
-- если удаление файла раньше не прошло). Файлы удаляет Edge Function через
-- Storage API: прямое удаление строк storage.objects в Supabase запрещено и
-- самих файлов не стирает.
create or replace function public.device_shot_expired() returns jsonb
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  v_paths text[];
begin
  delete from public.device_screenshots where created_at < now() - interval '24 hours';
  select coalesce(array_agg(name), '{}') into v_paths
    from storage.objects
   where bucket_id = 'diag-shots' and created_at < now() - interval '24 hours';
  return jsonb_build_object('ok', true, 'paths', to_jsonb(v_paths));
end;
$$;
revoke all on function public.device_shot_expired() from public, anon, authenticated;
grant execute on function public.device_shot_expired() to service_role;

-- ---------- 4. Команды супервизора ----------

-- collect_diagnostics: params {} или {"log_minutes": 1..60}.
-- capture_screen: params {}.
-- Частота на сервере: одно и то же действие не чаще раза в минуту на
-- аппарат (в приложении ещё и 3 в час).
create or replace function public.supervisor_request_diag(
  p_device text,
  p_action text,
  p_params jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_denied text := public._diag_supervisor_denied();
  v_params jsonb := coalesce(p_params, '{}'::jsonb);
  v_org    uuid;
  v_id     text;
  v_min    jsonb;
begin
  if v_denied is not null then
    return jsonb_build_object('ok', false, 'error', v_denied);
  end if;
  if p_action not in ('collect_diagnostics', 'capture_screen') then
    return jsonb_build_object('ok', false, 'error', 'action_not_allowed');
  end if;
  if jsonb_typeof(v_params) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;
  if p_action = 'capture_screen' and v_params <> '{}'::jsonb then
    return jsonb_build_object('ok', false, 'error', 'bad_params');
  end if;
  if p_action = 'collect_diagnostics' and v_params <> '{}'::jsonb then
    v_min := v_params -> 'log_minutes';
    if (select count(*) from jsonb_object_keys(v_params)) <> 1
       or v_min is null or jsonb_typeof(v_min) <> 'number'
       or (v_min #>> '{}') !~ '^[0-9]{1,2}$'
       or not ((v_min #>> '{}')::int between 1 and 60) then
      return jsonb_build_object('ok', false, 'error', 'bad_params');
    end if;
  end if;

  select org_id into v_org from public.devices where id = p_device;
  if v_org is null then
    return jsonb_build_object('ok', false, 'error', 'no_device');
  end if;
  if exists (select 1 from public.commands
              where device_id = p_device and action = p_action
                and created_at > now() - interval '1 minute') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  insert into public.commands(device_id, org_id, action, params)
  values (p_device, v_org, p_action, v_params)
  returning id::text into v_id;

  perform public.staff_audit_add(v_org, 'supervisor_' || p_action, p_device,
    jsonb_build_object('command', v_id, 'params', v_params));
  return jsonb_build_object('ok', true, 'command_id', v_id);
end;
$$;

-- ---------- 5. Чтение для супервизора ----------

-- Последние 10 пакетов аппарата: id, когда, сколько частей пришло.
create or replace function public.supervisor_diag_list(p_device text) returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_denied text := public._diag_supervisor_denied();
begin
  if v_denied is not null then
    return jsonb_build_object('ok', false, 'error', v_denied);
  end if;
  return jsonb_build_object('ok', true, 'bundles', coalesce((
    select jsonb_agg(b order by b.created_at desc)
      from (
        select bundle_id,
               max(created_at)            as created_at,
               count(*)                   as parts_received,
               max(parts)                 as parts,
               sum(length(data))          as size_chars
          from public.device_diagnostics
         where device_id = p_device
         group by bundle_id
         order by max(created_at) desc
         limit 10
      ) b), '[]'::jsonb));
end;
$$;

-- Пакет целиком (части склеены по порядку). p_bundle null — последний.
create or replace function public.supervisor_diag_get(
  p_device text,
  p_bundle text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_denied text := public._diag_supervisor_denied();
  v_bundle text := p_bundle;
  v_org    uuid;
  v_data   text;
  v_got    int;
  v_parts  int;
  v_at     timestamptz;
begin
  if v_denied is not null then
    return jsonb_build_object('ok', false, 'error', v_denied);
  end if;
  if v_bundle is null then
    select bundle_id into v_bundle from public.device_diagnostics
     where device_id = p_device order by created_at desc limit 1;
  end if;
  if v_bundle is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  select string_agg(data, '' order by part), count(*), max(parts), max(created_at)
    into v_data, v_got, v_parts, v_at
    from public.device_diagnostics
   where device_id = p_device and bundle_id = v_bundle;
  if v_data is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select org_id into v_org from public.devices where id = p_device;
  perform public.staff_audit_add(v_org, 'supervisor_diag_read', p_device,
    jsonb_build_object('bundle', v_bundle));
  return jsonb_build_object('ok', true, 'bundle_id', v_bundle,
    'complete', v_got = v_parts, 'parts', v_parts, 'parts_received', v_got,
    'created_at', v_at, 'data', v_data);
end;
$$;

-- Последний снимок: путь в бакете diag-shots (ссылку портал получает
-- createSignedUrl на 60 с — чтение файла разрешено политикой выше).
create or replace function public.supervisor_shot_latest(p_device text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_denied text := public._diag_supervisor_denied();
  v_org    uuid;
  s        record;
begin
  if v_denied is not null then
    return jsonb_build_object('ok', false, 'error', v_denied);
  end if;
  select shot_id, path, bytes, created_at into s
    from public.device_screenshots
   where device_id = p_device and created_at > now() - interval '24 hours'
   order by created_at desc limit 1;
  if s.shot_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  select org_id into v_org from public.devices where id = p_device;
  perform public.staff_audit_add(v_org, 'supervisor_shot_read', p_device,
    jsonb_build_object('shot', s.shot_id));
  return jsonb_build_object('ok', true, 'shot_id', s.shot_id, 'bucket', 'diag-shots',
    'path', s.path, 'bytes', s.bytes, 'created_at', s.created_at);
end;
$$;

-- ---------- 6. Светофор для клиента ----------

-- Цвета: green / yellow / red / grey (нет данных). Только поля
-- reported_config и время связи; журнал и снимки сюда не попадают.
-- reported_config.health и kiosk_lock присылает приложение с RD1.
create or replace function public.customer_device_health(p_device text) returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  d      record;
  c      jsonb;
  h      jsonb;
  k      jsonb;
  v_age  interval;
  v_conn text;
  v_bus  text;
  v_sens text;
  v_term text;
  v_kiosk text;
begin
  if auth.uid() is null or not public.customer_has_access(p_device) then
    return jsonb_build_object('ok', false, 'error', 'no_access');
  end if;
  select last_seen_at, reported_config into d from public.devices where id = p_device;
  c := coalesce(d.reported_config, '{}'::jsonb);
  h := c -> 'health';
  k := c -> 'kiosk_lock';

  v_age := now() - d.last_seen_at;
  v_conn := case
    when d.last_seen_at is null then 'grey'
    when v_age < interval '3 minutes' then 'green'
    when v_age < interval '30 minutes' then 'yellow'
    else 'red' end;

  v_bus := case
    when (c ->> 'out_of_service') = 'true' then 'red'
    when h is null or h -> 'bus_ok' is null then 'grey'
    when (h ->> 'bus_ok') = 'true' then 'green'
    else 'red' end;

  v_sens := case
    when h is null then 'grey'
    when (h ->> 'thermo') = 'fail' or (h ->> 'meter') = 'fail' then 'red'
    when jsonb_array_length(coalesce(c -> 'payment_blocked_by_config', '[]'::jsonb)) > 0
      then 'yellow'
    else 'green' end;

  v_term := case
    when h is null or h ->> 'terminal' is null then 'grey'
    when h ->> 'terminal' = 'off' then 'grey'
    when h ->> 'terminal' = 'ok' then 'green'
    else 'red' end;

  v_kiosk := case
    when k is null then 'grey'
    when (k ->> 'lock_task_active') = 'true' then 'green'
    when (k ->> 'lock_enabled') = 'true' then 'yellow'
    else 'yellow' end;

  return jsonb_build_object('ok', true,
    'connection', v_conn, 'bus', v_bus, 'sensors', v_sens,
    'terminal', v_term, 'kiosk', v_kiosk,
    'last_seen_at', d.last_seen_at);
end;
$$;

-- ---------- Права ----------

revoke all on function public.supervisor_request_diag(text, text, jsonb) from public, anon;
revoke all on function public.supervisor_diag_list(text) from public, anon;
revoke all on function public.supervisor_diag_get(text, text) from public, anon;
revoke all on function public.supervisor_shot_latest(text) from public, anon;
revoke all on function public.customer_device_health(text) from public, anon;
grant execute on function public.supervisor_request_diag(text, text, jsonb) to authenticated;
grant execute on function public.supervisor_diag_list(text) to authenticated;
grant execute on function public.supervisor_diag_get(text, text) to authenticated;
grant execute on function public.supervisor_shot_latest(text) to authenticated;
grant execute on function public.customer_device_health(text) to authenticated;
