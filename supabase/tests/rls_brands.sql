-- ============================================================
-- Проверка BRAND1 (бренды дистрибьюторов): права, согласие, лимиты.
-- По образцу rls_remote_diag.sql.
-- НЕ применять к рабочей базе: запускать на копии/тестовом проекте под
-- полными правами (SQL Editor) ПОСЛЕ миграции
-- 20261106000000_brand1_brands.sql.
-- Всё в одной транзакции, в конце rollback — данные не остаются.
--
-- Что подставить:
--   <SUPERVISOR_UUID>  пользователь, для которого is_portal_supervisor() = true
--   <CUSTOMER_UUID>    клиент с доступом к <DEVICE_ID> (device_access)
--   <DEVICE_ID>        аппарат клиента
--   <DEVICE_TOKEN>     токен <DEVICE_ID> (только на тестовом проекте!)
-- Каждая проверка пишет в «Messages» строку ok или ОШИБКА.
-- ============================================================
begin;

-- Тестовый бренд с одной версией. Вставляем напрямую (под полными правами),
-- потому что обычный путь — Edge Function brand-upload.
insert into public.brands (id, name) values ('acmetest', 'ACME Test')
on conflict (id) do nothing;
insert into public.brand_versions (
  brand_id, version, sha256, size_bytes, path, manifest,
  logo_consent, consent_note, contrast_ok, created_by)
values ('acmetest', 1, repeat('a', 64), 2048, 'acmetest/v1.zip',
        jsonb_build_object('schema', 1, 'id', 'acmetest', 'version', 1,
          'name', 'ACME Test', 'slogan', 'Test slogan', 'logo', 'logo.png',
          'colors', jsonb_build_object(
            'primary', '#2EC4B6', 'primaryAlt', '#00C6B2',
            'background', '#1A1A1A', 'backgroundStandby', '#0B2545',
            'surface', '#2E2E2E', 'textPrimary', '#FFFFFF',
            'textSecondary', '#8899AA')),
        true, 'проверка прав, тестовые данные', true, '<SUPERVISOR_UUID>')
on conflict do nothing;
update public.brands set current_version = 1 where id = 'acmetest';

-- ---------- ограничения таблиц ----------

-- Версия без согласия на логотип не вставляется ВООБЩЕ (кроме carfog).
do $$ begin
  insert into public.brand_versions (
    brand_id, version, sha256, size_bytes, path, manifest,
    logo_consent, consent_note, contrast_ok, created_by)
  values ('acmetest', 99, repeat('b', 64), 10, 'acmetest/v99.zip', '{}'::jsonb,
          false, 'нет согласия', true, '<SUPERVISOR_UUID>');
  raise notice 'ОШИБКА: версия без согласия на логотип вставилась';
exception when check_violation then
  raise notice 'ok: версия без согласия на логотип отклонена ограничением';
end $$;

-- Версия без пройденного контраста не вставляется.
do $$ begin
  insert into public.brand_versions (
    brand_id, version, sha256, size_bytes, path, manifest,
    logo_consent, consent_note, contrast_ok, created_by)
  values ('acmetest', 98, repeat('c', 64), 10, 'acmetest/v98.zip', '{}'::jsonb,
          true, 'есть согласие', false, '<SUPERVISOR_UUID>');
  raise notice 'ОШИБКА: версия с непройденным контрастом вставилась';
exception when check_violation then
  raise notice 'ok: версия с непройденным контрастом отклонена ограничением';
end $$;

-- Пустая заметка о согласии не проходит.
do $$ begin
  insert into public.brand_versions (
    brand_id, version, sha256, size_bytes, path, manifest,
    logo_consent, consent_note, contrast_ok, created_by)
  values ('acmetest', 97, repeat('d', 64), 10, 'acmetest/v97.zip', '{}'::jsonb,
          true, '  ', true, '<SUPERVISOR_UUID>');
  raise notice 'ОШИБКА: пустая заметка о согласии прошла';
exception when check_violation then
  raise notice 'ok: пустая заметка о согласии отклонена';
end $$;

-- id бренда по шаблону, sha256 — 64 hex, размер в пределах 1 МБ.
do $$ begin
  insert into public.brands (id, name) values ('ACME', 'x');
  raise notice 'ОШИБКА: id бренда не по шаблону прошёл';
