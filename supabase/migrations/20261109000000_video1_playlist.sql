-- ============================================================
-- VIDEO1: видео заставки через портал (плейлист с галочками) — база.
-- ТЗ docs/video_playlist_tz.md, раздел 3.
--
-- НЕ ПРИМЕНЕНО. SQL выполняет ассистент после отдельного «да» владельца.
-- Порядок применения, развёртывания и откат — docs/video_playlist.md.
--
-- Применять ПОСЛЕ: R1 (device_token_valid), R3 (rollout_target),
-- R4 (devices.org_id, staff_audit_add, customer_has_access),
-- 20261018000000_token_hash_phase_a, RD1 (_diag_supervisor_denied),
-- BRAND1 (20261106000000: device_poll с полем brand, _brand_for_device).
--
-- Что здесь:
--  1. Закрытый бакет Storage device-videos (public=false, только video/mp4).
--     Политик на storage.objects НЕТ ВОВСЕ — как у brand-packs: писать и
--     читать файлы может только сервисный ключ (Edge Functions).
--  2. Таблица device_videos, devices.videos_rev, служебные таблицы лимитов.
--  3. Функции портала (клиент своих аппаратов / супервайзер с 2FA).
--  4. Служебные функции для Edge Functions (только service_role).
--  5. Функции аппарата: device_videos_get, device_video_report,
--     device_video_path (для video-url).
--  6. device_poll: добавлено ТОЛЬКО поле videos_rev.
--
-- Журнал действий (решение исполнителя). Пишем в ту же staff_audit, что и
-- супервайзерские действия, а не в отдельную таблицу: один журнал проще
-- смотреть и чистить. Действие называется по роли —
-- 'supervisor_video_*' или 'customer_video_*', в details лежит 'role',
-- video_id, название и размер. Читает журнал только персонал организации
-- (политика staff_audit_read); клиент свой журнал не видит, но запись о его
-- действии остаётся (кто — actor = auth.uid(), когда — at, какой файл —
-- details).
--
-- Удаление файлов из бакета делает Edge Function video-purge раз в сутки
-- (20261109000100_video1_cron.sql), а не база: удалять строки из
-- storage.objects напрямую нельзя (файл остался бы в хранилище).
-- Пока строка в статусе deleted, ссылки на файл никому не выдаются.
-- ============================================================

