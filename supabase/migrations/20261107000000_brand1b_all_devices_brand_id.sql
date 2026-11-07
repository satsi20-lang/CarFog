-- Применено ассистентом 2026-11-07 по «да» владельца; добавляет brand_id в ответ
-- supervisor_all_devices; остальное без изменений.
-- (Нужно порталу: раздел «Бренды» показывает, какой бренд назначен аппарату.
-- null = встроенный CaRFog.)

create or replace function public.supervisor_all_devices()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  if not public.is_portal_supervisor() then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  return jsonb_build_object('ok', true, 'devices', coalesce((
    select jsonb_agg(jsonb_build_object(
      'device_id', d.id, 'name', d.name, 'app_version', d.app_version,
      'last_seen_at', d.last_seen_at,
      'online', coalesce(d.last_seen_at > now() - interval '10 minutes', false),
      'customer_email', u.email, 'company_name', p.company_name,
      'label', da.label, 'valid_until', da.valid_until,
      'active', coalesce(da.valid_until > now(), false),
      'sub_status', s.status,
      'brand_id', d.brand_id) order by d.id)
    from public.devices d
    left join public.device_access da on da.device_id = d.id and da.ended_at is null
    left join auth.users u on u.id = da.customer_id
    left join public.customer_profiles p on p.customer_id = da.customer_id
    left join public.device_subscriptions s on s.device_id = d.id
  ), '[]'::jsonb));
end;
$function$;
