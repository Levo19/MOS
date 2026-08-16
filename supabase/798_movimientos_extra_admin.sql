-- 798_movimientos_extra_admin.sql — [Extras admin desde MOS] CRUD auditado de me.movimientos_extra.
--
-- POR QUÉ: el 15-ago una cajera registró DOS egresos equivocados con concepto "Cierre de caja"
-- (Yape S/1964.40 + Efectivo S/1640.00). El cierre YA descuenta lo entregado, así que esos extras
-- duplicaron la salida y el arqueo quedó en −1925.60 cuando debía ser +1678.80. Hasta hoy MOS solo
-- podía MIRAR los extras (me.movimientos_extra_caja, 403) y su historial (mos.me_historial_extra, 118):
-- no había forma de corregirlos sin entrar a la base. Estas 4 RPCs cierran el hueco con PIN admin.
--
-- CONVENCIONES DE LA CASA: {p jsonb} único, security definer, set search_path='', gate por claim de app
-- (me.jwt_app), re-verificación server-side del PIN admin (mos.reverificar_clave_admin — mismo patrón que
-- me.cobrar_venta_directo), grants a anon/authenticated/service_role como sus vecinas del esquema me.
--
-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- DECISIÓN 1 · ELIMINAR = DELETE REAL (no borrado lógico). POR QUÉ:
--   me.movimientos_extra NO tiene columna de anulado (02_schema_me.sql:91) y HAY 13 funciones que la
--   leen y suman (me.cerrar_caja, me.cerrar_caja_forzado, me.simular_cierre_caja, me.cierre_datos_caja,
--   me.datos_turno, me.estado_cajas, me.alerta_calcular_efectivo, me.confirmar_cobro,
--   me.cobrar_credito_directo, me.crear_movimiento_directo, me.movimientos_extra_caja,
--   mos.cierres_caja, mos.me_historial_extra). Agregar `anulado` obligaría a parchear TODAS: la que se
--   olvide seguiría sumando el extra "borrado" al arqueo — es decir, el borrado lógico NO arreglaría el
--   problema real del dueño y encima dejaría el sistema inconsistente. Se elige DELETE real + RASTRO
--   COMPLETO en mos.auditoria_admin (la tabla de auditoría que YA usa el ecosistema, 49_mos_autorizacion_f0):
--   fila con accion='EXTRA_ELIMINAR', quién autorizó, motivo y el registro íntegro en cliente_meta.
--   Un extra borrado se puede reconstruir 1:1 desde esa fila.
--
-- DECISIÓN 2 · `total` en extras_de_caja = CANTIDAD de movimientos (no un monto). Los montos van en
--   totalIngreso / totalEgreso / totalIngresoVirtual / totalEgresoVirtual (+ netoEfectivo / netoVirtual
--   de regalo, para que el front no tenga que hacer aritmética de dinero en JS).
--
-- DECISIÓN 3 · extra_crear NO exige caja ABIERTA (a diferencia de me.crear_movimiento_directo, que sí lo
--   hace porque ahí escribe la cajera en vivo). Acá escribe el ADMIN, y el caso de uso es justamente
--   corregir una caja ya cerrada. Sí se valida que el id_caja EXISTA (nunca inventar una caja).
-- ─────────────────────────────────────────────────────────────────────────────────────────────────

-- ── Catálogo de acciones auth (mos.permisos_accion → lo lee mos.auth_catalogo/386 y pedirAuth) ──
--    EDITAR/CREAR = tier 2 (cache 5 min, como EDITAR_CLIENTE_VENTA). ELIMINAR = tier 3 (sin cache,
--    como CIERRE_CAJA_FORZADO): destruye un registro de dinero, se pide el PIN cada vez.
insert into mos.permisos_accion (accion, tier, nivel_minimo, label, app) values
  ('EXTRA_CREAR',    2, 2, 'Crear movimiento extra',    'MOS'),
  ('EXTRA_EDITAR',   2, 2, 'Editar movimiento extra',   'MOS'),
  ('EXTRA_ELIMINAR', 3, 2, 'Eliminar movimiento extra', 'MOS')
