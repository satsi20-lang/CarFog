-- ============================================================
-- R3: раскатка обновления по кольцам («целевая версия»).
-- НЕ ПРИМЕНЕНО автоматически; SQL в Supabase выполняет только владелец.
-- Применять ПОСЛЕ 20261003000200_r2_releases.sql (app_releases) и
-- 20261003000000_r1_server_token_poll.sql (device_poll).
--
-- Принцип: аппарат не получает команду, а узнаёт «целевую версию» из ответа
-- device_poll (поле target) и сам обновляется тем же update_app-кодом
-- (все проверки, скрипт, откат — без изменений). Откат остаётся ручным.
--
-- Решения владельца (не менять без согласования):
--  1. Кольца test / early / all назначаются аппарату вручную; переход к
--     следующему кольцу — только кнопкой владельца, не по таймеру.
--  2. Окно установки 02:00–05:00 по местному времени аппарата + случайная
--     (детерминированная для пары аппарат+раскатка) задержка до 30 минут.
--     Часы и пояс планшета ненадёжны: окно считает СЕРВЕР по своему времени
--     и поясу, заданному аппарату в панели (devices.timezone, IANA).
--  3. Автопауза: один автоматический откат (update_rolled_back,
--     automatic=true) или две ошибки установки на РАЗНЫХ аппаратах; busy,
--     not_newer, rate_limited*, url_failed*, download_failed, no_space не
--     считаются. Продолжить — только кнопкой владельца.
--
-- Схема (проверено запросом в рабочей базе, 06.10.2026):
--  * членство: org_members(user_id, org_id); public.is_org_member(p_org uuid)
--    (security definer, stable) = exists(select 1 from org_members where
--    user_id = auth.uid() and org_id = p_org) — на ней построены все политики;
--  * devices: id text, org_id, token, name, app_version, last_seen_at, ...;
--  * events: device_id, org_id, type, ts (время по часам АППАРАТА, ненадёжно),
--    received_at (время СЕРВЕРА), data jsonb; столбца created_at НЕТ —
--    всё сравнение времени событий здесь только по received_at;
--  * device_poll в рабочей базе совпадает с версией в r1 (ниже — она же +target).
--
-- ПРАВА. В PostgreSQL execute на новую функцию по умолчанию у PUBLIC, поэтому
-- у каждой функции ниже явный revoke from public, anon и выдача только нужным
-- ролям: функции панели — authenticated; rollout_target, rollout_my_org и
-- триггерная функция — никому (их вызывает только security definer-код).
-- ============================================================

-- ---------- devices: кольцо и часовой пояс ----------
alter table public.devices
  add column if not exists ring text not null default 'all'
    check (ring in ('test', 'early', 'all'));

alter table public.devices
  add column if not exists timezone text not null default 'UTC';

-- ---------- Организация вошедшего пользователя (только для rollout_create) ----------
-- Если у пользователя РОВНО одна строка в org_members — её org_id, иначе
-- (ноль или несколько) — null; rollout_create различает случаи кодами
-- no_org / ambiguous_org. Ошибки не глотаются. Остальные функции организацию
-- пользователя НЕ угадывают: берут org из самого объекта (раскатка, аппарат)
-- и проверяют public.is_org_member(org).
create or replace function public.rollout_my_org() returns uuid
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_n   int;
  v_org uuid;
begin
  select count(*), (array_agg(org_id))[1] into v_n, v_org
    from public.org_members where user_id = auth.uid();
  if v_n = 1 then return v_org; end if;
  return null;
end;
$$;
revoke all on function public.rollout_my_org() from public, anon, authenticated;

