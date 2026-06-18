-- ============================================================================================================
-- 167_mos_cutover_eval_jornada_directo.sql — [MIGRACIÓN MOS · CUTOVER DELETE-SAFE · DINERO · 40x]
-- ------------------------------------------------------------------------------------------------------------
-- OBJETIVO: que EVALUACIONES y JORNADAS sean escritura DIRECTO-PURA a Supabase, delete-safe (sin Sheet),
-- replicando 1:1 los HOOKS DE DINERO que hoy corre GAS (gas/Evaluaciones.gs::crearEvaluacion +
-- gas/Finanzas.gs jornadas). Hasta hoy las RPCs `mos.crear_evaluacion` (82) y `mos.registrar_jornada` (84)
-- SOLO insertaban la fila cruda → NO materializaban LIQUIDACIONES_DIA (bono/sanción/totalDía). Por eso el
-- front estaba en DUAL-WRITE (GAS = verdad + hooks). Sin Sheet, GAS no puede correr esos hooks ⇒ habría que
-- mover los hooks al server. Eso hace este archivo.
--
-- ── PIEZAS (todas idempotentes; re-aplicar no daña) ─────────────────────────────────────────────────────────
--   A) LATIDO en las escrituras directas eval/jornada/etiqueta: hoy SOLO gastos toca _tocar_latido_sync().
--      Cuando se apague el sync-que-lee-Sheet, el heartbeat MOS_SYNC_HEARTBEAT debe seguir vivo. Cada RPC de
--      escritura directa exitosa lo estampa (best-effort; jamás aborta la tx de DINERO). + el cron (pieza E).
--   B) mos.crear_evaluacion AMPLIADA: tras el INSERT, corre los hooks DINERO server-side, REPLICA EXACTA de
--      gas/Evaluaciones.gs:116-187:
--        1) materializar_liquidacion_dia(fecha, forzar=true)  → refresca AUTO (montoBase/bonoMeta/pagoEnvasado)
--           + crea/actualiza la fila del día PRESERVANDO bon/san/estado/id_pago.
--        2) si _ajusteTocado (o bon>0 o san>0): set_bonificacion_sancion con soloTipo + FUSIÓN de motivos
--           (concatena todos los motivos de EVALUACIONES activas del día con ' · ', igual que GAS).
--      Idempotencia: si la eval fue dedup (local_id/PK ya existían) NO se re-corre el hook de ajuste (paridad:
--      GAS tampoco re-evalúa el ajuste de una eval que no se insertó; y el ajuste es idempotente igual: setear
--      el MISMO valor 2x no cambia el dinero). La materialización SÍ se corre siempre (es idempotente y refresca
--      AUTO). forzar=true: el día de una evaluación recién creada ES fresco por definición (la persona operó hoy);
--      saltar el gate de frescura aquí evita un falso WH_SESIONES_STALE que dejaría la fila sin AUTO.
--   C) mos.registrar_jornada_auto(p jsonb): NUEVA RPC para los 3 escritores AUTO de jornada de GAS
--      (importarJornadasDesdeCajas / _registrarJornadaIdempotente / _sincronizarJornadasAutoDelDia). Su dedupe
--      hoy LEE la hoja JORNADAS por (nombre LOWER + fecha). Acá la dedupe es SERVER-SIDE contra mos.jornadas:
--      si YA existe CUALQUIER jornada (activa o tombstone) de ese nombre+fecha → NO crea (idéntico al "veto vale
--      todo el día" de _sincronizarJornadasAutoDelDia, y al "ya registrado" de los otros dos). monto puede ser 0
--      (los AUTO permiten monto 0 cuando montoBase=0; registrar_jornada lo rechazaba — por eso una RPC dedicada).
--   D) mos.jornadas_nombres_dia(p jsonb): lectura de nombres LOWER con jornada en una fecha (para que la dedupe
--      GAS, si se conserva, consulte la sombra en vez de la hoja). Devuelve { ok, data:[nombreLower...] } + frescura.
--   E) (en 168) pg_cron mos-heartbeat-nativo: estampa MOS_SYNC_HEARTBEAT + CATALOGO_SYNC_HEARTBEAT cada 10 min
--      independiente del Sheet (este archivo solo define la función; el agendado va en 168 para separar DDL/cron).
--
-- ── MONEY-SAFETY / 40x ──────────────────────────────────────────────────────────────────────────────────────
--   · Todo SECURITY DEFINER + search_path='' + gate mos._claim_ok() + kill-switch por flag (igual que el lote).
--   · La materialización usa el MISMO motor (mos.materializar_liquidacion_dia + set_bonificacion_sancion) ya
--     validado a paridad EXACTA (verify_resumen_dia_FULL.js: 432/0 al centavo). No re-implementa dinero.
--   · Idempotente: re-correr crear_evaluacion con el MISMO localId NO duplica fila NI infla bon/san (set es
--     reemplazo, no suma; soloTipo preserva el otro).
--   · El latido es best-effort (exception→null): un fallo del heartbeat JAMÁS aborta la escritura de DINERO.
-- ============================================================================================================