on conflict (accion) do update
  set tier = excluded.tier, nivel_minimo = excluded.nivel_minimo,
      label = excluded.label, app = excluded.app;

-- ── Helper: historial_cambios normalizado a ARRAY ──────────────────────────────────────────────
-- El campo nació libre: puede venir null, array, o el objeto {historial:[...]} (mos.me_historial_extra
-- ya contempla las 3 formas). Todo lo que escribamos de acá en adelante es ARRAY plano.
create or replace function me._movext_hist(p_hc jsonb)
returns jsonb language sql immutable set search_path='' as $fn$
  select case
    when p_hc is null then '[]'::jsonb
    when jsonb_typeof(p_hc) = 'array' then p_hc
    when jsonb_typeof(p_hc) = 'object' and p_hc ? 'historial'
         and jsonb_typeof(p_hc->'historial') = 'array' then p_hc->'historial'
    else '[]'::jsonb
  end;
$fn$;

-- ── Helper: ¿fue EDITADO alguna vez? ───────────────────────────────────────────────────────────
-- OJO: no alcanza con "historial no vacío". me.extra_crear siembra un evento CREAR, así que un extra
-- recién nacido desde MOS tendría historial y saldría marcado como "editado" siendo mentira. Editado =
-- existe al menos un evento que NO sea la creación.
create or replace function me._movext_editado(p_hc jsonb)
returns boolean language sql immutable set search_path='' as $fn$
  select exists (
    select 1 from jsonb_array_elements(me._movext_hist(p_hc)) e
     where upper(coalesce(e->>'accion','')) not in ('CREAR','ALTA')
  );
$fn$;

-- ── Helper: ¿tipo válido? (el signo lo da el tipo; el monto SIEMPRE es positivo) ────────────────
create or replace function me._movext_tipo_ok(p_tipo text)
returns boolean language sql immutable set search_path='' as $fn$
  select upper(btrim(coalesce(p_tipo,''))) in ('INGRESO','EGRESO','INGRESO_VIRTUAL','EGRESO_VIRTUAL');
$fn$;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 1) me.extras_de_caja(p {idCaja}) — TODOS los extras de una caja + totales por tipo.
--    Alimenta el overlay "💸 Extras" de MOS. Orden ascendente por ts (como los ve la cajera).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.extras_de_caja(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare
  v_caja  text := nullif(btrim(coalesce(p->>'idCaja','')),'');
  v_tz    text := 'America/Lima';
  v_items jsonb; v_n int;
  v_ti numeric; v_te numeric; v_tiv numeric; v_tev numeric;
begin
  if coalesce(me.jwt_app(),'') not in ('MOS','mosExpress') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_caja is null then
    return jsonb_build_object('ok',false,'error','idCaja requerido');
  end if;

  with base as (
    select m.id_extra, m.tipo, m.monto, m.concepto, m.obs, m.registrado_por, m.historial_cambios,
           coalesce(m.ts, m.created_at) as ord
      from me.movimientos_extra m
     where m.id_caja = v_caja
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'idExtra',       b.id_extra,
      'ts',            case when b.ord is not null
                            then to_char(b.ord at time zone v_tz, 'YYYY-MM-DD"T"HH24:MI') else '' end,
      'tipo',          upper(coalesce(b.tipo,'EGRESO')),
      'monto',         round(coalesce(b.monto,0), 2),
      'concepto',      coalesce(b.concepto,''),
      'obs',           coalesce(b.obs,''),
      'registradoPor', coalesce(b.registrado_por,''),
      'editado',       me._movext_editado(b.historial_cambios),
      'creadoEnMos',   exists (select 1 from jsonb_array_elements(me._movext_hist(b.historial_cambios)) e
                                where upper(coalesce(e->>'accion','')) = 'CREAR')
    ) order by b.ord asc nulls last, b.id_extra asc), '[]'::jsonb),
    count(*)::int,
    coalesce(sum(case when upper(coalesce(b.tipo,'')) = 'INGRESO'         then b.monto else 0 end), 0),
    coalesce(sum(case when upper(coalesce(b.tipo,'')) = 'EGRESO'          then b.monto else 0 end), 0),
    coalesce(sum(case when upper(coalesce(b.tipo,'')) = 'INGRESO_VIRTUAL' then b.monto else 0 end), 0),
    coalesce(sum(case when upper(coalesce(b.tipo,'')) = 'EGRESO_VIRTUAL'  then b.monto else 0 end), 0)
    into v_items, v_n, v_ti, v_te, v_tiv, v_tev
  from base b;

  return jsonb_build_object(
    'ok', true, 'idCaja', v_caja,
    'items', coalesce(v_items,'[]'::jsonb),
    'total', coalesce(v_n,0),                      -- ← CANTIDAD de movimientos (ver DECISIÓN 2)
    'totalIngreso',        round(coalesce(v_ti,0), 2),
    'totalEgreso',         round(coalesce(v_te,0), 2),
    'totalIngresoVirtual', round(coalesce(v_tiv,0), 2),
    'totalEgresoVirtual',  round(coalesce(v_tev,0), 2),
    'netoEfectivo',        round(coalesce(v_ti,0) - coalesce(v_te,0), 2),
    'netoVirtual',         round(coalesce(v_tiv,0) - coalesce(v_tev,0), 2));