-- ---------- Раскатки ----------
create table if not exists public.rollouts (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid        not null,
  release_id     uuid        not null references public.app_releases(id),
  ring           text        not null check (ring in ('test', 'early', 'all')),
  status         text        not null default 'paused'
                   check (status in ('paused', 'active', 'done', 'cancelled')),
  window_start   time        not null default '02:00',
  window_end     time        not null default '05:00',
  jitter_minutes int         not null default 30
                   check (jitter_minutes between 0 and 120),
  pause_reason   text,
  created_at     timestamptz not null default now(),
  created_by     uuid        default auth.uid(),
  updated_at     timestamptz not null default now(),
  -- Момент последнего перехода в 'active' (в том числе возобновления после
  -- паузы): автопауза считает ошибки установки только после него, чтобы
  -- старые ошибки не ставили возобновлённую раскатку на паузу снова.
  resumed_at     timestamptz
);

alter table public.rollouts add column if not exists resumed_at timestamptz;

-- Не более одной активной раскатки на пару (организация, кольцо).
create unique index if not exists rollouts_one_active_per_ring
  on public.rollouts (org_id, ring) where status = 'active';

alter table public.rollouts enable row level security;
revoke all on table public.rollouts from public, anon, authenticated;
grant select on table public.rollouts to authenticated;

-- Читать — участникам организации (is_org_member, как во всех политиках
-- проекта). Писать — только через функции ниже (insert/update/delete у
-- authenticated отозваны).
-- Индекс rollouts_one_active_per_ring (org_id, ring) where status='active'
-- обслуживает и запрос rollout_target (where org_id = … and ring = … and
-- status = 'active'): условие запроса совпадает с предикатом индекса, поэтому
-- планировщик берёт его (index scan по паре org+ring, строк активных единицы);
-- EXPLAIN без сервера не проверен.
create policy rollouts_read on public.rollouts
  for select to authenticated
  using (public.is_org_member(org_id));

-- ---------- Журнал раскаток (паузы и ручные действия) ----------
create table if not exists public.rollout_log (
  id         bigint generated always as identity primary key,
  org_id     uuid,                   -- для чтения по is_org_member
  rollout_id uuid        references public.rollouts(id) on delete cascade,
  at         timestamptz not null default now(),
  kind       text        not null,   -- created / status / paused_auto / trigger_error
  detail     jsonb       not null default '{}'::jsonb
);
alter table public.rollout_log enable row level security;
revoke all on table public.rollout_log from public, anon, authenticated;
grant select on table public.rollout_log to authenticated;
create policy rollout_log_read on public.rollout_log
  for select to authenticated
  using (org_id is not null and public.is_org_member(org_id));