-- ---------- 1. Закрытый бакет ----------
-- file_size_limit = null: действует глобальный предел проекта (Storage →
-- Settings). Если файл больше, Storage ответит 413, и портал покажет понятное
-- сообщение.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('device-videos', 'device-videos', false, null, array['video/mp4'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------- 2. Таблицы ----------

alter table public.devices
  add column if not exists videos_rev int not null default 0;
comment on column public.devices.videos_rev is
  'Растёт при любом изменении желаемого набора видео (галочки, новое видео, удаление). Аппарат видит его в device_poll.';

create table if not exists public.device_videos (
  id               uuid        primary key default gen_random_uuid(),
  device_id        text        not null references public.devices(id),
  org_id           uuid,
  title            text        not null check (length(btrim(title)) between 1 and 120),
  source           text        not null check (source in ('upload', 'sd_local')),
  storage_path     text,                       -- null для sd_local
  local_name       text        check (local_name is null or length(local_name) between 1 and 255),
  sha256           text        check (sha256 is null or sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes       bigint      check (size_bytes is null or size_bytes >= 0),
  width            int         check (width is null or width between 1 and 16384),
  height           int         check (height is null or height between 1 and 16384),
  duration_ms      bigint      check (duration_ms is null or duration_ms >= 0),
  has_audio        boolean,
  status           text        not null default 'pending_upload'
                     check (status in ('pending_upload', 'validating', 'rejected',
                                       'ready', 'on_device', 'failed',
                                       'delete_requested', 'deleted')),
  reject_reason    text        check (reject_reason is null or length(reject_reason) <= 200),
  play             boolean     not null default false,
  device_state     text        check (device_state is null or device_state ~
                                 '^(downloading|present|missing|failed:[A-Za-z0-9_ .-]{1,60})$'),
  local_deletable  boolean,                    -- только sd_local: можно ли удалить с карты
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  object_removed_at timestamptz,               -- когда video-purge убрал файл из бакета
  constraint device_videos_upload_shape check (
    source <> 'upload' or (storage_path is not null and sha256 is not null
                           and size_bytes is not null)),
  constraint device_videos_local_shape check (
    source <> 'sd_local' or (storage_path is null and local_name is not null))
);

create index if not exists device_videos_device_idx
  on public.device_videos (device_id, created_at);
-- Одно имя файла на карте — одна строка sd_local (повторы не плодим).
create unique index if not exists device_videos_local_name_key
  on public.device_videos (device_id, local_name)
  where source = 'sd_local' and status <> 'deleted';

alter table public.device_videos enable row level security;
revoke all on table public.device_videos from public, anon, authenticated;

-- Лимиты частоты (по образцу brand_url_requests).
create table if not exists public.video_get_requests (
  device_id text primary key,
  last_at   timestamptz not null
);
create table if not exists public.video_url_requests (
  video_id uuid primary key,
  last_at  timestamptz not null
);
alter table public.video_get_requests enable row level security;
alter table public.video_url_requests enable row level security;
revoke all on table public.video_get_requests from public, anon, authenticated;
revoke all on table public.video_url_requests from public, anon, authenticated;

-- ---------- 3. Помощники (не вызываются снаружи) ----------

-- Кто вызывает: 'supervisor' (с 2FA), 'customer' (активный доступ к
-- аппарату) или null. Супервайзер-владелец аппарата как клиент тоже
-- считается супервайзером.
create or replace function public._video_role(p_device text) returns text
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if public._diag_supervisor_denied() is null then
    return 'supervisor';
  end if;
  if public.customer_has_access(p_device) then
    return 'customer';
  end if;
  return null;
end;
$$;

-- Код отказа для вызывающего: 'mfa_required' (супервайзер без 2FA),
-- иначе 'forbidden'.
create or replace function public._video_denied() returns text
language sql
security definer
stable
set search_path = public
as $$
  select case when public._diag_supervisor_denied() = 'mfa_required'
              then 'mfa_required' else 'forbidden' end;
$$;

create or replace function public._video_bump(p_device text) returns void
language sql
security definer
set search_path = public
as $$
  update public.devices set videos_rev = videos_rev + 1 where id = p_device;
$$;

create or replace function public._video_audit(
  p_role text, p_action text, p_video public.device_videos, p_actor uuid default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_details jsonb := jsonb_build_object(
    'role', p_role, 'video_id', p_video.id, 'title', p_video.title,
    'size_bytes', p_video.size_bytes, 'source', p_video.source);
begin
  if p_actor is null then
    perform public.staff_audit_add(p_video.org_id, p_role || '_video_' || p_action,
                                   p_video.device_id, v_details);
  else
    -- Вызов из Edge Function под сервисным ключом: auth.uid() пуст,
    -- поэтому актор передан явно (как в _brand_version_register).
    insert into public.staff_audit (org_id, actor, action, device_id, details)
    values (p_video.org_id, p_actor, p_role || '_video_' || p_action,
            p_video.device_id, v_details);
  end if;
end;
$$;

revoke all on function public._video_role(text) from public, anon, authenticated;
revoke all on function public._video_denied() from public, anon, authenticated;
revoke all on function public._video_bump(text) from public, anon, authenticated;
revoke all on function public._video_audit(text, text, public.device_videos, uuid)
  from public, anon, authenticated;

-- ---------- 4. Функции портала ----------

-- Список для портала. Путь в бакете не отдаётся.
create or replace function public.video_list(p_device text) returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_role text;
  v_rev  int;
  v_prof text;
begin
  select videos_rev, hardware_profile into v_rev, v_prof
    from public.devices where id = p_device;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_device');
  end if;
  v_role := public._video_role(p_device);
  if v_role is null then
    return jsonb_build_object('ok', false, 'error', public._video_denied());
  end if;
  return jsonb_build_object('ok', true, 'role', v_role,
    'hardware_profile', v_prof, 'videos_rev', v_rev,
    'videos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', v.id, 'title', v.title, 'source', v.source,
               'local_name', v.local_name,
               'size_bytes', v.size_bytes, 'width', v.width, 'height', v.height,
               'duration_ms', v.duration_ms, 'has_audio', v.has_audio,
               'status', v.status, 'reject_reason', v.reject_reason,
               'play', v.play, 'device_state', v.device_state,
               'deletable', case when v.source = 'sd_local'
                                 then coalesce(v.local_deletable, false) else true end,
               'created_at', v.created_at) order by v.created_at, v.id)
        from public.device_videos v
       where v.device_id = p_device
         and v.status <> 'deleted'
         -- Неудавшиеся загрузки показываем неделю, потом скрываем.
         and (v.status not in ('rejected', 'failed', 'pending_upload')
              or v.created_at > now() - interval '7 days')), '[]'::jsonb));