end; $fn$;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 2) me.extra_editar(p {idExtra, tipo?, monto?, concepto?, obs?, usuario, rol?, motivo?, claveAdmin})
--    Parchea SOLO las llaves presentes en p. Acumula en historial_cambios un evento
--    {accion:'EDITAR', antes, despues, usuario, ts}. Sin cambios reales → noop idempotente.
--    El evento incluye además `timestamp` y `cambios[{campo,antes,despues}]` porque así lo pinta el
--    timeline que YA existe en MOS (_tkHistRender, app.js) — mismo dato, dos formas.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.extra_editar(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_rvf   jsonb;
  v_id    text := nullif(btrim(coalesce(p->>'idExtra','')),'');
  v_user  text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'MOS-admin');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_mot   text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'');
  v_row   me.movimientos_extra%rowtype;
  v_tipo  text; v_monto numeric; v_conc text; v_obs text;
  v_antes jsonb := '{}'::jsonb; v_desp jsonb := '{}'::jsonb; v_cambios jsonb := '[]'::jsonb;
  v_ts    text := to_char(now() at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI:SS');
begin
  -- PIN admin re-verificado en el servidor (no alcanza con que el front lo haya pedido).
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'EXTRA_EDITAR',
                                       coalesce(v_id,''), coalesce(p->>'app','MOS'), true);
  if v_rvf is not null then return v_rvf; end if;
  if coalesce(me.jwt_app(),'') <> 'MOS' then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idExtra requerido'); end if;

  -- Lock por extra: dos admins editando el mismo movimiento se serializan.
  perform pg_advisory_xact_lock(hashtext('movext:'||v_id));
  select * into v_row from me.movimientos_extra where id_extra = v_id for update;
  if not found then
    return jsonb_build_object('ok',false,'error','Movimiento '||v_id||' no encontrado');
  end if;

  -- Valores nuevos: solo las llaves PRESENTES en p (patch parcial, nunca borrar por omisión).
  v_tipo := upper(coalesce(v_row.tipo,'EGRESO'));
  if p ? 'tipo' and nullif(btrim(coalesce(p->>'tipo','')),'') is not null then
    v_tipo := upper(btrim(p->>'tipo'));
    if not me._movext_tipo_ok(v_tipo) then
      return jsonb_build_object('ok',false,'error','tipo inválido (INGRESO/EGRESO/INGRESO_VIRTUAL/EGRESO_VIRTUAL)');
    end if;
  end if;

  v_monto := round(coalesce(v_row.monto,0), 2);
  if p ? 'monto' and nullif(btrim(coalesce(p->>'monto','')),'') is not null then
    begin
      v_monto := round((p->>'monto')::numeric, 2);
    exception when others then
      return jsonb_build_object('ok',false,'error','monto inválido');
    end;
    if v_monto <= 0 then
      return jsonb_build_object('ok',false,'error','El monto debe ser mayor a 0 (el signo lo da el tipo)');
    end if;
  end if;

  v_conc := coalesce(v_row.concepto,'');
  if p ? 'concepto' then v_conc := btrim(coalesce(p->>'concepto','')); end if;
  v_obs  := coalesce(v_row.obs,'');
  if p ? 'obs' then v_obs := btrim(coalesce(p->>'obs','')); end if;

  -- Diff campo por campo (solo lo que REALMENTE cambia entra al historial).
  if v_tipo is distinct from upper(coalesce(v_row.tipo,'EGRESO')) then
    v_antes := v_antes || jsonb_build_object('tipo', upper(coalesce(v_row.tipo,'')));
    v_desp  := v_desp  || jsonb_build_object('tipo', v_tipo);
    v_cambios := v_cambios || jsonb_build_array(jsonb_build_object(
      'campo','Tipo','antes',upper(coalesce(v_row.tipo,'')),'despues',v_tipo));
  end if;
  if v_monto is distinct from round(coalesce(v_row.monto,0),2) then
    v_antes := v_antes || jsonb_build_object('monto', round(coalesce(v_row.monto,0),2));
    v_desp  := v_desp  || jsonb_build_object('monto', v_monto);
    v_cambios := v_cambios || jsonb_build_array(jsonb_build_object(
      'campo','Monto','antes',to_char(round(coalesce(v_row.monto,0),2),'FM999999990.00'),
      'despues',to_char(v_monto,'FM999999990.00')));
  end if;
  if v_conc is distinct from coalesce(v_row.concepto,'') then
    v_antes := v_antes || jsonb_build_object('concepto', coalesce(v_row.concepto,''));
    v_desp  := v_desp  || jsonb_build_object('concepto', v_conc);
    v_cambios := v_cambios || jsonb_build_array(jsonb_build_object(
      'campo','Concepto','antes',coalesce(v_row.concepto,''),'despues',v_conc));
  end if;
  if v_obs is distinct from coalesce(v_row.obs,'') then
    v_antes := v_antes || jsonb_build_object('obs', coalesce(v_row.obs,''));
    v_desp  := v_desp  || jsonb_build_object('obs', v_obs);
    v_cambios := v_cambios || jsonb_build_array(jsonb_build_object(
      'campo','Obs','antes',coalesce(v_row.obs,''),'despues',v_obs));
  end if;

  -- Idempotencia: reintento/doble-tap con los mismos valores no ensucia el historial.
  if jsonb_array_length(v_cambios) = 0 then
    return jsonb_build_object('ok',true,'noop',true,'idExtra',v_id,'mensaje','Sin cambios');
  end if;

  update me.movimientos_extra
     set tipo = v_tipo, monto = v_monto, concepto = v_conc, obs = v_obs,
         historial_cambios = me._movext_hist(v_row.historial_cambios) || jsonb_build_array(
           jsonb_build_object(
             'accion','EDITAR',
             'antes', v_antes, 'despues', v_desp, 'cambios', v_cambios,
             'usuario', v_user, 'rol', v_rol,
             'motivo', v_mot, 'origen','MOS-admin',
             'ts', v_ts, 'timestamp', v_ts,
             'autorizadoPor', jsonb_build_object('nombre', v_user))),
         updated_at = now()
   where id_extra = v_id;

  return jsonb_build_object('ok',true,'idExtra',v_id,'cambios',v_cambios,
                            'data', jsonb_build_object('idExtra',v_id,'tipo',v_tipo,'monto',v_monto,
                                                       'concepto',v_conc,'obs',v_obs));
