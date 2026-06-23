-- 232_login_pin_wh.sql — Login de operador WH 100% Supabase + SEGURO (FIX login caído + erradica GAS loginPersonal).
-- CONTEXTO: catalogo_wh_rls excluye `pin`/`pin_hash` (decisión de seguridad: NUNCA exponer PINs al navegador) →
-- validarPinLocal del front quedó sin pin para comparar → login local roto. Este RPC valida el PIN SERVER-SIDE
-- (el pin nunca sale del server) contra mos.personal, crea/reusa la sesión en wh.sesiones (fecha_inicio anclada a
-- medianoche-Lima, igual que cerrar_sesion espera), y devuelve el operador SIN pin. Réplica de loginPersonal (GAS).
-- ⚠️ HORARIO: permisivo por ahora — el horarioCustom (override por persona) vive solo en la Hoja; el gate estricto
--    de horario se migra aparte. Restaurar el login es prioridad; el heartbeat de horario sigue post-login.
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
  -- PIN comparado SERVER-SIDE; jamás se devuelve ni se expone.
  select * into v_op from mos.personal
    where pin = v_pin and lower(coalesce(app_origen,'')) like '%warehouse%' and coalesce(estado,false) = true
    limit 1;
  if not found then return jsonb_build_object('ok',false,'error','PIN incorrecto'); end if;

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