create schema if not exists mos;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- A) LATIDO en escrituras directas eval/jornada/etiqueta.
--    Reemplazamos crear_evaluacion (abajo, B) y agregamos perform _tocar_latido_sync() a registrar_jornada,
--    eliminar_jornada, rehabilitar_jornada, crear_etiqueta_zona, actualizar_etiqueta_zona vía ALTER no existe;
--    como son CREATE OR REPLACE completos en 82/84, aquí redefinimos SOLO las que NO se redefinen abajo,
--    añadiendo el latido al final del happy-path. Para minimizar superficie, lo hacemos con wrappers: cada RPC
--    de escritura llama a un helper que, además de su lógica, toca el latido. PERO redefinir las 5 enteras aquí
--    duplicaría ~400 líneas. En su lugar: el cron (pieza E, 168) mantiene el latido SIEMPRE vivo cada 10 min,
--    que es el mecanismo robusto y suficiente. Las escrituras directas se benefician del cron sin tocar cada RPC.
--    (Decisión 40x: el latido-por-escritura es "nice to have"; el latido-por-cron es la garantía dura. Evitamos
--     reescribir 5 RPCs DINERO ya validadas solo para añadir una línea best-effort. crear_evaluacion SÍ lo toca
--     porque la reescribimos completa abajo por los hooks.)

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- B) mos.crear_evaluacion(p jsonb) — AMPLIADA con los hooks de materialización DINERO (delete-safe).
--    Mantiene EXACTAMENTE el insert idempotente de 82 (mismos defaults/validaciones/idempotencia local_id+PK),
--    y AÑADE, tras un insert/dedup OK y SOLO si MOS_LIQDIA_DIRECTO='1', los hooks réplica de gas crearEvaluacion.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.crear_evaluacion(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local  text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id     text := nullif(btrim(coalesce(p->>'idEval','')), '');
  v_pers   text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_rol    text := nullif(btrim(coalesce(p->>'rol','')), '');
  v_fecha  timestamptz;
  v_fecha_s text;
  v_checks jsonb;
  v_inserted int;
  v_existe text;
  v_dedup boolean := false;
  -- hooks DINERO
  v_bon_new numeric := greatest(0, coalesce(mos._numn(p->>'bonificacion'),0));
  v_san_new numeric := greatest(0, coalesce(mos._numn(p->>'sancion'),0));
  v_ajuste_tocado boolean;
  v_ajuste_tipo text := nullif(lower(btrim(coalesce(p->>'ajusteTipo',''))), '');
  v_solo text;
  v_bonmot_fin text := coalesce(p->>'bonificacionMotivo','');
  v_sanmot_fin text := coalesce(p->>'sancionMotivo','');
  v_tmp text;
begin
  if coalesce((select valor from mos.config where clave='MOS_EVAL_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_EVAL_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_pers is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  if v_rol  is null then return jsonb_build_object('ok',false,'error','rol requerido'); end if;

  -- control_checks (idéntico a 82)
  if (p ? 'controlChecks') and jsonb_typeof(p->'controlChecks') in ('object','array') then
    v_checks := p->'controlChecks';
  else
    begin
      v_checks := coalesce(nullif(btrim(coalesce(p->>'controlChecks','')),'')::jsonb, '{}'::jsonb);
    exception when others then v_checks := '{}'::jsonb;
    end;
  end if;

  -- fecha: SOLO-fecha 'YYYY-MM-DD' → ancla a MEDIANOCHE LIMA (Perú UTC-5 fijo), igual que _mosDate de GAS y
  -- que set_bonificacion_sancion/materializar (85/96). Sin esto, '2026-06-13' se parsea como UTC-midnight →
  -- (at time zone Lima)::date = 2026-06-12 → materializaría/llavearía el DÍA ANTERIOR (bug date-only 40x).
  -- ISO con offset/hora explícita → se respeta tal cual.
  v_tmp := nullif(btrim(coalesce(p->>'fecha','')),'');
  begin
    if v_tmp is not null and v_tmp ~ '^\d{4}-\d{2}-\d{2}$' then
      v_fecha := (v_tmp || 'T00:00:00-05:00')::timestamptz;       -- medianoche Lima
    else
      v_fecha := v_tmp::timestamptz;
    end if;
  exception when others then v_fecha := null;
  end;
  v_fecha := coalesce(v_fecha, now());
  -- fecha 'YYYY-MM-DD' en DÍA DE NEGOCIO Lima (para los hooks que llavean por fecha-Lima, = _hoy() del GAS).
  v_fecha_s := to_char((v_fecha at time zone 'America/Lima')::date, 'YYYY-MM-DD');

  -- IDEMPOTENCIA por local_id (gesto)
  if v_local is not null then
    select id_eval into v_existe from mos.evaluaciones where local_id = v_local limit 1;
    if found then v_dedup := true; v_id := v_existe; end if;
  end if;
  -- IDEMPOTENCIA por PK
  if not v_dedup and v_id is not null and exists (select 1 from mos.evaluaciones where id_eval = v_id) then
    v_dedup := true;
  end if;

  if not v_dedup then
    v_id := coalesce(v_id, 'EV'||(extract(epoch from clock_timestamp())*1000)::bigint::text);
    begin
      insert into mos.evaluaciones (
        id_eval, fecha, id_personal, rol, hora,
        limpieza_pct, limpieza_prof_pct, control_checks, comentario, evaluado_por,
        aplica_comision, aplica_bono_meta, activo,
        sancion, sancion_motivo, bonificacion, bonificacion_motivo, local_id
      ) values (
        v_id, v_fecha, v_pers, v_rol,
        coalesce(nullif(btrim(coalesce(p->>'hora','')),''), to_char(clock_timestamp(),'HH24:MI:SS')),
        coalesce(mos._numn(p->>'limpiezaPct'),0),
        coalesce(mos._numn(p->>'limpiezaProfPct'),0),
        v_checks,
        coalesce(nullif(btrim(coalesce(p->>'comentario','')),''),''),
        coalesce(nullif(btrim(coalesce(p->>'evaluadoPor','')),''),''),
        case when (p ? 'aplicaComision') and (p->>'aplicaComision') in ('false','f','0') then false else true end,
        case when (p ? 'aplicaBonoMeta') and (p->>'aplicaBonoMeta') in ('false','f','0') then false else true end,
        true,
        v_san_new,
        coalesce(nullif(btrim(coalesce(p->>'sancionMotivo','')),''),''),
        v_bon_new,
        coalesce(nullif(btrim(coalesce(p->>'bonificacionMotivo','')),''),''),
        v_local
      )
      on conflict (id_eval) do nothing;
      get diagnostics v_inserted = row_count;
      if v_inserted = 0 then v_dedup := true; end if;
    exception when unique_violation then
      v_dedup := true;
      if v_local is not null then
        select id_eval into v_existe from mos.evaluaciones where local_id = v_local limit 1;
        if found then v_id := v_existe; end if;
      end if;
    end;
  end if;

  -- ── HOOKS DINERO (réplica gas/Evaluaciones.gs:116-187) — solo si LIQDIA directo está ON ──
  -- 1) materializar AUTO del día (idempotente; forzar=true → el día de la eval es fresco por definición).
  -- 2) set bon/san con soloTipo + fusión de motivos, si _ajusteTocado || bon>0 || san>0.
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') = '1' then
    -- soloTipo: explícito ('sancion'|'bonificacion') o derivado (bon>0&san=0→bonif; san>0&bon=0→sanción).
    v_solo := case
                when v_ajuste_tipo in ('sancion','bonificacion') then v_ajuste_tipo
                when v_bon_new > 0 and v_san_new = 0 then 'bonificacion'
                when v_san_new > 0 and v_bon_new = 0 then 'sancion'
                else null end;
    v_ajuste_tocado := (p->>'_ajusteTocado' in ('true','t','1'))
                    or (p->>'_resetBonSan'  in ('true','t','1'))
                    or v_bon_new > 0 or v_san_new > 0;

    -- (1) materializar AUTO. NUNCA aborta la eval por un fallo del hook (la fila cruda YA está commiteada).
    begin
      perform mos.materializar_liquidacion_dia(jsonb_build_object('fecha', v_fecha_s, 'forzar', true));
    exception when others then null;
    end;

    -- (2) set bon/san (reemplazo, soloTipo preserva el otro) con FUSIÓN de motivos del día.
    if v_ajuste_tocado then
      begin
        -- Fusión motivos: concatenar (' · ') los motivos de TODAS las evaluaciones activas del día/persona,
        -- por tipo, SOLO si el tipo activo tiene valor > 0 (réplica EXACTA gas:159-176).
        if v_bon_new > 0 and (v_solo = 'bonificacion' or v_solo is null) then
          select string_agg(m, ' · ' order by ord)
            into v_tmp
            from (
              select btrim(coalesce(e.bonificacion_motivo,'')) m, e.hora ord
                from mos.evaluaciones e
               where coalesce(e.activo,true)=true
                 and e.id_personal = v_pers
                 and (e.fecha at time zone 'America/Lima')::date = v_fecha_s::date
                 and coalesce(e.bonificacion,0) > 0
                 and btrim(coalesce(e.bonificacion_motivo,'')) <> ''
            ) s;
          if v_tmp is not null and v_tmp <> '' then v_bonmot_fin := v_tmp; end if;
        elsif v_bon_new = 0 and v_solo = 'bonificacion' then
          v_bonmot_fin := '';
        end if;

        if v_san_new > 0 and (v_solo = 'sancion' or v_solo is null) then
          select string_agg(m, ' · ' order by ord)
            into v_tmp
            from (
              select btrim(coalesce(e.sancion_motivo,'')) m, e.hora ord
                from mos.evaluaciones e
               where coalesce(e.activo,true)=true
                 and e.id_personal = v_pers
                 and (e.fecha at time zone 'America/Lima')::date = v_fecha_s::date
                 and coalesce(e.sancion,0) > 0
                 and btrim(coalesce(e.sancion_motivo,'')) <> ''
            ) s;
          if v_tmp is not null and v_tmp <> '' then v_sanmot_fin := v_tmp; end if;
        elsif v_san_new = 0 and v_solo = 'sancion' then
          v_sanmot_fin := '';
        end if;

        perform mos.set_bonificacion_sancion(jsonb_build_object(
          'idPersonal', v_pers,
          'fecha',      v_fecha_s,
          'bonificacion', v_bon_new,
          'sancion',      v_san_new,
          'bonificacionMotivo', v_bonmot_fin,
          'sancionMotivo',      v_sanmot_fin,
          'soloTipo',   v_solo,
          'rol',        v_rol
        ));
      exception when others then null;  -- best-effort: jamás abortar la eval ya commiteada
      end;
    end if;
  end if;

  -- LATIDO: mantener viva la frescura de la sombra sin depender del sync-que-lee-Sheet.
  perform mos._tocar_latido_sync();

  if v_dedup then
    return jsonb_build_object('ok',true,'dedup',true,'data',
      jsonb_build_object('idEval', v_id, 'bonificacion', v_bon_new, 'sancion', v_san_new));
  end if;
  return jsonb_build_object('ok',true,'dedup',false,'data',
    jsonb_build_object('idEval', v_id, 'bonificacion', v_bon_new, 'sancion', v_san_new));
end;
$fn$;
revoke all on function mos.crear_evaluacion(jsonb) from public;
grant execute on function mos.crear_evaluacion(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- C) mos.registrar_jornada_auto(p jsonb) — para los 3 escritores AUTO de GAS (dedupe por nombre+fecha-Lima).
--    Dedupe SERVER-SIDE: si YA existe CUALQUIER jornada (activa o tombstone fuente='ELIMINADA') de ese nombre
--    LOWER + fecha-Lima → NO crea (devuelve dedup=true). Acepta monto 0 (los AUTO lo permiten; el "veto vale
--    todo el día" se respeta porque el tombstone TAMBIÉN bloquea). Idempotente por (nombre+fecha) Y por local_id.
--    Requeridos: nombre. Resto opcional (idéntico al appendRow AUTO de GAS).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.registrar_jornada_auto(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local  text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id     text := nullif(btrim(coalesce(p->>'idJornada','')), '');
  v_nombre text := nullif(btrim(coalesce(p->>'nombre','')), '');
  v_monto  numeric := coalesce(mos._numn(p->>'montoJornal'),0);
  v_fecha  timestamptz;
  v_fecha_d date;
  v_ft     text;
  v_existe text;
  v_inserted int;
begin
  if coalesce((select valor from mos.config where clave='MOS_JORNADAS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_JORNADAS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nombre is null then return jsonb_build_object('ok',false,'error','Requiere nombre'); end if;
  if v_monto < 0 then return jsonb_build_object('ok',false,'error','monto inválido'); end if;  -- AUTO permite 0, no negativo

  -- fecha: SOLO-fecha → medianoche Lima (bug date-only); ISO con hora → tal cual.
  v_ft := nullif(btrim(coalesce(p->>'fecha','')),'');
  begin
    if v_ft is not null and v_ft ~ '^\d{4}-\d{2}-\d{2}$' then
      v_fecha := (v_ft || 'T00:00:00-05:00')::timestamptz;
    else
      v_fecha := v_ft::timestamptz;
    end if;
  exception when others then v_fecha := null;
  end;
  v_fecha := coalesce(v_fecha, now());
  v_fecha_d := (v_fecha at time zone 'America/Lima')::date;

  -- IDEMPOTENCIA por local_id (gesto)
  if v_local is not null then
    select id_jornada into v_existe from mos.jornadas where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_existe)); end if;
  end if;

  -- DEDUPE por NOMBRE LOWER + FECHA-Lima (réplica de la dedupe de hoja de los 3 escritores AUTO).
  -- Bloquea TANTO activas como tombstones (fuente='ELIMINADA') → el veto vale todo el día.
  select id_jornada into v_existe
    from mos.jornadas
   where lower(btrim(coalesce(nombre,''))) = lower(v_nombre)
     and (fecha at time zone 'America/Lima')::date = v_fecha_d
   limit 1;
  if found then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_existe));
  end if;

  v_id := coalesce(v_id, 'JOR'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.jornadas (
    id_jornada, fecha, id_personal, nombre, rol, app_origen, zona,
    monto_jornal, observacion, registrado_por, fuente, local_id
  ) values (
    v_id, v_fecha,
    coalesce(nullif(btrim(coalesce(p->>'idPersonal','')),''),''),
    v_nombre,
    coalesce(nullif(btrim(coalesce(p->>'rol','')),''),''),
    coalesce(nullif(btrim(coalesce(p->>'appOrigen','')),''),'AUTO'),
    coalesce(nullif(btrim(coalesce(p->>'zona','')),''),''),
    v_monto,
    coalesce(nullif(btrim(coalesce(p->>'observacion','')),''),''),
    coalesce(nullif(btrim(coalesce(p->>'registradoPor','')),''),'AUTO'),
    coalesce(nullif(btrim(coalesce(p->>'fuente','')),''),'AUTO'),
    v_local
  )
  on conflict (id_jornada) do nothing;
  get diagnostics v_inserted = row_count;

  perform mos._tocar_latido_sync();

  if v_inserted = 0 then
    -- carrera por PK o por la dedupe nombre+fecha (otra tx insertó en paralelo) → re-leer
    select id_jornada into v_existe
      from mos.jornadas
     where lower(btrim(coalesce(nombre,''))) = lower(v_nombre)
       and (fecha at time zone 'America/Lima')::date = v_fecha_d
     limit 1;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', coalesce(v_existe, v_id)));
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idJornada', v_id));
exception
  when unique_violation then
    -- red anti-doble: dos tx con mismo local_id en paralelo → devolver la persistida.
    if v_local is not null then
      select id_jornada into v_existe from mos.jornadas where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_existe)); end if;
    end if;
    select id_jornada into v_existe
      from mos.jornadas
     where lower(btrim(coalesce(nombre,''))) = lower(v_nombre)
       and (fecha at time zone 'America/Lima')::date = v_fecha_d
     limit 1;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', coalesce(v_existe, v_id)));
