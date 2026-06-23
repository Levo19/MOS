-- 220_wh_config.sql — getConfig/setConfig de WH 100% Supabase (Frente 4). wh.config (clave/valor/descripcion)
-- ya existe y está poblada (DIAS_ALERTA_VENC, EMPRESA_*, etc.). Las PRINTNODE keys son null acá (viven en
-- secrets de la Edge `imprimir`) → no se exponen. get devuelve {ok,data:{clave:valor}} (mismo shape GAS).
create or replace function wh.get_config(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_data jsonb;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_object_agg(clave, valor), '{}'::jsonb) into v_data
    from wh.config where clave not ilike '%API_KEY%' and clave not ilike '%SECRET%';  -- nunca exponer secretos
  return jsonb_build_object('ok', true, 'data', v_data);
end;
$fn$;

create or replace function wh.set_config(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_clave text := nullif(btrim(coalesce(p->>'clave','')), '');
begin
  if coalesce((select valor from mos.config where clave='WH_CONFIG_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_CONFIG_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_clave is null then return jsonb_build_object('ok',false,'error','clave requerida'); end if;
  -- no permitir setear secretos desde el cliente
  if v_clave ilike '%API_KEY%' or v_clave ilike '%SECRET%' then return jsonb_build_object('ok',false,'error','SECRETO_NO_PERMITIDO'); end if;
  insert into wh.config (clave, valor, descripcion) values (v_clave, p->>'valor', coalesce(p->>'descripcion',''))
    on conflict (clave) do update set valor = excluded.valor;
  return jsonb_build_object('ok', true);
end;
$fn$;

insert into mos.config (clave, valor, descripcion) values
  ('WH_CONFIG_DIRECTO','1','WH: set_config directo a wh.config (no GAS). Lectura get_config siempre directa.')
on conflict (clave) do nothing;

revoke all on function wh.get_config(jsonb) from public;
revoke all on function wh.set_config(jsonb) from public;
grant execute on function wh.get_config(jsonb) to authenticated;
grant execute on function wh.set_config(jsonb) to authenticated;
