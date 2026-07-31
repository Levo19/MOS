-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 594_ext_amo_esclavo_device_anchored.sql — Extensión amo-esclavo: fix de RAÍZ (device-anchored)
-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- CONTEXTO (incidente Mia 2026-07-31): la TABLET (amo) cerró su caja a las 15:03; el CELULAR (esclavo),
-- 1 minuto después, abrió su PROPIA caja fantasma y registró un egreso. Raíz múltiple:
--   (a) `es_principal` en accesos_dispositivos quedó INVERTIDO (el celular figuraba principal y la
--       tablet como extensión) → el trigger 593 (que dependía de es_principal) NO habría disparado.
--   (b) el heartbeat de logout (registrar_presencia→debeCerrar) solo mira `estado_sesion` de la PERSONA
--       (fila compartida por ambos equipos) → no puede tumbar a UN equipo dejando vivo al otro.
--   (c) al perder el flag esExtension en localStorage, el watcher de extensión del ME no corre → el
--       esclavo "rogue" sobrevive.
--
-- FIX (todo backend, sin tocar el frontend ME):
--   1) me._trg_caja_close_mata_extension — REEMPLAZA la lógica de 593: ya NO depende de es_principal.
--      Al cerrar una caja, el device que la cerró mata los accesos ACTIVA de los OTROS equipos de su
--      MISMA sesión (id_dia). Modelo del dueño: "si el amo cierra caja, el esclavo cierra sesión".
--      El que cierra sigue logueado (flujo normal). Un cajero de UN solo equipo no tiene "otros" → nada.
--   2) me.registrar_presencia — añade cierre a NIVEL DEVICE: si el acceso de ESTE equipo quedó cerrado
--      (por el trigger) pero la sesión de la persona sigue ACTIVA → devuelve debeCerrar SOLO a este
--      equipo. Independiente de esExtension (por eso alcanza al esclavo "rogue"). El heartbeat (30s)
--      del ME ya honra debeCerrar → cae al login. Money-safe (no interrumpe cobro/cámara en curso).
--   3) me.abrir_caja — GUARD: un equipo cuyo acceso fue CERRADO hoy y que no tiene ningún acceso ACTIVO
--      (fue "matado" y aún no re-logueó) NO puede abrir caja propia → debe re-loguearse. Última línea
--      de defensa contra cajas fantasma en la ventana de <30s antes de que caiga al login.
--
-- Reversible por el MISMO flag de 593 (MOS_EXT_SLAVE_MUERE_CON_AMO). Best-effort en el trigger
-- (jamás rompe el cierre de caja). Verificado con tx+ROLLBACK antes de aplicar en prod.
-- ════════════════════════════════════════════════════════════════════════════════════════════════

-- ── 1) TRIGGER device-anchored (supersede 593) ─────────────────────────────────────────────────
create or replace function me._trg_caja_close_mata_extension() returns trigger
language plpgsql security definer set search_path = '' as $trg$
declare v_dia text;
begin
  -- solo cuando la caja RECIÉN pasa a cerrada
  if upper(coalesce(NEW.estado,'')) not in ('CERRADA','AUTOCERRADA','CERRADA_AUTO','CERRADA_FORZADA') then return NEW; end if;
  if upper(coalesce(OLD.estado,'')) in ('CERRADA','AUTOCERRADA','CERRADA_AUTO','CERRADA_FORZADA') then return NEW; end if;
  if coalesce((select valor from mos.config where clave='MOS_EXT_SLAVE_MUERE_CON_AMO' limit 1),'1') <> '1' then
    return NEW;
  end if;
  if coalesce(NEW.dispositivo_id,'') = '' then return NEW; end if;
  -- sesión(es) donde el device que cerró está ACTIVO hoy → matar a los OTROS equipos de esa sesión.
  -- NO depende de es_principal (que puede estar mal asignado). El que cerró queda logueado.
  for v_dia in
    select id_dia from mos.accesos_dispositivos
     where device_id = NEW.dispositivo_id and upper(coalesce(estado,'')) = 'ACTIVA'
  loop
    update mos.accesos_dispositivos
       set estado = 'CERRADA', ultima_conexion = now()
     where id_dia = v_dia
       and device_id <> NEW.dispositivo_id
       and upper(coalesce(estado,'')) = 'ACTIVA';
  end loop;
  return NEW;
exception when others then
  return NEW;  -- jamás romper el cierre de caja por esto
end;
$trg$;

drop trigger if exists trg_caja_close_mata_extension on me.cajas;
create trigger trg_caja_close_mata_extension
  after update on me.cajas
  for each row execute function me._trg_caja_close_mata_extension();

-- ── 2) me.registrar_presencia — + cierre a NIVEL DEVICE (base: 415) ─────────────────────────────
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
  v_iddia     text;            -- [594] idDia devuelto por el hook (para el chequeo por-device)
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
  if coalesce(p->>'esLogin','') <> '1'
     and v_device is not null and v_device <> ''
     and v_iddia is not null and v_iddia <> ''
     and exists (select 1 from mos.accesos_dispositivos
                  where id_dia = v_iddia and device_id = v_device
                    and upper(coalesce(estado,'')) <> 'ACTIVA') then
    return jsonb_build_object('ok', true, 'debeCerrar', true,
      'motivo', 'ACCESO_CERRADO', 'id_personal', v_id);
  end if;

  return jsonb_build_object('ok', true, 'id_personal', v_id, 'last_seen', now());