end;
$$;

-- Начало загрузки: создаёт строку pending_upload. Ссылку на загрузку выдаёт
-- Edge Function video-upload-url.
create or replace function public.video_upload_begin(
  p_device text,
  p_title  text,
  p_size   bigint,
  p_sha256 text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role  text;
  v_org   uuid;
  v_title text := btrim(coalesce(p_title, ''));
  v_row   public.device_videos;
begin
  select org_id into v_org from public.devices where id = p_device;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_device');
  end if;
  v_role := public._video_role(p_device);
  if v_role is null then
    return jsonb_build_object('ok', false, 'error', public._video_denied());
  end if;
  if length(v_title) < 1 or length(v_title) > 120
     or p_size is null or p_size < 1
     or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;

  -- Брошенные загрузки старше суток освобождают место в лимите.
  update public.device_videos
     set status = 'deleted', updated_at = now()
   where device_id = p_device and source = 'upload'
     and status in ('pending_upload', 'validating')
     and created_at < now() - interval '1 day';

  if (select count(*) from public.device_videos
       where device_id = p_device and status in ('pending_upload', 'validating')) >= 5 then
    return jsonb_build_object('ok', false, 'error', 'too_many_pending');
  end if;
  -- Предел числа видео на аппарат (не размера): защита от засорения списка.
  if (select count(*) from public.device_videos
       where device_id = p_device
         and status in ('pending_upload', 'validating', 'ready', 'on_device',
                        'delete_requested')) >= 100 then
    return jsonb_build_object('ok', false, 'error', 'too_many_videos');
  end if;

  insert into public.device_videos
    (device_id, org_id, title, source, sha256, size_bytes, status, created_by)
  values (p_device, v_org, v_title, 'upload', p_sha256, p_size,
          'pending_upload', auth.uid())
  returning * into v_row;
  update public.device_videos
     set storage_path = p_device || '/' || v_row.id || '.mp4'
   where id = v_row.id
  returning * into v_row;

  perform public._video_audit(v_role, 'upload_begin', v_row);
  return jsonb_build_object('ok', true, 'video_id', v_row.id);
end;
$$;

-- Галочка «Проигрывать».
create or replace function public.video_set_play(
  p_video uuid,
  p_play  boolean
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v    public.device_videos;
  v_role text;
begin
  select * into v from public.device_videos where id = p_video;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  v_role := public._video_role(v.device_id);
  if v_role is null then
    return jsonb_build_object('ok', false, 'error', public._video_denied());
  end if;
  if p_play is null then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;
  -- Отмечать можно только то, что аппарат может проиграть.
  if v.status not in ('ready', 'on_device') then
    return jsonb_build_object('ok', false, 'error', 'bad_status');
  end if;

  if v.play is distinct from p_play then
    update public.device_videos set play = p_play, updated_at = now()
     where id = p_video returning * into v;
    perform public._video_bump(v.device_id);
    perform public._video_audit(v_role, case when p_play then 'play_on' else 'play_off' end, v);
  end if;
  return jsonb_build_object('ok', true, 'play', v.play);
end;
$$;

-- Удаление. Если файл мог попасть на аппарат — статус delete_requested,
-- аппарат удалит файл и сообщит; иначе сразу deleted (файл из бакета уберёт
-- video-purge).
create or replace function public.video_delete(p_video uuid) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v      public.device_videos;
  v_role text;
  v_on_device boolean;
begin
  select * into v from public.device_videos where id = p_video;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  v_role := public._video_role(v.device_id);
  if v_role is null then
    return jsonb_build_object('ok', false, 'error', public._video_denied());
  end if;
  if v.status in ('deleted', 'delete_requested') then
    return jsonb_build_object('ok', true, 'status', v.status);
  end if;

  -- Мог ли файл быть на карте: аппарат сообщил наличие/скачивание, либо это
  -- файл с карты, который там ещё есть.
  v_on_device := coalesce(v.device_state, '') in ('present', 'downloading')
              or (v.source = 'sd_local' and coalesce(v.device_state, '') <> 'missing');

  if v.source = 'sd_local' and v_on_device and not coalesce(v.local_deletable, false) then
    -- Android не даёт приложению удалить этот файл. Галочку снять можно,
    -- удалить нельзя.
    return jsonb_build_object('ok', false, 'error', 'not_deletable');
  end if;

  update public.device_videos
     set status = case when v_on_device then 'delete_requested' else 'deleted' end,
         play = false,
         updated_at = now()
   where id = p_video
  returning * into v;
  -- Желаемое состояние изменилось (файл мог быть у аппарата, галочка снята).
  perform public._video_bump(v.device_id);
  perform public._video_audit(v_role, 'delete', v);
  return jsonb_build_object('ok', true, 'status', v.status);
end;
$$;

-- ---------- 5. Для Edge Functions под JWT вызывающего ----------

-- «Можно ли этому пользователю работать с этим видео» + данные для проверки
-- файла. Вызывается из video-upload-url и video-validate ПОД JWT ВЫЗЫВАЮЩЕГО.
create or replace function public.video_access_check(p_video uuid) returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v      public.device_videos;
  v_role text;
  v_prof text;
begin
  select * into v from public.device_videos where id = p_video;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  v_role := public._video_role(v.device_id);
  if v_role is null then
    return jsonb_build_object('ok', false, 'error', public._video_denied());
  end if;
  if v.source <> 'upload' then
    return jsonb_build_object('ok', false, 'error', 'bad_status');
  end if;
  select hardware_profile into v_prof from public.devices where id = v.device_id;
  return jsonb_build_object('ok', true, 'actor', auth.uid(), 'role', v_role,
    'video_id', v.id, 'device_id', v.device_id, 'status', v.status,
    'size_bytes', v.size_bytes, 'hardware_profile', v_prof);
end;
$$;

-- ---------- 6. Только сервисный ключ (Edge Functions) ----------

-- Начало проверки: pending_upload → validating. Повтор проверки уже
-- начатой допустим (браузер мог оборваться).
create or replace function public._video_mark_validating(p_video uuid) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v public.device_videos;
begin
  update public.device_videos
     set status = 'validating', updated_at = now()
   where id = p_video and source = 'upload'
     and status in ('pending_upload', 'validating')
  returning * into v;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'bad_status');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public._video_mark_validated(
  p_video       uuid,
  p_actor       uuid,
  p_role        text,
  p_width       int,
  p_height      int,
  p_duration_ms bigint,
  p_has_audio   boolean
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v public.device_videos;
begin
  if p_role not in ('customer', 'supervisor') or p_actor is null then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;
  update public.device_videos
     set status = 'ready', width = p_width, height = p_height,
         duration_ms = p_duration_ms, has_audio = p_has_audio,
         reject_reason = null, updated_at = now()
   where id = p_video and source = 'upload'
     and status in ('pending_upload', 'validating')
  returning * into v;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'bad_status');
  end if;
  perform public._video_bump(v.device_id);
  perform public._video_audit(p_role, 'validated', v, p_actor);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public._video_mark_rejected(
  p_video  uuid,
  p_actor  uuid,
  p_role   text,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v public.device_videos;
begin
  if p_role not in ('customer', 'supervisor') or p_actor is null then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;
  update public.device_videos
     set status = 'rejected', reject_reason = left(coalesce(p_reason, 'unknown'), 200),
         updated_at = now()
   where id = p_video and source = 'upload'
     and status in ('pending_upload', 'validating')
  returning * into v;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'bad_status');
  end if;
  perform public._video_audit(p_role, 'rejected', v, p_actor);
  return jsonb_build_object('ok', true);
end;
$$;

-- Валидация не смогла завершиться по нашей вине (хранилище недоступно) —
-- помечаем failed, а не rejected: файл не виноват.
create or replace function public._video_mark_failed(p_video uuid, p_reason text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.device_videos
     set status = 'failed', reject_reason = left(coalesce(p_reason, 'internal'), 200),
         updated_at = now()
   where id = p_video and source = 'upload'
     and status in ('pending_upload', 'validating');
  return jsonb_build_object('ok', true);
end;
$$;

-- Что убрать из бакета: удалённые, отклонённые и брошенные загрузки.
-- Заодно закрывает зависшие запросы удаления (аппарат так и не ответил за
-- 30 дней — списан) и стирает старые записи без файлов.
create or replace function public._video_purge_pick(p_limit int default 200) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.device_videos
     set status = 'deleted', updated_at = now()
   where status in ('pending_upload', 'validating') and source = 'upload'
     and created_at < now() - interval '2 days';
  update public.device_videos
     set status = 'deleted', updated_at = now()
   where status = 'delete_requested' and updated_at < now() - interval '30 days';

  delete from public.device_videos
   where status = 'deleted' and updated_at < now() - interval '90 days'
     and (storage_path is null or object_removed_at is not null);

  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'path', x.storage_path))
      from (select id, storage_path from public.device_videos
             where storage_path is not null and object_removed_at is null
               and status in ('deleted', 'rejected', 'failed')
             order by updated_at limit greatest(1, least(coalesce(p_limit, 200), 500))) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public._video_purge_done(p_ids uuid[]) returns void
