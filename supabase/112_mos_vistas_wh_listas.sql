-- 112_mos_vistas_wh_listas.sql — [MIGRACIÓN MOS · FASE 2 · LECTURA CROSS-APP WH]
-- Replica con PARIDAD 3 getters GAS de gas/Conexiones.gs (vistas de WAREHOUSE consultadas desde MOS):
--   · getMermasWarehouse   (Conexiones.gs:128) → mos.mermas_warehouse(p jsonb)
--   · getEnvasadosWarehouse(Conexiones.gs:140) → mos.envasados_warehouse(p jsonb)
--   · getAlertasWarehouse  (Conexiones.gs:97)  → mos.alertas_warehouse(p jsonb)
--
-- Estos getters NO leen mos.*: leen el SHEET de WH en vivo (_abrirWhSheet + _sheetToObjectsLocal). En Supabase
-- las hojas equivalentes son SOMBRAS wh.mermas / wh.envasados / wh.lotes_vencimiento (03_schema_wh.sql),
-- alimentadas por el sync GAS→Supabase. Por eso van con SECURITY DEFINER cross-schema (la función definida en
-- `mos` lee `wh.*`) + envoltorio mos._frescura_sombra() para que el front pueda caer a GAS si la sombra
-- está congelada (el GAS lee la hoja en vivo → siempre fresco; estas RPCs leen la sombra → puede estar stale).
--
-- ⚠️ INERTE / NO-APLICAR-AUN: este archivo SOLO define 3 RPCs con sus grants. Nadie las llama todavía
--    (el wiring de js/api.js read-path + el flip de flags MOS_*_DIRECTO es tanda posterior). MOS sigue 100%
--    por GAS. Este SQL NO toca flags, NO toca sync, NO cablea frontend. Patrón inerte idéntico a 94/98/105-110.
--
-- ── FUENTES CRUZADAS (verificadas en 03_schema_wh.sql) ───────────────────────────────────────────────────────
--   · wh.mermas             (03:96)  — id_merma, fecha_ingreso, origen, cod_producto, id_lote, cantidad_original,
--                                       cantidad_pendiente, motivo, usuario, id_guia, estado, responsable,
--                                       cantidad_reparada, cantidad_desechada, foto, fecha_resolucion,
--                                       observacion_resolucion, id_guia_salida.
--   · wh.envasados          (03:145) — id_envasado, cod_producto_base, cantidad_base, unidad_base,
--                                       cod_producto_envasado, unidades_esperadas, unidades_producidas,
--                                       merma_real, eficiencia_pct, fecha, usuario, estado, id_guia_salida,
--                                       id_guia_ingreso, observacion.
--   · wh.lotes_vencimiento  (03:84)  — id_lote, cod_producto, fecha_vencimiento, cantidad_inicial,
--                                       cantidad_actual, id_guia, estado, fecha_creacion.
--
-- ── PARIDAD DE SHAPE (mismas claves camelCase que devuelve _sheetToObjectsLocal sobre el header de la hoja) ───
--   _sheetToObjectsLocal usa el HEADER de la hoja WH como claves del objeto (camelCase real de las hojas WH).
--   Aquí se traduce snake_case (sombra) → camelCase (hoja). Verificado contra los headers que el sync escribe.
--   ⚠️ Las RPCs replican EXACTAMENTE el shape que cada getter devuelve; ver bloque NOTAS para gaps de columnas.
--
-- ── SERIALIZACIÓN DE FECHAS (clave para paridad) ─────────────────────────────────────────────────────────────
--   _sheetToObjectsLocal serializa toda celda Date como `Utilities.formatDate(v, tz, 'yyyy-MM-dd HH:mm:ss')`
--   con tz = TZ del proyecto Apps Script = America/Lima. ⇒ el front recibe un STRING 'YYYY-MM-DD HH:MM:SS' en
--   hora Lima, NO un ISO con offset. Aquí toda columna timestamptz se emite con:
--       to_char(col at time zone 'America/Lima', 'YYYY-MM-DD HH24:MI:SS')
--   replicando bit-a-bit ese formato. Celdas vacías → '' (igual que _sheetToObjectsLocal, que deja el valor crudo;
--   para columnas no-Date vacías el getter devuelve '' o el valor; aquí coalesce a '' en strings, a 0 en números
--   donde el front hace parseFloat). Ver NOTA "fechas".
--
-- ── BOOLS ────────────────────────────────────────────────────────────────────────────────────────────────────
--   Ninguno de los 3 shapes WH expone booleanos (las hojas WH no tienen columnas bool en estas tablas; estado es
--   text 'ACTIVO'/'PENDIENTE'/etc.). No aplica la regla '1'/'0'. (diasRestantes/cantidades = número.)

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) mos.mermas_warehouse(p jsonb) — getMermasWarehouse(params)
--    p = { estado (opc) }.  Filtro: String(r.estado) === String(params.estado) si viene estado.
--    data = array de mermas (shape = header de la hoja MERMAS, camelCase).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.mermas_warehouse(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_estado text := nullif(p->>'estado', null);   -- presente sólo si la clave 'estado' viene en el payload
  v_tiene_estado boolean := (p ? 'estado');       -- paridad: el GAS filtra sólo si params.estado es truthy
  v_data jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- Paridad: el GAS filtra `if (params && params.estado)`. Un estado '' (string vacío) es falsy → NO filtra.
  -- Aquí: filtra sólo si la clave existe Y no es '' (replica el truthy de JS).
  if not v_tiene_estado or coalesce(v_estado,'') = '' then
    v_estado := null;
  end if;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'idMerma',              m.id_merma,
             'fechaIngreso',         case when m.fecha_ingreso is null then ''
                                       else to_char(m.fecha_ingreso at time zone 'America/Lima', 'YYYY-MM-DD HH24:MI:SS') end,
             'origen',               coalesce(m.origen, ''),
             'codigoProducto',       coalesce(m.cod_producto, ''),
             'idLote',               coalesce(m.id_lote, ''),
             'cantidadOriginal',     coalesce(m.cantidad_original, 0),
             'cantidadPendiente',    coalesce(m.cantidad_pendiente, 0),
             'motivo',               coalesce(m.motivo, ''),
             'usuario',              coalesce(m.usuario, ''),
             'idGuia',               coalesce(m.id_guia, ''),
             'estado',               coalesce(m.estado, ''),
             'responsable',          coalesce(m.responsable, ''),
             'cantidadReparada',     coalesce(m.cantidad_reparada, 0),
             'cantidadDesechada',    coalesce(m.cantidad_desechada, 0),
             'foto',                 coalesce(m.foto, ''),
             'fechaResolucion',      case when m.fecha_resolucion is null then ''
                                       else to_char(m.fecha_resolucion at time zone 'America/Lima', 'YYYY-MM-DD HH24:MI:SS') end,
             'observacionResolucion',coalesce(m.observacion_resolucion, ''),
             'idGuiaSalida',         coalesce(m.id_guia_salida, '')
           )
           -- _sheetToObjectsLocal preserva el orden físico de la hoja; aquí orden estable por fecha luego id.
           order by m.fecha_ingreso nulls last, m.id_merma
         ), '[]'::jsonb)
    into v_data
  from wh.mermas m
  where v_estado is null or m.estado = v_estado;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.mermas_warehouse(jsonb) from public;
