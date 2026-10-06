-- ============================================================
-- R4: модель «изготовитель — клиент», привязка аппарата по коду, права клиента.
-- НЕ ПРИМЕНЕНО автоматически; SQL в Supabase выполняет только владелец.
-- Применять ПОСЛЕ r1, r2, r3 и 20261006000100_r3_devices_grants.sql.
-- После применения отдельной командой:  notify pgrst, 'reload schema';
--
-- Решения владельца (не менять без согласования):
--  1. Аппарат всегда принадлежит организации-изготовителю (devices.org_id).
--     Клиент в org_id не переносится: доступ клиента — отдельная связь
--     device_access со сроком подписки.
--  2. Подписка считается за КАЖДЫЙ аппарат отдельно.
--  3. У клиента ОДИН вход (auth.users), без сотрудников и ролей.
--  4. Дистрибьюторов нет.
--  5. Привязка ТОЛЬКО по одноразовому коду (по номеру аппарата нельзя).
--  6. Окончание подписки отключает только доступ клиента к панели; работа
--     аппарата, обновления и телеметрия для изготовителя не меняются.
--  7. Права клиента ограничены на СЕРВЕРЕ (права БД, RLS, функции).
--  8. Срок подписки выставляет одна функция access_set_valid_until: позже её
--     вызовет вебхук Stripe (service role), сейчас — изготовитель вручную.
--
-- Принцип безопасности: клиент (authenticated, НЕ член организации) не имеет
-- доступа ни к одной базовой таблице. Он работает только через узкие
-- представления customer_* и функции ниже. Представления выполняются с
-- правами владельца (security_barrier), а выборка ограничена auth.uid().
--
-- ПРОВЕРКА ТЕКУЩИХ ПРАВ ПЕРЕД ПРИМЕНЕНИЕМ (только чтение):
--   select table_name, grantee, privilege_type
--     from information_schema.role_table_grants
--    where table_schema='public' and grantee in ('anon','authenticated')
--      and table_name in ('devices','events','commands','device_diagnostics')
--    order by 1,2,3;
--   select table_name, grantee, privilege_type, column_name
--     from information_schema.column_privileges
--    where table_schema='public' and table_name='devices'
--      and grantee in ('anon','authenticated') order by 3,4;
--   select schemaname, tablename, policyname, cmd, roles, qual, with_check
--     from pg_policies where schemaname='public' order by tablename, policyname;
-- ============================================================

-- ============================================================
-- 0. ДЕФЕКТЫ ТЕКУЩИХ ПРАВ (найдены аудитом, исправляются здесь)
-- ============================================================

-- ДЕФЕКТ A: политика commands_insert проверяла только is_org_member(org_id),
-- но не то, что device_id принадлежит ЭТОЙ организации: член организации X
-- мог вставить команду (org_id = X) для device_id организации Y, а
-- device_poll выбирает команды по одному device_id. Исправление — в политике
-- (для authenticated) и в триггере (для любых путей вставки).
drop policy if exists commands_insert on public.commands;
create policy commands_insert on public.commands
  for insert to authenticated
  with check (
    public.is_org_member(org_id)
    and exists (
      select 1 from public.devices d
       where d.id = commands.device_id and d.org_id = commands.org_id
    )
  );

create or replace function public.commands_device_org_check() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.devices d
                  where d.id = new.device_id and d.org_id = new.org_id) then
    raise exception 'commands: device_id не принадлежит org_id'
      using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function public.commands_device_org_check() from public, anon, authenticated;

drop trigger if exists commands_device_org_check_trg on public.commands;
create trigger commands_device_org_check_trg
  before insert on public.commands
  for each row execute function public.commands_device_org_check();

