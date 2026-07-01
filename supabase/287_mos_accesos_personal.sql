-- ============================================================================
-- 287_mos_accesos_personal.sql — SUPER TABLA de asistencia+jornal+auditoría (ME+WH)
-- ----------------------------------------------------------------------------
-- OBJETIVO (diseño DISENO_accesos_personal_unificado.md): que TODO empleado que
-- ingresa a ME o WH aparezca en "personal del día" AL MOMENTO de loguearse (no de
-- madrugada por el snapshot), con su asistencia (hora de ingreso + última conexión),
-- y se cierre forzado a las 23:00 Lima (re-login obligatorio + seguridad).
--
-- ENFOQUE: NO se crea tabla nueva. Se EXTIENDE mos.liquidaciones_dia (la super tabla
-- que ya es 1 fila/persona/día con monto_base/pago_envasado/bono_meta/total_dia/estado
-- VETADA/auditado...). Solo se agregan COLUMNAS de asistencia/producción/auditoría
-- (aditivo: las RPC viejas — upsert_liquidacion_dia, set_bonificacion_sancion, veto —
-- las ignoran, así que NADA se rompe y el dinero queda intacto).
--
-- ⚠️ MONEY-SAFE: este lote NO recomputa total_dia salvo en la fila NUEVA (= monto_base
--    fijo). En filas existentes solo toca columnas de ASISTENCIA; jamás pisa
--    bonificacion/sancion/estado/id_pago ni el total ya calculado. El cómputo de
--    pago_envasado/comisión sigue siendo del flujo existente (Fase 2 lo hará en vivo).
--
-- ⚠️ NACE INERTE: kill-switch mos.config MOS_ACCESOS_DIRECTO default '0'. Con el flag
--    OFF las RPC de ESCRITURA devuelven *_OFF y no hacen nada. El cron 11pm queda
--    programado pero su función respeta el flag (no cierra nada si OFF). El front se
--    cablea detrás del mismo flag. Activación = del dueño (prende el flag).
-- ============================================================================

-- ═══════════════════════════════════════════════════════════════════════════
-- 0) KILL-SWITCH (default '0' → INERTE).
-- ═══════════════════════════════════════════════════════════════════════════
insert into mos.config (clave, valor, descripcion) values
  ('MOS_ACCESOS_DIRECTO','0','Registro unificado de accesos de personal (asistencia ME+WH en liquidaciones_dia al ingresar + cierre 11pm). OFF → inerte.')
on conflict (clave) do nothing;

-- Tarifa por producto envasado, CENTRALIZADA en Supabase (hoy 0.10, antes dispersa en
-- el front/GAS). Las filas existentes ya usan 0.10; sembramos el mismo valor. Editable
-- desde MOS Config. Si ya existe, NO se pisa.
insert into mos.config (clave, valor, descripcion) values
  ('tarifa_envasado','0.10','Pago por producto envasado (S/ por unidad). Lo usa el cálculo de pago_envasado.')
on conflict (clave) do nothing;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1) COLUMNAS NUEVAS en mos.liquidaciones_dia (aditivo, idempotente).
--    Cada una explicada — son la capa de asistencia/producción/auditoría.
-- ═══════════════════════════════════════════════════════════════════════════
alter table mos.liquidaciones_dia
  add column if not exists es_temporal        boolean     default false,  -- true = vendedor/cajero de zona (usuario plantilla, sin id fijo)
  add column if not exists zona               text        default '',     -- zona_id (ej. 'ZONA-02')
  add column if not exists device_id          text        default '',     -- dispositivo desde el que ingresó (para forzar_logout 11pm)
  add column if not exists hora_ingreso       timestamptz,                 -- PRIMER login del día ("a qué hora entró")
  add column if not exists ultima_conexion    timestamptz,                 -- último heartbeat/polling ("sigue conectado?")
  add column if not exists hora_salida        timestamptz,                 -- logout / cierre forzado 11pm
  add column if not exists minutos_activos    numeric     default 0,       -- acumulado de actividad del día
  add column if not exists estado_sesion      text        default '',      -- ACTIVA | CERRADA | FORZADA_11PM | AUTOCIERRE
  add column if not exists reconexiones       integer     default 0,       -- cuántas veces volvió a entrar en el día
  add column if not exists productos_envasados numeric    default 0,       -- u envasadas (insumo pago_envasado) — lo llena Fase 2
  add column if not exists venta_cobrada      numeric     default 0,       -- S/ cobrado por la persona (insumo comisión) — Fase 2
  add column if not exists venta_zona         numeric     default 0,       -- S/ cobrado por toda la zona — Fase 2
  add column if not exists meta_zona          numeric     default 0,       -- meta de venta de la zona (un número por zona)
  add column if not exists progreso_venta_pct numeric     default 0,       -- venta_cobrada / meta × 100
  add column if not exists auditorias_hechas  numeric     default 0,       -- productos auditados en el día
  add column if not exists meta_auditorias    numeric     default 0,       -- cuota dinámica (config evalMetaAuditorias)
  add column if not exists cumplio_auditorias boolean     default false;   -- auditorias_hechas >= meta_auditorias

