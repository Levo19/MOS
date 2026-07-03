-- 331_mos_device_state.sql
-- [CERO-GAS] Snapshot de sesión del dispositivo (recovery si la PWA pierde localStorage+IDB) 100% Supabase.
-- Reemplaza el par GAS syncDeviceState (write cada 60s) + getDeviceState (read en boot). Migración PAREJA
-- (read+write juntos) para no dejar el lector viendo escrituras viejas. Shapes EXACTOS a DeviceState.gs.
-- Gate: acepta mosExpress/MOS/service. Grant authenticated+service_role.

create table if not exists mos.device_state (
  device_id        text primary key,
  app              text,
  vendedor         text,
  zona             text,
  id_caja          text,
  monto            numeric,
  estacion_codigo  text,
  estacion_nombre  text,
  printnode_id     text,
  config_json      jsonb,
  caja_activa_json jsonb,
  fecha_sesion     text,
  last_sync        timestamptz default now(),
  from_ip          text
);

-- WRITE (upsert). p = {deviceId, app, config:{vendedor,zona,estacion:{...}}, cajaActiva:{idCaja,monto}, fechaSesion, fromIp}
create or replace function mos.set_device_state(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_dev text := nullif(btrim(coalesce(p->>'deviceId','')),'');
  v_cfg jsonb := coalesce(p->'config','{}'::jsonb);
  v_ca  jsonb := coalesce(p->'cajaActiva','{}'::jsonb);
begin
  if v_claim not in ('mosExpress','MOS','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_dev is null then return jsonb_build_object('ok',false,'error','deviceId requerido'); end if;
  insert into mos.device_state (device_id, app, vendedor, zona, id_caja, monto, estacion_codigo, estacion_nombre,
                                printnode_id, config_json, caja_activa_json, fecha_sesion, last_sync, from_ip)
  values (v_dev, coalesce(p->>'app','ME'), coalesce(v_cfg->>'vendedor',''), coalesce(v_cfg->>'zona',''),
          coalesce(v_ca->>'idCaja',''), nullif(v_ca->>'monto','')::numeric,
          coalesce(v_cfg->'estacion'->>'Estacion_Codigo',''), coalesce(v_cfg->'estacion'->>'Estacion_Nombre',''),
          coalesce(v_cfg->'estacion'->>'PrintNode_ID',''), v_cfg, v_ca, coalesce(p->>'fechaSesion',''), now(),
          coalesce(p->>'fromIp',''))
  on conflict (device_id) do update set
    app=excluded.app, vendedor=excluded.vendedor, zona=excluded.zona, id_caja=excluded.id_caja, monto=excluded.monto,
    estacion_codigo=excluded.estacion_codigo, estacion_nombre=excluded.estacion_nombre, printnode_id=excluded.printnode_id,
    config_json=excluded.config_json, caja_activa_json=excluded.caja_activa_json, fecha_sesion=excluded.fecha_sesion,
    last_sync=now(), from_ip=excluded.from_ip;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('saved',true,'deviceId',v_dev));
end;
$fn$;
revoke all on function mos.set_device_state(jsonb) from public, anon;
grant execute on function mos.set_device_state(jsonb) to authenticated, service_role;

-- READ. p = {deviceId}. Shape EXACTO al GAS getDeviceState.
create or replace function mos.get_device_state(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_dev text := nullif(btrim(coalesce(p->>'deviceId','')),'');
  r mos.device_state%rowtype;
begin
  if v_claim not in ('mosExpress','MOS','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_dev is null then return jsonb_build_object('ok',false,'error','deviceId requerido'); end if;
  select * into r from mos.device_state where device_id = v_dev limit 1;
  if not found then return jsonb_build_object('ok',true,'data',jsonb_build_object('encontrado',false,'deviceId',v_dev)); end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'encontrado',true,'deviceId',v_dev,'app',coalesce(r.app,''),'vendedor',coalesce(r.vendedor,''),
    'zona',coalesce(r.zona,''),'idCaja',coalesce(r.id_caja,''),'monto',coalesce(r.monto,0),
    'estacion',jsonb_build_object('Estacion_Codigo',coalesce(r.estacion_codigo,''),'Estacion_Nombre',coalesce(r.estacion_nombre,''),'PrintNode_ID',coalesce(r.printnode_id,'')),
    'config',r.config_json,'cajaActiva',r.caja_activa_json,'fechaSesion',coalesce(r.fecha_sesion,''),
    'lastSync', case when r.last_sync is not null then to_char(r.last_sync at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end));
end;
$fn$;
revoke all on function mos.get_device_state(jsonb) from public, anon;
grant execute on function mos.get_device_state(jsonb) to authenticated, service_role;
