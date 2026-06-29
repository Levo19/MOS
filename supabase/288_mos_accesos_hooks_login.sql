-- ============================================================================
-- 288_mos_accesos_hooks_login.sql — ENGANCHE del registro unificado en los logins
-- ----------------------------------------------------------------------------
-- Conecta mos.registrar_ingreso_personal (287) a los DOS puntos de entrada reales,
-- 100% server-side (cero/mínimo frontend), gateado por MOS_ACCESOS_DIRECTO e
-- INERTE por defecto:
--   · me.registrar_presencia  → ME (vendedores/cajeros TEMPORALES). Como el front la
--       llama al entrar Y cada ~60s, esto da registro + heartbeat (última conexión) en
--       vivo SIN tocar el frontend de ME.
--   · mos.login_pin_wh        → WH (personal_master). Registra al loguearse → aparece
--       de inmediato en "personal del día".
--
-- ⚠️ A PRUEBA DE FALLOS: el enganche va en un bloque BEGIN/EXCEPTION que traga cualquier
--    error → el login / la presencia NUNCA se rompen por el registro de asistencia.
-- ⚠️ Re-creación VERBATIM de ambas funciones + el hook (no cambia su lógica original).
-- ============================================================================

-- ───────────────────────────────────────────────────────────────────────────
-- 1) me.registrar_presencia (verbatim de 89_me_presencia_mensajeria.sql — CON
--    device_id/push_token/ingreso de la mensajería) + hook accesos. ⚠️ basarse en
--    el 89, NO en el 88, o se pierde el manejo de push_token (rompe mensajería).
-- ───────────────────────────────────────────────────────────────────────────
create or replace function me.registrar_presencia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id        text := btrim(coalesce(p->>'id_personal',''));
  v_nombre    text := coalesce(p->>'nombre','');
  v_zona      text := coalesce(p->>'zona','');
  v_estacion  text := coalesce(p->>'estacion','');
  v_rol       text := lower(btrim(coalesce(nullif(p->>'rol',''),'vendedor')));
  -- device_id / push_token: NULL si no vienen (no pisamos un token bueno con '').
  v_device    text := nullif(btrim(coalesce(p->>'device_id','')),'');
  v_token     text := nullif(btrim(coalesce(p->>'push_token','')),'');