-- Índice para la lectura "quién está conectado ahora" (presencia en vivo) y por día.
create index if not exists idx_liqdia_fecha_sesion
  on mos.liquidaciones_dia (fecha, estado_sesion);

-- ═══════════════════════════════════════════════════════════════════════════
-- 2) helper: monto_base fijo por persona (real) o por rol-plantilla (temporal ME).
--    El temporal de zona NO tiene id_personal propio → su fijo sale de la plantilla
--    de su rol en mos.personal (ej. CAJERO → PER099.monto_base = 50).
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function mos._fijo_personal(p_id_personal text, p_rol text)
returns numeric language sql stable set search_path = '' as $fn$
  select coalesce(
    -- 1) persona real por id
    (select monto_base from mos.personal
      where id_personal = p_id_personal and monto_base is not null limit 1),
    -- 2) plantilla por rol (cualquier persona activa de ese rol con fijo definido)
    (select monto_base from mos.personal
      where upper(coalesce(rol,'')) = upper(coalesce(p_rol,''))
        and monto_base is not null and coalesce(estado,false) = true
      order by monto_base desc limit 1),
    0::numeric);
$fn$;
revoke all on function mos._fijo_personal(text,text) from public;
grant execute on function mos._fijo_personal(text,text) to service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3) mos.registrar_ingreso_personal(p jsonb) — REGISTRO AL INGRESAR (ME + WH).
--    Lo llama el front al loguearse. Crea la fila del día si no existe (la persona
--    APARECE de inmediato en "personal del día") y sella la asistencia. Idempotente.
--    p = { idPersonal, nombre, rol, appOrigen, zona, estacion, deviceId, esTemporal }
--    Gate: claim de app (cualquier app autenticada del ecosistema). MASTER/ADMIN no
--    generan jornal (igual que upsert_liquidacion_dia) → skipped.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function mos.registrar_ingreso_personal(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_rol     text := upper(btrim(coalesce(p->>'rol','')));
  v_nombre  text := btrim(coalesce(p->>'nombre',''));
  v_app     text := btrim(coalesce(p->>'appOrigen',''));
  v_zona    text := btrim(coalesce(p->>'zona',''));
  v_dev     text := btrim(coalesce(p->>'deviceId',''));
  v_temp    boolean := coalesce((p->>'esTemporal')::boolean, false);
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
  select true, hora_ingreso, coalesce(estado_sesion,'')
    into v_exists, v_ingreso, v_estado_ses
    from mos.liquidaciones_dia where id_dia = v_id_dia for update;

  if v_exists then
    -- SOLO asistencia. NO se toca dinero (monto_base/pago_envasado/bono_meta/total_dia)
    -- ni manual (bonificacion/sancion/estado/id_pago). reconexiones++ si estaba cerrada.
    update mos.liquidaciones_dia set
        hora_ingreso    = coalesce(hora_ingreso, v_now),         -- primer login: se fija una vez
        ultima_conexion = v_now,
        estado_sesion   = 'ACTIVA',
        hora_salida     = null,                                   -- reabre si volvió a entrar
        presente        = true,
        zona            = case when v_zona <> '' then v_zona else zona end,
        device_id       = case when v_dev  <> '' then v_dev  else device_id end,
        es_temporal     = v_temp,
        meta_auditorias = case when v_metaaud > 0 then v_metaaud else meta_auditorias end,
        reconexiones    = reconexiones + case when v_estado_ses in ('CERRADA','FORZADA_11PM','AUTOCIERRE') then 1 else 0 end,
        ts_actualizado  = v_now
      where id_dia = v_id_dia;
    -- [ext] registrar/refrescar el device de la sesión (principal si es el 1º ACTIVO)
    if v_dev <> '' then
      insert into mos.accesos_dispositivos (id_dia, device_id, rol, es_principal, estado)
      values (v_id_dia, v_dev, v_rol,
              not exists(select 1 from mos.accesos_dispositivos where id_dia=v_id_dia and es_principal and upper(coalesce(estado,''))='ACTIVA'),
              'ACTIVA')
      on conflict (id_dia, device_id) do update set estado='ACTIVA', ultima_conexion=v_now, rol=excluded.rol;
    end if;
    return jsonb_build_object('ok',true,'created',false,'idDia',v_id_dia,'horaIngreso',coalesce(v_ingreso,v_now));
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
$fn$;
revoke all on function mos.registrar_ingreso_personal(jsonb) from public;
grant execute on function mos.registrar_ingreso_personal(jsonb) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4) mos.heartbeat_personal(p jsonb) — PULSO (polling cada ~60s mientras logueado).
--    Actualiza ultima_conexion y minutos_activos (now − hora_ingreso, capped 24h).
--    No toca dinero. Idempotente. p = { idPersonal }
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function mos.heartbeat_personal(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
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
  return jsonb_build_object('ok', v_n>0, 'idDia', v_id_dia);
end;
$fn$;
revoke all on function mos.heartbeat_personal(jsonb) from public;
grant execute on function mos.heartbeat_personal(jsonb) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5) mos.cerrar_sesiones_forzado_11pm() — CIERRE DURO 23:00 Lima (cron).
--    Cierra TODA sesión ACTIVA del día → FORZADA_11PM, sella salida + minutos, y marca
--    forzar_logout en los dispositivos que estaban logueados → re-login obligatorio
--    mañana + seguridad (sin sesiones abiertas de noche). Respeta el flag (INERTE si OFF).
--    Sin gate de claim (la corre pg_cron como owner). NO toca dinero.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function mos.cerrar_sesiones_forzado_11pm()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_dia   date := (now() at time zone 'America/Lima')::date;
  v_fecha timestamptz := ((to_char(v_dia,'YYYY-MM-DD') || ' 00:00:00')::timestamp at time zone 'America/Lima');
  v_now   timestamptz := now();
  v_ses int := 0; v_dev int := 0;
