-- ============================================================
-- BRAND1: бренды дистрибьюторов (белый лейбл), этап 1 — база.
-- ТЗ TZ_Brand_WhiteLabel_v1, разделы 3, 4, 5, 6.
--
-- НЕ ПРИМЕНЕНО. SQL выполняет владелец (или его ассистент) после «да».
-- Порядок применения и откат — docs/brands.md.
--
-- Применять ПОСЛЕ: R1 (device_token_valid), R2 (закрытый бакет releases,
-- release_url_requests), R3 (rollout_target, device_poll с полем target),
-- R4 (devices.org_id, staff_audit_add, is_portal_supervisor),
-- 20261018000000_token_hash_phase_a (device_poll на token_hash),
-- RD1 (_diag_supervisor_denied).
--
-- Что здесь:
--  1. Закрытый бакет Storage brand-packs (public=false, до 1 МБ,
--     только application/zip). Политик на storage.objects НЕТ ВОВСЕ:
--     ни anon, ни authenticated (включая супервайзера) не читают и не
--     пишут файлы напрямую. Пишет и читает только сервисный ключ —
--     Edge Functions brand-upload и brand-url. Обоснование — ниже.
--  2. Таблицы brands и brand_versions, колонка devices.brand_id
--     (null = встроенный бренд CaRFog из assets приложения).
--  3. Служебная запись brands('carfog','CaRFog') без версий.
--  4. Функции супервайзера (с 2FA): список, привязка, выбор текущей
--     версии, предпросмотр. Каждое действие — staff_audit_add.
--  5. _brand_version_register — только для сервисного ключа, её вызывает
--     Edge Function brand-upload ПОСЛЕ всех проверок пакета.
--  6. device_brand_get / device_brand_path — для аппарата и brand-url.
--  7. device_poll отвечает дополнительным полем brand (как target).
--
-- Почему у бакета brand-packs нет ни одной политики (решение по п. 2
-- задания). Диагностическим снимкам политика чтения для супервайзера
-- нужна: портал показывает картинку, а пути она не раскрывает. Пакету
-- бренда такая политика не нужна:
--   * при СОЗДАНИИ версии логотип лежит у супервайзера в браузере — он
--     сам его только что выбрал, предпросмотр заставки рисуется из этого
--     файла и из семи цветов, скачивать из бакета нечего;
--   * для УЖЕ созданной версии порталу нужны только название, слоган,
--     цвета и признак контраста — всё это отдаёт supervisor_brand_preview
--     из колонки manifest, архив не нужен;
--   * архив целиком нужен только аппарату, и он получает его по
--     подписанной ссылке на 5 минут от Edge Function brand-url.
-- Так ни у одного пользовательского ключа нет прав на бакет вообще:
-- меньше поверхность, нечего подбирать. Если позже владелец захочет
-- видеть в портале логотип уже загруженной версии, это добавляется одной
-- веткой для супервайзера в brand-url (отдельное «да»), а не политикой.
-- ============================================================

