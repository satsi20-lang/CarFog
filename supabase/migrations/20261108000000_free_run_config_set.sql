-- Бесплатный запуск по коду (только CARFOG-001 и только по решению владельца).
-- Супервайзер (aal2) отправляет аппарату update_config с белым списком ключей:
-- free_run_enabled, free_run_code_hash, free_run_code_salt и данные продавца
-- (qr_url, seller_*). customer_send_command такие ключи не пропускает (только
-- цена и длительность), поэтому нужна отдельная супервайзерская функция.
--
-- НЕ ПРИМЕНЕНО. Применяет ассистент после отдельного «да» владельца.
--
-- Что в базе остаётся: хеш и соль кода лежат в таблице commands (params) —
-- как у любой команды. Сам код сюда не попадает: хеш считает браузер
-- (PBKDF2-HMAC-SHA256, 10 000 итераций, соль 16 байт, 32 байта на выходе).
-- В staff_audit пишутся только ИМЕНА ключей, значения — нет.

create or replace function public.supervisor_device_config_set(
  p_device text,
  p_patch  jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_denied text := public._diag_supervisor_denied();
  v_patch  jsonb := coalesce(p_patch, '{}'::jsonb);
  v_org    uuid;
  v_key    text;
  v_val    jsonb;
  v_id     text;
  v_keys   text[] := '{}';
begin
  if v_denied is not null then
    return jsonb_build_object('ok', false, 'error', v_denied);
  end if;
  if jsonb_typeof(v_patch) <> 'object' or v_patch = '{}'::jsonb then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;
  select org_id into v_org from public.devices where id = p_device;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_device');
  end if;

  for v_key, v_val in select key, value from jsonb_each(v_patch) loop
    if v_key not in ('free_run_enabled', 'free_run_code_hash', 'free_run_code_salt',
                     'qr_url', 'seller_phone', 'seller_email', 'seller_site', 'seller_legal') then
      return jsonb_build_object('ok', false, 'error', 'key_not_allowed');
    end if;
    if v_key = 'free_run_enabled' and jsonb_typeof(v_val) <> 'boolean' then
      return jsonb_build_object('ok', false, 'error', 'bad_params');
    end if;
    -- хеш: 32 байта в hex; соль: 16 байт в hex
    if v_key = 'free_run_code_hash'
       and (jsonb_typeof(v_val) <> 'string' or (v_val #>> '{}') !~ '^[0-9a-f]{64}$') then
      return jsonb_build_object('ok', false, 'error', 'bad_params');
    end if;
    if v_key = 'free_run_code_salt'
       and (jsonb_typeof(v_val) <> 'string' or (v_val #>> '{}') !~ '^[0-9a-f]{32}$') then
      return jsonb_build_object('ok', false, 'error', 'bad_params');
    end if;
    -- данные продавца: строка до 300 знаков (точную проверку делает приложение)
    if v_key like 'seller\_%' or v_key = 'qr_url' then
      if jsonb_typeof(v_val) <> 'string' or char_length(v_val #>> '{}') > 300 then
        return jsonb_build_object('ok', false, 'error', 'bad_params');
      end if;
    end if;
    v_keys := v_keys || v_key;
  end loop;

  insert into public.commands(device_id, org_id, action, params)
  values (p_device, v_org, 'update_config', v_patch)
  returning id::text into v_id;

  -- В журнал аудита — только имена ключей, без значений (хеша и соли).
  perform public.staff_audit_add(v_org, 'supervisor_device_config_set', p_device,
    jsonb_build_object('keys', to_jsonb(v_keys)));

  return jsonb_build_object('ok', true, 'command_id', v_id);
end;
$$;

revoke all on function public.supervisor_device_config_set(text, jsonb) from public, anon;
grant execute on function public.supervisor_device_config_set(text, jsonb) to authenticated;
