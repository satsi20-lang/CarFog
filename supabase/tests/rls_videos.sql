-- ============================================================
-- Проверка VIDEO1 (видео заставки через портал): права, лимиты, поток
-- состояний. По образцу rls_brands.sql.
-- НЕ применять к рабочей базе: запускать на копии/тестовом проекте под
-- полными правами (SQL Editor) ПОСЛЕ миграции
-- 20261109000000_video1_playlist.sql.
-- Всё в одной транзакции, в конце rollback — данные не остаются.
--
-- Что подставить:
--   <SUPERVISOR_UUID>  пользователь, для которого is_portal_supervisor() = true
--                      (без device_access к <DEVICE_ID>)
--   <CUSTOMER_UUID>    клиент с доступом к <DEVICE_ID> (device_access)
--   <DEVICE_ID>        аппарат клиента
--   <OTHER_DEVICE_ID>  другой аппарат (у клиента к нему доступа нет)
--   <DEVICE_TOKEN>     токен <DEVICE_ID> (только на тестовом проекте!)
-- Каждая проверка пишет в «Messages» строку ok или ОШИБКА.
-- ============================================================
begin;

create temp table _v (name text primary key, id uuid);
grant all on _v to public;

-- ---------- ограничения таблицы (под полными правами) ----------
do $$ begin
  insert into public.device_videos (device_id, title, source, sha256, size_bytes, storage_path)
  values ('<DEVICE_ID>', '   ', 'upload', repeat('a', 64), 10, 'x/y.mp4');
  raise notice 'ОШИБКА: пустое название прошло';
exception when check_violation then raise notice 'ok: пустое название отклонено';
end $$;
do $$ begin
  insert into public.device_videos (device_id, title, source, sha256, size_bytes, storage_path)
  values ('<DEVICE_ID>', repeat('я', 121), 'upload', repeat('a', 64), 10, 'x/y.mp4');
  raise notice 'ОШИБКА: название длиннее 120 прошло';
exception when check_violation then raise notice 'ok: название ограничено 120 знаками';
end $$;
do $$ begin
  insert into public.device_videos (device_id, title, source, sha256, size_bytes, storage_path)
  values ('<DEVICE_ID>', 'x', 'upload', 'nothex', 10, 'x/y.mp4');
  raise notice 'ОШИБКА: sha256 не из 64 hex прошёл';
exception when check_violation then raise notice 'ok: sha256 проверяется';
end $$;
do $$ begin
  insert into public.device_videos (device_id, title, source, status)
  values ('<DEVICE_ID>', 'x', 'upload', 'ready');
  raise notice 'ОШИБКА: upload без пути, sha и размера прошёл';
exception when check_violation then raise notice 'ok: форма строки upload проверяется';
end $$;
do $$ begin
  insert into public.device_videos (device_id, title, source, status)
  values ('<DEVICE_ID>', 'x', 'sd_local', 'on_device');
  raise notice 'ОШИБКА: sd_local без имени файла прошёл';
exception when check_violation then raise notice 'ok: форма строки sd_local проверяется';
end $$;
do $$ begin
  insert into public.device_videos (device_id, title, source, local_name, status, device_state)
  values ('<DEVICE_ID>', 'x', 'sd_local', 'a.mp4', 'on_device', 'whatever');
  raise notice 'ОШИБКА: произвольное состояние на аппарате прошло';
exception when check_violation then raise notice 'ok: состояние на аппарате проверяется';
end $$;

-- Бакет закрыт и без политик.
do $$
declare n int; pub boolean;
begin
  select public into pub from storage.buckets where id = 'device-videos';
  if pub is false then raise notice 'ok: бакет device-videos закрытый';
  else raise notice 'ОШИБКА: бакет device-videos публичный или не создан'; end if;
  select count(*) into n from pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and (coalesce(qual, '') like '%device-videos%' or coalesce(with_check, '') like '%device-videos%');
  if n = 0 then raise notice 'ok: у бакета device-videos нет политик';
  else raise notice 'ОШИБКА: у бакета device-videos % политик', n; end if;
end $$;