-- Пункт B (ослабленная защита): у authenticated на devices права выданы ПО
-- СТОЛБЦАМ; SELECT — на все, кроме token (токен прочитать нельзя — так и
-- должно быть). Но были ещё INSERT, UPDATE, REFERENCES на все столбцы,
-- включая token; запись блокировало лишь отсутствие политик RLS. Второй
-- рубеж (как для app_releases и rollouts): отозвать. Отзыв на уровне таблицы
-- снимает и столбцовые права. Панель пишет только через insert в commands и
-- функции (security definer) — этим правам не нужна.
-- ВАЖНО: каждый НОВЫЙ столбец devices требует явного
--   grant select (<столбец>) on public.devices to authenticated;
-- иначе панель его не увидит (так вышло с ring и timezone в R3).
revoke insert, update, delete, truncate, references, trigger
  on public.devices from authenticated;
revoke all on public.devices from anon;

-- Аудит остальных таблиц. Панель читает commands, events, device_diagnostics
-- и пишет только insert в commands; всё остальное закрыто:
revoke update, delete, truncate, references, trigger
  on public.commands from authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.events from authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.device_diagnostics from authenticated;
revoke all on public.commands, public.events, public.device_diagnostics from anon;

-- ============================================================
-- 1. ПОМОЩНИКИ
-- ============================================================

-- Изготовитель («супервизор»): член организации-владельца аппарата.
-- ЕДИНСТВЕННАЯ точка, через которую проверяются права изготовителя в
-- функциях R4. MFA для изготовителя включается ЗДЕСЬ (см. docs/tenancy.md):
--   ... and coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
create or replace function public.is_staff(p_org uuid) returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select public.is_org_member(p_org);
$$;
revoke all on function public.is_staff(uuid) from public, anon;
grant execute on function public.is_staff(uuid) to authenticated;

-- Изготовитель или service role (вебхук Stripe позже вызовет
-- access_set_valid_until с сервисным ключом).
create or replace function public.is_staff_or_service(p_org uuid) returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '')
           = 'service_role'
      or public.is_staff(p_org);
$$;
revoke all on function public.is_staff_or_service(uuid) from public, anon, authenticated;


-- ============================================================
-- 2. ТАБЛИЦЫ
-- ============================================================

-- Код привязки: в базе только соль и хэш sha256(соль || код). Открытый код
-- не хранится. Формат кода: 12 знаков алфавита без похожих символов
-- (без 0/O, 1/I/L), регистр не важен, на наклейке XXXX-XXXX-XXXX. При 31
-- символе это ≈ 59 бит; перебор ограничен claim_attempts (5 неудач в час на
-- пользователя, 50 в сутки на аппарат). Хэш считается так же заводским
-- генератором (tool/provision_devices.py): sha256(utf8(соль + КОД_ЗАГЛАВНЫМИ
-- _БЕЗ_ДЕФИСОВ)), hex.
create table if not exists public.device_claims (
  device_id  text        primary key references public.devices(id) on delete cascade,
  code_salt  text        not null,
  code_hash  text        not null,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  claimed_by uuid
);
alter table public.device_claims enable row level security;
revoke all on table public.device_claims from public, anon, authenticated;

-- Доступ клиента к аппарату. «Активный доступ» = ended_at is null и
-- valid_until > now(). Не более одной открытой записи на аппарат.
create table if not exists public.device_access (
  id           uuid        primary key default gen_random_uuid(),
  device_id    text        not null references public.devices(id),
  customer_id  uuid        not null references auth.users(id),
  label        text,
  valid_until  timestamptz not null,
  source       text        not null check (source in ('stripe', 'manual')),
  external_ref text,
  created_at   timestamptz not null default now(),
  ended_at     timestamptz
);
create unique index if not exists device_access_one_open_per_device
  on public.device_access (device_id) where ended_at is null;
create index if not exists device_access_customer_idx
  on public.device_access (customer_id) where ended_at is null;
alter table public.device_access enable row level security;
revoke all on table public.device_access from public, anon, authenticated;

-- Попытки привязки (защита от перебора). device_id — текст без внешнего
-- ключа: попытки с несуществующим номером тоже учитываются и ничего не
-- раскрывают.
create table if not exists public.claim_attempts (
  id        bigint generated always as identity primary key,
  user_id   uuid        not null,
  device_id text        not null,
  ok        boolean     not null,
  at        timestamptz not null default now()
);
create index if not exists claim_attempts_user_idx on public.claim_attempts (user_id, at);
create index if not exists claim_attempts_device_idx on public.claim_attempts (device_id, at);
alter table public.claim_attempts enable row level security;
revoke all on table public.claim_attempts from public, anon, authenticated;