grant execute on function mos.mermas_warehouse(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) mos.envasados_warehouse(p jsonb) — getEnvasadosWarehouse(params)
--    p = { desde (opc 'YYYY-MM-DD'), hasta (opc 'YYYY-MM-DD'), usuario (opc), limit (opc, default 500) }.
--    Filtros GAS:
--      · desde:  String(r.fecha||'').substring(0,10) >= desde
--      · hasta:  String(r.fecha||'').substring(0,10) <= hasta
--      · usuario: lower(trim(r.usuario)) === lower(trim(usuario))
--    Orden: fecha desc (localeCompare sobre el string de fecha serializado). Limit: parseInt(limit)||500.
--    data = array de envasados (shape = header de la hoja ENVASADOS, camelCase).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.envasados_warehouse(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_desde   text := nullif(btrim(coalesce(p->>'desde','')), '');   -- 'YYYY-MM-DD' (10 chars), comparación lexicográfica
  v_hasta   text := nullif(btrim(coalesce(p->>'hasta','')), '');
  v_usuario text := nullif(lower(btrim(coalesce(p->>'usuario',''))), '');
  v_limit   int;
  v_data    jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- limit: parseInt(params.limit) || 500. Clamp defensivo (1..100000) para no devolver el universo por error.
  v_limit := coalesce(nullif(btrim(coalesce(p->>'limit','')), '')::int, 500);
  if v_limit is null or v_limit <= 0 then v_limit := 500; end if;
  if v_limit > 100000 then v_limit := 100000; end if;

  with base as (
    select
      e.*,
      -- fecha serializada igual que _sheetToObjectsLocal (Lima, 'YYYY-MM-DD HH24:MI:SS'). '' si null.
      case when e.fecha is null then ''
           else to_char(e.fecha at time zone 'America/Lima', 'YYYY-MM-DD HH24:MI:SS') end as fecha_str
    from wh.envasados e
  ),
  filtrado as (
    select b.*
    from base b
    where
      -- Paridad: comparación sobre substring(fecha_str,0,10) = 'YYYY-MM-DD' (los primeros 10 chars).
      (v_desde   is null or left(b.fecha_str, 10) >= v_desde)
      and (v_hasta is null or left(b.fecha_str, 10) <= v_hasta)
      and (v_usuario is null or lower(btrim(coalesce(b.usuario,''))) = v_usuario)
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'idEnvasado',          f.id_envasado,
             'codigoProductoBase',  coalesce(f.cod_producto_base, ''),
             'cantidadBase',        coalesce(f.cantidad_base, 0),
             'unidadBase',          coalesce(f.unidad_base, ''),
             'codigoProductoEnvasado', coalesce(f.cod_producto_envasado, ''),
             'unidadesEsperadas',   coalesce(f.unidades_esperadas, 0),
             'unidadesProducidas',  coalesce(f.unidades_producidas, 0),
             'mermaReal',           coalesce(f.merma_real, 0),
             'eficienciaPct',       coalesce(f.eficiencia_pct, 0),
             'fecha',               f.fecha_str,
             'usuario',             coalesce(f.usuario, ''),
             'estado',              coalesce(f.estado, ''),
             'idGuiaSalida',        coalesce(f.id_guia_salida, ''),
             'idGuiaIngreso',       coalesce(f.id_guia_ingreso, ''),
             'observacion',         coalesce(f.observacion, '')
           )
           order by f.fecha_str desc   -- paridad: rows.sort((a,b)=>localeCompare(b.fecha,a.fecha)) = fecha desc
         ), '[]'::jsonb)
    into v_data
  from (
    select * from filtrado
    order by fecha_str desc
    limit v_limit
  ) f;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.envasados_warehouse(jsonb) from public;