begin
  -- fail-closed: solo tokens de ME (la PWA). Cualquier otro claim → rechazo.
  if me.jwt_app() <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- id_personal es obligatorio (es la PK / identidad del pulso).
  if v_id = '' then
    return jsonb_build_object('ok', false, 'error', 'id_personal requerido');
  end if;

  insert into me.presencia (id_personal, nombre, zona, estacion, rol,
                            device_id, push_token, ingreso, last_seen)
  values (v_id, v_nombre, v_zona, v_estacion, v_rol,
          v_device, v_token, now(), now())
  on conflict (id_personal) do update
    set nombre     = excluded.nombre,
        zona       = excluded.zona,
        estacion   = excluded.estacion,
        rol        = excluded.rol,
        -- device_id / push_token: refrescar SOLO si llega un valor nuevo no vacío.
        device_id  = coalesce(excluded.device_id,  me.presencia.device_id),
        push_token = coalesce(excluded.push_token, me.presencia.push_token),
        -- ingreso: se fija una sola vez (1er pulso del turno), NO se pisa.
        ingreso    = coalesce(me.presencia.ingreso, excluded.ingreso),
        last_seen  = now();

  -- [accesos unificados] registro + heartbeat en liquidaciones_dia (ME = TEMPORAL).
  -- Gateado e idempotente. A prueba de fallos: la presencia NUNCA falla por esto.
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') = '1' then
    begin
      perform mos.registrar_ingreso_personal(jsonb_build_object(
        'idPersonal',  v_id,
        'nombre',      v_nombre,
        'rol',         v_rol,
        'appOrigen',   'mosExpress',
        'zona',        v_zona,
        'estacion',    v_estacion,
        'deviceId',    btrim(coalesce(p->>'deviceId', p->>'device_id', '')),
        'esTemporal',  true));
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('ok', true, 'id_personal', v_id, 'last_seen', now());
end;
$fn$;
revoke all on function me.registrar_presencia(jsonb) from public;
grant execute on function me.registrar_presencia(jsonb) to authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────────
-- 2) mos.login_pin_wh (verbatim de 232_login_pin_wh.sql) + hook accesos.
--    El hook va tras resolver v_op (operador) y antes del branch de sesión → corre
--    UNA vez tanto en sesión nueva como en reapertura.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function mos.login_pin_wh(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_pin text := nullif(btrim(coalesce(p->>'pin','')), '');
  v_op  mos.personal%rowtype;
  v_dia date := (now() at time zone 'America/Lima')::date;
  v_hora text := to_char(now() at time zone 'America/Lima', 'HH24:MI:SS');
  v_fini timestamptz := ((v_dia::text || ' 00:00:00')::timestamp at time zone 'America/Lima');
  v_ses wh.sesiones%rowtype; v_sid text;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_pin is null then return jsonb_build_object('ok',false,'error','PIN requerido'); end if;
  -- [234_review_fixes_100x] match tolerante a PINs con espacios en la Hoja.
  select * into v_op from mos.personal
    where btrim(coalesce(pin,'')) = v_pin and coalesce(estado,false) = true
    order by (lower(coalesce(app_origen,'')) like '%warehouse%') desc
    limit 1;
  if not found then return jsonb_build_object('ok',false,'error','PIN incorrecto'); end if;

  -- [accesos unificados] registro al ingresar (WH = personal_master, NO temporal).
  -- Gateado, idempotente, a prueba de fallos: el login NUNCA se rompe por esto.
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') = '1' then
    begin
      perform mos.registrar_ingreso_personal(jsonb_build_object(
        'idPersonal',  v_op.id_personal::text,
        'nombre',      v_op.nombre,
        'rol',         v_op.rol,
        'appOrigen',   'warehouseMos',
        'deviceId',    btrim(coalesce(p->>'deviceId', p->>'device_id', '')),
        'esTemporal',  false));
    exception when others then null;
    end;
  end if;

  -- ¿sesión ACTIVA de hoy? (segundo device / reapertura) → devolverla
  select * into v_ses from wh.sesiones
    where id_personal = v_op.id_personal::text and upper(coalesce(estado,'')) = 'ACTIVA'
      and (fecha_inicio at time zone 'America/Lima')::date = v_dia
    order by fecha_inicio desc limit 1;
  if found then
    return jsonb_build_object('ok',true,'data', jsonb_build_object(
      'idSesion', v_ses.id_sesion, 'idPersonal', v_op.id_personal, 'nombre', v_op.nombre,
      'apellido', v_op.apellido, 'rol', v_op.rol, 'color', v_op.color, 'foto', v_op.foto,
      'horaInicio', v_ses.hora_inicio, 'yaEnSesionHoy', true, 'bienvenidaImpresa', true));
  end if;

  -- nueva sesión del día
  v_sid := 'SES-' || to_char(now(),'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text || v_op.id_personal), 1, 6);
  insert into wh.sesiones (id_sesion, id_personal, fecha_inicio, hora_inicio, minutos_activos, estado)
  values (v_sid, v_op.id_personal::text, v_fini, v_hora, 0, 'ACTIVA');
  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'idSesion', v_sid, 'idPersonal', v_op.id_personal, 'nombre', v_op.nombre, 'apellido', v_op.apellido,
    'rol', v_op.rol, 'color', v_op.color, 'foto', v_op.foto,
    'horaInicio', v_hora, 'yaEnSesionHoy', false, 'bienvenidaImpresa', false));
end;
$fn$;
revoke all on function mos.login_pin_wh(jsonb) from public;
grant execute on function mos.login_pin_wh(jsonb) to authenticated;
