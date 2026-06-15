-- 82_mos_evaluaciones_etiquetas_horarios.sql — [MIGRACIÓN MOS · FASE 2 · LOTE BAJO RIESGO (NO DINERO)]
-- RPCs de ESCRITURA directa para 3 módulos operativos de bajo riesgo:
--   1. EVALUACIONES (RRHH, calidad de personal) — gas/Evaluaciones.gs::crearEvaluacion
--   2. ETIQUETAS de zona (membretes de precio)   — gas/Etiquetas.gs (crear fila + marcar visto/pegada/impresa)
--   3. HORARIOS de apps (bloqueo por app)         — gas/Horarios.gs::setHorarioApp
--
-- ⚠️ NACE INERTE (triple, IDÉNTICO al patrón de 81): (1) kill-switch server-side por flag mos.config —
--    UNO POR MÓDULO (MOS_EVAL_DIRECTO / MOS_ETIQ_DIRECTO / MOS_HORARIO_DIRECTO), todos default '0';
--    (2) nadie cablea js/api.js todavía → ninguna PWA llama estas RPCs; (3) MOS sigue 100% por GAS.
--    Las RPCs existen y tienen grant, pero el flag OFF las hace devolver *_OFF (el front cae a GAS).
--
-- ── PARIDAD HONESTA CON GAS (verificada contra los handlers reales) ──────────────────────────────────────
--   · EVALUACIONES: crearEvaluacion en GAS hace appendRow CRUDO (sin lock/dedup) → doble-tap duplica fila.
--       Acá: insert idempotente por local_id. ⚠️ NO se espejan los hooks de materialización
--       (_liqDiaRecomputar/_liqDiaSetBonSan) porque tocan LIQUIDACIONES_DIA (DINERO) y los orquestadores
--       quedan en GAS por diseño. Esta RPC SOLO inserta la fila cruda de evaluación (paridad del appendRow).
--       NO existe actualizarEvaluacion en GAS → NO se crea RPC de update (sería inventar contrato).
--   · ETIQUETAS: GAS no tiene un "crearEtiqueta" expuesto en el router (las filas nacen del hook de precio
--       _etiqGenerarParaZonas, 1 por zona). Acá damos el PRIMITIVO atómico de 1 fila: crear_etiqueta_zona
--       (insert idempotente) + actualizar_etiqueta_zona (UPDATE atómico patch parcial, cubre el estado/
--       visto_csv/ts_pegada/pegada_por/ts_impresa/impresa_por/job_id que GAS toca celda-a-celda en
--       marcarVisto/marcarPegada/_etiqMarcarImpresa). UPDATE atómico por PK → sin lost-update vs el
--       read(getValues)→setValue de GAS.
--   · HORARIOS: setHorarioApp es un UPSERT por la PK natural `app` (no inserta filas nuevas idempotentes
--       por gesto — la clave de negocio ES la app). Por eso config_horarios_apps NO recibe local_id.
--       Espejamos la validación HH:MM por día activo y el merge de los 7 días (default 07:00/19:00 igual
--       que GAS). NO disparamos push ni invalidación de cache de WH (eso queda en GAS).
--
-- ── IDS ──────────────────────────────────────────────────────────────────────────────────────────────────
--   _generateId('EV') de GAS = 'EV' + epoch ms.  idEtiq de GAS = 'ETQ-' + epoch ms + '-' + zona(0..6).
--   Acá generamos ids equivalentes; la idempotencia REAL es por local_id (no por el id de negocio), y el
--   id de negocio se puede reenviar desde el front (se respeta on conflict (PK)).

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- 0) CIMIENTO (idempotente): columna local_id + índice único PARCIAL en las 2 tablas que reciben INSERTs.
--    config_horarios_apps NO lleva local_id (upsert por PK natural `app`).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
alter table mos.evaluaciones    add column if not exists local_id text;
alter table mos.etiquetas_zona  add column if not exists local_id text;

