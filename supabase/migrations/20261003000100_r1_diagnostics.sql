-- ============================================================
-- R1: удалённая диагностика (пакеты диагностики по частям).
--
-- Применять ПОСЛЕ 20261003000000_r1_server_token_poll.sql: функция
-- device_token_valid (проверка токена устройства) определена там.
-- Исходников device_report/device_ack в репозитории нет — сверить с ними
-- проверку токена перед применением.
--
-- Выбор: таблица, а не Storage-бакет.
--  * та же схема доступа, что у остальных RPC (токен устройства),
--    без отдельных ключей и политик бакета;
--  * пакет режется на части по DiagnosticsLimits.chunkChars (128 КБ
--    символов) — лимит тела RPC проекта не проверялся, часть заведомо
--    ниже типичных ограничений PostgREST;
--  * при росте объёма можно перейти на Storage, не меняя приложение:
--    достаточно заменить тело device_diag_put.
-- ============================================================

create table if not exists public.device_diagnostics (
  device_id  text        not null,
  bundle_id  text        not null,
  part       int         not null,
  parts      int         not null,
  data       text        not null,
  created_at timestamptz not null default now(),
  primary key (device_id, bundle_id, part)
);

create index if not exists device_diagnostics_created_idx
  on public.device_diagnostics (created_at);

-- Политик нет сознательно: прямой доступ закрыт, запись — только через
-- security definer RPC ниже, чтение — только владельцем проекта (service
-- role / SQL Editor). Двойная защита: RLS включён, а права на таблицу у
-- anon/authenticated отозваны явно (в Supabase по умолчанию они выданы
-- на все таблицы схемы public — без revoke защита держалась бы на одном
-- RLS).
alter table public.device_diagnostics enable row level security;
revoke all on table public.device_diagnostics from public, anon, authenticated;

-- Приём одной части пакета. Проверка токена — public.device_token_valid
-- (определена в 20261003000000_r1_server_token_poll.sql, закрыта от прямого
-- вызова снаружи).
create or replace function public.device_diag_put(
  p_device text,
  p_token  text,
  p_bundle text,
  p_part   int,
  p_parts  int,
  p_data   text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.device_token_valid(p_device, p_token) then
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;

  -- Лимиты формы (подтверждены приложением: 128 КБ на часть). Запас х2.
  if p_part < 1 or p_parts < 1 or p_part > p_parts or p_parts > 100
     or p_data is null or length(p_data) > 262144
     or p_bundle is null or length(p_bundle) > 64 then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;

  -- Срок хранения без внешнего планировщика: старое чистится при приёме
  -- первой части каждого нового пакета (по индексу created_at это дёшево).
  if p_part = 1 then
    perform public.device_diag_purge();
  end if;

  insert into public.device_diagnostics
    (device_id, bundle_id, part, parts, data)
  values
    (p_device, p_bundle, p_part, p_parts, p_data)
  on conflict (device_id, bundle_id, part)
  do update set data = excluded.data, parts = excluded.parts,
                created_at = now();

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.device_diag_put(text, text, text, int, int, text)
  to anon;

-- Срок хранения: 14 дней (DiagnosticsLimits.serverRetention, НЕ ИЗМЕРЕНО —
-- решает владелец). Запускать по расписанию (pg_cron):
--   select cron.schedule('device-diag-purge', '17 3 * * *',
--                        $$select public.device_diag_purge()$$);
create or replace function public.device_diag_purge() returns void
language sql
security definer
set search_path = public
as $$
  delete from public.device_diagnostics
  where created_at < now() - interval '14 days';
$$;

-- Только владелец (и device_diag_put как security definer): снаружи очистку
-- вызывать нельзя.
revoke all on function public.device_diag_purge() from public, anon, authenticated;

-- Сборка пакета из частей (для просмотра владельцем):
--   select string_agg(data, '' order by part)
--   from public.device_diagnostics
--   where device_id = '...' and bundle_id = '...';

-- device_poll (created_at и срок жизни команд на сервере) — в
-- 20261003000000_r1_server_token_poll.sql. Новые действия белого списка
-- приложения: collect_diagnostics, restart_app.