-- Какие типы событий и какие ключи data видит клиент. Остальное — нет.
-- duplicate_payment в приложении сейчас не существует (есть
-- unexpected_payment — списание вне экрана оплаты); оба в списке.
create table if not exists public.customer_event_types (
  event_type   text   primary key,
  allowed_keys text[] not null default '{}'
);
alter table public.customer_event_types enable row level security;
revoke all on table public.customer_event_types from public, anon, authenticated;

insert into public.customer_event_types (event_type, allowed_keys) values
  ('session_complete',       array['session_id','flavor','price_cents','paid_cents','duration_s','completed','payment_method','reason','service_delivered']),
  ('low_liquid',             array['channel','flavor']),
  ('liquid_restored',        array['channel','flavor']),
  ('out_of_service',         array['code','since']),
  ('out_of_service_cleared', array['code','since','cleared_at']),
  ('hardware_error',         array['code']),
  ('payment_abandoned',      array['reason','balance_cents','price_cents']),
  ('duplicate_payment',      array[]::text[]),
  ('unexpected_payment',     array[]::text[])
on conflict (event_type) do nothing;

-- Журнал команд клиента: лимит частоты и просмотр «моих команд».
create table if not exists public.customer_command_log (
  id          bigint generated always as identity primary key,
  device_id   text        not null,
  customer_id uuid        not null,
  command_id  text,
  action      text        not null,
  at          timestamptz not null default now()
);
create index if not exists customer_command_log_dev_idx on public.customer_command_log (device_id, at);
create index if not exists customer_command_log_cust_idx on public.customer_command_log (customer_id, at);
alter table public.customer_command_log enable row level security;
revoke all on table public.customer_command_log from public, anon, authenticated;

-- Журнал действий изготовителя. Читает только изготовитель; клиенту не
-- отдаётся (решение о показе клиенту — позже).
create table if not exists public.staff_audit (
  id        bigint generated always as identity primary key,
  at        timestamptz not null default now(),
  org_id    uuid,
  actor     uuid,                 -- auth.uid(); null — service role / SQL Editor
  action    text        not null,
  device_id text,
  details   jsonb       not null default '{}'::jsonb
);
create index if not exists staff_audit_org_idx on public.staff_audit (org_id, at desc);
alter table public.staff_audit enable row level security;
revoke all on table public.staff_audit from public, anon, authenticated;
grant select on table public.staff_audit to authenticated;
create policy staff_audit_read on public.staff_audit
  for select to authenticated
  using (org_id is not null and public.is_staff(org_id));

-- Внутренняя запись в журнал (только из security definer-кода).
create or replace function public.staff_audit_add(
  p_org uuid, p_action text, p_device text, p_details jsonb
) returns void
language sql
security definer
set search_path = public
as $$
  insert into public.staff_audit(org_id, actor, action, device_id, details)
  values (p_org, auth.uid(), p_action, p_device, coalesce(p_details, '{}'::jsonb));
$$;
revoke all on function public.staff_audit_add(uuid, text, text, jsonb) from public, anon, authenticated;

-- Команды, вставленные изготовителем (панель: insert into commands).
create or replace function public.commands_audit() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and public.is_staff(new.org_id) then
    insert into public.staff_audit(org_id, actor, action, device_id, details)
    values (new.org_id, auth.uid(), 'command', new.device_id,
            jsonb_build_object('action', new.action));
  end if;
  return new;
end;
$$;
revoke all on function public.commands_audit() from public, anon, authenticated;
drop trigger if exists commands_audit_trg on public.commands;
create trigger commands_audit_trg
  after insert on public.commands
  for each row execute function public.commands_audit();

-- ============================================================
-- 3. КОДЫ ПРИВЯЗКИ
-- ============================================================

