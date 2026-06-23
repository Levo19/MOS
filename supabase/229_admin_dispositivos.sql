-- 229_admin_dispositivos.sql — Escrituras admin de dispositivos (panel MOS) 100% Supabase. Port fiel de
-- gas/Config.gs (crearDispositivo/actualizarDispositivo/aprobarDispositivoPendiente). Gate: app='MOS' (solo el
-- panel MOS, que ya está gateado por login admin). El front manda claves PascalCase (ID_Dispositivo, etc.).
-- (revocarDispositivo ya tiene RPC mos.revocar_dispositivo; el push de aprobación queda como efecto GAS aparte.)

create or replace function mos.admin_crear_dispositivo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := btrim(coalesce(p->>'ID_Dispositivo','')); v_nom text := btrim(coalesce(p->>'Nombre_Equipo',''));
begin
  if coalesce(me.jwt_app(),'') <> 'MOS' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere ID_Dispositivo'); end if;
  if v_nom = '' then return jsonb_build_object('ok',false,'error','Requiere Nombre_Equipo'); end if;
  if exists (select 1 from mos.dispositivos where id_dispositivo = v_id) then
    return jsonb_build_object('ok',false,'error','Dispositivo ya registrado: '||v_id); end if;
  insert into mos.dispositivos (id_dispositivo, nombre_equipo, app, estado, ultima_conexion, ultima_zona, ultima_estacion)
  values (v_id, v_nom, coalesce(nullif(btrim(coalesce(p->>'App','')),''),'mosExpress'),
          coalesce(nullif(btrim(coalesce(p->>'Estado','')),''),'ACTIVO'), now(),
          coalesce(p->>'Ultima_Zona',''), coalesce(p->>'Ultima_Estacion',''));
  return jsonb_build_object('ok',true,'data', jsonb_build_object('ID_Dispositivo', v_id));
end;
$fn$;

create or replace function mos.admin_actualizar_dispositivo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := btrim(coalesce(p->>'ID_Dispositivo','')); v_n int;
begin
  if coalesce(me.jwt_app(),'') <> 'MOS' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere ID_Dispositivo'); end if;
  update mos.dispositivos set
    nombre_equipo   = case when p ? 'Nombre_Equipo'   then coalesce(p->>'Nombre_Equipo', nombre_equipo)   else nombre_equipo end,
    app             = case when p ? 'App'              then coalesce(nullif(btrim(coalesce(p->>'App','')),''), app) else app end,
    estado          = case when p ? 'Estado'           then coalesce(nullif(btrim(coalesce(p->>'Estado','')),''), estado) else estado end,
    ultima_zona     = case when p ? 'Ultima_Zona'      then coalesce(p->>'Ultima_Zona', ultima_zona)         else ultima_zona end,
    ultima_estacion = case when p ? 'Ultima_Estacion'  then coalesce(p->>'Ultima_Estacion', ultima_estacion) else ultima_estacion end
  where id_dispositivo = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','Dispositivo no encontrado: '||v_id); end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('ID_Dispositivo', v_id));
end;
$fn$;

-- aprobar pendiente (panel): ACTIVO + limpiar forzar_reverify/inactivo_alerta_ts/suspendido_desde. Idempotente.
create or replace function mos.admin_aprobar_pendiente(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := btrim(coalesce(p->>'ID_Dispositivo','')); v_est text;
begin
  if coalesce(me.jwt_app(),'') <> 'MOS' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere ID_Dispositivo'); end if;
  select upper(coalesce(estado,'')) into v_est from mos.dispositivos where id_dispositivo = v_id;
  if not found then return jsonb_build_object('ok',false,'error','Dispositivo no encontrado: '||v_id); end if;
  if v_est = 'ACTIVO' then return jsonb_build_object('ok',true,'skipped',true,'motivo','ya_activo'); end if;
  update mos.dispositivos set
    estado = 'ACTIVO',
    forzar_reverify = null,
    inactivo_alerta_ts = null,
    suspendido_desde = case when v_est = 'SUSPENDIDO' then null else suspendido_desde end,
    nombre_equipo = case when p ? 'Nombre_Equipo' and btrim(coalesce(p->>'Nombre_Equipo',''))<>'' then p->>'Nombre_Equipo' else nombre_equipo end,
    app = case when p ? 'App' and btrim(coalesce(p->>'App',''))<>'' then p->>'App' else app end
  where id_dispositivo = v_id;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('ID_Dispositivo', v_id, 'estado','ACTIVO'));
end;
$fn$;

do $$ declare f text; begin
  foreach f in array array['admin_crear_dispositivo(jsonb)','admin_actualizar_dispositivo(jsonb)','admin_aprobar_pendiente(jsonb)'] loop
    execute 'revoke all on function mos.'||f||' from public';
    execute 'grant execute on function mos.'||f||' to authenticated';
  end loop;
end $$;
