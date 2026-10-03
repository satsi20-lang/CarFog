-- ============================================================
-- CaRFog: серверная часть этапа R1. Выполнять в Supabase -> SQL Editor.
-- Порядок: 0 (только чтение) -> 1 -> 2. Каждый блок можно запускать отдельно.
-- Затем применять 20261003000100_r1_diagnostics.sql (использует
-- device_token_valid из блока 1).
-- (Текст блоков 1 и 2 — от владельца проекта, перенесён без изменений.)
-- ============================================================

-- ---------- 0. ПРОВЕРКА ПЕРЕД ИЗМЕНЕНИЯМИ (только чтение) ----------
-- Колонки таблицы commands (нужно подтвердить created_at и status):
--   select column_name, data_type from information_schema.columns
--    where table_schema='public' and table_name='commands' order by ordinal_position;
-- Сколько команд сейчас висит в статусе pending (их заберёт чистка из п.2):
--   select id, device_id, action, status, created_at from commands
--    where status='pending' order by created_at;
-- Включена ли защита строк (RLS) на таблицах:
--   select relname, relrowsecurity from pg_class
--    where relname in ('devices','commands','events');
-- ПЕРЕД п.2 дополнительно проверить (приложение этого не видит):
--  * допускает ли CHECK-ограничение / enum столбца commands.status значение
--    'expired' (иначе update из device_poll упадёт и сломает весь опрос);
--  * существует ли столбец commands.executed_at.

-- ---------- 1. ПРОВЕРКА ТОКЕНА УСТРОЙСТВА ----------
-- Та же проверка, что уже стоит внутри device_poll/device_report/device_ack
-- (devices.id + devices.token), вынесенная в функцию, которую вызывает
-- device_diag_put из миграции R1. Закрыта от прямого вызова снаружи:
-- иначе её можно было бы использовать для подбора токена.
create or replace function public.device_token_valid(p_device text, p_token text)
returns boolean
language sql
security definer
stable
set search_path to 'public'
as $$
  select exists (
    select 1 from devices where id = p_device and token = p_token
  );
$$;

revoke all on function public.device_token_valid(text, text) from public, anon, authenticated;

-- ---------- 2. device_poll: created_at и срок жизни команд ----------
-- Что меняется относительно текущей версии:
--  * каждая команда отдаётся вместе с created_at;
--  * команды старше 10 минут НЕ отдаются и помечаются status='expired'
--    (сервер — единственные надёжные часы: у планшета время может уйти);
--  * в ответе по-прежнему есть server_time — приложение сравнивает
--    server_time и created_at, а НЕ своё время.
-- Остальное (учёт last_seen_at, reported_config, config) без изменений.
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
    'server_time', now()
  );
end;
$function$;
