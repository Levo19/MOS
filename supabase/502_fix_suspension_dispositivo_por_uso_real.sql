-- 502_fix_suspension_dispositivo_por_uso_real.sql
-- El cron de inactividad (2d) lee mos.dispositivos.ultima_conexion, que ANTES solo refrescaba el
-- device-gate (verificar_dispositivo). El login/venta/heartbeat NO lo tocaban -> un equipo EN USO
-- (app abierta, varios usuarios/dia) se suspendia igual. Fix: login y heartbeat cuentan como uso del
-- dispositivo; y verificar deja de pisar ultima_conexion en check-ins de equipos bloqueados (mentira).

CREATE OR REPLACE FUNCTION mos.registrar_ingreso_personal(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_rol     text := upper(btrim(coalesce(p->>'rol','')));
  v_nombre  text := btrim(coalesce(p->>'nombre',''));
  v_app     text := btrim(coalesce(p->>'appOrigen',''));
  v_zona    text := btrim(coalesce(p->>'zona',''));
  v_dev     text := btrim(coalesce(p->>'deviceId',''));
  v_temp    boolean := coalesce((p->>'esTemporal')::boolean, false);
  -- [415] marcadores del cliente nuevo. AUSENTES ambos = llamador legacy
  -- (login WH / ME viejo cacheado) → semántica original intacta.
  v_login   boolean := coalesce(p->>'esLogin','') = '1';
  v_marcado boolean := (p ? 'esLogin') or (p ? 'sesionVigente');
  v_attach  boolean;
  v_dia     date := (now() at time zone 'America/Lima')::date;
  v_fecha_s text := to_char(v_dia, 'YYYY-MM-DD');
  v_fecha   timestamptz := ((v_fecha_s || ' 00:00:00')::timestamp at time zone 'America/Lima');
  v_now     timestamptz := now();
  v_id_dia  text;
  v_fijo    numeric;
  v_metaaud numeric;
  v_exists  boolean := false;
  v_ingreso timestamptz;
  v_estado_ses text;
begin
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_ACCESOS_DIRECTO_OFF');
  end if;
  if coalesce(me.jwt_app(),'') = '' then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_idp is null then
    return jsonb_build_object('ok',false,'error','idPersonal requerido');
  end if;
  -- [FIX 502] Un login REAL cuenta como USO del DISPOSITIVO -> refresca su ultima_conexion para que
  -- el cron de inactividad (2 dias) no suspenda un equipo EN USO (antes solo lo refrescaba el device-gate
  -- verificar_dispositivo, no el login/venta). deviceId opcional; solo toca equipos ya ACTIVOS.
  if v_dev ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    update mos.dispositivos set ultima_conexion = now() where id_dispositivo = v_dev and upper(coalesce(estado,'')) = 'ACTIVO';
  end if;
  -- MASTER/ADMIN no liquidan jornal (paridad con upsert_liquidacion_dia).
  if v_rol in ('MASTER','ADMIN','ADMINISTRADOR') then
    return jsonb_build_object('ok',true,'skipped','ROL_BLOQUEADO');
  end if;

  v_id_dia  := mos._liqdia_key(v_idp, v_fecha_s);
  v_fijo    := mos._fijo_personal(v_idp, v_rol);
  v_metaaud := coalesce(mos._numn((select valor from mos.config where clave='evalMetaAuditorias' limit 1)), 0);

  -- ¿ya existe la fila del día? (creada por login previo, snapshot, o ajuste manual)
  -- (v_estado_ses CRUDO, igual que el original → reconexiones cuenta idéntico en legacy)
  select true, hora_ingreso, coalesce(estado_sesion,'')
    into v_exists, v_ingreso, v_estado_ses
    from mos.liquidaciones_dia where id_dia = v_id_dia for update;

  if v_exists then
    -- [415] cliente nuevo + PULSO (no login) + sesión ya cerrada → NO resucitar.
    -- El heartbeat de un equipo con la sesión cerrada (cron 11pm / cierre desde
    -- otro equipo / cascada / limpiar-fantasmas 402) recibe la orden de cerrar.
    -- Un LOGIN explícito (esLogin=1: wizard o retoma con PIN) SÍ reabre.
    if v_marcado and not v_login
       and upper(v_estado_ses) in ('CERRADA','FORZADA_11PM','AUTOCIERRE') then
      return jsonb_build_object('ok',true,'sesionCerrada',true,'idDia',v_id_dia,
        'motivo','SESION_'||upper(v_estado_ses));
    end if;
    -- [415] ¿este device puede atarse/refrescarse y representar la sesión?
    --   legacy → siempre (comportamiento original) · login explícito → sí ·
    --   pulso → SOLO si ya está atado y ACTIVA hoy (un acceso CERRADO no se
    --   re-activa con un ping — el vínculo muerto se queda muerto, regla dueño).
    v_attach := (not v_marcado) or v_login
                or (v_dev <> '' and exists(
                     select 1 from mos.accesos_dispositivos
                      where id_dia = v_id_dia and device_id = v_dev
                        and upper(coalesce(estado,'')) = 'ACTIVA'));
    -- SOLO asistencia. NO se toca dinero (monto_base/pago_envasado/bono_meta/total_dia)
    -- ni manual (bonificacion/sancion/estado/id_pago). reconexiones++ si estaba cerrada.
    -- [415] device_id/zona de la fila SOLO los pisa un equipo atado (v_attach):
    -- un pulso de un 2º equipo stale ya no roba la titularidad de la sesión.
    update mos.liquidaciones_dia set
        hora_ingreso    = coalesce(hora_ingreso, v_now),         -- primer login: se fija una vez
        ultima_conexion = v_now,
        estado_sesion   = 'ACTIVA',
        hora_salida     = null,                                   -- reabre si volvió a entrar
        presente        = true,
        zona            = case when v_attach and v_zona <> '' then v_zona else zona end,
        device_id       = case when v_attach and v_dev  <> '' then v_dev  else device_id end,
        es_temporal     = v_temp,
        meta_auditorias = case when v_metaaud > 0 then v_metaaud else meta_auditorias end,
        reconexiones    = reconexiones + case when v_estado_ses in ('CERRADA','FORZADA_11PM','AUTOCIERRE') then 1 else 0 end,
        ts_actualizado  = v_now
      where id_dia = v_id_dia;
    -- [ext] registrar/refrescar el device de la sesión (principal si es el 1º ACTIVO)
    if v_dev <> '' and v_attach then
      insert into mos.accesos_dispositivos (id_dia, device_id, rol, es_principal, estado)
      values (v_id_dia, v_dev, v_rol,
              not exists(select 1 from mos.accesos_dispositivos where id_dia=v_id_dia and es_principal and upper(coalesce(estado,''))='ACTIVA'),
              'ACTIVA')
      on conflict (id_dia, device_id) do update set estado='ACTIVA', ultima_conexion=v_now, rol=excluded.rol;
    end if;
    return jsonb_build_object('ok',true,'created',false,'idDia',v_id_dia,'horaIngreso',coalesce(v_ingreso,v_now));
  end if;

  -- [415] fila del día INEXISTENTE + cliente nuevo SIN login explícito → una
  -- zombi de otro día (o con reloj corrido — el server NO confía en la fecha
  -- del cliente) jamás crea la fila del día nuevo. El cliente se desloguea.
  if v_marcado and not v_login then
    return jsonb_build_object('ok',true,'sesionCerrada',true,'idDia',v_id_dia,
      'motivo','SIN_FILA_DIA');
  end if;

  -- FILA NUEVA: aparece YA en personal del día con su fijo. Autos en 0 (los llena el
  -- recompute / Fase 2). total_dia = fijo (capped ≥0). estado PENDIENTE, sesión ACTIVA.
  insert into mos.liquidaciones_dia (
    id_dia, fecha, id_personal, nombre, rol, app_origen, virtual,
    monto_base, pago_envasado, bono_meta, bonificacion, sancion,
    bonificacion_motivo, sancion_motivo, total_dia, auditado,
    evaluaciones_count, score_final, tarifa_envasado, presente, estado, id_pago,
    es_temporal, zona, device_id, hora_ingreso, ultima_conexion, estado_sesion,
    minutos_activos, reconexiones, meta_auditorias,
    ts_creado, ts_actualizado
  ) values (
    v_id_dia, v_fecha, v_idp, v_nombre, v_rol, v_app,
    case when v_idp like 'MEX:%' then 'true' else 'false' end,
    coalesce(v_fijo,0), 0, 0, 0, 0,
    '', '', mos._liqdia_total(v_fijo, 0, 0, 0, 0), false,
    0, 0, coalesce(mos._numn((select valor from mos.config where clave='tarifa_envasado' limit 1)),0),
    true, 'PENDIENTE', '',
    v_temp, v_zona, v_dev, v_now, v_now, 'ACTIVA',
    0, 0, v_metaaud,
    v_now, v_now
  )
  on conflict (id_dia) do nothing;

  if not found then
    -- carrera: otra tx la insertó → reintentar como UPDATE de asistencia.
    return mos.registrar_ingreso_personal(p);
  end if;
  -- [ext] la fila nació → su device es el PRINCIPAL de la sesión.
  if v_dev <> '' then
    insert into mos.accesos_dispositivos (id_dia, device_id, rol, es_principal, estado)
    values (v_id_dia, v_dev, v_rol, true, 'ACTIVA')
    on conflict (id_dia, device_id) do update set estado='ACTIVA', es_principal=true, ultima_conexion=v_now;
  end if;
  return jsonb_build_object('ok',true,'created',true,'idDia',v_id_dia,'horaIngreso',v_now,'montoBase',coalesce(v_fijo,0));
end;
$function$
;

CREATE OR REPLACE FUNCTION mos.heartbeat_personal(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha_s text := to_char((now() at time zone 'America/Lima')::date, 'YYYY-MM-DD');
  v_now     timestamptz := now();
  v_id_dia  text;
  v_n int;
begin
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_ACCESOS_DIRECTO_OFF');
  end if;
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;

  v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
  update mos.liquidaciones_dia set
      ultima_conexion = v_now,
      estado_sesion   = case when estado_sesion in ('CERRADA','FORZADA_11PM','AUTOCIERRE') then estado_sesion else 'ACTIVA' end,
      minutos_activos = least(1440, greatest(coalesce(minutos_activos,0),
                          round(extract(epoch from (v_now - coalesce(hora_ingreso, v_now)))/60.0))),
      ts_actualizado  = v_now
    where id_dia = v_id_dia;
  get diagnostics v_n = row_count;
  -- [FIX 502] el heartbeat (app abierta y activa) cuenta como USO del/los dispositivo(s) atados a la
  -- sesion -> refresca su ultima_conexion para que el cron 2d no suspenda un equipo que se esta usando.
  update mos.dispositivos dd set ultima_conexion = v_now
    from mos.accesos_dispositivos a
   where a.id_dia = v_id_dia and upper(coalesce(a.estado,'')) = 'ACTIVA'
     and dd.id_dispositivo = a.device_id and upper(coalesce(dd.estado,'')) = 'ACTIVO';
  return jsonb_build_object('ok', v_n>0, 'idDia', v_id_dia);
end;
$function$
;

CREATE OR REPLACE FUNCTION mos.verificar_dispositivo(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id   text := btrim(coalesce(p->>'id_dispositivo',''));
  v_ver  text;
  v_sdc  boolean;
  d      mos.dispositivos%rowtype;
begin
  select valor into v_ver from mos.config where clave = 'DEVICE_VERIFY_VERSION' limit 1;
  v_ver := coalesce(v_ver, '1');
  -- [FASE 4.1 · F] flag: ¿el front debe SALTARSE el doble-check a GAS y confiar en la sombra? (default false)
  v_sdc := (coalesce((select valor from mos.config where clave='MOS_AUTH_SIN_DOBLECHECK' limit 1),'0') = '1');

  if v_id !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false,
      'verify_version', v_ver, 'sin_doblecheck', v_sdc,
      'fecha_hoy_lima', to_char((now() at time zone 'America/Lima')::date,'YYYY-MM-DD'));
  end if;

  -- heartbeat + limpieza de suspendido_desde si reaparece ACTIVO; devuelve la fila actualizada.
  update mos.dispositivos
     set ultima_conexion  = case when estado='ACTIVO' then now() else ultima_conexion end,  -- [FIX 502] no contar check-ins bloqueados como uso
         suspendido_desde = case when estado='ACTIVO' then null else suspendido_desde end
   where id_dispositivo = v_id
   returning * into d;

  if not found then
    return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false,
      'verify_version', v_ver, 'sin_doblecheck', v_sdc,
      'fecha_hoy_lima', to_char((now() at time zone 'America/Lima')::date,'YYYY-MM-DD'));
  end if;

  return jsonb_build_object(
    'ok', true,
    'estado',                    d.estado,
    'autorizado',                (d.estado = 'ACTIVO'),
    'nombre_equipo',             d.nombre_equipo,
    'app',                       d.app,
    'forzar_wizard',             coalesce(d.forzar_wizard,false),
    'forzar_logout',             coalesce(d.forzar_logout,false),
    'forzar_push',               coalesce(d.forzar_push,false),
    'forzar_reverify',           coalesce(d.forzar_reverify,false),
    'logout_auto_ts',            d.logout_auto_ts,
    'suspendido_desde',          d.suspendido_desde,
    'desbloqueo_temporal_hasta', d.desbloqueo_temporal_hasta,
    'fecha_caducidad',           d.fecha_caducidad,
    'permisos_json',             d.permisos_json,
    'verify_version',            v_ver,
    'sin_doblecheck',            v_sdc,
    'fecha_hoy_lima',            to_char((now() at time zone 'America/Lima')::date,'YYYY-MM-DD')
  );
exception when others then
  -- fail-soft: si la RPC falla, el front cae a su cache; la denylist de get_flags es el backstop server.
  return jsonb_build_object('ok', false, 'error', 'ERROR_VERIFICACION');
end;
$function$
;