create unique index if not exists ux_mos_evaluaciones_localid on mos.evaluaciones (local_id) where local_id is not null;
create unique index if not exists ux_mos_etiquetaszona_localid on mos.etiquetas_zona (local_id) where local_id is not null;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- 1) KILL-SWITCHES (uno por módulo, default '0' → INERTE). Sembrado idempotente.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
insert into mos.config (clave, valor, descripcion) values
  ('MOS_EVAL_DIRECTO',    '0','MOS Fase 2: escritura directa de EVALUACIONES de personal a Supabase. OFF → front cae a GAS.'),
  ('MOS_ETIQ_DIRECTO',    '0','MOS Fase 2: escritura directa de ETIQUETAS de zona a Supabase. OFF → front cae a GAS.'),
  ('MOS_HORARIO_DIRECTO', '0','MOS Fase 2: escritura directa de HORARIOS de apps a Supabase. OFF → front cae a GAS.')
on conflict (clave) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) EVALUACIONES — mos.crear_evaluacion(p jsonb)  (espeja crearEvaluacion, SOLO el appendRow)
--    Idempotente por local_id (gesto) y por PK id_eval (si el front reenvía el id).
--    Defaults paridad GAS:
--      · activo = true
--      · aplica_comision/aplica_bono_meta = true salvo que venga explícitamente 'false'
--      · limpieza_pct/limpieza_prof_pct = 0 si no parsea
--      · sancion/bonificacion = max(0, num) (nunca negativas)
--      · control_checks: acepta jsonb directo, string JSON, u objeto vacío {}
--      · hora: HH:mm:ss del server si no viene (GAS usa la hora del trigger)
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
  v_checks jsonb;
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_EVAL_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_EVAL_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- Validaciones paridad GAS: idPersonal + rol requeridos.
  if v_pers is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  if v_rol  is null then return jsonb_build_object('ok',false,'error','rol requerido'); end if;

  -- control_checks: jsonb directo (objeto/array) o string JSON; basura → {} (paridad JSON.stringify(... || {})).
  if (p ? 'controlChecks') and jsonb_typeof(p->'controlChecks') in ('object','array') then
    v_checks := p->'controlChecks';
  else
    begin
      v_checks := coalesce(nullif(btrim(coalesce(p->>'controlChecks','')),'')::jsonb, '{}'::jsonb);
    exception when others then v_checks := '{}'::jsonb;
    end;
  end if;

  -- fecha: yyyy-MM-dd o ISO → timestamptz; ausente/basura → now() (GAS usa la fecha del día).
  begin
    v_fecha := nullif(btrim(coalesce(p->>'fecha','')),'')::timestamptz;
  exception when others then v_fecha := null;
  end;
  v_fecha := coalesce(v_fecha, now());

  -- IDEMPOTENCIA por local_id (gesto)
  if v_local is not null then
    select id_eval into v_existe from mos.evaluaciones where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEval', v_existe)); end if;
  end if;
  -- IDEMPOTENCIA por PK
  if v_id is not null and exists (select 1 from mos.evaluaciones where id_eval = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEval', v_id));
  end if;

  v_id := coalesce(v_id, 'EV'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

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
    -- aplica_comision/aplica_bono_meta: true salvo que venga 'false' explícito (paridad === false || 'false')
    case when (p ? 'aplicaComision') and (p->>'aplicaComision') in ('false','f','0') then false else true end,
    case when (p ? 'aplicaBonoMeta') and (p->>'aplicaBonoMeta') in ('false','f','0') then false else true end,
    true,
    greatest(0, coalesce(mos._numn(p->>'sancion'),0)),
    coalesce(nullif(btrim(coalesce(p->>'sancionMotivo','')),''),''),
    greatest(0, coalesce(mos._numn(p->>'bonificacion'),0)),
    coalesce(nullif(btrim(coalesce(p->>'bonificacionMotivo','')),''),''),
    v_local
  )
  on conflict (id_eval) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    if v_local is not null then
      select id_eval into v_existe from mos.evaluaciones where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEval', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEval', v_id));
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idEval', v_id));
exception
  -- red de seguridad: dos tx con el MISMO local_id en paralelo → la perdedora choca el índice único parcial.
  when unique_violation then
    if v_local is not null then
      select id_eval into v_existe from mos.evaluaciones where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEval', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEval', v_id));