end; $fn$;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 3) me.extra_eliminar(p {idExtra, usuario, rol?, motivo, claveAdmin}) — DELETE real + rastro.
--    Ver DECISIÓN 1 arriba: el registro completo (incluido su historial) queda en mos.auditoria_admin
--    con accion='EXTRA_ELIMINAR'. Idempotente: si ya no existe devuelve noop.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.extra_eliminar(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_rvf  jsonb;
  v_id   text := nullif(btrim(coalesce(p->>'idExtra','')),'');
  v_user text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'MOS-admin');
  v_rol  text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_mot  text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'');
  v_row  me.movimientos_extra%rowtype;
  v_snap jsonb;
  v_acc  text;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'EXTRA_ELIMINAR',
                                       coalesce(v_id,''), coalesce(p->>'app','MOS'), true);
  if v_rvf is not null then return v_rvf; end if;
  if coalesce(me.jwt_app(),'') <> 'MOS' then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idExtra requerido'); end if;

  perform pg_advisory_xact_lock(hashtext('movext:'||v_id));
  select * into v_row from me.movimientos_extra where id_extra = v_id for update;
  if not found then
    return jsonb_build_object('ok',true,'noop',true,'idExtra',v_id,'mensaje','Ya no existe');
  end if;

  -- Snapshot íntegro ANTES de borrar (to_jsonb del row + su historial normalizado).
  v_snap := to_jsonb(v_row) || jsonb_build_object('historial_cambios', me._movext_hist(v_row.historial_cambios));
  v_acc  := 'EXTRADEL-'||v_id||'-'||to_char(clock_timestamp() at time zone 'UTC','YYYYMMDDHH24MISSUS');

  insert into mos.auditoria_admin (id_accion, fecha, accion, ref_documento,
                                   nombre_autoriza, rol_autoriza, nivel_autoriza,
                                   app_origen, tier, cliente_meta, detalle)
  values (v_acc, now(), 'EXTRA_ELIMINAR', v_id,
          v_user, v_rol, mos.rol_nivel(v_rol),
          'MOS', 3,
          jsonb_build_object('motivo', v_mot, 'extraBorrado', v_snap),
          'Movimiento extra eliminado desde MOS · caja '||coalesce(v_row.id_caja,'—')||
          ' · '||upper(coalesce(v_row.tipo,''))||' S/ '||to_char(round(coalesce(v_row.monto,0),2),'FM999999990.00')||
          ' · '||coalesce(v_row.concepto,'')||case when v_mot <> '' then ' · motivo: '||v_mot else '' end);

  delete from me.movimientos_extra where id_extra = v_id;

  return jsonb_build_object('ok',true,'idExtra',v_id,'idCaja',coalesce(v_row.id_caja,''),
                            'auditoria', v_acc,
                            'data', jsonb_build_object('idExtra',v_id,'eliminado',true));