end;
$fn$;
revoke all on function mos.registrar_jornada_auto(jsonb) from public;
grant execute on function mos.registrar_jornada_auto(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- D) mos.jornadas_nombres_dia(p jsonb) — lectura de nombres LOWER con jornada en una fecha-Lima (para que la
--    dedupe de GAS, si se conserva, consulte la sombra en vez de la hoja). { ok, data:[nombreLower...] } + frescura.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.jornadas_nombres_dia(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_fecha   date;
  v_data    jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_fecha_s is null then return jsonb_build_object('ok',false,'error','Requiere fecha'); end if;
  begin v_fecha := v_fecha_s::date; exception when others then return jsonb_build_object('ok',false,'error','fecha inválida'); end;

  select coalesce(jsonb_agg(distinct n), '[]'::jsonb) into v_data
    from (
      select lower(btrim(coalesce(nombre,''))) n
        from mos.jornadas
       where (fecha at time zone 'America/Lima')::date = v_fecha
         and btrim(coalesce(nombre,'')) <> ''
    ) s;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.jornadas_nombres_dia(jsonb) from public;
grant execute on function mos.jornadas_nombres_dia(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- D2) mos.resumen_dia_uno(p jsonb) — wrapper de mos.resumen_dia para UNA persona REAL, con shape
--     { ok, data:<objeto único o null>, _fresh, _heartbeat... } que consume _sbLeerRpcFreshMOS de GAS
--     (espeja getResumenDia({idPersonal,fecha})). data = el item de esa persona (presente o no); null si no
--     aparece (no evaluable / no en mos.personal). Adjunta frescura → GAS cae a HOJA si la sombra está stale.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.resumen_dia_uno(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha   date;
  v_rsm     jsonb;
  v_item    jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_fecha_s is null or v_idp is null then return jsonb_build_object('ok',false,'error','fecha e idPersonal requeridos'); end if;
  begin v_fecha := v_fecha_s::date; exception when others then return jsonb_build_object('ok',false,'error','fecha inválida'); end;

  v_rsm := mos.resumen_dia(v_fecha, v_idp);
  if coalesce((v_rsm->>'ok')::boolean,false) is not true then
    return jsonb_build_object('ok',false,'error','resumen_dia falló') || mos._frescura_sombra();
  end if;
  v_item := (v_rsm->'data')->0;   -- el primer (único) item de esa persona, o null
  return jsonb_build_object('ok', true, 'data', v_item) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.resumen_dia_uno(jsonb) from public;
grant execute on function mos.resumen_dia_uno(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- E) mos.cron_heartbeat_nativo() — estampa el latido de las SOMBRAS YA DIRECTO-PURAS (MOS_SYNC_HEARTBEAT:
--    finanzas/eval/jornadas/proveedores/pagos/etc.). En DIRECTO-PURO la sombra ES la verdad → mantener
--    _fresh=true es CORRECTO (no enmascara staleness real: ya no hay un origen externo que pueda atrasarse).
--
--    ⚠️ NO estampa CATALOGO_SYNC_HEARTBEAT: el catálogo (productos/etiquetas) SIGUE en DUAL-WRITE (su sombra
--    se llena del Sheet vía sync GAS). Si el cron estampara su latido, ENMASCARARÍA una muerte real del sync de
--    catálogo (el front serviría un catálogo stale como si fuera fresco → PELIGRO: precios viejos). El latido de
--    catálogo DEBE seguir reflejando la corrida REAL del sync de catálogo. Cuando catálogo cute a directo-puro,
--    se añade aquí su clave. (Decisión money-safe: solo latir lo que YA es directo-puro.)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.cron_heartbeat_nativo()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_iso text := to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
begin
  insert into mos.config (clave, valor, descripcion) values
    ('MOS_SYNC_HEARTBEAT', v_iso, 'Latido NATIVO (pg_cron mos-heartbeat-nativo): sombras DIRECTO-PURAS (finanzas/eval/jornadas/proveedores/pagos/etc.) — la sombra ES la verdad; mantiene _fresh=true sin depender del sync-que-lee-Sheet. NO cubre catálogo (sigue dual-write).')
  on conflict (clave) do update set valor = excluded.valor;
  return jsonb_build_object('ok', true, 'heartbeat', v_iso);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$fn$;
revoke all on function mos.cron_heartbeat_nativo() from public, anon, authenticated;
grant execute on function mos.cron_heartbeat_nativo() to service_role;
