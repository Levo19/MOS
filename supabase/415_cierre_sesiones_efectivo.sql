-- ════════════════════════════════════════════════════════════════════════════
-- 415 · CIERRE DE SESIONES EFECTIVO (incidente XF/Mía 2026-07-10/11)
-- ════════════════════════════════════════════════════════════════════════════
-- CAUSA RAÍZ (verificada en prod):
--   El cron mos-cierre-forzado-11pm SÍ corre y SÍ cierra (XF quedó FORZADA_11PM
--   a las 23:00 exactas, con cascada a accesos_dispositivos y push nocturno —
--   la versión viva ya extiende al 287) y SÍ marca dispositivos.forzar_logout —
--   pero NINGÚN cliente honra ese flag (device-auth.js no lo lee; el day-guard
--   local de ME se eliminó en v2.7.0 confiando en un contrato GAS que murió en
--   el cutover). Peor: el hook mos.registrar_ingreso_personal (287), enganchado
--   al heartbeat me.registrar_presencia (288/398, pulso cada 30s), RESUCITABA:
--     · reabría estado_sesion='ACTIVA' + hora_salida=null en CUALQUIER ping,
--     · re-ataba el device a accesos_dispositivos sin aprobación (así el iPhone
--       quedó re-anclado a la sesión de HOY de Mía sin pasar por extensión),
--     · CREABA la fila del día nuevo desde una sesión zombi restaurada (así XF
--       "reapareció con posibilidades de vender" a las 08:13 del día siguiente).
--
-- REGLAS DEL DUEÑO:
--   · 23:00 = se cierra TODO; al día siguiente todos los usuarios limpios.
--   · El vínculo de extensión muere con la sesión/el día (no queda anclado).
--
-- FIX (2 funciones; el cron 11pm vivo NO se toca — ya hace cascada + push):
--   1. mos.registrar_ingreso_personal: marcadores nuevos opcionales
--      esLogin='1' (login explícito: wizard / retoma con PIN) y sesionVigente
--      (informativo). SIN marcadores (login WH, ME viejo cacheado) el
--      comportamiento es BYTE-IDÉNTICO al actual (cero regresión asistencia/
--      pagos). CON marcadores (cliente nuevo):
--        · un PULSO (no-login) NUNCA reabre una sesión CERRADA/FORZADA_11PM/
--          AUTOCIERRE → {sesionCerrada:true} (el cliente se desloguea),
--        · un PULSO NUNCA ata un device a accesos ni re-activa un acceso
--          CERRADO (solo refresca el que ya está ACTIVA; atar/reactivar =
--          login explícito o flujo de extensión QR) y tampoco pisa
--          device_id/zona de la fila del día desde un equipo no atado,
--        · fila del día inexistente → SOLO la crea un login explícito (una
--          zombi de otro día, o con reloj corrido, ya no crea nada — el
--          servidor no confía en la fecha del cliente).
--   2. me.registrar_presencia: pasa los marcadores al hook (solo si vienen), y
--      si el hook dice sesionCerrada → borra su identidad de presencia (sin
--      fantasma en el login) y devuelve {debeCerrar:true} → el heartbeat de ME
--      (30s) se autodesloguea, money-safe. El cierre 11pm ahora llega a la
--      PANTALLA en ≤30s. Presencia se upserta ANTES del hook (igual que la
--      versión original: bajo contención del lock de liquidaciones_dia el
--      last_seen ya quedó fresco).
--
-- El flag dispositivos.forzar_logout se sigue marcando por el cron (informativo);
-- el mecanismo efectivo pasa a ser sesionCerrada→debeCerrar vía heartbeat.
-- Hardening pendiente aparte (pre-existente, ahora amplificado): el gate de
-- mos.extension_cerrar_cascada (402) acepta cualquier token de app ≠ '' → un
-- device de vendedor puede cerrar la sesión de otro por nombre+zona. Se anota
-- como follow-up (requiere pasar deviceId desde el frontend).
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1) mos.registrar_ingreso_personal — sin resurrección ni re-anclaje ──────
create or replace function mos.registrar_ingreso_personal(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
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
$function$;

revoke all on function mos.registrar_ingreso_personal(jsonb) from public;
grant execute on function mos.registrar_ingreso_personal(jsonb) to authenticated, service_role;

-- ── 2) me.registrar_presencia — pasa marcadores + devuelve debeCerrar ────────
create or replace function me.registrar_presencia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id        text := btrim(coalesce(p->>'id_personal',''));
  v_nombre    text := coalesce(p->>'nombre','');
  v_zona      text := coalesce(p->>'zona','');
  v_estacion  text := coalesce(p->>'estacion','');
  v_rol       text := lower(btrim(coalesce(nullif(p->>'rol',''),'vendedor')));
  v_device    text := nullif(btrim(coalesce(p->>'device_id','')),'');
  v_token     text := nullif(btrim(coalesce(p->>'push_token','')),'');
  v_hook      jsonb := null;   -- [415] resultado del hook de accesos
  -- [415] marcadores del cliente NUEVO: solo se propagan al hook si el cliente
  -- realmente los mandó. Un ME viejo cacheado (sin marcadores) debe llegar al
  -- hook como LEGACY (sin las claves) → su login sigue creando la fila del día.
  v_extra     jsonb := case when (p ? 'sesionVigente') or (p ? 'esLogin')
                            then jsonb_build_object(
                                   'esLogin',       coalesce(p->>'esLogin',''),
                                   'sesionVigente', coalesce(p->>'sesionVigente',''))
                            else '{}'::jsonb end;
