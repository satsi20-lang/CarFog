-- Применено в боевой базе 2026-10-18 через MCP; файл фиксирует схему в репозитории.
-- ============================================================
-- Права на функции.
--  * device_* (вход аппарата по токену) — только anon и service_role;
--    у public и authenticated отозваны.
--  * is_org_member / is_staff (используются в политиках RLS) — только
--    authenticated и service_role; у public и anon отозваны.
--  * _claim_hash: фиксированный search_path.
-- ============================================================

revoke execute on function public.device_poll(text,text,text,jsonb) from public, authenticated;
revoke execute on function public.device_report(text,text,jsonb) from public, authenticated;
revoke execute on function public.device_ack(text,text,uuid,boolean,text) from public, authenticated;
revoke execute on function public.device_diag_put(text,text,text,integer,integer,text) from public, authenticated;
revoke execute on function public.device_release_get(text,text,uuid) from public, authenticated;
grant execute on function public.device_poll(text,text,text,jsonb) to anon, service_role;
grant execute on function public.device_report(text,text,jsonb) to anon, service_role;
grant execute on function public.device_ack(text,text,uuid,boolean,text) to anon, service_role;
grant execute on function public.device_diag_put(text,text,text,integer,integer,text) to anon, service_role;
grant execute on function public.device_release_get(text,text,uuid) to anon, service_role;
revoke execute on function public.is_org_member(uuid) from public, anon;
revoke execute on function public.is_staff(uuid) from public, anon;
grant execute on function public.is_org_member(uuid) to authenticated, service_role;
grant execute on function public.is_staff(uuid) to authenticated, service_role;
alter function public._claim_hash(text, text) set search_path = public;
