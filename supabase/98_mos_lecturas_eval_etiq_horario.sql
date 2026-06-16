-- 98_mos_lecturas_eval_etiq_horario.sql — [MIGRACIÓN MOS · FASE 2 · LECTURA-LISTA · módulos sin *_lista]
-- Completa los read-paths directos de los 3 módulos MOS que tenían dual-write (sombra fresca) pero NINGUNA
-- RPC de lectura porque su getter GAS NO lee la tabla cruda — FILTRA/AGREGA/ENRIQUECE:
--   · getEvaluacionesDia (Evaluaciones.gs:193)  → filtra por día (TZ Lima) + activo + idPersonal opcional.
--   · getHorariosApps    (Horarios.gs:74)        → AGRUPA por app, parsea horario_json, emite alias .dias.
--   · getEtiquetasPendientes (Etiquetas.gs:219)  → ventana 3 días desde ts_cambio + estado != PEGADA/OBSOLETA
--                                                  + idZona opcional + enriquece (_minutosDesdeCambio/_vistoPorMi/
--                                                  _cantidadVistos) + orden más-antiguas-primero.
--
-- ⚠️ INERTE (idéntico patrón a 94): estas RPCs existen y tienen grant, pero el flip (flags MOS_*_DIRECTO +
--   apagar sync por tabla) y el wiring de js/api.js (read-paths) son tanda POSTERIOR. NADIE las llama hoy.
--   Este archivo NO toca flags, NO toca MOS_SYNC_OFF_TABLAS, NO cablea. MOS sigue 100% por GAS.
--
-- ── SHAPE (paridad con GAS) ─────────────────────────────────────────────────────────────────────────────────
--   getEvaluacionesDia / getEtiquetasPendientes devuelven `_sheetToObjects(HOJA)` (filas camelCase, tipos JS)
--   envueltas en {ok,data:[...]}. getHorariosApps devuelve {ok,data:{<app>:{...}}} (OBJETO keyed por app).
--   Estas RPCs MAPEAN snake→camel EXACTAMENTE según _MOS_SPECS (gas/MigracionMOS.gs) + replican el filtro/
--   enriquecimiento server-side, y concatenan mos._frescura_sombra() ({_fresh,_heartbeat,_now,_ttl_min}).
--   El front lee `data` (compatible con el shape GAS); _fresh es la señal de frescura de la SOMBRA (si está
--   congelada → el front cae a GAS), mismo criterio que 76/94.
--
-- ── DÍA / TZ ────────────────────────────────────────────────────────────────────────────────────────────────
--   GAS computa el día con Session.getScriptTimeZone() = America/Lima (appsscript.json) y _hoy() =
--   formatDate(now, TZ, 'yyyy-MM-dd'). Estas RPCs comparan (ts at time zone 'America/Lima')::date para espejar
--   ese cómputo (idéntico a jornadas_lista en 94). El default "hoy" se calcula con TZ Lima en SQL si el front
--   no manda fecha (paridad con getEvaluacionesDia que usa _hoy() cuando params.fecha está vacío).
--
-- ── TIPOS / DIVERGENCIAS HONESTAS ───────────────────────────────────────────────────────────────────────────
--   · control_checks: jsonb en la sombra; en la HOJA GAS era STRING JSON. _sheetToObjects NO lo parsea (lo deja
--     string). Esta RPC emite el jsonb DIRECTO (objeto/array). ⚠️ DIVERGENCIA DE TIPO: un consumidor que hiciera
--     JSON.parse(controlChecks) fallaría. VERIFICADO: el front MOS (app.js, prefetch getEvaluacionesDia) solo
--     cachea el array y lee bonificacion/sancion/idPersonal/activo — NUNCA toca controlChecks. Seguro hoy.
--   · numeric (limpiezaPct/sancion/bonificacion/precioAnterior/precioNuevo): emitidos como NÚMERO JSON (paridad
--     con _sheetToObjects que devuelve Number). El front hace parseFloat() defensivo.
--   · timestamptz (fecha/ts_cambio/ts_impresa/ts_pegada/fechaActualizacion): ISO 8601 (jsonb serializa así).
--     GAS devolvía Date nativo; el front usa fmtDate()/String().substring(0,10) → ambos toleran ISO. ✅
--   · horario_json: jsonb en la sombra (el dual-write de setHorarioApp escribe el objeto directo, idéntico a
--     parsear el string del batch). getHorariosApps hacía JSON.parse(r.horarioJson). Esta RPC emite el jsonb
--     directo bajo `horario` Y `dias` (alias que SeguridadSystem lee). ✅ paridad con el objeto resultante.
--   · admins_libres: en la tabla es TEXT ('true'/'false'); getHorariosApps emite boolean (String(x)==='true').
--     Esta RPC replica esa coerción → boolean. ✅
--
-- ── ENRIQUECIMIENTOS — qué SÍ y qué NO se puede replicar en SQL ─────────────────────────────────────────────
--   getEtiquetasPendientes calcula 3 campos derivados; TODOS son función pura de columnas persistidas → se
--   replican EXACTO en SQL:
--     · _minutosDesdeCambio = round((now - ts_cambio)/60000). now() del servidor == new Date() de GAS (mismo
--       instante de evaluación; diferencia de red despreciable, ambos "ahora").
--     · _vistoPorMi         = (lower(usuario) ∈ split(visto_csv)).  usuario viene en `p->>'usuario'`.
--     · _cantidadVistos     = #elementos no vacíos de visto_csv.
--   NINGÚN enriquecimiento depende de estado runtime no-persistido → NADA queda fuera. (Contrastar con eval/
--   horario, que no tienen enriquecimientos derivados.)

