-- ============================================================
-- R2: релизы приложения и доставка по подписанным ссылкам.
-- НЕ ПРИМЕНЕНО автоматически. Применять ПОСЛЕ
-- 20261003000000_r1_server_token_poll.sql (там device_token_valid).
-- Перед применением сверить политики на таблице devices — правила ниже
-- ссылаются на неё («владелец = тот, кто видит хотя бы одно устройство»).
-- ============================================================

-- ---------- Записи о релизах ----------
create table if not exists public.app_releases (
  id           uuid primary key default gen_random_uuid(),
  version_name text        not null,
  version_code int         not null unique,
  file_path    text        not null,
  sha256       text        not null check (sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes   bigint      not null check (size_bytes > 0),
  notes        text,
  created_at   timestamptz not null default now()
);

alter table public.app_releases enable row level security;
revoke all on table public.app_releases from public, anon;

-- Вошедший пользователь может ТОЛЬКО читать (по решению владельца
-- 04.10.2026). Политик insert/update/delete нет вовсе: запись о релизе
-- создаётся только под полными правами (SQL Editor в панели Supabase).
-- Подзапрос к devices выполняется ПОД ПРАВАМИ пользователя, то есть
-- возвращает строки, только если RLS devices пропускает этого пользователя.
-- anon прав не имеет вовсе. Права на запись отозваны и на уровне таблицы
-- (второй рубеж поверх RLS).
create policy app_releases_read on public.app_releases
  for select to authenticated
  using (exists (select 1 from public.devices));

revoke insert, update, delete, truncate on table public.app_releases from authenticated;

-- ---------- Запись о релизе для устройства ----------
-- Вызывается Edge Function release-url под сервисным ключом после
-- device_token_valid. Прямой вызов anon разрешён по заданию — токен
-- проверяется и здесь, внутри.
create or replace function public.device_release_get(
  p_device  text,
  p_token   text,
  p_release uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.app_releases%rowtype;
begin
  if not public.device_token_valid(p_device, p_token) then
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;

  select * into r from public.app_releases where id = p_release;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object(
    'ok',           true,
    'version_name', r.version_name,
    'version_code', r.version_code,
    'file_path',    r.file_path,
    'sha256',       r.sha256,
    'size_bytes',   r.size_bytes
  );
end;
$$;

grant execute on function public.device_release_get(text, text, uuid) to anon;

-- ---------- Ограничение частоты выдачи ссылок ----------
-- Одна строка на устройство: время последней выданной ссылки. Пишет только
-- Edge Function под сервисным ключом (он обходит RLS); политик нет, прав у
-- anon/authenticated нет.
create table if not exists public.release_url_requests (
  device_id text        primary key,
  last_at   timestamptz not null
);
alter table public.release_url_requests enable row level security;
revoke all on table public.release_url_requests from public, anon, authenticated;

-- ---------- Закрытый бакет releases ----------
-- public = false: файлы НЕ доступны по прямому адресу; скачивание — только по
-- подписанной ссылке на 10 минут от Edge Function.
insert into storage.buckets (id, name, public)
values ('releases', 'releases', false)
on conflict (id) do update set public = false;

-- Политик на storage.objects для бакета releases НЕТ намеренно (решение
-- владельца 04.10.2026): файлы читает только Edge Function по подписанной
-- ссылке (сервисный ключ обходит RLS), а загружает владелец через панель
-- Supabase. anon и authenticated не получают ничего.
