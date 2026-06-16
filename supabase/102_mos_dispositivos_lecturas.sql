-- 102_mos_dispositivos_lecturas.sql — [FASE 4.1 · Etapa D] RPCs de LECTURA sobre la sombra mos.dispositivos
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- Read-paths directos a Supabase para los lectores de la hoja DISPOSITIVOS (paneles, heartbeat, push/audio/
-- espía, horarios). INERTE: nadie las llama todavía (el cableo del frontend/GAS es un paso posterior, con
-- node -c + deploy disponibles). Estilo idéntico al 100/96: SECURITY DEFINER, search_path='', devuelven jsonb.
--
-- ⚠️ NO incluye `dispositivos_bloqueados`: el modelo real de bloqueo NO es estado='BLOQUEADO' — cruza con la
--    hoja BLOQUEOS (filas con motivo 'DEVICE:') + estado='INACTIVO' en DISPOSITIVOS (ver Bloqueos.gs:607).
--    Requiere una sombra de la hoja BLOQUEOS que aún no existe → gap documentado en DISENO_FASE4_auth_puro.md.
--    Se construirá cuando se porte la hoja BLOQUEOS (fuera del alcance de este lote).
--
-- GRANTS:
--   · consultar_estado_dispositivo / verificar_horario → ANON (las llama el device pre-login en su heartbeat,
--     exponen el estado de UN device por id — bajo riesgo, igual criterio que mos.verificar_dispositivo).
--   · listar_dispositivos / dispositivos_pendientes / fcm_token → service_role+authenticated (NO anon:
--     listar/pendientes exponen TODA la flota; fcm_token es para los hooks server-side de push/audio/espía).

create schema if not exists mos;

-- Helper local: timestamptz → ISO UTC con Z (o '' si null). Espeja Utilities.formatDate(...,'UTC',...'Z') de GAS.
create or replace function mos._iso_z(ts timestamptz)
returns text language sql immutable as $$
  select case when ts is null then '' else to_char(ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) consultar_estado_dispositivo(p) — paridad con GAS consultarEstadoDispositivo, SOLO LECTURA.
--    ⚠️ La versión GAS ADEMÁS escribe heartbeat (Ultima_Conexion) y limpia Suspendido_Desde. Aquí NO se
--    escribe (es read-path): el heartbeat lo hará la RPC de escritura registrar_sesion (Etapa G). El cableo
--    decidirá si el device sigue mandando el heartbeat por GAS o por RPC. Shape de `data` idéntico al de GAS.
--    p = { deviceId | ID_Dispositivo }
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.consultar_estado_dispositivo(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_id   text := nullif(btrim(coalesce(p->>'deviceId', p->>'ID_Dispositivo','')), '');
  v_row  mos.dispositivos%rowtype;
  v_ver  text := coalesce((select valor from mos.config where clave='MOS_DEVICE_VERIFY_VERSION' limit 1),'1');
  v_hoy  text := to_char((now() at time zone 'America/Lima')::date, 'YYYY-MM-DD');
begin
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere ID_Dispositivo'); end if;
  select * into v_row from mos.dispositivos where id_dispositivo = v_id limit 1;
  if not found then
    return jsonb_build_object('ok',true,'data', jsonb_build_object(
      'registrado', false, 'estado','NO_REGISTRADO',
      'verifyVersion', v_ver, 'fechaHoyLima', v_hoy));
  end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'registrado',                true,
    'estado',                    coalesce(v_row.estado,''),
    'nombre',                    coalesce(v_row.nombre_equipo,''),
    'app',                       coalesce(v_row.app,''),
    'forzar_wizard',             coalesce(v_row.forzar_wizard,false),
    'forzar_logout',             coalesce(v_row.forzar_logout,false),
    'logout_auto_ts',            mos._iso_z(v_row.logout_auto_ts),
    'forzar_push',               coalesce(v_row.forzar_push,false),
    'forzar_reverify',           coalesce(v_row.forzar_reverify,false),
    'desbloqueo_temporal_hasta', mos._iso_z(v_row.desbloqueo_temporal_hasta),
    'verifyVersion',             v_ver,
    'fechaHoyLima',              v_hoy));
end;
$fn$;
revoke all on function mos.consultar_estado_dispositivo(jsonb) from public;
grant execute on function mos.consultar_estado_dispositivo(jsonb) to anon, authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) fcm_token_dispositivo(p) — para los hooks server-side de push/audio/espía. p = { deviceId }
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.fcm_token_dispositivo(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_id  text := nullif(btrim(coalesce(p->>'deviceId', p->>'ID_Dispositivo','')), '');
  v_row mos.dispositivos%rowtype;
begin
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere deviceId'); end if;
  select * into v_row from mos.dispositivos where id_dispositivo = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','NO_REGISTRADO'); end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'fcmToken', coalesce(v_row.fcm_token,''),
    'estado',   coalesce(v_row.estado,''),
    'app',      coalesce(v_row.app,'')));