-- helper: tokeniza visto_csv (lower, trim, drop vacíos) → text[] (espeja el split/map/filter de GAS).
-- Definido ANTES de etiquetas_pendientes (que lo usa).
create or replace function mos._etiq_visto_tokens(p_csv text)
returns text[]
language sql
immutable
set search_path = ''
as $fn$
  select coalesce(array_agg(tok), array[]::text[])
  from (
    select btrim(lower(x)) as tok
    from unnest(string_to_array(coalesce(p_csv,''), ',')) as x
  ) s
  where tok <> '';
$fn$;
revoke all on function mos._etiq_visto_tokens(text) from public;
grant execute on function mos._etiq_visto_tokens(text) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.evaluaciones_dia(p jsonb default '{}') — espeja getEvaluacionesDia (router 'getEvaluacionesDia', API.get).
--   Filtro (paridad GAS): activo truthy (boolean true) + fecha(día, TZ Lima) == p.fecha (default = hoy TZ Lima)
--   + idPersonal opcional (== ). Orden estable por hora, id_eval (GAS devuelve el orden de hoja; aquí estable).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.evaluaciones_dia(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_fecha_in text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_fecha    date;
  v_pers     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_data     jsonb;
  v_count    int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- Default "hoy" en TZ Lima (paridad con _hoy() de GAS). Fecha basura → error limpio (no filtro roto).
  begin
    v_fecha := coalesce(v_fecha_in::date, (now() at time zone 'America/Lima')::date);
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'Fecha inválida (YYYY-MM-DD)');
  end;

  select coalesce(jsonb_agg(row order by ord_hora, ord_id), '[]'::jsonb), count(*)
    into v_data, v_count
  from (
    select jsonb_build_object(
      'idEval',             t.id_eval,
      'fecha',              t.fecha,
      'idPersonal',         t.id_personal,
      'rol',                t.rol,
      'hora',               t.hora,
      'limpiezaPct',        t.limpieza_pct,
      'limpiezaProfPct',    t.limpieza_prof_pct,
      'controlChecks',      t.control_checks,
      'comentario',         t.comentario,
      'evaluadoPor',        t.evaluado_por,
      'aplicaComision',     t.aplica_comision,
      'aplicaBonoMeta',     t.aplica_bono_meta,
      'activo',             t.activo,
      'sancion',            t.sancion,
      'sancionMotivo',      t.sancion_motivo,
      'bonificacion',       t.bonificacion,
      'bonificacionMotivo', t.bonificacion_motivo
    ) as row,
    coalesce(t.hora,'') as ord_hora, t.id_eval as ord_id
    from mos.evaluaciones t
    where t.activo is true                                            -- paridad: activo===false/'0'/'false' → fuera
      and (t.fecha at time zone 'America/Lima')::date = v_fecha       -- día en TZ Lima (espeja _hoy()/formatDate)
      and (v_pers is null or t.id_personal = v_pers)                  -- idPersonal opcional (== )
  ) s;

  return jsonb_build_object('ok', true, 'data', v_data, '_count', v_count) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.evaluaciones_dia(jsonb) from public;