end;
$function$;

revoke all on function me.registrar_presencia(jsonb) from public;
grant execute on function me.registrar_presencia(jsonb) to authenticated, service_role;

-- ── 3) me.abrir_caja — + GUARD equipo matado no abre caja propia (base: 246) ────────────────────
create or replace function me.abrir_caja(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app      text := me.jwt_app();
  v_vendedor text := nullif(btrim(coalesce(p->>'vendedor','')), '');
  v_estacion text := coalesce(p->>'estacion','');
  v_zona     text := nullif(btrim(coalesce(p->>'zona','')), '');
  v_monto    numeric := coalesce(nullif(btrim(coalesce(p->>'montoInicial','')),'')::numeric, 0);
  v_pn       text := coalesce(p->>'printNodeId','');
  v_dev      text := coalesce(p->>'deviceId','');
  v_auto     int := 0;
  v_existe   me.cajas%rowtype;
  v_id       text;
  v_hoy      date := (now() at time zone 'America/Lima')::date;
begin
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_APERTURA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('status','error','error','APERTURA_DIRECTA_DESACTIVADA');
  end if;
  if v_vendedor is null then return jsonb_build_object('status','error','error','VENDEDOR_REQUERIDO'); end if;
  if v_zona     is null then return jsonb_build_object('status','error','error','ZONA_REQUERIDA'); end if;

  perform pg_advisory_xact_lock(hashtext('me_abrir_caja:'||v_zona));

  -- 1. Auto-cerrar cajas ABIERTAS de días anteriores (TZ Lima) en la zona.
  with vieja as (
    update me.cajas set estado='CERRADA_AUTO', fecha_cierre=now()
     where estado='ABIERTA' and zona_id = v_zona
       and (fecha_apertura at time zone 'America/Lima')::date < v_hoy
    returning 1
  )
  select count(*)::int into v_auto from vieja;

  -- 2. Guard 1-cajero-por-zona (sobre lo que quedó ABIERTA hoy).
  select * into v_existe from me.cajas where zona_id = v_zona and estado = 'ABIERTA' limit 1;
  if found then
    if v_existe.vendedor is not distinct from v_vendedor then
      -- idempotente: el mismo cajero ya abrió (retry / extensión que comparte la caja del amo).
      return jsonb_build_object('status','success','dedup',true,'idCaja',v_existe.id_caja,
        'cajasAutoCerradas',v_auto,'mensaje','Caja ya abierta');
    end if;
    return jsonb_build_object('status','error','error',
      'Ya hay un turno activo en '||v_zona||' (cajero: '||coalesce(v_existe.vendedor,'')||'). Cierra ese turno primero.');
  end if;

  -- [594] GUARD esclavo matado: si este device tiene un acceso CERRADO hoy y NINGÚN acceso ACTIVO
  -- (fue cerrado por el amo/trigger y aún no re-logueó) → NO abre caja propia; debe re-loguearse.
  -- Si re-logueó, registrar_ingreso_personal le dejó un acceso ACTIVA → no se bloquea. Un device de
  -- un día anterior no cuenta (filtro por fecha Lima de ultima_conexion).
  if v_dev <> '' and exists (
       select 1 from mos.accesos_dispositivos
        where device_id = v_dev and upper(coalesce(estado,'')) = 'CERRADA'
          and (ultima_conexion at time zone 'America/Lima')::date = v_hoy
     ) and not exists (
       select 1 from mos.accesos_dispositivos
        where device_id = v_dev and upper(coalesce(estado,'')) = 'ACTIVA'
          and (ultima_conexion at time zone 'America/Lima')::date = v_hoy
     ) then
    return jsonb_build_object('status','error','error','SESION_CERRADA_RELOGIN',
      'mensaje','Tu sesión fue cerrada por el equipo principal. Vuelve a iniciar sesión.');
  end if;

  -- 3. Crear la caja.
  v_id := 'CAJA-' || (extract(epoch from clock_timestamp())*1000)::bigint;
  insert into me.cajas (id_caja, vendedor, estacion, fecha_apertura, monto_inicial, estado, zona_id, printnode_id, dispositivo_id)
  values (v_id, v_vendedor, v_estacion, now(), v_monto, 'ABIERTA', v_zona, nullif(v_pn,''), nullif(v_dev,''));

  return jsonb_build_object('status','success','idCaja',v_id,'cajasAutoCerradas',v_auto,
                            'mensaje','Caja aperturada exitosamente');
end;
$fn$;

revoke all on function me.abrir_caja(jsonb) from public;
grant execute on function me.abrir_caja(jsonb) to authenticated, service_role;

notify pgrst, 'reload schema';