-- ---------- 1. Закрытый бакет ----------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('brand-packs', 'brand-packs', false, 1048576, array['application/zip'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Политик на storage.objects для этого бакета не создаётся намеренно
-- (обоснование в шапке). На случай, если политика когда-то была создана
-- вручную, снимаем её.
drop policy if exists brand_packs_supervisor_read on storage.objects;

-- ---------- 2. Таблицы ----------

create table if not exists public.brands (
  id              text        primary key
                    check (id ~ '^[a-z0-9][a-z0-9_-]{1,30}$'),
  name            text        not null check (length(btrim(name)) between 1 and 40),
  current_version int,
  created_at      timestamptz not null default now()
);

create table if not exists public.brand_versions (
  brand_id     text        not null references public.brands(id),
  version      int         not null check (version >= 1),
  sha256       text        not null check (sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes   int         not null check (size_bytes between 1 and 1048576),
  path         text        not null,            -- бакет brand-packs
  manifest     jsonb       not null,
  -- Письменное согласие дистрибьютора на использование логотипа.
  -- false допустим только для встроенного бренда carfog (решение
  -- владельца 5 в ТЗ). Та же проверка повторена в _brand_version_register.
  logo_consent boolean     not null,
  consent_note text,                            -- кто, когда, где документ
  contrast_ok  boolean     not null,
  created_by   uuid        not null,
  created_at   timestamptz not null default now(),
  primary key (brand_id, version),
  constraint brand_versions_consent_required
    check (logo_consent or brand_id = 'carfog'),
  constraint brand_versions_consent_note_required
    check (brand_id = 'carfog' or length(btrim(coalesce(consent_note, ''))) >= 3),
  -- Версия без пройденной проверки контраста не хранится вообще.
  constraint brand_versions_contrast_required check (contrast_ok)
);

create index if not exists brand_versions_brand_idx
  on public.brand_versions (brand_id, version desc);

-- current_version должна указывать на существующую версию.
alter table public.brands
  drop constraint if exists brands_current_version_fk;
alter table public.brands
  add constraint brands_current_version_fk
  foreign key (id, current_version) references public.brand_versions(brand_id, version);

alter table public.devices
  add column if not exists brand_id text references public.brands(id);
comment on column public.devices.brand_id is
  'Бренд аппарата. null = встроенный бренд CaRFog из assets приложения.';

alter table public.brands         enable row level security;
alter table public.brand_versions enable row level security;
revoke all on table public.brands         from public, anon, authenticated;
revoke all on table public.brand_versions from public, anon, authenticated;

-- Лимит частоты выдачи ссылки на архив (по образцу release_url_requests).
create table if not exists public.brand_url_requests (
  device_id text        primary key,
  last_at   timestamptz not null
);
alter table public.brand_url_requests enable row level security;
revoke all on table public.brand_url_requests from public, anon, authenticated;

-- ---------- 3. Служебная запись встроенного бренда ----------
-- Версий у carfog нет и не будет: встроенный бренд живёт в приложении
-- (assets/brand/default/). Запись нужна, чтобы на него можно было
-- сослаться в портале и чтобы id 'carfog' не занял дистрибьютор.
insert into public.brands (id, name) values ('carfog', 'CaRFog')
on conflict (id) do nothing;

-- ---------- 4. Доступ супервайзера ----------

-- Проверка «супервайзер портала с 2FA» + кто именно (для аудита версии,
-- которую создаёт Edge Function под сервисным ключом: там auth.uid()
-- уже недоступен, актора передаём явно).
-- Вызывается из Edge Function brand-upload ПОД JWT ВЫЗЫВАЮЩЕГО.
create or replace function public.supervisor_brand_check() returns jsonb
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
  return jsonb_build_object('ok', true, 'actor', auth.uid());
end;
$$;

-- Список брендов: версии и сколько аппаратов привязано.
create or replace function public.supervisor_brand_list() returns jsonb
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
  return jsonb_build_object('ok', true, 'brands', coalesce((
    select jsonb_agg(x order by x->>'id')
      from (
        select jsonb_build_object(
                 'id',              b.id,
                 'name',            b.name,
                 'current_version', b.current_version,
                 'builtin',         b.id = 'carfog',
                 'devices',         (select count(*) from public.devices d
                                      where d.brand_id = b.id),
                 'created_at',      b.created_at,
                 'versions',        coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'version',      v.version,
                            'sha256',       v.sha256,
                            'size_bytes',   v.size_bytes,
                            'logo_consent', v.logo_consent,
                            'consent_note', v.consent_note,
                            'contrast_ok',  v.contrast_ok,
                            'name',         v.manifest ->> 'name',
                            'slogan',       v.manifest ->> 'slogan',
                            'created_by',   v.created_by,
                            'created_at',   v.created_at
                          ) order by v.version desc)
                     from public.brand_versions v
                    where v.brand_id = b.id), '[]'::jsonb)
               ) as x
          from public.brands b
      ) s), '[]'::jsonb));