language sql
security definer
set search_path = public
as $$
  update public.device_videos set object_removed_at = now()
   where id = any(coalesce(p_ids, '{}'::uuid[])) and object_removed_at is null;
$$;

-- Для video-url: проверяет токен аппарата и что видео его и годное,
-- отдаёт путь в бакете. Лимит частоты — не чаще раза в 10 с на видео.
create or replace function public.device_video_path(
  p_device text,
  p_token  text,
  p_video  uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v public.device_videos;
begin
  if not public.device_token_valid(p_device, p_token) then
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;
  select * into v from public.device_videos
   where id = p_video and device_id = p_device and source = 'upload'
     and status in ('ready', 'on_device');
  if not found or v.storage_path is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if exists (select 1 from public.video_url_requests
              where video_id = p_video
                and last_at > now() - interval '10 seconds'
                and last_at <= now()) then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  insert into public.video_url_requests (video_id, last_at) values (p_video, now())
  on conflict (video_id) do update set last_at = now();
  return jsonb_build_object('ok', true, 'path', v.storage_path,
    'sha256', v.sha256, 'size_bytes', v.size_bytes);
end;
$$;

-- ---------- 7. Для аппарата ----------

-- Желаемое состояние. Лимит — не чаще раза в 30 с на аппарат (после
-- изменения videos_rev аппарат повторит запрос позже).
create or replace function public.device_videos_get(
  p_device text,
  p_token  text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_rev int;
begin
  if not public.device_token_valid(p_device, p_token) then
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;
  if exists (select 1 from public.video_get_requests
              where device_id = p_device
                and last_at > now() - interval '30 seconds'
                and last_at <= now()) then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  insert into public.video_get_requests (device_id, last_at) values (p_device, now())
  on conflict (device_id) do update set last_at = now();

  select videos_rev into v_rev from public.devices where id = p_device;
  return jsonb_build_object('ok', true, 'videos_rev', v_rev,
    'videos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', v.id, 'title', v.title, 'source', v.source,
               'local_name', v.local_name, 'sha256', v.sha256,
               'size_bytes', v.size_bytes, 'play', v.play,
               'delete', v.status = 'delete_requested',
               'created_at', v.created_at) order by v.created_at, v.id)
        from public.device_videos v
       where v.device_id = p_device
         and ((v.source = 'upload' and v.status in ('ready', 'on_device', 'delete_requested'))
           or (v.source = 'sd_local' and v.status in ('on_device', 'delete_requested')))
    ), '[]'::jsonb));
