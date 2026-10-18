-- Применено в боевой базе 2026-10-18 через MCP; файл фиксирует схему в репозитории.
-- ============================================================
-- Хеширование токенов аппаратов, фаза A.
--
-- devices.token_hash = sha256(token) в hex. Токен — 32 случайных байта
-- (256 бит), поэтому медленный хеш не нужен. Проверка токена во всех
-- device_* переводится на сравнение хеша; приложение шлёт токен как раньше.
-- Открытый токен обнуляется в фазе B (20261018000100_token_hash_phase_b.sql).
-- Права на device_* — в 20261018000200_function_grants_hardening.sql.
-- ============================================================

alter table public.devices add column if not exists token_hash text;
update public.devices
   set token_hash = encode(sha256(convert_to(token, 'UTF8')), 'hex')
 where token_hash is null and token is not null;
create unique index if not exists devices_token_hash_key on public.devices (token_hash);

-- ---------- device_token_valid (device_diag_put, device_release_get, release-url) ----------
create or replace function public.device_token_valid(p_device text, p_token text)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select exists (
    select 1 from devices
     where id = p_device
       and token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
  );
$function$;

-- ---------- device_report ----------
-- Тело снято с боевой базы (до этой миграции исходника в репозитории не было).
create or replace function public.device_report(p_device text, p_token text, p_events jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_org uuid;
begin
  select org_id into v_org
    from devices
   where id = p_device
     and token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');

  if v_org is null then
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;

  insert into events (device_id, org_id, type, ts, data)
  select p_device,
         v_org,
         e->>'type',
         coalesce((e->>'ts')::timestamptz, now()),
         coalesce(e->'data', '{}'::jsonb)
    from jsonb_array_elements(p_events) as e
   where e ? 'type';

  update devices set last_seen_at = now() where id = p_device;

  return jsonb_build_object('ok', true);
end;
$function$;

-- ---------- device_ack ----------
-- Тело снято с боевой базы (до этой миграции исходника в репозитории не было).
create or replace function public.device_ack(p_device text, p_token text, p_command uuid, p_ok boolean, p_result text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_org uuid;
begin
  select org_id into v_org
    from devices
   where id = p_device
     and token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');

  if v_org is null then
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;

  update commands
     set status      = case when p_ok then 'done' else 'failed' end,
         result      = p_result,
         executed_at = now()
   where id = p_command and device_id = p_device;

  return jsonb_build_object('ok', true);
end;
$function$;

-- ---------- device_poll ----------
-- Тело — из 20261006000000_r3_rollouts.sql (поле target); изменено ТОЛЬКО
-- условие проверки токена.
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
   where id = p_device and token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');

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