-- У текущего клиента есть АКТИВНЫЙ доступ к аппарату (связь не закрыта и срок
-- подписки не истёк).
create or replace function public.customer_has_access(p_device text) returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.device_access da
     where da.device_id = p_device
       and da.customer_id = auth.uid()
       and da.ended_at is null
       and da.valid_until > now()
  );
$$;
revoke all on function public.customer_has_access(text) from public, anon, authenticated;

-- Новый код: 12 знаков из 31, равномерно (отбраковка байтов ≥ 248 убирает
-- смещение по модулю). Случайность — gen_random_uuid() (криптостойкая);
-- байты 6 и 8 uuid частично фиксированы и пропускаются.
create or replace function public._claim_new_code() returns text
language plpgsql
volatile
set search_path = public
as $$
declare
  c_alpha constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';  -- 31 знак
  v_out   text := '';
  v_b     bytea;
  v_i     int;
  v_byte  int;
begin
  while length(v_out) < 12 loop
    v_b := uuid_send(gen_random_uuid());
    for v_i in 0..15 loop
      continue when v_i in (6, 8);
      v_byte := get_byte(v_b, v_i);
      if v_byte < 248 and length(v_out) < 12 then
        v_out := v_out || substr(c_alpha, (v_byte % 31) + 1, 1);
      end if;
    end loop;
  end loop;
  return v_out;
end;
$$;
revoke all on function public._claim_new_code() from public, anon, authenticated;

create or replace function public._claim_hash(p_salt text, p_normalized text) returns text
language sql
immutable
as $$
  select encode(sha256(convert_to(p_salt || p_normalized, 'UTF8')), 'hex');
$$;
revoke all on function public._claim_hash(text, text) from public, anon, authenticated;

-- Привязка аппарата клиентом по коду. Неверный номер, неверный код и «уже
-- привязан» отвечают ОДНИМ сообщением invalid_claim (не раскрываем, существует
-- ли аппарат). Блокировка: 5 неудач за час на пользователя и 50 за сутки на
-- аппарат; во время блокировки даже верный код отказывает.
-- Порог на аппарат намеренно высокий (50): подбор кода невозможен (31^12 ≈ 2^59),
-- а номер аппарата угадывается (CARFOG-001), и низкий порог позволял бы любому
-- зарегистрированному пользователю блокировать привязку честному клиенту (DoS).
create or replace function public.device_claim(
  p_device text,
  p_code   text,
  p_label  text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_dev   text := left(coalesce(p_device, ''), 64);
  v_norm  text;
  v_label text;
  c       public.device_claims%rowtype;
  v_ok    boolean := false;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  delete from public.claim_attempts where at < now() - interval '2 days';

  if (select count(*) from public.claim_attempts
       where user_id = v_uid and not ok and at > now() - interval '1 hour') >= 5
     or (select count(*) from public.claim_attempts
          where device_id = v_dev and not ok and at > now() - interval '1 day') >= 50 then
    return jsonb_build_object('ok', false, 'error', 'too_many_attempts');
  end if;

  v_norm := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));

  select * into c from public.device_claims where device_id = v_dev for update;
  if found
     and v_norm ~ '^[A-HJ-KM-NP-Z2-9]{12}$'
     and c.claimed_at is null
     and not exists (select 1 from public.device_access
                      where device_id = v_dev and ended_at is null)
     and public._claim_hash(c.code_salt, v_norm) = c.code_hash then
    v_ok := true;
  end if;

  if not v_ok then
    insert into public.claim_attempts(user_id, device_id, ok) values (v_uid, v_dev, false);
    return jsonb_build_object('ok', false, 'error', 'invalid_claim');
  end if;

  v_label := nullif(btrim(coalesce(p_label, '')), '');
  if v_label is not null and length(v_label) > 60 then
    v_label := left(v_label, 60);
  end if;

  begin
    insert into public.device_access(device_id, customer_id, label, valid_until, source)
    values (v_dev, v_uid, coalesce(v_label, v_dev), now(), 'manual');
  exception when unique_violation then
    insert into public.claim_attempts(user_id, device_id, ok) values (v_uid, v_dev, false);
    return jsonb_build_object('ok', false, 'error', 'invalid_claim');
  end;

  update public.device_claims
     set claimed_at = now(), claimed_by = v_uid
   where device_id = v_dev;
  insert into public.claim_attempts(user_id, device_id, ok) values (v_uid, v_dev, true);
  return jsonb_build_object('ok', true, 'device_id', v_dev);