end;
$$;

-- Отчёт аппарата — ПОЛНЫЙ снимок. Элементы:
--   {"kind":"upload","id":"<uuid>","state":"downloading|present|failed:<причина>|missing"}
--   {"kind":"local","local_name":"a.mp4","size_bytes":N,"width":W,"height":H,
--    "duration_ms":D,"deletable":true,"mtime_ms":T}
-- Что было в базе, а в отчёте нет, считается пропавшим (missing); запросы
-- удаления при этом закрываются (deleted). Новые файлы с карты получают
-- строку sd_local с play = true, чтобы после обновления заставка, как и
-- раньше, играла все файлы с карты (решение исполнителя, см. опись).
create or replace function public.device_video_report(
  p_device text,
  p_token  text,
  p_items  jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_state constant text :=
    '^(downloading|present|missing|failed:[A-Za-z0-9_ .-]{1,60})$';
  v_org    uuid;
  v_item   jsonb;
  v_kind   text;
  v_id     uuid;
  v_state  text;
  v_name   text;
  v_size   bigint;
  v_w      int;
  v_h      int;
  v_dur    bigint;
  v_mtime  timestamptz;
  v_ids    uuid[] := '{}';
  v_names  text[] := '{}';
  v_locals int;
  v_new    boolean := false;
  v_rev    int;
begin
  if not public.device_token_valid(p_device, p_token) then
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;
  if jsonb_array_length(p_items) > 200 then
    return jsonb_build_object('ok', false, 'error', 'too_many');
  end if;
  select org_id into v_org from public.devices where id = p_device;

  select count(*) into v_locals from public.device_videos
   where device_id = p_device and source = 'sd_local' and status <> 'deleted';

  for v_item in select value from jsonb_array_elements(p_items) loop
    if jsonb_typeof(v_item) <> 'object' then continue; end if;
    v_kind := v_item ->> 'kind';

    if v_kind = 'upload' then
      begin
        v_id := (v_item ->> 'id')::uuid;
      exception when others then
        continue;
      end;
      v_state := v_item ->> 'state';
      if v_state is null or v_state !~ c_state then continue; end if;
      v_ids := v_ids || v_id;
      update public.device_videos
         set device_state = v_state,
             status = case
                        when v_state = 'present' and status = 'ready' then 'on_device'
                        when v_state = 'missing' and status = 'on_device' then 'ready'
                        when v_state = 'missing' and status = 'delete_requested' then 'deleted'
                        else status end,
             updated_at = now()
       where id = v_id and device_id = p_device and source = 'upload'
         and status in ('ready', 'on_device', 'delete_requested');

    elsif v_kind = 'local' then
      v_name := v_item ->> 'local_name';
      if v_name is null or length(v_name) not between 1 and 255
         or position('/' in v_name) > 0 then
        continue;
      end if;
      begin
        v_size := greatest(0, (v_item ->> 'size_bytes')::bigint);
        v_w    := nullif((v_item ->> 'width')::int, 0);
        v_h    := nullif((v_item ->> 'height')::int, 0);
        v_dur  := greatest(0, (v_item ->> 'duration_ms')::bigint);
        v_mtime := least(now(), coalesce(
          to_timestamp(((v_item ->> 'mtime_ms')::bigint) / 1000.0), now()));
      exception when others then
        -- Битое число в одном элементе не должно ронять весь отчёт.
        v_size := null; v_w := null; v_h := null; v_dur := null; v_mtime := now();
      end;
      if v_w is not null and v_w not between 1 and 16384 then v_w := null; end if;
      if v_h is not null and v_h not between 1 and 16384 then v_h := null; end if;
      v_names := v_names || v_name;

      update public.device_videos
         set size_bytes = v_size, width = v_w, height = v_h, duration_ms = v_dur,
             local_deletable = coalesce((v_item ->> 'deletable')::boolean, false),
             device_state = 'present', updated_at = now()
       where device_id = p_device and source = 'sd_local' and local_name = v_name
         and status in ('on_device', 'delete_requested');
      if not found and v_locals < 200 then
        begin
          insert into public.device_videos
            (device_id, org_id, title, source, local_name, size_bytes, width,
             height, duration_ms, status, play, device_state, local_deletable,
             created_at)
          values (p_device, v_org,
                  left(regexp_replace(v_name, '\.[^.]*$', ''), 120),
                  'sd_local', v_name, v_size, v_w, v_h, v_dur, 'on_device', true,
                  'present', coalesce((v_item ->> 'deletable')::boolean, false),
                  v_mtime);
          v_locals := v_locals + 1;
          v_new := true;
        exception when unique_violation or check_violation then
          null;
        end;
      end if;
    end if;
  end loop;

  -- Чего нет в снимке — того нет на карте.
  update public.device_videos
     set device_state = 'missing',
         status = case status when 'delete_requested' then 'deleted'
                              when 'on_device' then 'ready' else status end,
         updated_at = now()
   where device_id = p_device and source = 'upload'
     and status in ('on_device', 'delete_requested')
     and not (id = any(v_ids));
  update public.device_videos
     set device_state = 'missing',
         status = case status when 'delete_requested' then 'deleted' else status end,
         updated_at = now()
   where device_id = p_device and source = 'sd_local'
     and status in ('on_device', 'delete_requested')
     and not (local_name = any(v_names));
  -- Загруженное, что было «ready» с отметкой «скачивается/есть», но в снимок
  -- не попало, обработано выше только для on_device; ready с device_state
  -- present/downloading тоже считается пропавшим.
  update public.device_videos
     set device_state = 'missing', updated_at = now()
   where device_id = p_device and source = 'upload' and status = 'ready'
     and device_state in ('present', 'downloading')
     and not (id = any(v_ids));

  if v_new then perform public._video_bump(p_device); end if;
  select videos_rev into v_rev from public.devices where id = p_device;
  return jsonb_build_object('ok', true, 'videos_rev', v_rev);
end;
$$;

-- ---------- 8. device_poll: ТОЛЬКО поле videos_rev ----------
-- Тело — из 20261106000000_brand1_brands.sql (там была последняя правка)
-- БЕЗ изменений, добавлена одна строка 'videos_rev' в итоговом jsonb.
-- Приложения без поддержки поля его не читают.
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
    'target',      public.rollout_target(p_device),  -- null, если цели нет
    'brand',       coalesce(public._brand_for_device(p_device), 'null'::jsonb),
    'videos_rev',  (select videos_rev from devices where id = p_device)
  );