end;
$fn$;
revoke all on function mos.crear_evaluacion(jsonb) from public;
grant execute on function mos.crear_evaluacion(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) ETIQUETAS DE ZONA — mos.crear_etiqueta_zona(p jsonb)  (primitivo atómico de 1 fila)
--    Espeja la rama "crear nueva fila" de _etiqGenerarParaZonas. estado nace 'PENDIENTE' (paridad GAS).
--    codigo_barra/sku_base SIEMPRE texto (regla en piedra del ecosistema). Idempotente por local_id + PK.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.crear_etiqueta_zona(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id    text := nullif(btrim(coalesce(p->>'idEtiq','')), '');
  v_zona  text := nullif(btrim(coalesce(p->>'idZona','')), '');
  v_ts    timestamptz;
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_ETIQ_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_ETIQ_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_zona is null then return jsonb_build_object('ok',false,'error','idZona requerido'); end if;

  -- ts_cambio: viene del front o now() (GAS usa _etiqNowIso()).
  begin
    v_ts := nullif(btrim(coalesce(p->>'tsCambio','')),'')::timestamptz;
  exception when others then v_ts := null;
  end;
  v_ts := coalesce(v_ts, now());

  -- IDEMPOTENCIA por local_id (gesto)
  if v_local is not null then
    select id_etiq into v_existe from mos.etiquetas_zona where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEtiq', v_existe)); end if;
  end if;
  -- IDEMPOTENCIA por PK
  if v_id is not null and exists (select 1 from mos.etiquetas_zona where id_etiq = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEtiq', v_id));
  end if;

  v_id := coalesce(v_id, 'ETQ-'||(extract(epoch from clock_timestamp())*1000)::bigint::text||'-'||left(v_zona,6));

  insert into mos.etiquetas_zona (
    id_etiq, id_zona, zona_nombre, id_producto, descripcion,
    codigo_barra, sku_base, precio_anterior, precio_nuevo,
    ts_cambio, cambiado_por, estado, visto_csv, local_id
  ) values (
    v_id, v_zona,
    nullif(btrim(coalesce(p->>'zonaNombre','')),''),
    nullif(btrim(coalesce(p->>'idProducto','')),''),
    nullif(btrim(coalesce(p->>'descripcion','')),''),
    nullif(btrim(coalesce(p->>'codigoBarra','')),''),   -- texto SIEMPRE
    nullif(btrim(coalesce(p->>'skuBase','')),''),        -- texto SIEMPRE
    coalesce(mos._numn(p->>'precioAnterior'),0),
    coalesce(mos._numn(p->>'precioNuevo'),0),
    v_ts,
    nullif(btrim(coalesce(p->>'cambiadoPor','')),''),
    coalesce(nullif(btrim(coalesce(p->>'estado','')),''),'PENDIENTE'),  -- nace PENDIENTE (paridad GAS)
    '',                                                                 -- visto_csv vacío al crear
    v_local
  )
  on conflict (id_etiq) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    if v_local is not null then
      select id_etiq into v_existe from mos.etiquetas_zona where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEtiq', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEtiq', v_id));
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idEtiq', v_id));
exception
  when unique_violation then
    if v_local is not null then
      select id_etiq into v_existe from mos.etiquetas_zona where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEtiq', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idEtiq', v_id));
