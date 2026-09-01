-- ============================================================================
-- 1006_me_retoma_caja_por_device_y_presencia_autocura.sql
-- ----------------------------------------------------------------------------
-- INCIDENTE 2026-09-01 · Shadya · ZONA-01 (ver memoria architecture_me_sesion_escondida_retoma_2026-09-01)
--
-- (A) me.confirmar_retoma_caja buscaba la caja ABIERTA por `printnode_id = deviceId`.
--     printnode_id guarda el ID de la IMPRESORA (75711340), no el UUID del equipo → NUNCA
--     encontraba la caja → devolvía status:'error' "No hay caja ABIERTA para este deviceId"
--     y el front lo mostraba como "Clave incorrecta" (la clave ni se llegaba a validar).
--     me.retomar_caja_device ya se corrigió en 401 (busca por dispositivo_id) pero esta
--     RPC hermana quedó con el criterio viejo. Además devolvía `estacion` como TEXTO: al
--     repoblar mosexpress_config con estacion string, el guard de boot "estacionInvalida"
--     borraba la config → wizard otra vez. Ahora devuelve el MISMO objeto que 401.
--     Fix: dispositivo_id (fallback printnode_id para cajas viejas) + estacion objeto +
--     `mensaje` legible en todos los errores.
--
-- (B) me.registrar_presencia: un pulso NO-login sin fila del día (SIN_FILA_DIA) ordenaba
--     debeCerrar → el equipo borraba la sesión local aunque tuviera una caja ABIERTA de HOY
--     en el servidor (la caja siguió abierta 50 min sin cajera; 29 POR_COBRAR se anularon
--     en el cierre forzado). Una caja ABIERTA de hoy en ESTE equipo es prueba de sesión
--     vigente → en vez de ordenar cerrar, se AUTOCURA: reintenta el hook como login
--     (crea la fila del día) y responde ok. También se devuelve `hookOk`/`hookError`/`idDia`
--     para que el cliente no dé por confirmado un login cuyo hook falló en silencio.
-- Idempotente. Solo lectura extra en me.cajas (índices existentes por dispositivo_id/estado).
-- ============================================================================