end;
$function$;

-- ---------- Права ----------
-- Таблицы закрыты выше (revoke all). Доступ — только через функции.

-- Портал: клиент и супервайзер (проверку роли делает сама функция).
revoke all on function public.video_list(text) from public, anon;
revoke all on function public.video_upload_begin(text, text, bigint, text) from public, anon;
revoke all on function public.video_set_play(uuid, boolean) from public, anon;
revoke all on function public.video_delete(uuid) from public, anon;
revoke all on function public.video_access_check(uuid) from public, anon;
grant execute on function public.video_list(text) to authenticated;
grant execute on function public.video_upload_begin(text, text, bigint, text) to authenticated;
grant execute on function public.video_set_play(uuid, boolean) to authenticated;
grant execute on function public.video_delete(uuid) to authenticated;
grant execute on function public.video_access_check(uuid) to authenticated;

-- Edge Functions (сервисный ключ).
revoke all on function public._video_mark_validating(uuid) from public, anon, authenticated;
revoke all on function public._video_mark_validated(uuid, uuid, text, int, int, bigint, boolean)
  from public, anon, authenticated;
revoke all on function public._video_mark_rejected(uuid, uuid, text, text)
  from public, anon, authenticated;
revoke all on function public._video_mark_failed(uuid, text) from public, anon, authenticated;
revoke all on function public._video_purge_pick(int) from public, anon, authenticated;
revoke all on function public._video_purge_done(uuid[]) from public, anon, authenticated;
revoke all on function public.device_video_path(text, text, uuid)
  from public, anon, authenticated;
grant execute on function public._video_mark_validating(uuid) to service_role;
grant execute on function public._video_mark_validated(uuid, uuid, text, int, int, bigint, boolean)
  to service_role;
grant execute on function public._video_mark_rejected(uuid, uuid, text, text) to service_role;
grant execute on function public._video_mark_failed(uuid, text) to service_role;
grant execute on function public._video_purge_pick(int) to service_role;
grant execute on function public._video_purge_done(uuid[]) to service_role;
grant execute on function public.device_video_path(text, text, uuid) to service_role;

-- Аппарат: публичный ключ приложения (anon) и сервисный ключ.
revoke all on function public.device_videos_get(text, text) from public, authenticated;
revoke all on function public.device_video_report(text, text, jsonb) from public, authenticated;
grant execute on function public.device_videos_get(text, text) to anon, service_role;
grant execute on function public.device_video_report(text, text, jsonb) to anon, service_role;

-- device_poll пересоздана выше — вернуть ровно те же права, что были
-- (20261018000200_function_grants_hardening.sql).
revoke execute on function public.device_poll(text, text, text, jsonb)
  from public, authenticated;
grant execute on function public.device_poll(text, text, text, jsonb)
  to anon, service_role;
