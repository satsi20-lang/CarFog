-- ============================================================
-- R5: спецификация аппарата (число насосов, набор языков).
-- Применять ПОСЛЕ 20261007000000_r4_tenancy.sql. НЕ ПРИМЕНЕНО автоматически;
-- SQL в Supabase выполняет только владелец. Миграция идемпотентна (можно
-- запускать повторно).
--
-- Контракт «spec» (единый для базы, генератора, заводского файла, приложения):
--   pumps        целое 4…10 (число насосов = число ароматов), по умолчанию 4
--   langs        коды языков (нижний регистр, без повторов, 1…24 шт.), порядок
--                = порядок на экране выбора; по умолчанию {et,en,ru}
--   default_lang один из langs; по умолчанию 'et'
--   hardware_profile строка, сейчас 'sy156-a510'
-- Допустимые коды (каталог): bg cs da de el en es et fi fr ga hr hu it lt lv
-- mt nl pl pt ro ru sk sl sv uk no.
--
-- Номер аппарата остаётся «глухим» (CARFOG-100): спецификация хранится здесь и
-- попадает в аппарат через заводскую запись (файл конфигурации).
-- Клиентские представления customer_* новые столбцы НЕ показывают (они
-- перечисляют столбцы явно). Запись — только через device_set_spec.
-- ============================================================

-- Каталог кодов языков (единственное место в базе).
create or replace function public._spec_lang_catalog() returns text[]
language sql
immutable
set search_path = public
as $$
  select array['bg','cs','da','de','el','en','es','et','fi','fr','ga','hr','hu',
               'it','lt','lv','mt','nl','pl','pt','ro','ru','sk','sl','sv','uk','no']::text[];
$$;
revoke all on function public._spec_lang_catalog() from public, anon, authenticated;
grant execute on function public._spec_lang_catalog() to authenticated, service_role;

-- Набор языков допустим: 1…24 кода из каталога, без повторов и NULL.
create or replace function public._spec_langs_valid(p_langs text[]) returns boolean
language sql
immutable
set search_path = public
as $$
  select p_langs is not null
     and cardinality(p_langs) between 1 and 24
     and array_ndims(p_langs) = 1
     and not exists (select 1 from unnest(p_langs) l where l is null)
     and (select count(distinct l) from unnest(p_langs) l) = cardinality(p_langs)
     and p_langs <@ public._spec_lang_catalog();
$$;
revoke all on function public._spec_langs_valid(text[]) from public, anon, authenticated;
grant execute on function public._spec_langs_valid(text[]) to authenticated, service_role;

-- Столбцы devices.
alter table public.devices add column if not exists spec_pumps int not null default 4;
alter table public.devices add column if not exists spec_langs text[] not null default '{et,en,ru}';
alter table public.devices add column if not exists spec_default_lang text not null default 'et';
alter table public.devices add column if not exists hardware_profile text not null default 'sy156-a510';

alter table public.devices drop constraint if exists devices_spec_pumps_chk;
alter table public.devices add constraint devices_spec_pumps_chk
  check (spec_pumps between 4 and 10);
alter table public.devices drop constraint if exists devices_spec_langs_chk;
alter table public.devices add constraint devices_spec_langs_chk
  check (public._spec_langs_valid(spec_langs));
alter table public.devices drop constraint if exists devices_spec_default_lang_chk;
alter table public.devices add constraint devices_spec_default_lang_chk
  check (spec_default_lang = any (spec_langs));
alter table public.devices drop constraint if exists devices_hardware_profile_chk;
alter table public.devices add constraint devices_hardware_profile_chk
  check (length(hardware_profile) between 1 and 64);

-- Запись спецификации — только через функцию (прямого update у клиентов нет).
-- Изготовитель организации аппарата (как access_set_valid_until) или service
-- role. Аппарат с привязанным клиентом изменять можно (решает изготовитель).
-- Ответы единые: {ok:false,error:'forbidden'|'not_found'|'bad_request'}.
-- «not_found» получает только изготовитель/service (не раскрывает существование
-- аппаратов остальным: им в обоих случаях «forbidden»).
create or replace function public.device_set_spec(
  p_device_id text,
  p_pumps     int,
  p_langs     text[],
  p_default   text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_old public.devices%rowtype;
  v_ok  boolean;
begin
  select * into v_old from public.devices where id = p_device_id;
  v_org := v_old.org_id;

  if v_org is null then
    -- аппарата нет: «not_found» только тем, кто вообще вправе менять spec
    v_ok := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '')
              = 'service_role'
         or exists (select 1 from public.org_members m
                     where m.user_id = auth.uid() and public.is_staff(m.org_id));
    return jsonb_build_object('ok', false, 'error', case when v_ok then 'not_found' else 'forbidden' end);
  end if;
  if not public.is_staff_or_service(v_org) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  if p_pumps is null or p_pumps not between 4 and 10
     or not public._spec_langs_valid(p_langs)
     or p_default is null or not (p_default = any (p_langs)) then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;

  update public.devices
     set spec_pumps = p_pumps, spec_langs = p_langs, spec_default_lang = p_default
   where id = p_device_id;

  perform public.staff_audit_add(v_org, 'device_set_spec', p_device_id,
    jsonb_build_object(
      'pumps', p_pumps, 'langs', to_jsonb(p_langs), 'default_lang', p_default,
      'prev_pumps', v_old.spec_pumps, 'prev_langs', to_jsonb(v_old.spec_langs),
      'prev_default_lang', v_old.spec_default_lang));
  return jsonb_build_object('ok', true, 'pumps', p_pumps, 'langs', to_jsonb(p_langs),
                            'default_lang', p_default);
end;
$$;
revoke all on function public.device_set_spec(text, int, text[], text) from public, anon;
grant execute on function public.device_set_spec(text, int, text[], text) to authenticated, service_role;

-- Права на чтение новых столбцов (правило проекта: у authenticated права на
-- devices выданы ПО СТОЛБЦАМ; token закрыт и здесь НЕ трогается). Читать их
-- сможет только член организации (политика dev_read/RLS devices).
grant select (spec_pumps, spec_langs, spec_default_lang, hardware_profile)
  on public.devices to authenticated;

-- Схема PostgREST кэшируется: чтобы API увидел столбцы и функцию.
notify pgrst, 'reload schema';
