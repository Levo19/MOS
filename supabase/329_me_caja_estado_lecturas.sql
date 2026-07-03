-- 329_me_caja_estado_lecturas.sql
-- [CERO-GAS · migración ME] 4 lecturas de estado de caja 100% Supabase (reemplazan GAS cajero_activo,
-- cajeros_activos_todos, caja_activa_zona, retomar_caja_device). Todas READ-ONLY (STABLE) — NO cierran caja.
-- El auto-cierre de zombis (cajas ABIERTA de días previos) YA lo cubren los crons me-autocierre-inactividad
-- (c/15min) + mos-cierre-forzado-11pm (verificado activos), así que estas RPCs sólo OCULTAN los zombis del
-- resultado (filtro día Lima), sin cerrarlos. Template: gate me.jwt_app() in (mosExpress,MOS), grant
-- authenticated+service_role, revoke anon/public. Shapes EXACTOS a los del GAS.

-- 1) retomar_caja_device
create or replace function me.retomar_caja_device(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_dev  text := nullif(btrim(coalesce(p->>'deviceId','')),'');
  v_caja me.cajas%rowtype;
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then
    return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA','encontrada',false);
  end if;
  if v_dev is null then
    return jsonb_build_object('status','error','error','deviceId requerido','encontrada',false);
  end if;
  select * into v_caja from me.cajas
  where upper(coalesce(estado,''))='ABIERTA' and coalesce(printnode_id,'')=v_dev
    and to_char(fecha_apertura at time zone 'America/Lima','YYYY-MM-DD')=to_char(now() at time zone 'America/Lima','YYYY-MM-DD')
  order by fecha_apertura desc nulls last, created_at desc nulls last limit 1;
  if not found then return jsonb_build_object('status','success','encontrada',false); end if;
  return jsonb_build_object('status','success','encontrada',true,
    'idCaja',coalesce(v_caja.id_caja,''), 'vendedor',coalesce(v_caja.vendedor,''),
    'zona',coalesce(v_caja.zona_id,''), 'monto',coalesce(v_caja.monto_inicial,0),
    'fechaApertura', case when v_caja.fecha_apertura is not null then to_char(v_caja.fecha_apertura at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end,
    'estacion', jsonb_build_object('Estacion_Codigo',coalesce(v_caja.estacion,''),'Estacion_Nombre',coalesce(v_caja.estacion,''),'PrintNode_ID',coalesce(nullif(v_caja.printnode_id,''),v_dev)));
end; $fn$;
revoke all on function me.retomar_caja_device(jsonb) from public, anon;
grant execute on function me.retomar_caja_device(jsonb) to authenticated, service_role;

-- 2) caja_activa_zona
create or replace function me.caja_activa_zona(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_zona text := nullif(btrim(coalesce(p->>'zona','')),'');
  v_caja me.cajas%rowtype;
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona is null then return jsonb_build_object('ok',false,'error','zona requerida'); end if;
  select * into v_caja from me.cajas
  where upper(coalesce(estado,''))='ABIERTA' and coalesce(zona_id,'')=v_zona
    and to_char(fecha_apertura at time zone 'America/Lima','YYYY-MM-DD')=to_char(now() at time zone 'America/Lima','YYYY-MM-DD')
  order by fecha_apertura desc nulls last, created_at desc nulls last limit 1;
  if not found then return jsonb_build_object('ok',true,'data',jsonb_build_object('hayCaja',false,'zona',v_zona)); end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'hayCaja',true,'idCaja',coalesce(v_caja.id_caja,''),'cajero',coalesce(v_caja.vendedor,''),
    'estacion',coalesce(v_caja.estacion,''),'montoInicial',coalesce(v_caja.monto_inicial,0),
    'abiertaTs', case when v_caja.fecha_apertura is not null then to_char(v_caja.fecha_apertura at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end,
    'zona',v_zona));
end; $fn$;
revoke all on function me.caja_activa_zona(jsonb) from public, anon;
grant execute on function me.caja_activa_zona(jsonb) to authenticated, service_role;

-- 3) cajero_activo
create or replace function me.cajero_activo(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_zona text := nullif(btrim(coalesce(p->>'zona','')),'');
  v_caja me.cajas%rowtype;
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA','activo',false); end if;
  if v_zona is null then return jsonb_build_object('status','error','error','zona requerida','activo',false); end if;
  select * into v_caja from me.cajas
  where upper(coalesce(estado,''))='ABIERTA' and coalesce(zona_id,'')=v_zona
    and to_char(fecha_apertura at time zone 'America/Lima','YYYY-MM-DD')=to_char(now() at time zone 'America/Lima','YYYY-MM-DD')
  order by fecha_apertura desc nulls last, created_at desc nulls last limit 1;
  if not found then return jsonb_build_object('status','success','activo',false,'cajasAutoCerradas',0); end if;
  return jsonb_build_object('status','success','activo',true,'vendedor',coalesce(v_caja.vendedor,''),
    'idCaja',coalesce(v_caja.id_caja,''),
    'desde', case when v_caja.fecha_apertura is not null then to_char(v_caja.fecha_apertura at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end,
    'cajasAutoCerradas',0);
end; $fn$;
revoke all on function me.cajero_activo(jsonb) from public, anon;
grant execute on function me.cajero_activo(jsonb) to authenticated, service_role;

-- 4) cajeros_activos_todos
create or replace function me.cajeros_activos_todos(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_por jsonb;
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA','porZona','{}'::jsonb); end if;
  select coalesce(jsonb_object_agg(zona_id,obj),'{}'::jsonb) into v_por from (
    select distinct on (coalesce(zona_id,'')) coalesce(zona_id,'') as zona_id,
      jsonb_build_object('vendedor',coalesce(vendedor,''),'idCaja',coalesce(id_caja,''),
        'desde', case when fecha_apertura is not null then to_char(fecha_apertura at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end) as obj
    from me.cajas
    where upper(coalesce(estado,''))='ABIERTA' and coalesce(zona_id,'')<>''
      and to_char(fecha_apertura at time zone 'America/Lima','YYYY-MM-DD')=to_char(now() at time zone 'America/Lima','YYYY-MM-DD')
    order by coalesce(zona_id,''), fecha_apertura desc nulls last, created_at desc nulls last) t;
  return jsonb_build_object('status','success','porZona',v_por,'cajasAutoCerradas',0);
end; $fn$;
revoke all on function me.cajeros_activos_todos(jsonb) from public, anon;
grant execute on function me.cajeros_activos_todos(jsonb) to authenticated, service_role;
