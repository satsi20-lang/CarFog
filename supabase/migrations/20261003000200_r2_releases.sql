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

-- Читать и писать может только вошедший владелец. Правило то же, что на
-- devices: подзапрос к devices выполняется ПОД ПРАВАМИ пользователя, то есть
-- возвращает строки, только если RLS devices пропускает этого пользователя.
-- anon прав не имеет вовсе.
create policy app_releases_owner_all on public.app_releases
  for all to authenticated
  using (exists (select 1 from public.devices))
  with check (exists (select 1 from public.devices));

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

-- Владелец может загружать и просматривать файлы релизов (например, из
-- панели Supabase). anon не получает ничего.
create policy releases_owner_read on storage.objects
  for select to authenticated
  using (bucket_id = 'releases' and exists (select 1 from public.devices));

create policy releases_owner_write on storage.objects
  for insert to authenticated
  with check (bucket_id = 'releases' and exists (select 1 from public.devices));

create policy releases_owner_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'releases' and exists (select 1 from public.devices));