exception when check_violation then raise notice 'ok: id бренда проверяется шаблоном';
end $$;
do $$ begin
  insert into public.brand_versions (
    brand_id, version, sha256, size_bytes, path, manifest,
    logo_consent, consent_note, contrast_ok, created_by)
  values ('acmetest', 96, 'nothex', 10, 'acmetest/v96.zip', '{}'::jsonb,
          true, 'заметка', true, '<SUPERVISOR_UUID>');
  raise notice 'ОШИБКА: sha256 не из 64 hex прошёл';
exception when check_violation then raise notice 'ok: sha256 проверяется';
end $$;
do $$ begin
  insert into public.brand_versions (
    brand_id, version, sha256, size_bytes, path, manifest,
    logo_consent, consent_note, contrast_ok, created_by)
  values ('acmetest', 95, repeat('e', 64), 1048577, 'acmetest/v95.zip', '{}'::jsonb,
          true, 'заметка', true, '<SUPERVISOR_UUID>');
  raise notice 'ОШИБКА: архив больше 1 МБ прошёл';
exception when check_violation then raise notice 'ok: размер архива ограничен 1 МБ';
end $$;

-- ---------- клиент организации ----------
select set_config('request.jwt.claims',
  '{"sub":"<CUSTOMER_UUID>","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;

do $$
declare r jsonb;
begin
  r := public.supervisor_brand_list();
  if r->>'error' = 'forbidden' then raise notice 'ok: клиент не видит список брендов';
  else raise notice 'ОШИБКА: клиент увидел список брендов: %', r; end if;

  r := public.supervisor_brand_assign('<DEVICE_ID>', 'acmetest');
  if r->>'error' = 'forbidden' then raise notice 'ok: клиент не привязывает бренд';
  else raise notice 'ОШИБКА: клиент привязал бренд: %', r; end if;

  r := public.supervisor_brand_set_current('acmetest', 1);
  if r->>'error' = 'forbidden' then raise notice 'ok: клиент не меняет текущую версию';
  else raise notice 'ОШИБКА: клиент сменил текущую версию: %', r; end if;

  r := public.supervisor_brand_preview('acmetest', 1);
  if r->>'error' = 'forbidden' then raise notice 'ok: клиент не видит предпросмотр';
  else raise notice 'ОШИБКА: клиент увидел предпросмотр: %', r; end if;

  r := public.supervisor_brand_check();
  if r->>'error' = 'forbidden' then raise notice 'ok: клиент не проходит проверку супервайзера';
  else raise notice 'ОШИБКА: клиент прошёл проверку супервайзера: %', r; end if;
end $$;

-- Таблицы закрыты напрямую.
do $$ begin
  perform 1 from public.brands limit 1;
  raise notice 'ОШИБКА: authenticated читает brands напрямую';
exception when insufficient_privilege then raise notice 'ok: brands закрыта для authenticated';
end $$;
do $$ begin
  perform 1 from public.brand_versions limit 1;
  raise notice 'ОШИБКА: authenticated читает brand_versions напрямую';
exception when insufficient_privilege then raise notice 'ok: brand_versions закрыта для authenticated';
end $$;
do $$ begin
  perform 1 from public.brand_url_requests limit 1;
  raise notice 'ОШИБКА: authenticated читает brand_url_requests напрямую';
exception when insufficient_privilege then raise notice 'ok: brand_url_requests закрыта для authenticated';
end $$;

-- Бакет brand-packs: политик нет вовсе, значит видно 0 файлов.
do $$
declare n int;
begin
  select count(*) into n from storage.objects where bucket_id = 'brand-packs';
  if n = 0 then raise notice 'ok: authenticated не видит файлы brand-packs';
  else raise notice 'ОШИБКА: authenticated видит % файлов brand-packs', n; end if;
end $$;

-- Регистрация версии и путь архива — только сервисный ключ.
do $$ begin
  perform public._brand_version_register('acmetest', 'ACME', 2, repeat('a', 64), 10,
    'acmetest/v2.zip', '{}'::jsonb, true, 'заметка', true, '<SUPERVISOR_UUID>');
  raise notice 'ОШИБКА: authenticated вызвал _brand_version_register';
exception when insufficient_privilege then
  raise notice 'ok: _brand_version_register закрыта для authenticated';
end $$;
do $$ begin
  perform public.device_brand_path('acmetest', 1);
  raise notice 'ОШИБКА: authenticated вызвал device_brand_path';
exception when insufficient_privilege then
  raise notice 'ok: device_brand_path закрыта для authenticated';
end $$;
do $$ begin
  perform public.device_brand_get('<DEVICE_ID>', '<DEVICE_TOKEN>');
  raise notice 'ОШИБКА: authenticated вызвал device_brand_get';
exception when insufficient_privilege then
  raise notice 'ok: device_brand_get закрыта для authenticated';
end $$;
do $$ begin
  perform public._brand_for_device('<DEVICE_ID>');
  raise notice 'ОШИБКА: authenticated вызвал _brand_for_device';
exception when insufficient_privilege then
  raise notice 'ok: _brand_for_device закрыта для authenticated';
end $$;

reset role;

-- ---------- anon: только device_* ----------
set local role anon;
do $$ begin
  perform public.supervisor_brand_list();
  raise notice 'ОШИБКА: anon вызвал supervisor_brand_list';
exception when insufficient_privilege then raise notice 'ok: anon не вызывает supervisor_brand_list';
end $$;
do $$ begin
  perform public._brand_version_register('acmetest', 'ACME', 2, repeat('a', 64), 10,
    'acmetest/v2.zip', '{}'::jsonb, true, 'заметка', true, '<SUPERVISOR_UUID>');
  raise notice 'ОШИБКА: anon вызвал _brand_version_register';
exception when insufficient_privilege then raise notice 'ok: anon не вызывает _brand_version_register';
end $$;
do $$ begin
  perform public.device_brand_path('acmetest', 1);
  raise notice 'ОШИБКА: anon вызвал device_brand_path';
exception when insufficient_privilege then raise notice 'ok: anon не вызывает device_brand_path';
end $$;

-- ЧУЖОЙ ТОКЕН: отказ 'auth', бренда не видно.
do $$
declare r jsonb;
begin
  r := public.device_brand_get('<DEVICE_ID>', 'определённо-неверный-токен');
  if r->>'error' = 'auth' then raise notice 'ok: чужой токен — auth';
  else raise notice 'ОШИБКА: чужой токен прошёл: %', r; end if;
end $$;
reset role;

-- ---------- супервайзер без 2FA ----------
select set_config('request.jwt.claims',
  '{"sub":"<SUPERVISOR_UUID>","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
do $$
declare r jsonb; n int;
begin
  r := public.supervisor_brand_list();
  if r->>'error' = 'mfa_required' then raise notice 'ok: без 2FA список брендов закрыт';
  else raise notice 'ОШИБКА: без 2FA список брендов открыт: %', r; end if;

  r := public.supervisor_brand_assign('<DEVICE_ID>', 'acmetest');
  if r->>'error' = 'mfa_required' then raise notice 'ok: без 2FA привязка закрыта';
  else raise notice 'ОШИБКА: без 2FA привязка прошла: %', r; end if;

  r := public.supervisor_brand_set_current('acmetest', 1);
  if r->>'error' = 'mfa_required' then raise notice 'ok: без 2FA смена версии закрыта';
  else raise notice 'ОШИБКА: без 2FA версия сменена: %', r; end if;

  r := public.supervisor_brand_check();
  if r->>'error' = 'mfa_required' then raise notice 'ok: без 2FA brand-upload не пропустит';
  else raise notice 'ОШИБКА: без 2FA проверка пройдена: %', r; end if;

  select count(*) into n from storage.objects where bucket_id = 'brand-packs';
  if n = 0 then raise notice 'ok: без 2FA файлы brand-packs не видны';
  else raise notice 'ОШИБКА: без 2FA видны файлы brand-packs'; end if;
end $$;
reset role;

-- ---------- супервайзер с 2FA ----------
select set_config('request.jwt.claims',
  '{"sub":"<SUPERVISOR_UUID>","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
do $$
declare r jsonb; b jsonb;
begin
  r := public.supervisor_brand_check();
  if r->>'ok' = 'true' and r->>'actor' = '<SUPERVISOR_UUID>' then
    raise notice 'ok: супервайзер с 2FA опознан, актор для аудита есть';
  else raise notice 'ОШИБКА: проверка супервайзера: %', r; end if;

  r := public.supervisor_brand_list();
  if r->>'ok' = 'true' and jsonb_array_length(r->'brands') >= 2 then
    raise notice 'ok: список брендов (carfog и acmetest) виден';
  else raise notice 'ОШИБКА: список брендов: %', r; end if;

  -- Встроенный бренд в списке помечен и версий не имеет.
  select x into b from jsonb_array_elements(r->'brands') x where x->>'id' = 'carfog';
  if b->>'builtin' = 'true' and jsonb_array_length(b->'versions') = 0 then
    raise notice 'ok: carfog помечен встроенным и без версий';
  else raise notice 'ОШИБКА: запись carfog: %', b; end if;

  -- Число привязанных аппаратов считается.
  select x into b from jsonb_array_elements(r->'brands') x where x->>'id' = 'acmetest';
  if (b->>'devices')::int >= 0 and b->>'current_version' = '1' then
    raise notice 'ok: у acmetest текущая версия 1 и счётчик аппаратов';
  else raise notice 'ОШИБКА: запись acmetest: %', b; end if;

  r := public.supervisor_brand_preview('acmetest', 1);
  if r->>'ok' = 'true' and r->'manifest'->'colors'->>'primary' = '#2EC4B6' then
    raise notice 'ok: предпросмотр отдаёт манифест с цветами';
  else raise notice 'ОШИБКА: предпросмотр: %', r; end if;

  -- Предпросмотр без номера версии берёт текущую.
  r := public.supervisor_brand_preview('acmetest');
  if r->>'version' = '1' then raise notice 'ok: предпросмотр по умолчанию — текущая версия';
  else raise notice 'ОШИБКА: предпросмотр без версии: %', r; end if;

  r := public.supervisor_brand_preview('acmetest', 42);
  if r->>'error' = 'not_found' then raise notice 'ok: несуществующая версия — not_found';
  else raise notice 'ОШИБКА: предпросмотр чужой версии: %', r; end if;

  -- Привязка и снятие.
  r := public.supervisor_brand_assign('<DEVICE_ID>', 'acmetest');
  if r->>'ok' = 'true' and r->>'brand' = 'acmetest' then
    raise notice 'ok: бренд привязан к аппарату';
  else raise notice 'ОШИБКА: привязка: %', r; end if;

  r := public.supervisor_brand_assign('<DEVICE_ID>', null);
  if r->>'ok' = 'true' and r->'brand' = 'null'::jsonb then
    raise notice 'ok: бренд снят, аппарат вернулся на встроенный CaRFog';
  else raise notice 'ОШИБКА: снятие бренда: %', r; end if;

  -- 'carfog' равен снятию бренда.
  r := public.supervisor_brand_assign('<DEVICE_ID>', 'carfog');
  if r->>'ok' = 'true' and r->'brand' = 'null'::jsonb then
    raise notice 'ok: привязка carfog = встроенный бренд (null)';
  else raise notice 'ОШИБКА: привязка carfog: %', r; end if;

  r := public.supervisor_brand_assign('<DEVICE_ID>', 'нет-такого');
  if r->>'error' = 'no_brand' then raise notice 'ok: несуществующий бренд — no_brand';
  else raise notice 'ОШИБКА: привязка несуществующего: %', r; end if;

  r := public.supervisor_brand_assign('НЕТ-ТАКОГО-АППАРАТА', 'acmetest');
  if r->>'error' = 'no_device' then raise notice 'ok: несуществующий аппарат — no_device';
  else raise notice 'ОШИБКА: привязка к несуществующему аппарату: %', r; end if;

  r := public.supervisor_brand_set_current('acmetest', 42);
  if r->>'error' = 'no_version' then raise notice 'ok: текущей нельзя сделать несуществующую версию';
  else raise notice 'ОШИБКА: смена на несуществующую версию: %', r; end if;

  r := public.supervisor_brand_set_current('acmetest', 1);
  if r->>'ok' = 'true' then raise notice 'ok: текущая версия назначена (откат допустим)';
  else raise notice 'ОШИБКА: смена версии: %', r; end if;
end $$;

-- Действия супервайзера попали в журнал.
do $$
declare n int;
begin
  select count(*) into n from public.staff_audit
   where action in ('supervisor_brand_assign', 'supervisor_brand_set_current')
     and at > now() - interval '5 minutes';
  if n >= 2 then raise notice 'ok: действия с брендом записаны в staff_audit (%)', n;
  else raise notice 'ОШИБКА: в staff_audit нет записей о брендах (%)', n; end if;
end $$;
reset role;

-- ---------- аппарат: device_brand_get и device_poll ----------
-- Токен проверяется по хешу, поэтому вызываем от anon с настоящим токеном.
set local role anon;

-- Бренда у аппарата нет (его сняли выше) — ok:true и brand:null.
do $$
declare r jsonb;
begin
  r := public.device_brand_get('<DEVICE_ID>', '<DEVICE_TOKEN>');
  if r->>'ok' = 'true' and r->'brand' = 'null'::jsonb then
    raise notice 'ok: без бренда аппарат получает brand:null (встроенный CaRFog)';
  else raise notice 'ОШИБКА: ответ без бренда: %', r; end if;

  -- ЛИМИТ ЧАСТОТЫ: второй вызов в те же 30 с.
  r := public.device_brand_get('<DEVICE_ID>', '<DEVICE_TOKEN>');
  if r->>'error' = 'rate_limited' then raise notice 'ok: второй запрос за 30 с — rate_limited';
  else raise notice 'ОШИБКА: лимит частоты не работает: %', r; end if;
end $$;

-- device_poll отдаёт поле brand (null, пока бренда нет) и не потерял target.
do $$
declare r jsonb;
begin
  r := public.device_poll('<DEVICE_ID>', '<DEVICE_TOKEN>', '1.12.1+58', null);
  if r->>'ok' = 'true' and r ? 'brand' and r->'brand' = 'null'::jsonb then
    raise notice 'ok: device_poll отдаёт brand:null для аппарата без бренда';
  else raise notice 'ОШИБКА: device_poll без бренда: %', r; end if;
  if r ? 'commands' and r ? 'config' and r ? 'server_time' and r ? 'target' then
    raise notice 'ok: прежние поля device_poll на месте';
  else raise notice 'ОШИБКА: device_poll потерял поля: %', r; end if;
end $$;
reset role;

-- Привязываем бренд и смотрим, что аппарат его видит.
update public.devices set brand_id = 'acmetest' where id = '<DEVICE_ID>';
delete from public.brand_url_requests where device_id = '<DEVICE_ID>';

set local role anon;
do $$
declare r jsonb;
begin
  r := public.device_brand_get('<DEVICE_ID>', '<DEVICE_TOKEN>');
  if r->'brand'->>'id' = 'acmetest' and r->'brand'->>'version' = '1'
     and r->'brand'->>'sha256' = repeat('a', 64) then
    raise notice 'ok: аппарат получает ТОЛЬКО свой бренд: %', r->'brand';
  else raise notice 'ОШИБКА: бренд аппарата: %', r; end if;

  -- Ссылки здесь нет: её выдаёт Edge Function brand-url.
  if not (r->'brand' ? 'url') and not (r->'brand' ? 'path') then
    raise notice 'ok: device_brand_get не отдаёт ни ссылку, ни путь';
  else raise notice 'ОШИБКА: device_brand_get отдал ссылку или путь: %', r; end if;

  r := public.device_poll('<DEVICE_ID>', '<DEVICE_TOKEN>', '1.12.1+58', null);
  if r->'brand'->>'id' = 'acmetest' then
    raise notice 'ok: device_poll отдаёт бренд аппарата';
  else raise notice 'ОШИБКА: device_poll с брендом: %', r; end if;
end $$;
reset role;

-- Бренд без годной версии привязать нельзя.
insert into public.brands (id, name) values ('emptytest', 'Empty Test')
on conflict (id) do nothing;
select set_config('request.jwt.claims',
  '{"sub":"<SUPERVISOR_UUID>","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
do $$
declare r jsonb;
begin
  r := public.supervisor_brand_assign('<DEVICE_ID>', 'emptytest');
  if r->>'error' = 'no_version' then raise notice 'ok: бренд без версии не привязывается';
  else raise notice 'ОШИБКА: привязался бренд без версии: %', r; end if;
end $$;
reset role;

rollback;