grant execute on function mos.envasados_warehouse(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) mos.alertas_warehouse(p jsonb) — getAlertasWarehouse()
--    p = {} (el GAS no recibe params). Lee LOTES_VENCIMIENTO; calcula diasRestantes; filtra y ordena.
--    Lógica GAS:
--      · diasRestantes = (l.fechaVencimiento && l.estado==='ACTIVO')
--          ? Math.ceil((new Date(l.fechaVencimiento) - hoy) / 86400000)
--          : 9999
--      · activos = lotes con diasRestantes <= 30 AND parseFloat(l.cantidadActual) > 0
--      · sort ascendente por diasRestantes
--      · data = { criticos: dias<=7 , alertas: dias>7 }     ← OBJETO, no array (ver GAP #1)
--    AQUÍ (por requisito del task): data = ARRAY plano de lotes con diasRestantes (los `activos` ya ordenados).
--    TZ: `hoy` del GAS = medianoche-local-Lima implícita; aquí diasRestantes se calcula con el DÍA Lima.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.alertas_warehouse(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_hoy  date := (now() at time zone 'America/Lima')::date;  -- "hoy" Lima (ver NOTA "diasRestantes / hoy")
  v_data jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  with calc as (
    select
      l.*,
      -- diasRestantes: si tiene fechaVencimiento y estado='ACTIVO' → ceil(dias hasta vto), si no 9999.
      -- Math.ceil((vto - hoy)/86400000): ambos extremos a medianoche Lima ⇒ diferencia entera de días.
      -- (vto at time zone Lima)::date - hoy(Lima)  == nº de días calendario (ya es entero, ceil() no cambia).
      case
        when l.fecha_vencimiento is not null and l.estado = 'ACTIVO'
          then ((l.fecha_vencimiento at time zone 'America/Lima')::date - v_hoy)
        else 9999
      end as dias_restantes
    from wh.lotes_vencimiento l
  ),
  activos as (
    select c.*
    from calc c
    where c.dias_restantes <= 30
      and coalesce(c.cantidad_actual, 0) > 0   -- parseFloat(l.cantidadActual) > 0
  ),
  -- [FIX 40x] paridad EXACTA con getAlertasWarehouse: data = { criticos:[dias<=7], alertas:[dias>7] } (OBJETO,
  -- no array). Ambos ordenados por diasRestantes asc. El objeto-lote es idéntico para ambas ramas.
  objs as (
    select a.dias_restantes as dr, a.id_lote as idl,
      jsonb_build_object(
        'idLote',            a.id_lote,
        'codigoProducto',    coalesce(a.cod_producto, ''),
        'fechaVencimiento',  case when a.fecha_vencimiento is null then ''
                               else to_char(a.fecha_vencimiento at time zone 'America/Lima', 'YYYY-MM-DD HH24:MI:SS') end,
        'cantidadInicial',   coalesce(a.cantidad_inicial, 0),
        'cantidadActual',    coalesce(a.cantidad_actual, 0),
        'idGuia',            coalesce(a.id_guia, ''),
        'estado',            coalesce(a.estado, ''),
        'fechaCreacion',     case when a.fecha_creacion is null then ''
                               else to_char(a.fecha_creacion at time zone 'America/Lima', 'YYYY-MM-DD HH24:MI:SS') end,
        'diasRestantes',     a.dias_restantes
      ) as o
    from activos a
  )
  select jsonb_build_object(
    'criticos', coalesce((select jsonb_agg(o order by dr asc, idl) from objs where dr <= 7), '[]'::jsonb),
    'alertas',  coalesce((select jsonb_agg(o order by dr asc, idl) from objs where dr >  7), '[]'::jsonb)
  ) into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.alertas_warehouse(jsonb) from public;
grant execute on function mos.alertas_warehouse(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTAS DE PARIDAD / DIVERGENCIAS / GAPS (honestidad 40x)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- GAP #1 — FORMA DEL `data` DE ALERTAS (DIVERGENCIA DELIBERADA pedida por el task):
--   El GAS getAlertasWarehouse devuelve  data = { criticos:[dias<=7], alertas:[dias>7] }  (un OBJETO con 2 arrays).
--   Esta RPC devuelve  data = [ ...lotes activos ordenados por diasRestantes... ]  (un ARRAY plano), como exige
--   el requisito. El consumidor (js/api.js read-path o el componente que pinte alertas) DEBE re-particionar por
--   diasRestantes (<=7 críticos, >7 alertas) si quiere el shape exacto del GAS. Cada elemento ya trae
--   `diasRestantes` para hacerlo trivialmente en el cliente. ⚠️ Si se prefiere paridad bit-a-bit del envoltorio,
--   cambiar el return a: jsonb_build_object('ok',true,'data', jsonb_build_object(
--       'criticos', (filtrar dias<=7), 'alertas', (filtrar dias>7))) || mos._frescura_sombra().
--
-- GAP #2 — diasRestantes / "hoy" y TZ:
--   El GAS hace `new Date()` (instante actual del servidor Apps Script, TZ Lima) y resta `new Date(fechaVto)`.
--   fechaVto en la hoja es una fecha (a menudo medianoche). Math.ceil sobre el cociente de ms ⇒ si vto cae HOY
--   más tarde, da 1; si ya pasó, negativo. Aquí se calcula por DÍA calendario Lima: (vtoLima::date - hoyLima),
--   que es entero exacto y estable (no depende de la hora del momento de la consulta). DIVERGENCIA POSIBLE de
--   ±1 respecto al GAS en el borde, según la hora del día y si la celda vto traía hora ≠ 00:00. Para alertas de
--   vencimiento (umbral 30/7 días) el efecto es marginal y MÁS estable que el GAS. Si se exige el cómputo por
--   ms del GAS, usar: ceil(extract(epoch from (l.fecha_vencimiento - now()))/86400)::int — pero eso reintroduce
--   la dependencia del instante exacto y la fragilidad de TZ.
--
-- GAP #3 — SHAPE camelCase vs HEADER REAL DE LA HOJA:
--   _sheetToObjectsLocal usa el HEADER literal de cada hoja WH como claves. Aquí se asumió el camelCase canónico
--   del ecosistema (idMerma, codigoProducto, fechaIngreso, ...). Los nombres de columna de la SOMBRA (snake_case)
--   están verificados contra 03_schema_wh.sql, pero el HEADER EXACTO de la hoja WH (que es lo que ve el front)
--   NO se pudo verificar desde este repo (la hoja vive en WH). Riesgo: si una columna en la hoja se llama p.ej.
--   'codProducto' en vez de 'codigoProducto', el front no la encontraría. MITIGACIÓN antes del cutover: confirmar
--   los headers reales de MERMAS/ENVASADOS/LOTES_VENCIMIENTO en WH y ajustar las claves de jsonb_build_object.
--   En particular revisar: cod_producto → 'codigoProducto' (asumido; podría ser 'codProducto'),
--   cod_producto_base/envasado → 'codigoProductoBase'/'codigoProductoEnvasado'.
--
-- GAP #4 — FILAS VACÍAS:
--   _sheetToObjectsLocal descarta filas totalmente vacías (filter: alguna celda no '' / null). En la sombra no
--   existen filas-fantasma (cada row tiene PK), así que no hace falta replicar ese filtro. Sin divergencia.
--
-- GAP #5 — SERIALIZACIÓN DE NÚMEROS vs STRINGS:
--   El GAS devuelve los valores crudos de la celda (Number para numéricas, string para texto). Aquí las numéricas
--   van como número JSON (cantidad*, eficienciaPct, diasRestantes) y las de texto con coalesce a ''. El front ya
--   hace parseFloat() defensivo sobre cantidades (visto en getStockWarehouse), así que el tipo exacto no rompe.
--
-- GAP #6 — ORDEN DE MERMAS:
--   getMermasWarehouse NO ordena (devuelve el orden físico de la hoja). Aquí se impone orden estable
--   (fecha_ingreso, id_merma) porque SQL sin ORDER BY no garantiza orden. Si el front dependiera del orden de
--   inserción de la hoja, podría diferir; en la práctica el front re-ordena/filtra por estado. RIESGO BAJO.
--
-- GAP #7 — ENVASADOS sin columna 'fecha' poblada:
--   El sort y los filtros desde/hasta del GAS operan sobre String(r.fecha||'').substring(0,10); filas con fecha
--   vacía quedan con '' → '' >= 'YYYY-MM-DD' es false ⇒ se EXCLUYEN si hay filtro desde, y ordenan al final en
--   desc. Replicado: fecha_str='' para null, mismo comportamiento de comparación lexicográfica. Sin divergencia.
--
-- GATE + ENVOLTORIO: mos._claim_ok() (74) y mos._frescura_sombra() (94) ya existen; este archivo los CONSUME, no
-- los redefine. Resultado de cada RPC: { ok, data, _heartbeat, _now, _ttl_min, _fresh }.
--
-- FRESCURA: wh.mermas / wh.envasados / wh.lotes_vencimiento son SOMBRAS del sync GAS→Supabase. El GAS lee la hoja
-- en vivo (siempre fresco); estas RPCs leen la sombra. Antes del cutover de ESTOS getters, el sync de esas 3
-- tablas DEBE estar vivo, o _fresh=false y el front debe caer a GAS.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