end;
$$;

-- Предпросмотр версии для портала: манифест (цвета, название, слоган) без
-- архива. Логотип в предпросмотре берётся из файла, который супервайзер
-- выбрал сам (см. обоснование в шапке).
create or replace function public.supervisor_brand_preview(
  p_brand   text,
  p_version int default null
) returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_denied  text := public._diag_supervisor_denied();
  v_version int  := p_version;
  v         record;
begin
  if v_denied is not null then
    return jsonb_build_object('ok', false, 'error', v_denied);
  end if;
  if v_version is null then
    select current_version into v_version from public.brands where id = p_brand;
  end if;
  if v_version is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  select * into v from public.brand_versions
   where brand_id = p_brand and version = v_version;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  return jsonb_build_object('ok', true,
    'brand_id', v.brand_id, 'version', v.version,
    'sha256', v.sha256, 'size_bytes', v.size_bytes,
    'contrast_ok', v.contrast_ok, 'logo_consent', v.logo_consent,
    'manifest', v.manifest);
end;
$$;

-- Привязка аппарата к бренду. p_brand null — снять бренд, аппарат
-- вернётся на встроенный CaRFog. 'carfog' отдельно не привязывается: это
-- то же самое, что null, поэтому принимается и сохраняется как null.
create or replace function public.supervisor_brand_assign(
  p_device text,
  p_brand  text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_denied text := public._diag_supervisor_denied();
  v_brand  text := nullif(p_brand, 'carfog');
  v_org    uuid;
  v_cur    int;
begin
  if v_denied is not null then
    return jsonb_build_object('ok', false, 'error', v_denied);
  end if;
  select org_id into v_org from public.devices where id = p_device;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_device');
  end if;

  if v_brand is not null then
    select current_version into v_cur from public.brands where id = v_brand;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'no_brand');
    end if;
    -- Привязывать бренд без годной версии нельзя: аппарату нечего скачать.
    if v_cur is null then
      return jsonb_build_object('ok', false, 'error', 'no_version');
    end if;
  end if;

  update public.devices set brand_id = v_brand where id = p_device;

  perform public.staff_audit_add(v_org, 'supervisor_brand_assign', p_device,
    jsonb_build_object('brand', v_brand, 'version', v_cur));
  return jsonb_build_object('ok', true, 'brand', v_brand, 'version', v_cur);
end;
$$;