end;
$$;

-- Новый код привязки (изготовитель). Показывается ОДИН раз (возвращается
-- открытым), старый недействителен. Только если аппарат не привязан.
create or replace function public.claim_regenerate(p_device text) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org  uuid;
  v_code text;
  v_salt text;
begin
  select org_id into v_org from public.devices where id = p_device;
  if v_org is null or not public.is_staff(v_org) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if exists (select 1 from public.device_access where device_id = p_device and ended_at is null) then
    raise exception 'device_bound' using errcode = 'P0001';
  end if;

  v_code := public._claim_new_code();
  v_salt := replace(gen_random_uuid()::text, '-', '');
  insert into public.device_claims(device_id, code_salt, code_hash)
  values (p_device, v_salt, public._claim_hash(v_salt, v_code))
  on conflict (device_id) do update
    set code_salt = excluded.code_salt, code_hash = excluded.code_hash,
        created_at = now(), claimed_at = null, claimed_by = null;

  perform public.staff_audit_add(v_org, 'claim_regenerate', p_device, '{}'::jsonb);
  return substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4) || '-' || substr(v_code, 9, 4);
end;
$$;

-- ============================================================
-- 4. ПОДПИСКА И ДОСТУП
-- ============================================================

-- Срок подписки аппарата. Изготовитель (вручную, для тестов) или service
-- role (вебхук Stripe). Нужна открытая связь (аппарат привязан).
create or replace function public.access_set_valid_until(
  p_device text,
  p_until  timestamptz,
  p_source text,
  p_ref    text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  a     public.device_access%rowtype;
begin
  select org_id into v_org from public.devices where id = p_device;
  if v_org is null or not public.is_staff_or_service(v_org) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  if p_until is null or p_source not in ('stripe', 'manual')
     or p_until > now() + interval '3 years' then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;

  select * into a from public.device_access
   where device_id = p_device and ended_at is null for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_bound');
  end if;

  update public.device_access
     set valid_until = p_until, source = p_source, external_ref = p_ref
   where id = a.id;

  perform public.staff_audit_add(v_org, 'access_set_valid_until', p_device,
    jsonb_build_object('until', p_until, 'source', p_source));
  return jsonb_build_object('ok', true, 'valid_until', p_until);
end;
$$;

-- Закрыть связь (перепродажа, возврат). Только изготовитель.
create or replace function public.access_end(p_device text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_n   int;
begin
  select org_id into v_org from public.devices where id = p_device;
  if v_org is null or not public.is_staff(v_org) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  update public.device_access set ended_at = now()
   where device_id = p_device and ended_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'not_bound'); end if;
  perform public.staff_audit_add(v_org, 'access_end', p_device, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end;
$$;

-- Клиент переименовывает свой аппарат (нужен активный доступ).
create or replace function public.device_set_label(p_device text, p_label text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text := nullif(btrim(coalesce(p_label, '')), '');
begin
  if auth.uid() is null or not public.customer_has_access(p_device) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  if v_label is null or length(v_label) > 60 then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;
  update public.device_access set label = v_label
   where device_id = p_device and customer_id = auth.uid() and ended_at is null;
  return jsonb_build_object('ok', true);
end;
$$;

-- ============================================================
-- 5. КОМАНДЫ КЛИЕНТА
-- ============================================================

-- Единственный путь клиента к commands. Разрешено: ping, restart_app,
-- reset_session, update_config (только treatmentPriceCents и
-- treatmentDurationS, границы как в приложении: lib/models/remote_limits.dart —
-- цена 50…2000 центов, длительность 10…120 с). Всё остальное (update_app,
-- rollback_app, factory_reset, set_pin, collect_diagnostics, unlock, любые
-- другие ключи) — отказ. Нужен активный доступ. Лимит: не более 20 команд в
-- час на аппарат (НЕ ИЗМЕРЕНО, задано решением владельца как пример).
create or replace function public.customer_send_command(
  p_device text,
  p_action text,
  p_params jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_org    uuid;
  v_params jsonb := coalesce(p_params, '{}'::jsonb);
  v_key    text;
  v_val    jsonb;
  v_id     text;
begin
  if v_uid is null or not public.customer_has_access(p_device) then
    return jsonb_build_object('ok', false, 'error', 'no_access');
  end if;
  if p_action not in ('ping', 'restart_app', 'reset_session', 'update_config') then
    return jsonb_build_object('ok', false, 'error', 'action_not_allowed');
  end if;
  if jsonb_typeof(v_params) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;

  if p_action = 'update_config' then
    if v_params = '{}'::jsonb then
      return jsonb_build_object('ok', false, 'error', 'bad_request');
    end if;
    for v_key, v_val in select key, value from jsonb_each(v_params) loop
      if v_key not in ('treatmentPriceCents', 'treatmentDurationS')
         or jsonb_typeof(v_val) <> 'number'
         or (v_val #>> '{}') !~ '^[0-9]{1,6}$' then
        return jsonb_build_object('ok', false, 'error', 'bad_params');
      end if;
      if v_key = 'treatmentPriceCents'
         and not ((v_val #>> '{}')::int between 50 and 2000) then
        return jsonb_build_object('ok', false, 'error', 'out_of_range');
      end if;
      if v_key = 'treatmentDurationS'
         and not ((v_val #>> '{}')::int between 10 and 120) then
        return jsonb_build_object('ok', false, 'error', 'out_of_range');
      end if;
    end loop;
  elsif v_params <> '{}'::jsonb then
    return jsonb_build_object('ok', false, 'error', 'bad_params');
  end if;

  if (select count(*) from public.customer_command_log
       where device_id = p_device and at > now() - interval '1 hour') >= 20 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  select org_id into v_org from public.devices where id = p_device;
  insert into public.commands(device_id, org_id, action, params)
  values (p_device, v_org, p_action, v_params)
  returning id::text into v_id;

  insert into public.customer_command_log(device_id, customer_id, command_id, action)
  values (p_device, v_uid, v_id, p_action);
  return jsonb_build_object('ok', true);
end;
$$;

-- ============================================================
-- 6. ПРЕДСТАВЛЕНИЯ ДЛЯ КЛИЕНТА (security_barrier, права владельца,
--    выборка ограничена auth.uid() и активным доступом)
-- ============================================================

-- Только безопасные поля слепка. НЕ отдаются: токен, версия приложения,
-- rollback, adb, debug_modes, last_update_result, skip_health_signal_build,
-- rollout_*, ring, timezone, org_id. «На связи» — последний контакт не старше
-- 5 минут (НЕ ИЗМЕРЕНО; опрос каждые 30 с).
create or replace view public.customer_devices
with (security_barrier = true) as
select
  d.id                                             as device_id,
  da.label                                         as label,
  d.last_seen_at                                   as last_seen_at,
  case when d.last_seen_at > now() - interval '5 minutes'
       then 'online' else 'offline' end            as connection,
  da.valid_until                                   as valid_until,
  nullif(d.reported_config ->> 'price_cents', '')::int  as price_cents,
  nullif(d.reported_config ->> 'duration_s', '')::int   as duration_s,
  nullif(d.reported_config ->> 'flavor_count', '')::int as flavor_count,
  d.reported_config -> 'flavor_names_ru'           as flavor_names,
  coalesce((d.reported_config ->> 'out_of_service')::boolean, false) as out_of_service,
  -- пустые канистры: последнее событие канала — low_liquid
  (select coalesce(jsonb_agg(x.ch order by x.ch), '[]'::jsonb)
     from (select distinct on (e.data ->> 'channel')
                  (e.data ->> 'channel')::int as ch, e.type
             from public.events e
            where e.device_id = d.id
              and e.type in ('low_liquid', 'liquid_restored')
              and e.received_at >= da.created_at
              and (e.data ->> 'channel') ~ '^[0-9]+$'
            order by (e.data ->> 'channel'), e.received_at desc) x
    where x.type = 'low_liquid')                   as empty_channels
from public.device_access da
join public.devices d on d.id = da.device_id
where da.customer_id = auth.uid()
  and da.ended_at is null
  and da.valid_until > now();

-- События из разрешённого списка и только разрешённые ключи data. Только
-- свои аппараты и только с момента привязки (данные до привязки не
-- показываем; пришедшее за время просрочки видно после продления: данные не
-- удаляются). Выручка — те же события: session_complete несёт price_cents и
-- paid_cents, панель клиента суммирует их (отдельных агрегатов нет — проще).
create or replace view public.customer_events
with (security_barrier = true) as
select
  e.id                                             as id,
  e.device_id                                      as device_id,
  da.label                                         as label,
  e.type                                           as type,
  e.received_at                                    as at,
  coalesce((select jsonb_object_agg(x.key, x.value)
              from jsonb_each(case when jsonb_typeof(e.data) = 'object'
                                   then e.data else '{}'::jsonb end) as x(key, value)
             where x.key = any (t.allowed_keys)), '{}'::jsonb) as data
from public.events e
join public.customer_event_types t on t.event_type = e.type
join public.device_access da
  on da.device_id = e.device_id
 and da.customer_id = auth.uid()
 and da.ended_at is null
 and da.valid_until > now()
where e.received_at >= da.created_at;

-- Свои команды: действие, статус и результат (только короткий текстовый код;
-- структурированный ответ, например ping с версией, клиенту не отдаётся).
create or replace view public.customer_commands
with (security_barrier = true) as
select
  l.id                                             as id,
  l.device_id                                      as device_id,
  da.label                                         as label,
  l.action                                         as action,
  l.at                                             as at,
  c.status::text                                   as status,
  case when c.result is not null
        and c.result::text !~ '^\s*[\[{]'
        and length(c.result::text) <= 120
       then c.result::text end                     as result
from public.customer_command_log l
join public.device_access da
  on da.device_id = l.device_id
 and da.customer_id = auth.uid()
 and da.ended_at is null
 and da.valid_until > now()
left join public.commands c on c.id::text = l.command_id
where l.customer_id = auth.uid()
  and l.at >= da.created_at;

-- Для изготовителя: кто привязан, срок, источник (без хэша кода).
create or replace view public.staff_device_access
with (security_barrier = true) as
select
  da.device_id, da.customer_id, da.label, da.valid_until, da.source,
  da.external_ref, da.created_at, da.ended_at
from public.device_access da
join public.devices d on d.id = da.device_id
where public.is_staff(d.org_id);

-- ============================================================
-- 7. ПЕРЕОПРЕДЕЛЕНИЕ ФУНКЦИЙ R3 (журнал действий изготовителя, is_staff):
--    rollout_create, rollout_set_status, device_set_ring_tz
-- ============================================================

-- rollout_create (из R3) + запись в staff_audit; логика и ответы прежние.
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
  perform public.staff_audit_add(v_org, 'rollout_create', null,
    jsonb_build_object('rollout', v_id, 'release', p_release, 'ring', p_ring));

  return jsonb_build_object('ok', true, 'id', v_id, 'status', 'paused');
end;
$$;

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
  if not found or not public.is_staff(r.org_id) then
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
  perform public.staff_audit_add(r.org_id, 'rollout_status', null,
    jsonb_build_object('rollout', r.id, 'from', r.status, 'to', p_status));
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
  if v_org is null or not public.is_staff(v_org) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  if not exists (select 1 from pg_timezone_names where name = p_tz) then
    return jsonb_build_object('ok', false, 'error', 'bad_timezone');
  end if;
  update public.devices set ring = p_ring, timezone = p_tz where id = p_device;
  perform public.staff_audit_add(v_org, 'device_set_ring_tz', p_device,
    jsonb_build_object('ring', p_ring, 'tz', p_tz));
  return jsonb_build_object('ok', true);
end;
$$;

-- ============================================================
-- 8. ПРАВА (execute у PUBLIC по умолчанию — у каждой функции явно)
-- ============================================================

-- клиент
revoke all on function public.device_claim(text, text, text) from public, anon;
revoke all on function public.device_set_label(text, text) from public, anon;
revoke all on function public.customer_send_command(text, text, jsonb) from public, anon;
grant execute on function public.device_claim(text, text, text) to authenticated;
grant execute on function public.device_set_label(text, text) to authenticated;
grant execute on function public.customer_send_command(text, text, jsonb) to authenticated;

-- изготовитель (проверка членства внутри); access_set_valid_until ещё и
-- service role (вебхук Stripe)
revoke all on function public.claim_regenerate(text) from public, anon;
revoke all on function public.access_end(text) from public, anon;
revoke all on function public.access_set_valid_until(text, timestamptz, text, text) from public, anon;
revoke all on function public.rollout_create(uuid, text, time, time, int) from public, anon;
revoke all on function public.rollout_set_status(uuid, text) from public, anon;
revoke all on function public.device_set_ring_tz(text, text, text) from public, anon;
grant execute on function public.claim_regenerate(text) to authenticated;
grant execute on function public.access_end(text) to authenticated;
grant execute on function public.access_set_valid_until(text, timestamptz, text, text) to authenticated, service_role;
grant execute on function public.rollout_create(uuid, text, time, time, int) to authenticated;
grant execute on function public.rollout_set_status(uuid, text) to authenticated;
grant execute on function public.device_set_ring_tz(text, text, text) to authenticated;

-- представления
revoke all on public.customer_devices, public.customer_events,
              public.customer_commands, public.staff_device_access
  from public, anon;
grant select on public.customer_devices, public.customer_events,
                public.customer_commands, public.staff_device_access
  to authenticated;

-- ============================================================
-- 9. ДОПОЛНИТЕЛЬНАЯ ЖЁСТКОСТЬ ПРАВ
-- ============================================================
-- Проверено запросами к реальной базе: RLS включена на всех таблицах public, но
-- у ролей остались избыточные права по умолчанию Supabase (все права на каждую
-- новую таблицу получают anon и authenticated). Запись была защищена только
-- отсутствием политик RLS. Здесь — второй рубеж. Все revoke идемпотентны.

-- organizations, org_members: anon имел ВСЕ права, authenticated — тоже. Остаётся
-- только SELECT для authenticated (политики чтения прежние).
revoke all on public.organizations, public.org_members from anon;
revoke insert, update, delete, truncate, references, trigger
  on public.organizations, public.org_members from authenticated;

-- rollout_progress (представление): только SELECT для authenticated, anon — ничего.
revoke insert, update, delete, truncate, references, trigger
  on public.rollout_progress from authenticated;
revoke all on public.rollout_progress from anon;

-- app_releases, rollouts, rollout_log: authenticated — только SELECT, anon — ничего.
revoke insert, update, delete, truncate, references, trigger
  on public.app_releases, public.rollouts, public.rollout_log from authenticated;
revoke all on public.app_releases, public.rollouts, public.rollout_log from anon;

-- release_url_requests: пишет только Edge Function под сервисным ключом;
-- у anon и authenticated прав быть не должно.
revoke all on public.release_url_requests from anon, authenticated;

-- ПРАВА ПО УМОЛЧАНИЮ ДЛЯ БУДУЩИХ ОБЪЕКТОВ. В Supabase новые таблицы и
-- последовательности в public автоматически получают все права для anon и
-- authenticated. «Безопасно по умолчанию»: новый объект без явного grant
-- недоступен. ВАЖНО: команда действует только на объекты, которые создаёт ТЕКУЩАЯ
-- роль (та, что выполняет миграцию, в SQL Editor — postgres); объекты, созданные
-- другими ролями (например supabase_admin), и уже существующие объекты она не
-- меняет (для существующих — revoke выше). После этого каждая новая таблица
-- требует явного grant (и RLS) — см. docs/tenancy.md.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

-- PostgREST кэширует схему — после применения отдельной командой:
--   notify pgrst, 'reload schema';