grant execute on function mos.evaluaciones_dia(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.horarios_apps(p jsonb default '{}') — espeja getHorariosApps (router 'getHorariosApps', API.post sin args).
--   AGRUPA por app: devuelve data = OBJETO { <app>: {app,horario,dias,admins_libres,actualizadoPor,
--   fechaActualizacion} }. `horario` y `dias` son el MISMO jsonb (alias, paridad con el FIX v2.43.130). p se
--   ignora (getHorariosApps no toma params) — se acepta por uniformidad de firma (p jsonb).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.horarios_apps(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_data jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  select coalesce(jsonb_object_agg(t.app, jsonb_build_object(
           'app',                t.app,
           'horario',            coalesce(t.horario_json, '{}'::jsonb),
           'dias',               coalesce(t.horario_json, '{}'::jsonb),   -- alias para SeguridadSystem (.dias)
           'admins_libres',      (lower(coalesce(t.admins_libres,'')) = 'true'),  -- text → boolean (paridad GAS)
           'actualizadoPor',     coalesce(t.actualizado_por, ''),
           'fechaActualizacion', t.fecha_actualizacion                    -- ISO 8601 (GAS: .toISOString())
         )), '{}'::jsonb)
    into v_data
  from mos.config_horarios_apps t;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.horarios_apps(jsonb) from public;
grant execute on function mos.horarios_apps(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.etiquetas_pendientes(p jsonb default '{}') — espeja getEtiquetasPendientes (router 'getEtiquetasPendientes').
--   Filtro (paridad GAS): estado NOT IN (PEGADA, OBSOLETA, case-insensitive) + ventana 3 días desde ts_cambio
--   (oculta más viejas; filas SIN ts_cambio NO se ocultan, igual que GAS donde ts=0 salta el corte) + idZona
--   opcional (String ==). Enriquece (todo función pura de columnas → replicable EXACTO en SQL):
--     · _minutosDesdeCambio = round((now - ts_cambio)/60000); 0 si sin ts.
--     · _vistoPorMi         = lower(p.usuario) ∈ split(visto_csv); false si sin usuario.
--     · _cantidadVistos     = #tokens no vacíos de visto_csv.
--   Orden: más antiguas primero (_minutosDesdeCambio desc), id_etiq tie-break (estable).
--   ⚠️ Sin consumidor frontend en el repo MOS (las etiquetas las consumen WH/ME, no el panel admin MOS). La RPC
--      se crea por completitud/paridad; el wiring queda fuera por no inventar un consumidor inexistente.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.etiquetas_pendientes(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona  text := nullif(btrim(coalesce(p->>'idZona','')), '');
  v_user  text := lower(nullif(btrim(coalesce(p->>'usuario','')), ''));
  v_now   timestamptz := now();
  v_data  jsonb;
  v_count int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  select coalesce(jsonb_agg(row order by ord_min desc, ord_id), '[]'::jsonb), count(*)
    into v_data, v_count
  from (
    select jsonb_build_object(
      'idEtiq',             t.id_etiq,
      'idZona',             t.id_zona,
      'zonaNombre',         t.zona_nombre,
      'idProducto',         t.id_producto,
      'descripcion',        t.descripcion,
      'codigoBarra',        t.codigo_barra,
      'skuBase',            t.sku_base,
      'precioAnterior',     t.precio_anterior,
      'precioNuevo',        t.precio_nuevo,
      'ts_cambio',          t.ts_cambio,
      'cambiadoPor',        t.cambiado_por,
      'estado',             t.estado,
      'visto_csv',          t.visto_csv,
      'ts_impresa',         t.ts_impresa,
      'impresaPor',         t.impresa_por,
      'jobId',              t.job_id,
      'ts_pegada',          t.ts_pegada,
      'pegadaPor',          t.pegada_por,
      'comentario',         t.comentario,
      -- enriquecimientos (paridad GAS, función pura de columnas):
      '_minutosDesdeCambio', case when t.ts_cambio is not null
                                  then round(extract(epoch from (v_now - t.ts_cambio)) / 60.0)::int
                                  else 0 end,
      '_vistoPorMi',        case when v_user is null then false
                                 else v_user = any(mos._etiq_visto_tokens(t.visto_csv)) end,
      '_cantidadVistos',    coalesce(array_length(mos._etiq_visto_tokens(t.visto_csv), 1), 0)
    ) as row,
    case when t.ts_cambio is not null
         then round(extract(epoch from (v_now - t.ts_cambio)) / 60.0)::int else 0 end as ord_min,
    t.id_etiq as ord_id
    from mos.etiquetas_zona t
    where upper(coalesce(t.estado,'')) not in ('PEGADA','OBSOLETA')      -- paridad: oculta cerradas/obsoletas
      and (v_zona is null or t.id_zona = v_zona)                          -- idZona opcional (String ==)
      -- ventana 3 días: ocultar las más viejas. ts NULL NO se oculta (GAS: ts=0 salta el corte).
      and (t.ts_cambio is null or (v_now - t.ts_cambio) <= interval '3 days')
  ) s;

  return jsonb_build_object('ok', true, 'data', v_data, '_count', v_count) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.etiquetas_pendientes(jsonb) from public;
grant execute on function mos.etiquetas_pendientes(jsonb) to service_role, authenticated;