-- Какая версия бренда считается текущей. Откат на старую версию
-- допустим; согласие на логотип при откате не снимается (его проверили,
-- когда версию создавали).
create or replace function public.supervisor_brand_set_current(
  p_brand   text,
  p_version int
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_denied text := public._diag_supervisor_denied();
  v_prev   int;
begin
  if v_denied is not null then
    return jsonb_build_object('ok', false, 'error', v_denied);
  end if;
  select current_version into v_prev from public.brands where id = p_brand;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_brand');
  end if;
  if not exists (select 1 from public.brand_versions
                  where brand_id = p_brand and version = p_version) then
    return jsonb_build_object('ok', false, 'error', 'no_version');
  end if;

  update public.brands set current_version = p_version where id = p_brand;

  perform public.staff_audit_add(null, 'supervisor_brand_set_current', null,
    jsonb_build_object('brand', p_brand, 'version', p_version, 'was', v_prev));
  return jsonb_build_object('ok', true, 'brand', p_brand, 'version', p_version);
end;
$$;

-- ---------- 5. Регистрация версии (только сервисный ключ) ----------

-- Вызывает Edge Function brand-upload ПОСЛЕ того, как она сама:
-- посчитала sha256 архива, распаковала его в памяти с защитой от
-- zip-бомбы, проверила brand.json по схеме 1, PNG-картинки, контраст и
-- согласие, и положила архив в бакет. Здесь — только запись и те
-- проверки, которые обязаны жить в базе: шаблон id, рост версии ровно
-- на 1, согласие, контраст.
--
-- p_actor — супервайзер, которого функция проверила под его JWT через
-- supervisor_brand_check(): под сервисным ключом auth.uid() пуст, и
-- staff_audit_add записал бы актора null.
create or replace function public._brand_version_register(
  p_brand       text,
  p_name        text,
  p_version     int,
  p_sha256      text,
  p_size        int,
  p_path        text,
  p_manifest    jsonb,
  p_consent     boolean,
  p_note        text,
  p_contrast_ok boolean,
  p_actor       uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_next int;
begin
  if p_brand is null or p_brand !~ '^[a-z0-9][a-z0-9_-]{1,30}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_brand');
  end if;
  -- Встроенный бренд версиями не обновляется: он в сборке приложения.
  if p_brand = 'carfog' then
    return jsonb_build_object('ok', false, 'error', 'builtin_brand');
  end if;
  if p_actor is null then
    return jsonb_build_object('ok', false, 'error', 'no_actor');
  end if;
  if coalesce(p_contrast_ok, false) is not true then
    return jsonb_build_object('ok', false, 'error', 'contrast_failed');
  end if;
  -- Согласие на логотип: обязательно для любого бренда, кроме carfog
  -- (а carfog сюда и не доходит). Пустая заметка не считается.
  if coalesce(p_consent, false) is not true
     or length(btrim(coalesce(p_note, ''))) < 3 then
    return jsonb_build_object('ok', false, 'error', 'consent_required');
  end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$'
     or p_size is null or p_size < 1 or p_size > 1048576
     or p_path is null or p_path <> (p_brand || '/v' || p_version || '.zip')
     or p_manifest is null or jsonb_typeof(p_manifest) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;

  -- Бренд создаётся первой своей версией; название берётся из манифеста.
  insert into public.brands (id, name) values (p_brand, p_name)
  on conflict (id) do update set name = excluded.name;

  -- Версия растёт строго на 1 (повтор той же версии — тоже отказ, чтобы
  -- нельзя было подменить уже скачанный аппаратами архив).
  select coalesce(max(version), 0) + 1 into v_next
    from public.brand_versions where brand_id = p_brand;
  if p_version is null or p_version <> v_next then
    return jsonb_build_object('ok', false, 'error', 'bad_version',
      'expected', v_next);
  end if;

  insert into public.brand_versions (
    brand_id, version, sha256, size_bytes, path, manifest,
    logo_consent, consent_note, contrast_ok, created_by)
  values (p_brand, p_version, p_sha256, p_size, p_path, p_manifest,
          true, p_note, true, p_actor);

  update public.brands set current_version = p_version where id = p_brand;

  insert into public.staff_audit (org_id, actor, action, device_id, details)
  values (null, p_actor, 'supervisor_brand_create_version', null,
          jsonb_build_object('brand', p_brand, 'version', p_version,
                             'sha256', p_sha256, 'size_bytes', p_size,
                             'consent_note', p_note));

  return jsonb_build_object('ok', true, 'brand', p_brand, 'version', p_version);
end;
$$;

-- ---------- 6. Для аппарата ----------

-- Какой бренд и какая версия положены аппарату. Без проверки токена и без
-- лимита частоты: вызывается ВНУТРИ device_poll (её токен уже проверен) и
-- внутри device_brand_get.
create or replace function public._brand_for_device(p_device text) returns jsonb
language sql
security definer
stable
set search_path = public
as $$
  select case when v.version is null then null else jsonb_build_object(
           'id', v.brand_id, 'version', v.version, 'sha256', v.sha256,
           'size_bytes', v.size_bytes) end
    from public.devices d
    left join public.brands b  on b.id = d.brand_id
    left join public.brand_versions v
           on v.brand_id = b.id and v.version = b.current_version
   where d.id = p_device;
$$;

-- Аппарат спрашивает свой бренд перед скачиванием. Ссылку НЕ отдаёт:
-- подписанную ссылку выдаёт Edge Function brand-url, которая вызывает эту
-- функцию и затем device_brand_path.
-- Лимит частоты: не чаще раза в 30 с на аппарат. Он защищает именно путь
-- скачивания; знать свой бренд аппарат может сколько угодно часто — это
-- поле brand в device_poll, там лимита нет.
create or replace function public.device_brand_get(
  p_device text,
  p_token  text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_brand jsonb;
begin
  if not public.device_token_valid(p_device, p_token) then
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;

  if exists (select 1 from public.brand_url_requests
              where device_id = p_device
                and last_at > now() - interval '30 seconds'
                -- Часы ушли назад — не блокируем навсегда.
                and last_at <= now()) then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  insert into public.brand_url_requests (device_id, last_at)
  values (p_device, now())
  on conflict (device_id) do update set last_at = now();

  v_brand := public._brand_for_device(p_device);
  -- Бренда нет — это не ошибка: аппарат показывает встроенный CaRFog.
  return jsonb_build_object('ok', true, 'brand', coalesce(v_brand, 'null'::jsonb));
end;
$$;

-- Путь архива в бакете brand-packs — для brand-url. Только сервисный ключ.
create or replace function public.device_brand_path(
  p_brand   text,
  p_version int
) returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare v record;
begin
  select path, sha256, size_bytes into v from public.brand_versions
   where brand_id = p_brand and version = p_version;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  return jsonb_build_object('ok', true, 'path', v.path,
    'sha256', v.sha256, 'size_bytes', v.size_bytes);
end;
$$;

-- ---------- 7. device_poll: дополнительное поле brand ----------
-- Тело взято из 20261018000000_token_hash_phase_a.sql БЕЗ изменений,
-- добавлена ТОЛЬКО строка 'brand' в итоговом jsonb_build_object.
-- Приложения без поддержки поля его просто не читают.
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
    'brand',       coalesce(public._brand_for_device(p_device), 'null'::jsonb)
  );
end;
$function$;

-- ---------- Права ----------
-- Таблицы закрыты выше (revoke all). Доступ — только через функции.

-- Супервайзер портала (проверку 2FA делает сама функция).
revoke all on function public.supervisor_brand_check() from public, anon;
revoke all on function public.supervisor_brand_list() from public, anon;
revoke all on function public.supervisor_brand_preview(text, int) from public, anon;
revoke all on function public.supervisor_brand_assign(text, text) from public, anon;
revoke all on function public.supervisor_brand_set_current(text, int) from public, anon;
grant execute on function public.supervisor_brand_check() to authenticated;
grant execute on function public.supervisor_brand_list() to authenticated;
grant execute on function public.supervisor_brand_preview(text, int) to authenticated;
grant execute on function public.supervisor_brand_assign(text, text) to authenticated;
grant execute on function public.supervisor_brand_set_current(text, int) to authenticated;

-- Регистрация версии — только Edge Function brand-upload (сервисный ключ).
revoke all on function public._brand_version_register(
  text, text, int, text, int, text, jsonb, boolean, text, boolean, uuid)
  from public, anon, authenticated;
grant execute on function public._brand_version_register(
  text, text, int, text, int, text, jsonb, boolean, text, boolean, uuid)
  to service_role;

-- Служебная: вызывается внутри device_poll и device_brand_get.
revoke all on function public._brand_for_device(text)
  from public, anon, authenticated;

-- Путь в бакете — только brand-url (сервисный ключ).
revoke all on function public.device_brand_path(text, int)
  from public, anon, authenticated;
grant execute on function public.device_brand_path(text, int) to service_role;

-- device_* по образцу остальных: anon (приложение с публичным ключом) и
-- сервисный ключ.
revoke all on function public.device_brand_get(text, text)
  from public, authenticated;
grant execute on function public.device_brand_get(text, text) to anon, service_role;

-- device_poll пересоздана выше — вернуть ровно те же права, что были
-- (20261018000200_function_grants_hardening.sql).
revoke execute on function public.device_poll(text, text, text, jsonb)
  from public, authenticated;
grant execute on function public.device_poll(text, text, text, jsonb)
  to anon, service_role;