-- ---------- клиент организации ----------
select set_config('request.jwt.claims',
  '{"sub":"<CUSTOMER_UUID>","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;

do $$
declare r jsonb; vid uuid;
begin
  r := public.video_upload_begin('<DEVICE_ID>', 'Ролик 1', 1000, repeat('a', 64));
  if (r->>'ok')::boolean then
    insert into _v values ('c1', (r->>'video_id')::uuid);
    raise notice 'ok: клиент начал загрузку на свой аппарат';
  else raise notice 'ОШИБКА: клиент не начал загрузку: %', r; end if;

  r := public.video_upload_begin('<OTHER_DEVICE_ID>', 'Чужой', 1000, repeat('a', 64));
  if r->>'error' = 'forbidden' then raise notice 'ok: на чужой аппарат клиент загружать не может';
  else raise notice 'ОШИБКА: клиент начал загрузку на чужой аппарат: %', r; end if;

  r := public.video_list('<OTHER_DEVICE_ID>');
  if r->>'error' = 'forbidden' then raise notice 'ok: клиент не видит видео чужого аппарата';
  else raise notice 'ОШИБКА: клиент увидел список чужого аппарата: %', r; end if;

  r := public.video_upload_begin('<DEVICE_ID>', '', 1000, repeat('a', 64));
  if r->>'error' = 'bad_request' then raise notice 'ok: пустое название отклонено функцией';
  else raise notice 'ОШИБКА: пустое название: %', r; end if;
  r := public.video_upload_begin('<DEVICE_ID>', 'x', 0, repeat('a', 64));
  if r->>'error' = 'bad_request' then raise notice 'ok: нулевой размер отклонён';
  else raise notice 'ОШИБКА: нулевой размер: %', r; end if;
  r := public.video_upload_begin('<DEVICE_ID>', 'x', 10, 'ABC');
  if r->>'error' = 'bad_request' then raise notice 'ok: плохой sha256 отклонён';
  else raise notice 'ОШИБКА: плохой sha256: %', r; end if;

  -- Ещё загрузки до предела «в ожидании» (5).
  for i in 1..4 loop
    perform public.video_upload_begin('<DEVICE_ID>', 'Ролик ' || (i + 1), 1000, repeat('a', 64));
  end loop;
  r := public.video_upload_begin('<DEVICE_ID>', 'Лишний', 1000, repeat('a', 64));
  if r->>'error' = 'too_many_pending' then raise notice 'ok: больше 5 загрузок в ожидании нельзя';
  else raise notice 'ОШИБКА: предел загрузок в ожидании: %', r; end if;

  vid := (select id from _v where name = 'c1');
  r := public.video_set_play(vid, true);
  if r->>'error' = 'bad_status' then raise notice 'ok: отметить непроверенное видео нельзя';
  else raise notice 'ОШИБКА: отметили непроверенное: %', r; end if;

  r := public.video_list('<DEVICE_ID>');
  if (r->>'ok')::boolean and not (r::text like '%storage_path%')
     and not (r::text like '%/' || vid::text || '.mp4%') then
    raise notice 'ok: video_list не отдаёт путь в бакете';
  else raise notice 'ОШИБКА: video_list: %', r; end if;
end $$;

-- Прямого доступа к таблице нет.
do $$ declare n int; begin
  select count(*) into n from public.device_videos;
  raise notice 'ОШИБКА: authenticated читает device_videos напрямую (% строк)', n;
exception when insufficient_privilege then
  raise notice 'ok: таблица device_videos закрыта для authenticated';
end $$;
do $$ begin
  insert into public.device_videos (device_id, title, source, local_name, status)
  values ('<DEVICE_ID>', 'x', 'sd_local', 'z.mp4', 'on_device');
  raise notice 'ОШИБКА: authenticated вставил в device_videos';
exception when insufficient_privilege then
  raise notice 'ok: запись в device_videos закрыта для authenticated';
end $$;

-- Служебные функции и функции аппарата закрыты.
do $$ begin
  perform public._video_mark_validated(
    (select id from _v where name = 'c1'), '<CUSTOMER_UUID>', 'customer', 1280, 800, 1000, false);
  raise notice 'ОШИБКА: authenticated вызвал _video_mark_validated';
exception when insufficient_privilege then
  raise notice 'ok: _video_mark_validated закрыта для authenticated';
end $$;
do $$ begin
  perform public._video_mark_rejected(
    (select id from _v where name = 'c1'), '<CUSTOMER_UUID>', 'customer', 'x');
  raise notice 'ОШИБКА: authenticated вызвал _video_mark_rejected';
exception when insufficient_privilege then
  raise notice 'ok: _video_mark_rejected закрыта для authenticated';
end $$;
do $$ begin
  perform public._video_purge_pick(10);
  raise notice 'ОШИБКА: authenticated вызвал _video_purge_pick';
exception when insufficient_privilege then
  raise notice 'ok: _video_purge_pick закрыта для authenticated';
end $$;
do $$ begin
  perform public.device_video_path('<DEVICE_ID>', '<DEVICE_TOKEN>',
    (select id from _v where name = 'c1'));
  raise notice 'ОШИБКА: authenticated вызвал device_video_path';
exception when insufficient_privilege then
  raise notice 'ok: device_video_path закрыта для authenticated';
end $$;
do $$ begin
  perform public.device_videos_get('<DEVICE_ID>', '<DEVICE_TOKEN>');
  raise notice 'ОШИБКА: authenticated вызвал device_videos_get';
exception when insufficient_privilege then
  raise notice 'ok: device_videos_get закрыта для authenticated';
end $$;
do $$ begin
  perform public.device_video_report('<DEVICE_ID>', '<DEVICE_TOKEN>', '[]'::jsonb);
  raise notice 'ОШИБКА: authenticated вызвал device_video_report';
exception when insufficient_privilege then
  raise notice 'ok: device_video_report закрыта для authenticated';
end $$;
reset role;

-- ---------- супервайзер ----------
-- Без 2FA (aal1) — отказ.
select set_config('request.jwt.claims',
  '{"sub":"<SUPERVISOR_UUID>","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
do $$
declare r jsonb;
begin
  r := public.video_list('<OTHER_DEVICE_ID>');
  if r->>'error' = 'mfa_required' then raise notice 'ok: супервайзер без 2FA отклонён';
  else raise notice 'ОШИБКА: супервайзер без 2FA: %', r; end if;
  r := public.video_delete((select id from _v where name = 'c1'));
  if r->>'error' = 'mfa_required' then raise notice 'ok: удаление без 2FA отклонено';
  else raise notice 'ОШИБКА: удаление без 2FA: %', r; end if;
end $$;
reset role;

select set_config('request.jwt.claims',
  '{"sub":"<SUPERVISOR_UUID>","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
do $$
declare r jsonb;
begin
  r := public.video_upload_begin('<OTHER_DEVICE_ID>', 'Супервайзер 1', 5000, repeat('b', 64));
  if (r->>'ok')::boolean then
    insert into _v values ('s1', (r->>'video_id')::uuid);
    raise notice 'ok: супервайзер с 2FA загружает на любой аппарат';
  else raise notice 'ОШИБКА: супервайзер не начал загрузку: %', r; end if;
  r := public.video_list('<DEVICE_ID>');
  if (r->>'ok')::boolean and r->>'role' = 'supervisor' then
    raise notice 'ok: супервайзер видит список любого аппарата';
  else raise notice 'ОШИБКА: список супервайзера: %', r; end if;
end $$;
reset role;

-- ---------- поток состояний (под полными правами = сервисный ключ) ----------
do $$
declare r jsonb; rev0 int; rev1 int; vid uuid := (select id from _v where name = 'c1');
begin
  select videos_rev into rev0 from public.devices where id = '<DEVICE_ID>';
  r := public._video_mark_validating(vid);
  r := public._video_mark_validated(vid, '<CUSTOMER_UUID>', 'customer', 1280, 800, 15000, false);
  select videos_rev into rev1 from public.devices where id = '<DEVICE_ID>';
  if (r->>'ok')::boolean and rev1 = rev0 + 1 then
    raise notice 'ok: проверка пройдена, videos_rev вырос';
  else raise notice 'ОШИБКА: _video_mark_validated: % rev % -> %', r, rev0, rev1; end if;
  r := public._video_mark_validated(vid, '<CUSTOMER_UUID>', 'customer', 1280, 800, 15000, false);
  if r->>'error' = 'bad_status' then raise notice 'ok: повторное «проверено» отклонено';
  else raise notice 'ОШИБКА: повторное «проверено»: %', r; end if;
end $$;

-- Клиент ставит галочку: rev растёт, повтор того же значения — нет.
select set_config('request.jwt.claims',
  '{"sub":"<CUSTOMER_UUID>","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
do $$
declare r jsonb; rev0 int; rev1 int; rev2 int; vid uuid := (select id from _v where name = 'c1');
begin
  select videos_rev into rev0 from public.devices where id = '<DEVICE_ID>';
  r := public.video_set_play(vid, true);
  select videos_rev into rev1 from public.devices where id = '<DEVICE_ID>';
  r := public.video_set_play(vid, true);
  select videos_rev into rev2 from public.devices where id = '<DEVICE_ID>';
  if rev1 = rev0 + 1 and rev2 = rev1 then
    raise notice 'ok: галочка меняет videos_rev, повтор — нет';
  else raise notice 'ОШИБКА: videos_rev по галочке: % % %', rev0, rev1, rev2; end if;
end $$;
reset role;

-- Аппарат: желаемое состояние, лимит частоты, неверный токен.
set local role anon;
do $$
declare r jsonb;
begin
  r := public.device_videos_get('<DEVICE_ID>', 'wrong-token-xxxxxxxx');
  if r->>'error' = 'auth' then raise notice 'ok: неверный токен — auth';
  else raise notice 'ОШИБКА: неверный токен: %', r; end if;
  r := public.device_videos_get('<DEVICE_ID>', '<DEVICE_TOKEN>');
  if (r->>'ok')::boolean and jsonb_array_length(r->'videos') = 1
     and (r->'videos'->0->>'play')::boolean
     and not (r::text like '%storage_path%') then
    raise notice 'ok: аппарат получил набор с отметкой, без пути';
  else raise notice 'ОШИБКА: device_videos_get: %', r; end if;
  r := public.device_videos_get('<DEVICE_ID>', '<DEVICE_TOKEN>');
  if r->>'error' = 'rate_limited' then raise notice 'ok: лимит частоты 30 с';
  else raise notice 'ОШИБКА: лимит частоты: %', r; end if;

  r := public.device_poll('<DEVICE_ID>', '<DEVICE_TOKEN>', '1.13.2+61', null);
  if (r->>'videos_rev') is not null and r ? 'brand' and r ? 'target' then
    raise notice 'ok: device_poll отдаёт videos_rev, остальные поля на месте';
  else raise notice 'ОШИБКА: device_poll: %', r; end if;

  -- Отчёт: скачано + два файла с карты.
  r := public.device_video_report('<DEVICE_ID>', '<DEVICE_TOKEN>', jsonb_build_array(
    jsonb_build_object('kind', 'upload', 'id', (select id from _v where name = 'c1'), 'state', 'present'),
    jsonb_build_object('kind', 'local', 'local_name', 'ручной.mp4', 'size_bytes', 500,
      'width', 1280, 'height', 800, 'duration_ms', 9000, 'deletable', true),
    jsonb_build_object('kind', 'local', 'local_name', 'залочен.mp4', 'size_bytes', 600,
      'deletable', false)));
  if (r->>'ok')::boolean then raise notice 'ok: отчёт принят';
  else raise notice 'ОШИБКА: device_video_report: %', r; end if;
  r := public.device_video_report('<DEVICE_ID>', 'wrong-token-xxxxxxxx', '[]'::jsonb);
  if r->>'error' = 'auth' then raise notice 'ok: отчёт с неверным токеном — auth';
  else raise notice 'ОШИБКА: отчёт с неверным токеном: %', r; end if;
  r := public.device_video_report('<DEVICE_ID>', '<DEVICE_TOKEN>',
    (select jsonb_agg(jsonb_build_object('kind', 'local', 'local_name', 'f' || g || '.mp4'))
       from generate_series(1, 201) g));
  if r->>'error' = 'too_many' then raise notice 'ok: отчёт больше 200 элементов отклонён';
  else raise notice 'ОШИБКА: отчёт на 201 элемент: %', r; end if;
  r := public.device_video_report('<DEVICE_ID>', '<DEVICE_TOKEN>', '{"a":1}'::jsonb);
  if r->>'error' = 'bad_request' then raise notice 'ok: отчёт не-массив отклонён';
  else raise notice 'ОШИБКА: отчёт не-массив: %', r; end if;
end $$;
reset role;

do $$
declare n int; st text; pl boolean;
begin
  select status into st from public.device_videos where id = (select id from _v where name = 'c1');
  if st = 'on_device' then raise notice 'ok: после «present» статус on_device';
  else raise notice 'ОШИБКА: статус после present: %', st; end if;
  select play into pl from public.device_videos
   where device_id = '<DEVICE_ID>' and local_name = 'ручной.mp4';
  if pl is true then raise notice 'ok: файл с карты появился в списке с галочкой (как играл раньше)';
  else raise notice 'ОШИБКА: ручной файл: play=%', pl; end if;
end $$;

-- Файл с карты, который нельзя удалить; и который можно.
select set_config('request.jwt.claims',
  '{"sub":"<CUSTOMER_UUID>","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
do $$
declare r jsonb; lid uuid; nid uuid;
begin
  -- Идентификаторы строк sd_local берём из списка портала.
  select (x->>'id')::uuid into lid from jsonb_array_elements(
    public.video_list('<DEVICE_ID>')->'videos') x where x->>'local_name' = 'ручной.mp4';
  select (x->>'id')::uuid into nid from jsonb_array_elements(
    public.video_list('<DEVICE_ID>')->'videos') x where x->>'local_name' = 'залочен.mp4';
  r := public.video_delete(nid);
  if r->>'error' = 'not_deletable' then raise notice 'ok: файл, который нельзя удалить, — отказ';
  else raise notice 'ОШИБКА: удаление недоступного файла: %', r; end if;
  r := public.video_set_play(nid, false);
  if (r->>'ok')::boolean then raise notice 'ok: галочку с такого файла снять можно';
  else raise notice 'ОШИБКА: снять галочку: %', r; end if;
  r := public.video_delete(lid);
  if r->>'status' = 'delete_requested' then raise notice 'ok: удаление файла с карты — запрос аппарату';
  else raise notice 'ОШИБКА: удаление файла с карты: %', r; end if;
  -- Загруженное и скачанное тоже уходит запросом аппарату.
  r := public.video_delete((select id from _v where name = 'c1'));
  if r->>'status' = 'delete_requested' then raise notice 'ok: удаление скачанного — запрос аппарату';
  else raise notice 'ОШИБКА: удаление скачанного: %', r; end if;
  -- Ожидавшая загрузка, файла у аппарата нет — удаляется сразу.
  r := public.video_list('<DEVICE_ID>');
  select (x->>'id')::uuid into nid from jsonb_array_elements(r->'videos') x
   where x->>'status' = 'pending_upload' limit 1;
  r := public.video_delete(nid);
  if r->>'status' = 'deleted' then raise notice 'ok: удаление без файла на аппарате — сразу deleted';
  else raise notice 'ОШИБКА: удаление ожидающей загрузки: %', r; end if;
end $$;
reset role;

-- Аппарат подтверждает: файлов нет → запросы удаления закрываются.
set local role anon;
do $$ declare r jsonb; n int; begin
  r := public.device_video_report('<DEVICE_ID>', '<DEVICE_TOKEN>',
    jsonb_build_array(jsonb_build_object('kind', 'local', 'local_name', 'залочен.mp4',
      'size_bytes', 600, 'deletable', false)));
end $$;
reset role;
do $$ declare n int; begin
  select count(*) into n from public.device_videos
   where device_id = '<DEVICE_ID>' and status = 'delete_requested';
  if n = 0 then raise notice 'ok: после отчёта без файлов запросы удаления закрыты';
  else raise notice 'ОШИБКА: незакрытых запросов удаления: %', n; end if;
end $$;

-- Журнал: действия клиента и супервайзера записаны.
do $$ declare n int; begin
  select count(*) into n from public.staff_audit
   where action in ('customer_video_upload_begin', 'customer_video_delete',
                    'customer_video_play_on', 'supervisor_video_upload_begin');
  if n >= 4 then raise notice 'ok: действия записаны в журнал (% записей)', n;
  else raise notice 'ОШИБКА: в журнале мало записей: %', n; end if;
end $$;

-- Уборка: удалённое попадает в список на удаление из бакета.
do $$ declare r jsonb; begin
  r := public._video_purge_pick(100);
  if jsonb_typeof(r) = 'array' then raise notice 'ok: _video_purge_pick отвечает списком (% шт.)', jsonb_array_length(r);
  else raise notice 'ОШИБКА: _video_purge_pick: %', r; end if;
end $$;

-- ---------- anon: только device_* ----------
set local role anon;
do $$ begin
  perform public.video_list('<DEVICE_ID>');
  raise notice 'ОШИБКА: anon вызвал video_list';
exception when insufficient_privilege then raise notice 'ok: anon не вызывает video_list';
end $$;
do $$ begin
  perform public.video_upload_begin('<DEVICE_ID>', 'x', 1, repeat('a', 64));
  raise notice 'ОШИБКА: anon вызвал video_upload_begin';
exception when insufficient_privilege then raise notice 'ok: anon не вызывает video_upload_begin';
end $$;
do $$ begin
  perform public._video_mark_validated(gen_random_uuid(), '<CUSTOMER_UUID>', 'customer', 1, 1, 1, false);
  raise notice 'ОШИБКА: anon вызвал _video_mark_validated';
exception when insufficient_privilege then raise notice 'ok: anon не вызывает _video_mark_validated';
end $$;
do $$ begin
  perform public.device_video_path('<DEVICE_ID>', '<DEVICE_TOKEN>', gen_random_uuid());
  raise notice 'ОШИБКА: anon вызвал device_video_path';
exception when insufficient_privilege then raise notice 'ok: anon не вызывает device_video_path';
end $$;
do $$ begin
  perform public.video_access_check(gen_random_uuid());
  raise notice 'ОШИБКА: anon вызвал video_access_check';
exception when insufficient_privilege then raise notice 'ok: anon не вызывает video_access_check';
end $$;
reset role;

rollback;