begin
  if me.jwt_app() <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
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
        device_id  = coalesce(excluded.device_id,  me.presencia.device_id),
        push_token = coalesce(excluded.push_token, me.presencia.push_token),
        ingreso    = coalesce(me.presencia.ingreso, excluded.ingreso),
        last_seen  = now();

  -- [398] UN DISPOSITIVO = UNA FILA: al reloguear con otro nombre en el mismo equipo, la identidad vieja
  -- desaparece AL INSTANTE (no espera el TTL) → sin "sesión duplicada" fantasma del propio dispositivo.
  if v_device is not null and v_device <> '' then
    delete from me.presencia where device_id = v_device and id_personal <> v_id;
  end if;

  -- [accesos unificados] registro + heartbeat en liquidaciones_dia (ME = TEMPORAL). Gateado + idempotente.
  -- ⚠️ A PRUEBA DE FALLOS: una excepción del hook jamás rompe la presencia.
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') = '1' then
    begin
      v_hook := mos.registrar_ingreso_personal(jsonb_build_object(
        'idPersonal',  case
                         when v_id like 'NOID:%' or v_id like 'MEX:%'
                           then mos._identidad_persona(null, coalesce(nullif(btrim(v_nombre),''), substring(v_id from 6)), v_zona, true)
                         else v_id end,
        'nombre',      v_nombre,
        'rol',         v_rol,
        'appOrigen',   'mosExpress',
        'zona',        v_zona,
        'estacion',    v_estacion,
        'deviceId',    btrim(coalesce(p->>'deviceId', p->>'device_id', '')),
        'esTemporal',  true) || v_extra);
    exception when others then v_hook := null;
    end;
  end if;

  if coalesce(v_hook->>'sesionCerrada','') = 'true' then
    -- [415] sesión cerrada (11pm / otro equipo / día nuevo): baja SOLO de esta
    -- identidad (no de todo el device: otro usuario ya puede estar trabajando
    -- en el mismo equipo y su fila/ingreso no se toca) + orden de cierre.
    delete from me.presencia where id_personal = v_id;
    return jsonb_build_object('ok', true, 'debeCerrar', true,
      'motivo', coalesce(v_hook->>'motivo',''), 'id_personal', v_id);
  end if;

  return jsonb_build_object('ok', true, 'id_personal', v_id, 'last_seen', now());
end;
$function$;

revoke all on function me.registrar_presencia(jsonb) from public;
grant execute on function me.registrar_presencia(jsonb) to authenticated, service_role;

notify pgrst, 'reload schema';