-- (A) ───────────────────────────────────────────────────────────────────────
create or replace function me.confirmar_retoma_caja(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_dev   text := nullif(btrim(coalesce(p->>'deviceId', '')), '');
  v_clave text := coalesce(p->>'claveAdmin', '');
  v_caja  me.cajas%rowtype;
  v_verif jsonb;
begin
  if coalesce(me.jwt_app(), '') not in ('mosExpress', 'MOS') then
    return jsonb_build_object('status', 'error', 'error', 'APP_NO_AUTORIZADA', 'mensaje', 'App no autorizada');
  end if;
  if v_dev is null then
    return jsonb_build_object('status', 'error', 'error', 'deviceId requerido', 'mensaje', 'deviceId requerido');
  end if;
  if v_clave = '' or v_clave !~ '^\d{8}$' then
    return jsonb_build_object('status', 'error', 'error', 'claveAdmin debe ser 8 dígitos numéricos',
      'mensaje', 'La clave debe tener 8 dígitos numéricos');
  end if;

  -- (1) Caja ABIERTA de HOY de ESTE equipo — MISMO criterio que me.retomar_caja_device [401]:
  --     dispositivo_id (UUID del equipo). Fallback printnode_id solo para cajas viejas sin dispositivo_id.
  select * into v_caja from me.cajas
  where upper(coalesce(estado, '')) = 'ABIERTA'
    and (coalesce(dispositivo_id, '') = v_dev
         or (coalesce(dispositivo_id, '') = '' and coalesce(printnode_id, '') = v_dev))
    and to_char(fecha_apertura at time zone 'America/Lima', 'YYYY-MM-DD') = to_char(now() at time zone 'America/Lima', 'YYYY-MM-DD')
  order by fecha_apertura desc nulls last, created_at desc nulls last
  limit 1;
  if not found then
    return jsonb_build_object('status', 'error', 'error', 'No hay caja ABIERTA para este deviceId',
      'mensaje', 'No hay una caja ABIERTA de hoy para este equipo. Cierra este aviso y abre una sesión nueva.');
  end if;

  -- (2) Validar clave admin (8 díg = 4 global + 4 personal, bcrypt + lockout, auditoría).
  v_verif := mos.verificar_clave_admin(v_clave, 'RETOMA_CAJA_DESPUES_LOST_SESSION', coalesce(v_caja.id_caja, ''),
    'ME', v_dev, 'Retoma caja por deviceId ' || v_dev || ' · vendedor ' || coalesce(v_caja.vendedor, ''), 2);
  if not coalesce((v_verif->>'autorizado')::boolean, false) then
    return jsonb_build_object('status', 'success', 'autorizado', false,
      'mensaje', coalesce(v_verif->>'error', 'Clave incorrecta'));
  end if;

  -- (3) Autorizado → devolver la caja para repoblar la sesión (estacion = OBJETO, igual que 401).
  return jsonb_build_object('status', 'success', 'autorizado', true,
    'idCaja',   coalesce(v_caja.id_caja, ''),
    'vendedor', coalesce(v_caja.vendedor, ''),
    'zona',     coalesce(v_caja.zona_id, ''),
    'estacion', jsonb_build_object(
                  'Estacion_Codigo', coalesce(v_caja.estacion, ''),
                  'Estacion_Nombre', coalesce(v_caja.estacion, ''),
                  'PrintNode_ID',    coalesce(nullif(v_caja.printnode_id, ''), '')),
    'monto',    coalesce(v_caja.monto_inicial, 0),
    'autorizadoPor', coalesce(v_verif->>'nombre', 'admin'));
end;
$fn$;
revoke all on function me.confirmar_retoma_caja(jsonb) from public, anon;
grant execute on function me.confirmar_retoma_caja(jsonb) to authenticated, service_role;

-- (B) ───────────────────────────────────────────────────────────────────────
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
  v_device    text := nullif(btrim(coalesce(p->>'device_id','')),'');
  v_token     text := nullif(btrim(coalesce(p->>'push_token','')),'');
  v_hook      jsonb := null;   -- [415] resultado del hook de accesos
  v_hookerr   text  := null;   -- [1006] error del hook (antes se tragaba en silencio)
  v_iddia     text;            -- [594] idDia devuelto por el hook (para el chequeo por-device)
  v_idp_hook  text;            -- [1006] identidad que se le pasa al hook (para reintentar como login)
  v_autocura  boolean := false;
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

  if v_device is not null and v_device <> '' then
    delete from me.presencia where device_id = v_device and id_personal <> v_id;
  end if;

  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') = '1' then
    v_idp_hook := case
                    when v_id like 'NOID:%' or v_id like 'MEX:%'
                      then mos._identidad_persona(null, coalesce(nullif(btrim(v_nombre),''), substring(v_id from 6)), v_zona, true)
                    else v_id end;
    begin
      v_hook := mos.registrar_ingreso_personal(jsonb_build_object(
        'idPersonal',  v_idp_hook,
        'nombre',      v_nombre,
        'rol',         v_rol,
        'appOrigen',   'mosExpress',
        'zona',        v_zona,
        'estacion',    v_estacion,
        'deviceId',    btrim(coalesce(p->>'deviceId', p->>'device_id', '')),
        'esTemporal',  true) || v_extra);
    exception when others then v_hook := null; v_hookerr := left(SQLERRM, 200);
    end;

    -- [1006 AUTOCURA] pulso sin fila del día (SIN_FILA_DIA) pero ESTE equipo tiene una caja ABIERTA
    -- de HOY en el servidor → la sesión ES vigente (la fila faltó porque el pulso de login no la
    -- creó). Reintentar el hook como LOGIN (crea la fila) en vez de ordenar cerrar la sesión.
    if coalesce(v_hook->>'sesionCerrada','') = 'true'
       and coalesce(v_hook->>'motivo','') = 'SIN_FILA_DIA'
       and v_device is not null and v_device <> ''
       and exists (select 1 from me.cajas c
                    where coalesce(c.dispositivo_id,'') = v_device
                      and upper(coalesce(c.estado,'')) = 'ABIERTA'
                      and (c.fecha_apertura at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date) then
      begin
        v_hook := mos.registrar_ingreso_personal(jsonb_build_object(
          'idPersonal',  v_idp_hook,
          'nombre',      v_nombre,
          'rol',         v_rol,
          'appOrigen',   'mosExpress',
          'zona',        v_zona,
          'estacion',    v_estacion,
          'deviceId',    btrim(coalesce(p->>'deviceId', p->>'device_id', '')),
          'esTemporal',  true) || jsonb_build_object('esLogin','1','sesionVigente','1'));
        v_autocura := coalesce(v_hook->>'ok','') = 'true' and coalesce(v_hook->>'sesionCerrada','') <> 'true';
      exception when others then v_hook := null; v_hookerr := left(SQLERRM, 200);
      end;
    end if;
  end if;

  if coalesce(v_hook->>'sesionCerrada','') = 'true' then
    -- [415] sesión de la PERSONA cerrada (11pm / otro equipo / día nuevo): baja + orden de cierre.
    delete from me.presencia where id_personal = v_id;
    return jsonb_build_object('ok', true, 'debeCerrar', true,
      'motivo', coalesce(v_hook->>'motivo',''), 'id_personal', v_id);
  end if;

  -- [594] cierre a NIVEL DEVICE: la sesión de la persona sigue ACTIVA, pero el acceso de ESTE equipo
  -- fue cerrado (p.ej. el amo cerró caja → el trigger mató a este esclavo). Ordenar cerrar SOLO a este
  -- equipo. Independiente del flag esExtension (alcanza a un esclavo "rogue"). Solo en PULSO (no login,
  -- que reabre a propósito) y con device conocido. Requiere que EXISTA una fila de acceso no-ACTIVA
  -- para este device en esta sesión (si no hay fila = legacy → no se toca).
  v_iddia := v_hook->>'idDia';
  if coalesce(p->>'esLogin','') <> '1' and not v_autocura
     and v_device is not null and v_device <> ''
     and v_iddia is not null and v_iddia <> ''
     and exists (select 1 from mos.accesos_dispositivos
                  where id_dia = v_iddia and device_id = v_device
                    and upper(coalesce(estado,'')) <> 'ACTIVA') then
    return jsonb_build_object('ok', true, 'debeCerrar', true,
      'motivo', 'ACCESO_CERRADO', 'id_personal', v_id);
  end if;

  -- [1006] hookOk=false → el cliente NO da por confirmado el login (sigue insistiendo con esLogin).
  return jsonb_build_object('ok', true, 'id_personal', v_id, 'last_seen', now(),
    'hookOk',    (v_hook is not null and coalesce(v_hook->>'ok','') = 'true'),
    'hookError', v_hookerr,
    'idDia',     v_iddia,
    'autocurada', v_autocura);
end;
$fn$;