end;
$fn$;
revoke all on function mos.crear_etiqueta_zona(jsonb) from public;
grant execute on function mos.crear_etiqueta_zona(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) ETIQUETAS DE ZONA — mos.actualizar_etiqueta_zona(p jsonb)  (patch parcial, UPDATE atómico por PK)
--    Espeja marcarVistoEtiqueta / marcarPegadaEtiqueta / _etiqMarcarImpresa (que en GAS son setValue
--    celda-a-celda tras un getValues → propenso a lost-update; acá es 1 UPDATE atómico por id_etiq).
--    Cada campo: si la clave viene presente, se aplica; si no, se conserva. Espeja
--    "campos.forEach if params[c]!==undefined". Numéricos vía _numn; timestamps vía cast tolerante.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.actualizar_etiqueta_zona(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id   text := nullif(btrim(coalesce(p->>'idEtiq','')), '');
  v_tsp  timestamptz; v_tsp_set boolean := false;
  v_tsi  timestamptz; v_tsi_set boolean := false;
  v_tsc  timestamptz; v_tsc_set boolean := false;
  v_n    int;
begin
  if coalesce((select valor from mos.config where clave='MOS_ETIQ_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_ETIQ_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idEtiq'); end if;

  -- timestamps presentes → cast tolerante (basura → NULL, sin reventar)
  if p ? 'tsPegada' then v_tsp_set := true;
    begin v_tsp := nullif(btrim(coalesce(p->>'tsPegada','')),'')::timestamptz; exception when others then v_tsp := null; end;
  end if;
  if p ? 'tsImpresa' then v_tsi_set := true;
    begin v_tsi := nullif(btrim(coalesce(p->>'tsImpresa','')),'')::timestamptz; exception when others then v_tsi := null; end;
  end if;
  if p ? 'tsCambio' then v_tsc_set := true;
    begin v_tsc := nullif(btrim(coalesce(p->>'tsCambio','')),'')::timestamptz; exception when others then v_tsc := null; end;
  end if;

  update mos.etiquetas_zona t set
    estado          = case when p ? 'estado'         then nullif(btrim(coalesce(p->>'estado','')),'')         else t.estado end,
    visto_csv       = case when p ? 'vistoCsv'       then coalesce(btrim(coalesce(p->>'vistoCsv','')),'')     else t.visto_csv end,
    precio_anterior = case when p ? 'precioAnterior' then coalesce(mos._numn(p->>'precioAnterior'),0)         else t.precio_anterior end,
    precio_nuevo    = case when p ? 'precioNuevo'    then coalesce(mos._numn(p->>'precioNuevo'),0)            else t.precio_nuevo end,
    cambiado_por    = case when p ? 'cambiadoPor'    then nullif(btrim(coalesce(p->>'cambiadoPor','')),'')    else t.cambiado_por end,
    impresa_por     = case when p ? 'impresaPor'     then nullif(btrim(coalesce(p->>'impresaPor','')),'')     else t.impresa_por end,
    job_id          = case when p ? 'jobId'          then nullif(btrim(coalesce(p->>'jobId','')),'')          else t.job_id end,
    pegada_por      = case when p ? 'pegadaPor'      then nullif(btrim(coalesce(p->>'pegadaPor','')),'')      else t.pegada_por end,
    comentario      = case when p ? 'comentario'     then nullif(btrim(coalesce(p->>'comentario','')),'')     else t.comentario end,
    ts_pegada       = case when v_tsp_set            then v_tsp                                               else t.ts_pegada end,
    ts_impresa      = case when v_tsi_set            then v_tsi                                               else t.ts_impresa end,
    ts_cambio       = case when v_tsc_set            then v_tsc                                               else t.ts_cambio end
  where id_etiq = v_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then return jsonb_build_object('ok',false,'error','idEtiq no encontrado'); end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('idEtiq', v_id));
end;
$fn$;
revoke all on function mos.actualizar_etiqueta_zona(jsonb) from public;
grant execute on function mos.actualizar_etiqueta_zona(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 5) HORARIOS — mos.actualizar_horario_app(p jsonb)  (UPSERT por PK natural `app`, espeja setHorarioApp)
--    · app ∈ {warehouseMos, mosExpress, MOS} (paridad GAS).
--    · Acepta dos shapes de entrada: { dias: {lun..dom} } (preferido) o { horario: {lun..dom} } (legacy).
--    · Valida HH:MM SOLO en días activos (días cerrados pueden tener apertura/cierre arbitrarios — paridad
--      v2.43.133). Default 07:00/19:00 igual que GAS si el día no trae apertura/cierre.
--    · Guarda horario_json (los 7 días normalizados), admins_libres, actualizado_por, fecha_actualizacion.
--    · NO dispara push ni invalida cache de WH (orquestación queda en GAS).
--    · UPSERT atómico: on conflict (app) do update → sin lost-update vs el getRange/setValue de GAS.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.actualizar_horario_app(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_app   text := nullif(btrim(coalesce(p->>'app','')), '');
  v_src   jsonb;        -- objeto de días de entrada (dias | horario)
  v_out   jsonb := '{}'::jsonb;   -- 7 días normalizados
  v_admin boolean;
  v_por   text;
  v_dia   text;
  v_c     jsonb;
  v_activo boolean;
  v_ap    text;
  v_ci    text;
  v_invalido text := null;
  v_dias text[] := array['lun','mar','mie','jue','vie','sab','dom'];
begin
  if coalesce((select valor from mos.config where clave='MOS_HORARIO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_HORARIO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_app is null then return jsonb_build_object('ok',false,'error','app requerida'); end if;
  if v_app not in ('warehouseMos','mosExpress','MOS') then
    return jsonb_build_object('ok',false,'error','app no soportada (warehouseMos | mosExpress | MOS)');
  end if;

  -- Origen de días: prefiere `dias`, cae a `horario`, default {} (paridad params.dias || params.horario || {})
  if (p ? 'dias') and jsonb_typeof(p->'dias') = 'object' then
    v_src := p->'dias';
  elsif (p ? 'horario') and jsonb_typeof(p->'horario') = 'object' then
    v_src := p->'horario';
  else
    v_src := '{}'::jsonb;
  end if;

  -- Normalizar y validar los 7 días.
  foreach v_dia in array v_dias loop
    v_c := coalesce(v_src->v_dia, '{}'::jsonb);
    -- activo: true salvo que venga explícitamente false (paridad c.activo !== false)
    v_activo := not (jsonb_typeof(v_c->'activo') = 'boolean' and (v_c->>'activo') = 'false');
    v_ap := coalesce(nullif(btrim(coalesce(v_c->>'apertura','')),''), '07:00');
    v_ci := coalesce(nullif(btrim(coalesce(v_c->>'cierre','')),''), '19:00');
    -- Validar HH:MM solo si el día está activo (paridad v2.43.133)
    if v_activo and ( v_ap !~ '^([0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$'
                   or v_ci !~ '^([0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$' ) then
      v_invalido := v_dia || ' (' || v_ap || ' / ' || v_ci || ')';
    end if;
    v_out := v_out || jsonb_build_object(v_dia, jsonb_build_object('activo', v_activo, 'apertura', v_ap, 'cierre', v_ci));
  end loop;

  if v_invalido is not null then
    return jsonb_build_object('ok',false,'error','Hora inválida en día: ' || v_invalido);
  end if;

  -- admins_libres: true salvo que venga explícitamente false (paridad params.admins_libres !== false)
  v_admin := not ((p ? 'admins_libres') and (p->>'admins_libres') = 'false');
  v_por   := coalesce(nullif(btrim(coalesce(p->>'actualizadoPor','')),''), 'admin-mos');

  insert into mos.config_horarios_apps (app, horario_json, admins_libres, actualizado_por, fecha_actualizacion)
  values (v_app, v_out, case when v_admin then 'true' else 'false' end, v_por, now())
  on conflict (app) do update set
    horario_json        = excluded.horario_json,
    admins_libres       = excluded.admins_libres,
    actualizado_por     = excluded.actualizado_por,
    fecha_actualizacion = excluded.fecha_actualizacion;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'app', v_app, 'horario', v_out, 'admins_libres', v_admin));
end;
$fn$;
revoke all on function mos.actualizar_horario_app(jsonb) from public;
grant execute on function mos.actualizar_horario_app(jsonb) to service_role, authenticated;
