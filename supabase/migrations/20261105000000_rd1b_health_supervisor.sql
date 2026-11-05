-- ============================================================
-- RD1b: светофор (customer_device_health) — также для супервайзера с 2FA.
--
-- Применено в рабочей базе 2026-11-05: светофор доступен также
-- супервайзеру с 2FA.
--
-- Файл положен в репозиторий для истории; повторно применять не нужно
-- (CREATE OR REPLACE — повторное применение безвредно).
--
-- Отличие от 20261104000000_rd1_remote_diag.sql — только проверка
-- доступа: клиент с доступом к аппарату ИЛИ супервайзер, для которого
-- _diag_supervisor_denied() is null (is_portal_supervisor() и aal2).
-- Супервайзер без 2FA и все прочие получают no_access; anon не вызывает
-- функцию вовсе (права ниже, как в RD1).
-- Тело светофора не менялось.
-- ============================================================

CREATE OR REPLACE FUNCTION public.customer_device_health(p_device text) returns jsonb
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
  if auth.uid() is null
     or not (public.customer_has_access(p_device) or public._diag_supervisor_denied() is null) then
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

  -- health.thermo / meter: off | ok | stale (давно нет годного показания).
  v_sens := case
    when h is null then 'grey'
    when (h ->> 'thermo') = 'stale' or (h ->> 'meter') = 'stale' then 'yellow'
    when jsonb_array_length(coalesce(c -> 'payment_blocked_by_config', '[]'::jsonb)) > 0
      then 'yellow'
    else 'green' end;

  -- health.terminal: off | ok | down | unknown (импульсный: связь не
  -- проверяется).
  v_term := case
    when h is null or h ->> 'terminal' is null then 'grey'
    when h ->> 'terminal' in ('off', 'unknown') then 'grey'
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

revoke all on function public.customer_device_health(text) from public, anon;
grant execute on function public.customer_device_health(text) to authenticated;