end; $fn$;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- 4) me.extra_crear(p {idCaja, tipo, monto, concepto?, obs?, usuario, rol?, idExtra?, claveAdmin})
--    Mismo shape que crea ME (me.crear_movimiento_directo, 19) pero registrado_por = el ADMIN y con
--    historial_cambios sembrado con {accion:'CREAR', origen:'MOS-admin'} → se distingue a simple vista
--    de los que nacieron en el POS. Idempotente por id_extra.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.extra_crear(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_rvf   jsonb;
  v_caja  text := nullif(btrim(coalesce(p->>'idCaja','')),'');
  v_id    text := nullif(btrim(coalesce(p->>'idExtra','')),'');
  v_tipo  text := upper(btrim(coalesce(p->>'tipo','')));
  v_monto numeric;
  v_conc  text := btrim(coalesce(p->>'concepto',''));
  v_obs   text := btrim(coalesce(p->>'obs',''));
  v_user  text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'MOS-admin');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_mot   text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'');
  v_zona  text;
  v_ok    boolean;
  v_ins   int;
  v_ts    text := to_char(now() at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI:SS');
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'EXTRA_CREAR',
                                       coalesce(v_caja,''), coalesce(p->>'app','MOS'), true);
  if v_rvf is not null then return v_rvf; end if;
  if coalesce(me.jwt_app(),'') <> 'MOS' then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_caja is null then return jsonb_build_object('ok',false,'error','idCaja requerido'); end if;
  if not me._movext_tipo_ok(v_tipo) then
    return jsonb_build_object('ok',false,'error','tipo inválido (INGRESO/EGRESO/INGRESO_VIRTUAL/EGRESO_VIRTUAL)');
  end if;
  begin
    v_monto := round(coalesce(nullif(btrim(coalesce(p->>'monto','')),''),'0')::numeric, 2);
  exception when others then
    return jsonb_build_object('ok',false,'error','monto inválido');
  end;
  if v_monto <= 0 then
    return jsonb_build_object('ok',false,'error','El monto debe ser mayor a 0 (el signo lo da el tipo)');
  end if;

  -- La caja tiene que EXISTIR (nunca crear extras sobre un id inventado). No se exige ABIERTA:
  -- el admin corrige justamente cajas ya cerradas (ver DECISIÓN 3).
  select true, coalesce(c.zona_id,'') into v_ok, v_zona from me.cajas c where c.id_caja = v_caja limit 1;
  if not coalesce(v_ok,false) then
    return jsonb_build_object('ok',false,'error','Caja '||v_caja||' no encontrada');
  end if;

  -- id_extra: el del cliente (idempotencia ante reintento) o uno nuevo con el mismo formato de ME.
  if v_id is null then
    v_id := 'EX-'||((extract(epoch from clock_timestamp())*1000)::bigint)::text||'-'||substr(md5(random()::text),1,6);
  end if;

  perform pg_advisory_xact_lock(hashtext('movext:'||v_id));
  insert into me.movimientos_extra (id_extra, id_caja, ts, tipo, monto, concepto, obs,
                                    registrado_por, zona_id, dispositivo_id, historial_cambios)
  values (v_id, v_caja, now(), v_tipo, v_monto, v_conc, v_obs,
          v_user, coalesce(v_zona,''), coalesce(p->>'dispositivoId',''),
          jsonb_build_array(jsonb_build_object(
            'accion','CREAR',
            'despues', jsonb_build_object('tipo',v_tipo,'monto',v_monto,'concepto',v_conc,'obs',v_obs),
            'cambios', jsonb_build_array(
              jsonb_build_object('campo','Tipo','antes','—','despues',v_tipo),
              jsonb_build_object('campo','Monto','antes','—','despues',to_char(v_monto,'FM999999990.00')),
              jsonb_build_object('campo','Concepto','antes','—','despues',v_conc)),
            'usuario', v_user, 'rol', v_rol,
            'motivo', v_mot, 'origen','MOS-admin',
            'ts', v_ts, 'timestamp', v_ts,
            'autorizadoPor', jsonb_build_object('nombre', v_user))))
  on conflict (id_extra) do nothing;
  get diagnostics v_ins = row_count;

  return jsonb_build_object('ok',true,'idExtra',v_id,'idCaja',v_caja,'dedup', v_ins = 0,
                            'data', jsonb_build_object('idExtra',v_id,'tipo',v_tipo,'monto',v_monto,
                                                       'concepto',v_conc,'obs',v_obs,'dedup', v_ins = 0));
end; $fn$;


revoke all on function me._movext_hist(jsonb), me._movext_tipo_ok(text),
                       me._movext_editado(jsonb), me.extras_de_caja(jsonb), me.extra_editar(jsonb),
                       me.extra_eliminar(jsonb), me.extra_crear(jsonb) from public;
grant execute on function me._movext_hist(jsonb), me._movext_tipo_ok(text),
                          me._movext_editado(jsonb), me.extras_de_caja(jsonb), me.extra_editar(jsonb),
                          me.extra_eliminar(jsonb), me.extra_crear(jsonb)
  to anon, authenticated, service_role;