begin
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',true,'skipped','MOS_ACCESOS_DIRECTO_OFF');
  end if;

  -- 1) cerrar sesiones de asistencia abiertas de hoy
  with cerradas as (
    update mos.liquidaciones_dia set
        estado_sesion   = 'FORZADA_11PM',
        hora_salida     = v_now,
        minutos_activos = least(1440, greatest(coalesce(minutos_activos,0),
                            round(extract(epoch from (v_now - coalesce(hora_ingreso, v_fecha)))/60.0))),
        ts_actualizado  = v_now
      where fecha = v_fecha and upper(coalesce(estado_sesion,'')) = 'ACTIVA'
      returning device_id
  )
  select count(*) into v_ses from cerradas;

  -- 2) forzar re-login en los dispositivos que estaban logueados hoy (seguridad)
  update mos.dispositivos d set
      forzar_logout  = true,
      logout_auto_ts = v_now
    where coalesce(d.id_dispositivo,'') in (
      select distinct device_id from mos.liquidaciones_dia
      where fecha = v_fecha and device_id is not null and btrim(device_id) <> ''
    );
  get diagnostics v_dev = row_count;

  return jsonb_build_object('ok',true,'sesiones_cerradas',v_ses,'dispositivos_forzados',v_dev,'fecha',v_dia);
end;
$fn$;
revoke all on function mos.cerrar_sesiones_forzado_11pm() from public;
grant execute on function mos.cerrar_sesiones_forzado_11pm() to service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6) pg_cron 23:00 Lima = 04:00 UTC (Lima UTC-5, sin DST). Idempotente.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
begin
  perform cron.unschedule('mos-cierre-forzado-11pm') where exists (select 1 from cron.job where jobname='mos-cierre-forzado-11pm');
exception when others then null;
end $$;
select cron.schedule('mos-cierre-forzado-11pm', '0 4 * * *', $$ select mos.cerrar_sesiones_forzado_11pm(); $$);