end;
$fn$;
revoke all on function mos.fcm_token_dispositivo(jsonb) from public;
grant execute on function mos.fcm_token_dispositivo(jsonb) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) verificar_horario_dispositivo(p) — para Horarios.gs (desbloqueo temporal / forzar horario). p = { deviceId }
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.verificar_horario_dispositivo(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_id  text := nullif(btrim(coalesce(p->>'deviceId', p->>'ID_Dispositivo','')), '');
  v_row mos.dispositivos%rowtype;
begin
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere deviceId'); end if;
  select * into v_row from mos.dispositivos where id_dispositivo = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','NO_REGISTRADO'); end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'estado',                    coalesce(v_row.estado,''),
    'desbloqueoTemporalHasta',   mos._iso_z(v_row.desbloqueo_temporal_hasta),
    'forzarHorarioHasta',        mos._iso_z(v_row.forzar_horario_hasta)));
end;
$fn$;
revoke all on function mos.verificar_horario_dispositivo(jsonb) from public;
grant execute on function mos.verificar_horario_dispositivo(jsonb) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) listar_dispositivos(p) — paneles admin. p = { app?, estado? }. data = array de objetos cuyas CLAVES
--    espejan los headers de la hoja DISPOSITIVOS (paridad con getDispositivos, que devuelve _sheetToObjects
--    crudo). Así el frontend que hoy consume getDispositivos no cambia. EXPONE LA FLOTA → NO anon.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.listar_dispositivos(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_app text := nullif(btrim(coalesce(p->>'app','')), '');
  v_est text := nullif(btrim(coalesce(p->>'estado','')), '');
  v_arr jsonb;
begin
  select coalesce(jsonb_agg(obj order by obj->>'Ultima_Conexion' desc nulls last), '[]'::jsonb)
    into v_arr
  from (
    select jsonb_build_object(
      'ID_Dispositivo',            d.id_dispositivo,
      'Nombre_Equipo',             coalesce(d.nombre_equipo,''),
      'App',                       coalesce(d.app,''),
      'Estado',                    coalesce(d.estado,''),
      'Ultima_Conexion',           mos._iso_z(d.ultima_conexion),
      'Ultima_Zona',               coalesce(d.ultima_zona,''),
      'Ultima_Estacion',           coalesce(d.ultima_estacion,''),
      'Ultima_Sesion',             coalesce(d.ultima_sesion,''),
      'Permisos_JSON',             coalesce(d.permisos_json::text,''),
      'Permisos_LastUpdate',       mos._iso_z(d.permisos_lastupdate),
      'Forzar_Wizard',             coalesce(d.forzar_wizard,false),
      'Suspendido_Desde',          mos._iso_z(d.suspendido_desde),
      'Forzar_Logout',             coalesce(d.forzar_logout,false),
      'Logout_Auto_Ts',            mos._iso_z(d.logout_auto_ts),
      'Forzar_Push',               coalesce(d.forzar_push,false),
      'Forzar_ReVerify',           coalesce(d.forzar_reverify,false),
      'Inactivo_Alerta_Ts',        mos._iso_z(d.inactivo_alerta_ts),
      'Cancelado_Auto_Ts',         mos._iso_z(d.cancelado_auto_ts),
      'User_Agent',                coalesce(d.user_agent,''),
      'Fecha_Caducidad',           mos._iso_z(d.fecha_caducidad),
      'Desbloqueo_Temporal_Hasta', mos._iso_z(d.desbloqueo_temporal_hasta),
      'FCM_Token',                 coalesce(d.fcm_token,''),
      'Alerta_Seguridad',          coalesce(d.alerta_seguridad,''),
      'Alerta_Seguridad_Revisada', coalesce(d.alerta_seguridad_revisada,false),
      'Forzar_Horario_Hasta',      mos._iso_z(d.forzar_horario_hasta),
      'Razon_Bloqueo',             coalesce(d.razon_bloqueo,''),
      'Bloqueado_Desde',           mos._iso_z(d.bloqueado_desde)
    ) as obj
    from mos.dispositivos d
    where (v_app is null or d.app = v_app)
      and (v_est is null or d.estado = v_est)
  ) s;
  return jsonb_build_object('ok',true,'data', v_arr);
end;
$fn$;
revoke all on function mos.listar_dispositivos(jsonb) from public;
grant execute on function mos.listar_dispositivos(jsonb) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 5) dispositivos_pendientes(p) — los Estado='PENDIENTE_APROBACION' (consola de aprobación). Mismo shape que
--    listar_dispositivos (reusa su lógica filtrando estado). NO anon.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.dispositivos_pendientes(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
  return mos.listar_dispositivos(jsonb_build_object('estado','PENDIENTE_APROBACION'));
end;
$fn$;
revoke all on function mos.dispositivos_pendientes(jsonb) from public;
grant execute on function mos.dispositivos_pendientes(jsonb) to authenticated, service_role;