-- ---------- Функции для панели ----------
-- Организация берётся из самого объекта и проверяется is_org_member;
-- «нет такого» и «чужое» отвечают одним кодом forbidden (не раскрываем,
-- существует ли чужая раскатка/аппарат).
create or replace function public.rollout_create(
  p_release uuid,
  p_ring    text,
  p_start   time default '02:00',
  p_end     time default '05:00',
  p_jitter  int  default 30
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.rollout_my_org();
  v_n   int;
  v_id  uuid;
begin
  if v_org is null then
    select count(*) into v_n from public.org_members where user_id = auth.uid();
    return jsonb_build_object('ok', false, 'error',
             case when v_n = 0 then 'no_org' else 'ambiguous_org' end);
  end if;
  if p_ring not in ('test', 'early', 'all')
     or p_jitter is null or p_jitter not between 0 and 120
     or p_start is null or p_end is null
     or p_start = p_end then          -- пустое окно: цель не выдавалась бы никому
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;
  if not exists (select 1 from public.app_releases where id = p_release) then
    return jsonb_build_object('ok', false, 'error', 'release_not_found');
  end if;

  insert into public.rollouts(org_id, release_id, ring, window_start, window_end, jitter_minutes)
  values (v_org, p_release, p_ring, p_start, p_end, p_jitter)
  returning id into v_id;

  insert into public.rollout_log(org_id, rollout_id, kind, detail)
  values (v_org, v_id, 'created', jsonb_build_object('by', auth.uid(), 'ring', p_ring));

  return jsonb_build_object('ok', true, 'id', v_id, 'status', 'paused');
end;
$$;

-- Переходы: paused<->active, любой (кроме cancelled)->cancelled,
-- active->done вручную. Активация отказывает, если в кольце уже есть
-- активная раскатка.
create or replace function public.rollout_set_status(p_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.rollouts%rowtype;
begin
  if p_status not in ('paused', 'active', 'done', 'cancelled') then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;

  select * into r from public.rollouts where id = p_id for update;
  if not found or not public.is_org_member(r.org_id) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  if not (
       (r.status = 'paused' and p_status = 'active')
    or (r.status = 'active' and p_status = 'paused')
    or (r.status in ('paused', 'active', 'done') and p_status = 'cancelled')
    or (r.status = 'active' and p_status = 'done')
  ) then
    return jsonb_build_object('ok', false, 'error', 'bad_transition',
                              'from', r.status, 'to', p_status);
  end if;

  if p_status = 'active' and exists (
       select 1 from public.rollouts
        where org_id = r.org_id and ring = r.ring and status = 'active' and id <> r.id) then
    return jsonb_build_object('ok', false, 'error', 'active_exists');
  end if;

  begin
    update public.rollouts
       set status       = p_status,
           pause_reason = case when p_status = 'active' then null else pause_reason end,
           resumed_at   = case when p_status = 'active' then now() else resumed_at end,
           updated_at   = now()
     where id = r.id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'active_exists');
  end;

  insert into public.rollout_log(org_id, rollout_id, kind, detail)
  values (r.org_id, r.id, 'status',
          jsonb_build_object('from', r.status, 'to', p_status, 'by', auth.uid()));
  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

create or replace function public.device_set_ring_tz(p_device text, p_ring text, p_tz text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
begin
  if p_ring not in ('test', 'early', 'all') then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;
  select org_id into v_org from public.devices where id = p_device;
  if v_org is null or not public.is_org_member(v_org) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  if not exists (select 1 from pg_timezone_names where name = p_tz) then
    return jsonb_build_object('ok', false, 'error', 'bad_timezone');
  end if;
  update public.devices set ring = p_ring, timezone = p_tz where id = p_device;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.rollout_create(uuid, text, time, time, int) from public, anon;
revoke all on function public.rollout_set_status(uuid, text) from public, anon;
revoke all on function public.device_set_ring_tz(text, text, text) from public, anon;
grant execute on function public.rollout_create(uuid, text, time, time, int) to authenticated;
grant execute on function public.rollout_set_status(uuid, text) to authenticated;
grant execute on function public.device_set_ring_tz(text, text, text) to authenticated;

-- ---------- Целевая версия для аппарата ----------
-- Внутренняя: вызывается только из device_poll (security definer). Отдаёт
-- цель, если ПОРА: время сервера в поясе аппарата внутри окна, сдвинутого
-- на детерминированную задержку 0..jitter минут от начала окна, и
-- установленная версия (код после '+' в devices.app_version; нет кода — 0)
-- ниже целевой. Ошибки НЕ глотаются (решение владельца: глотание только в
-- триггере автопаузы); неизвестный пояс обрабатывается явно (→ UTC).
create or replace function public.rollout_target(p_device text) returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  d        record;
  r        record;
  v_tz     text;
  v_local  time;
  v_m      int;
  v_ms     int;
  v_len    int;
  v_off    int;
  v_jit    int;
  v_inst   int := 0;
begin
  select id, org_id, ring, timezone, app_version into d
    from public.devices where id = p_device;
  if not found then return null; end if;

  select ro.id as rollout_id, ro.window_start, ro.window_end, ro.jitter_minutes,
         ar.id as release_id, ar.version_name, ar.version_code
    into r
    from public.rollouts ro
    join public.app_releases ar on ar.id = ro.release_id
   where ro.org_id = d.org_id and ro.ring = d.ring and ro.status = 'active'
   order by ar.version_code desc
   limit 1;
  if not found then return null; end if;

  -- установленный код: часть app_version после '+'
  if d.app_version ~ '\+[0-9]+$' then
    v_inst := substring(d.app_version from '\+([0-9]+)$')::int;
  end if;
  if v_inst >= r.version_code then return null; end if;

  -- пояс аппарата; неизвестный пояс → UTC
  -- (pg_timezone_names здесь не трогаем: это медленное представление, а
  -- пояс проверяется при записи в device_set_ring_tz. Ловим ТОЛЬКО ошибку
  -- неверного пояса.)
  v_tz := coalesce(d.timezone, 'UTC');
  begin
    v_local := (now() at time zone v_tz)::time;
  exception when invalid_parameter_value then
    v_tz := 'UTC';
    v_local := (now() at time zone 'UTC')::time;
  end;

  v_m   := extract(hour from v_local)::int * 60 + extract(minute from v_local)::int;
  v_ms  := extract(hour from r.window_start)::int * 60 + extract(minute from r.window_start)::int;
  v_len := ((extract(hour from r.window_end)::int * 60 + extract(minute from r.window_end)::int)
            - v_ms + 1440) % 1440;
  v_off := (v_m - v_ms + 1440) % 1440;           -- минут от начала окна (с переходом через полночь)
  v_jit := (abs(hashtext(p_device || r.rollout_id::text)::bigint)
            % (r.jitter_minutes + 1))::int;

  if v_off >= v_jit and v_off < v_len then
    return jsonb_build_object(
      'rollout_id',   r.rollout_id,
      'release_id',   r.release_id,
      'version_name', r.version_name,
      'version_code', r.version_code
    );
  end if;
  return null;
end;
$$;
-- Никому: вызывается только из device_poll (security definer).
revoke all on function public.rollout_target(text) from public, anon, authenticated;

-- ---------- device_poll: поле target ----------
-- Остальное — как в 20261003000000_r1_server_token_poll.sql (проверка
-- токена, expired, версия, слепок), без изменений.
create or replace function public.device_poll(
  p_device text,
  p_token text,
  p_version text default null::text,
  p_config jsonb default null::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org    uuid;
  v_cmds   jsonb;
  v_config jsonb;
  c_ttl    constant interval := interval '10 minutes';
begin
  select org_id, config into v_org, v_config
    from devices
   where id = p_device and token = p_token;

  if v_org is null then
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;

  update devices
     set last_seen_at    = now(),
         app_version     = coalesce(p_version, app_version),
         reported_config = coalesce(p_config, reported_config),
         reported_at     = case when p_config is null then reported_at else now() end
   where id = p_device;

  -- просроченные не выполняем никогда
  update commands
     set status      = 'expired',
         result      = 'expired_on_server',
         executed_at = now()
   where device_id = p_device
     and status = 'pending'
     and created_at < now() - c_ttl;

  select coalesce(
           jsonb_agg(jsonb_build_object(
             'id', id, 'action', action, 'params', params,
             'created_at', created_at
           ) order by created_at), '[]'::jsonb)
    into v_cmds
    from commands
   where device_id = p_device and status = 'pending';

  return jsonb_build_object(
    'ok',          true,
    'commands',    v_cmds,
    'config',      coalesce(v_config, 'null'::jsonb),
    'server_time', now(),
    'target',      public.rollout_target(p_device)   -- null, если цели нет
  );
end;
$function$;

-- ---------- Автопауза ----------
-- После каждой вставки в events. Время событий — ТОЛЬКО received_at
-- (серверное; ts идёт по часам аппарата и ненадёжен, столбца created_at в
-- events нет). Ошибки здесь глотаются (событие устройства важнее раскатки и
-- не должно пропасть), НО причина пишется в rollout_log (kind
-- 'trigger_error'), чтобы тихая поломка была видна.
create or replace function public.rollout_autopause() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dev    record;
  v_reason text;
  v_n      int;
  r        record;
begin
  if new.type not in ('update_rolled_back', 'update_failed') then
    return new;
  end if;

  select id, org_id, ring into v_dev from public.devices where id = new.device_id;
  if not found then return new; end if;

  if new.type = 'update_rolled_back' then
    if coalesce(new.data->>'automatic', '') <> 'true' then return new; end if;
    -- раскатки кольца этого аппарата, у которых версия релиза = to_version
    for r in
      select ro.id from public.rollouts ro
        join public.app_releases ar on ar.id = ro.release_id
       where ro.org_id = v_dev.org_id and ro.ring = v_dev.ring
         and ro.status = 'active' and ar.version_name = new.data->>'to_version'
    loop
      update public.rollouts
         set status = 'paused', pause_reason = 'auto_rollback:' || v_dev.id, updated_at = now()
       where id = r.id;
      insert into public.rollout_log(org_id, rollout_id, kind, detail)
      values (v_dev.org_id, r.id, 'paused_auto',
              jsonb_build_object('reason', 'auto_rollback', 'device', v_dev.id));
    end loop;
    return new;
  end if;

  -- update_failed: исключения (это не ошибки установки)
  v_reason := coalesce(new.data->>'reason', '');
  if v_reason = 'busy' or v_reason like 'busy:%'
     or v_reason = 'not_newer'
     or v_reason like 'rate_limited%'
     or v_reason like 'url_failed%'
     or v_reason = 'download_failed'
     or v_reason = 'no_space' then
    return new;
  end if;

  for r in
    select ro.id, coalesce(ro.resumed_at, ro.created_at) as since from public.rollouts ro
     where ro.org_id = v_dev.org_id and ro.ring = v_dev.ring and ro.status = 'active'
  loop
    select count(distinct e.device_id) into v_n
      from public.events e
      join public.devices d on d.id = e.device_id
     where e.type = 'update_failed'
       and e.received_at >= r.since   -- с последнего запуска/возобновления
       and d.org_id = v_dev.org_id and d.ring = v_dev.ring
       and coalesce(e.data->>'reason', '') not in
           ('busy', 'not_newer', 'download_failed', 'no_space')
       and coalesce(e.data->>'reason', '') not like 'busy:%'
       and coalesce(e.data->>'reason', '') not like 'rate_limited%'
       and coalesce(e.data->>'reason', '') not like 'url_failed%';
    if v_n >= 2 then
      update public.rollouts
         set status = 'paused', pause_reason = 'update_failed:' || v_n || ' devices',
             updated_at = now()
       where id = r.id;
      insert into public.rollout_log(org_id, rollout_id, kind, detail)
      values (v_dev.org_id, r.id, 'paused_auto',
              jsonb_build_object('reason', 'update_failed', 'devices', v_n));
    end if;
  end loop;
  return new;
exception when others then
  -- событие не теряем, но поломку оставляем следом
  begin
    insert into public.rollout_log(org_id, kind, detail)
    values (new.org_id, 'trigger_error',
            jsonb_build_object('error', sqlerrm, 'sqlstate', sqlstate,
                               'event_type', new.type, 'device', new.device_id));
  exception when others then
    null;
  end;
  return new;
end;
$$;
-- Триггерная функция вызывается только триггером: execute никому.
revoke all on function public.rollout_autopause() from public, anon, authenticated;

drop trigger if exists rollout_autopause_trg on public.events;
create trigger rollout_autopause_trg
  after insert on public.events
  for each row execute function public.rollout_autopause();

-- ---------- Ход раскатки ----------
-- security_invoker: строки видны по RLS devices и rollouts (организация).
-- Откаты и ошибки панель берёт из events.
create or replace view public.rollout_progress
with (security_invoker = true) as
select
  r.id                                  as rollout_id,
  r.status                              as rollout_status,
  d.id                                  as device_id,
  d.name                                as name,
  coalesce(
    nullif(substring(d.app_version from '\+([0-9]+)$'), '')::int, 0
  )                                     as installed_code,
  ar.version_code                       as target_code,
  case when coalesce(nullif(substring(d.app_version from '\+([0-9]+)$'), '')::int, 0)
            >= ar.version_code then 'updated' else 'waiting' end as state,
  d.last_seen_at                        as last_seen_at
from public.rollouts r
join public.app_releases ar on ar.id = r.release_id
join public.devices d on d.org_id = r.org_id and d.ring = r.ring;

revoke all on public.rollout_progress from public, anon;
grant select on public.rollout_progress to authenticated;
