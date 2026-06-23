-- 154_mos_wh_lecturas_crudas.sql — [MIGRACIÓN MOS · LECTURAS WH CRUDAS · Almacen.gs]
-- ============================================================================================================
-- OBJETIVO: dar a MOS GAS (Almacen.gs) la MISMA fila cruda que hoy produce leer la HOJA de WH, pero desde la
-- SOMBRA wh.* en Supabase (que WH ahora escribe en VIVO; la hoja puede estar stale → el dashboard de almacén
-- de MOS mostraría datos viejos). NO replican lógica de negocio: devuelven el ARRAY de filas con EXACTAMENTE
-- las mismas KEYS camelCase y los mismos TIPOS/serialización de fecha que los leaf-readers de Almacen.gs:
--   · _safeReadWhStock()       (Almacen.gs:2178)  → _sheetToObjects(STOCK)            → mos.wh_stock_crudo()
--   · _safeReadWhLotes()       (Almacen.gs:2181)  → _sheetToObjects(LOTES_VENCIMIENTO)→ mos.wh_lotes_crudo()
--   · _safeReadWhMermas()      (Almacen.gs:2184)  → _sheetToObjects(MERMAS)           → mos.wh_mermas_crudo()
--   · _safeReadWhEnvasados()   (Almacen.gs:2187)  → _sheetToObjects(ENVASADOS)        → mos.wh_envasados_crudo()
--   · _safeReadWhGuias()       (Almacen.gs:2190)  → _readSheetPreservandoFecha(GUIAS) → mos.wh_guias_crudo()
--   · _safeReadWhPreingresos() (Almacen.gs:2194)  → _readSheetPreservandoFecha(PREINGRESOS) → mos.wh_preingresos_crudo()
--   · GUIA_DETALLE (Almacen.gs:1339/2032/2126)    → _sheetToObjects / _readSheetPreservandoFecha → mos.wh_guia_detalle_crudo()
--
-- ── SERIALIZACIÓN DE FECHAS (LOAD-BEARING — distingue cuál reader la consume) ────────────────────────────────
--   _sheetToObjects()              (Code.gs:581): Date  →  Utilities.formatDate(v, tzScript, 'yyyy-MM-dd')   ⇒ DATE-ONLY en TZ Lima.
--   _readSheetPreservandoFecha()   (Almacen.gs:2209): Date  →  v.toISOString()                               ⇒ ISO UTC '...Z' completo.
--   tzScript del proyecto Apps Script MOS = America/Lima.
--   ⇒ STOCK/LOTES/MERMAS/ENVASADOS (via _sheetToObjects) emiten fechas como 'YYYY-MM-DD' (Lima).
--   ⇒ GUIAS/PREINGRESOS (via _readSheetPreservandoFecha) emiten fechas como ISO 'YYYY-MM-DDTHH24:MI:SS.MSZ' (UTC).
--   GUIA_DETALLE se lee de AMBAS formas según el call-site; fecha_vencimiento es DATE (no Date object con hora) →
--     _sheetToObjects la dejaría como 'YYYY-MM-DD' igual; _readSheetPreservandoFecha emite ISO. Como GUIA_DETALLE
--     solo expone fecha_vencimiento (un date sin hora) y el front la trata como string, ambas formas coinciden en
--     la fecha; se replica 'YYYY-MM-DD' (paridad con _sheetToObjects, el call-site más usado) — ver NOTA D.
--
-- ── PARIDAD DE TIPOS NUMÉRICOS ───────────────────────────────────────────────────────────────────────────────
--   En la hoja las celdas numéricas son Number; aquí columnas numeric → número JSON (jsonb_build_object con
--   ::numeric da número, NO string). El GAS hace parseFloat() defensivo en todos los consumos de cantidad/precio,
--   así que el tipo exacto no rompe. NO se aplica coalesce-a-0 en numéricos que el GAS lee como '' cuando vacíos:
--   la hoja deja la celda Number o '' (vacía) → aquí null → JSON null. parseFloat(null)→NaN→||0 en el GAS. Para
--   máxima fidelidad con _sheetToObjects (que pone el valor crudo, no 0), los numéricos van TAL CUAL (null si null).
--   Los de TEXTO van TAL CUAL también (null si null), porque _sheetToObjects no coalesce-a-'' (deja '' solo si la
--   celda era ''). El GAS hace String(x||'') en los consumos de texto. Ver NOTA E.
--
-- ── KEYS camelCase (= HEADER REAL de cada hoja WH, verificadas) ──────────────────────────────────────────────
--   STOCK:        idStock, codigoProducto, cantidadDisponible, ultimaActualizacion   (cf. wh.stock_enriquecido, 10_fase1d_wh_stock.sql)
--   LOTES:        idLote, codigoProducto, fechaVencimiento, cantidadInicial, cantidadActual, idGuia, estado, fechaCreacion  (cf. 112)
--   MERMAS:       idMerma, fechaIngreso, origen, codigoProducto, idLote, cantidadOriginal, cantidadPendiente, motivo, usuario, idGuia, estado, responsable, cantidadReparada, cantidadDesechada, foto, fechaResolucion, observacionResolucion, idGuiaSalida  (cf. 112)
--   ENVASADOS:    idEnvasado, codigoProductoBase, cantidadBase, unidadBase, codigoProductoEnvasado, unidadesEsperadas, unidadesProducidas, mermaReal, eficienciaPct, fecha, usuario, estado, idGuiaSalida, idGuiaIngreso, observacion  (cf. 112)
--   GUIAS:        idGuia, tipo, fecha, usuario, idProveedor, idZona, numeroDocumento, comentario, montoTotal, estado, idPreingreso, foto  (cf. 117 guia_json; col extra OCR/ultima_actividad NO existen en la hoja MOS-leída → se omiten, paridad)
--   PREINGRESOS:  idPreingreso, fecha, idProveedor, cargadores, usuario, monto, fotos, comentario, estado, idGuia  (cf. 117 pre_json; snapshot_aviso NO está en la hoja → se omite)
--   GUIA_DETALLE: idGuia, linea, codigoProducto, cantidadEsperada, cantidadRecibida, precioUnitario, idLote, observacion, idProductoNuevo, idDetalle, fechaVencimiento, cantidadAplicada  (header WH verificado: cantidadEsperada/cantidadRecibida/idDetalle)
--
-- ── GATE + ENVOLTORIO ────────────────────────────────────────────────────────────────────────────────────────
--   mos._claim_ok() (74_mos_claim_ok_f0a.sql): service_role/GAS o claim app='MOS' → si no, APP_NO_AUTORIZADA.
--   Cada función: { ok:true, data:[...] }  (mismo envoltorio que el resto de lecturas mos.*; el GAS desempaqueta .data).
--   SECURITY DEFINER + search_path='' (las funciones viven en mos pero leen wh.* con RLS; definer las atraviesa).
--   grant execute a service_role + authenticated (MOS GAS usa service_role; authenticated por paridad con 112/117).
--
-- ⚠️ Solo-LECTURA. No muta nada. No toca flags ni sync. Idempotente (create or replace).
-- ============================================================================================================


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) mos.wh_stock_crudo() — espeja _safeReadWhStock() = _sheetToObjects(STOCK).
--    ultimaActualizacion: timestamptz → 'YYYY-MM-DD' (Lima) [_sheetToObjects corta Date→yyyy-MM-dd].
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.wh_stock_crudo()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_data jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'idStock',             s.id_stock,
           'codigoProducto',      s.cod_producto,
           'cantidadDisponible',  s.cantidad_disponible,
           'ultimaActualizacion', case when s.ultima_actualizacion is null then ''
                                    else to_char(s.ultima_actualizacion at time zone 'America/Lima', 'YYYY-MM-DD') end
         ) order by s.id_stock), '[]'::jsonb)
    into v_data
  from wh.stock s;
  return jsonb_build_object('ok', true, 'data', v_data);
end;
$fn$;
revoke all on function mos.wh_stock_crudo() from public;
grant execute on function mos.wh_stock_crudo() to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) mos.wh_lotes_crudo() — espeja _safeReadWhLotes() = _sheetToObjects(LOTES_VENCIMIENTO).
--    fechaVencimiento / fechaCreacion: timestamptz → 'YYYY-MM-DD' (Lima).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.wh_lotes_crudo()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_data jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'idLote',           l.id_lote,
           'codigoProducto',   l.cod_producto,
           'fechaVencimiento', case when l.fecha_vencimiento is null then ''
                                 else to_char(l.fecha_vencimiento at time zone 'America/Lima', 'YYYY-MM-DD') end,
           'cantidadInicial',  l.cantidad_inicial,
           'cantidadActual',   l.cantidad_actual,
           'idGuia',           l.id_guia,
           'estado',           l.estado,
           'fechaCreacion',    case when l.fecha_creacion is null then ''
                                 else to_char(l.fecha_creacion at time zone 'America/Lima', 'YYYY-MM-DD') end
         ) order by l.id_lote), '[]'::jsonb)
    into v_data
  from wh.lotes_vencimiento l;
  return jsonb_build_object('ok', true, 'data', v_data);
end;
$fn$;
revoke all on function mos.wh_lotes_crudo() from public;
grant execute on function mos.wh_lotes_crudo() to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) mos.wh_mermas_crudo() — espeja _safeReadWhMermas() = _sheetToObjects(MERMAS).
--    fechaIngreso / fechaResolucion: timestamptz → 'YYYY-MM-DD' (Lima).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.wh_mermas_crudo()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_data jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'idMerma',               m.id_merma,
           'fechaIngreso',          case when m.fecha_ingreso is null then ''
                                      else to_char(m.fecha_ingreso at time zone 'America/Lima', 'YYYY-MM-DD') end,
           'origen',                m.origen,
           'codigoProducto',        m.cod_producto,
           'idLote',                m.id_lote,
           'cantidadOriginal',      m.cantidad_original,
           'cantidadPendiente',     m.cantidad_pendiente,
           'motivo',                m.motivo,
           'usuario',               m.usuario,
           'idGuia',                m.id_guia,
           'estado',                m.estado,
           'responsable',           m.responsable,
           'cantidadReparada',      m.cantidad_reparada,
           'cantidadDesechada',     m.cantidad_desechada,
           'foto',                  m.foto,
           'fechaResolucion',       case when m.fecha_resolucion is null then ''
                                      else to_char(m.fecha_resolucion at time zone 'America/Lima', 'YYYY-MM-DD') end,
           'observacionResolucion', m.observacion_resolucion,
           'idGuiaSalida',          m.id_guia_salida
         ) order by m.fecha_ingreso nulls last, m.id_merma), '[]'::jsonb)
    into v_data
  from wh.mermas m;
  return jsonb_build_object('ok', true, 'data', v_data);
end;
$fn$;
revoke all on function mos.wh_mermas_crudo() from public;
grant execute on function mos.wh_mermas_crudo() to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) mos.wh_envasados_crudo() — espeja _safeReadWhEnvasados() = _sheetToObjects(ENVASADOS).
--    fecha: timestamptz → 'YYYY-MM-DD' (Lima)  [via _sheetToObjects, NO _readSheetPreservandoFecha].
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.wh_envasados_crudo()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_data jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'idEnvasado',             e.id_envasado,
           'codigoProductoBase',     e.cod_producto_base,
           'cantidadBase',           e.cantidad_base,
           'unidadBase',             e.unidad_base,
           'codigoProductoEnvasado', e.cod_producto_envasado,
           'unidadesEsperadas',      e.unidades_esperadas,
           'unidadesProducidas',     e.unidades_producidas,
           'mermaReal',              e.merma_real,
           'eficienciaPct',          e.eficiencia_pct,
           'fecha',                  case when e.fecha is null then ''
                                       else to_char(e.fecha at time zone 'America/Lima', 'YYYY-MM-DD') end,
           'usuario',                e.usuario,
           'estado',                 e.estado,
           'idGuiaSalida',           e.id_guia_salida,
           'idGuiaIngreso',          e.id_guia_ingreso,
           'observacion',            e.observacion
         ) order by e.fecha nulls last, e.id_envasado), '[]'::jsonb)
    into v_data
  from wh.envasados e;
  return jsonb_build_object('ok', true, 'data', v_data);
end;
$fn$;
revoke all on function mos.wh_envasados_crudo() from public;
grant execute on function mos.wh_envasados_crudo() to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 5) mos.wh_guias_crudo() — espeja _safeReadWhGuias() = _readSheetPreservandoFecha(GUIAS).
--    fecha: timestamptz → ISO UTC 'YYYY-MM-DDTHH24:MI:SS.MSZ'  [_readSheetPreservandoFecha usa toISOString()].
--    Solo las columnas que la HOJA GUIAS (leída por MOS) expone (12); las OCR_*/ultima_actividad de la SOMBRA
--    no están en la hoja MOS-leída → se omiten para paridad de shape.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.wh_guias_crudo()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_data jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'idGuia',          g.id_guia,
           'tipo',            g.tipo,
           'fecha',           case when g.fecha is null then ''
                                else to_char(g.fecha at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') end,
           'usuario',         g.usuario,
           'idProveedor',     g.id_proveedor,
           'idZona',          g.id_zona,
           'numeroDocumento', g.numero_documento,
           'comentario',      g.comentario,
           'montoTotal',      g.monto_total,
           'estado',          g.estado,
           'idPreingreso',    g.id_preingreso,
           'foto',            g.foto
         ) order by g.fecha nulls last, g.id_guia), '[]'::jsonb)
    into v_data
  from wh.guias g;
  return jsonb_build_object('ok', true, 'data', v_data);
end;
$fn$;
revoke all on function mos.wh_guias_crudo() from public;
grant execute on function mos.wh_guias_crudo() to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 6) mos.wh_preingresos_crudo() — espeja _safeReadWhPreingresos() = _readSheetPreservandoFecha(PREINGRESOS).
--    fecha: timestamptz → ISO UTC 'YYYY-MM-DDTHH24:MI:SS.MSZ'.
--    snapshot_aviso (jsonb de la sombra) NO está en la hoja MOS-leída → se omite (paridad).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.wh_preingresos_crudo()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_data jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'idPreingreso', pi.id_preingreso,
           'fecha',        case when pi.fecha is null then ''
                             else to_char(pi.fecha at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') end,
           'idProveedor',  pi.id_proveedor,
           'cargadores',   pi.cargadores,
           'usuario',      pi.usuario,
           'monto',        pi.monto,
           'fotos',        pi.fotos,
           'comentario',   pi.comentario,
           'estado',       pi.estado,
           'idGuia',       pi.id_guia
         ) order by pi.fecha nulls last, pi.id_preingreso), '[]'::jsonb)
    into v_data
  from wh.preingresos pi;
  return jsonb_build_object('ok', true, 'data', v_data);
end;
$fn$;
revoke all on function mos.wh_preingresos_crudo() from public;
grant execute on function mos.wh_preingresos_crudo() to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 7) mos.wh_guia_detalle_crudo() — espeja las lecturas de GUIA_DETALLE en Almacen.gs (1339/2032/2126).
--    fechaVencimiento es DATE (sin hora) → 'YYYY-MM-DD' (paridad _sheetToObjects; ver NOTA D).
--    Header WH verificado: idGuia, linea, codigoProducto, cantidadEsperada, cantidadRecibida, precioUnitario,
--    idLote, observacion, idProductoNuevo, idDetalle, fechaVencimiento, cantidadAplicada.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.wh_guia_detalle_crudo()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_data jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'idGuia',           d.id_guia,
           'linea',            d.linea,
           'codigoProducto',   d.cod_producto,
           'cantidadEsperada', d.cant_esperada,
           'cantidadRecibida', d.cant_recibida,
           'precioUnitario',   d.precio_unitario,
           'idLote',           d.id_lote,
           'observacion',      d.observacion,
           'idProductoNuevo',  d.id_producto_nuevo,
           'idDetalle',        d.id_detalle,
           'fechaVencimiento', case when d.fecha_vencimiento is null then ''
                                 else to_char(d.fecha_vencimiento, 'YYYY-MM-DD') end,
           'cantidadAplicada', d.cantidad_aplicada
         ) order by d.id_guia, d.linea), '[]'::jsonb)
    into v_data
  from wh.guia_detalle d;
  return jsonb_build_object('ok', true, 'data', v_data);
end;
$fn$;
revoke all on function mos.wh_guia_detalle_crudo() from public;
grant execute on function mos.wh_guia_detalle_crudo() to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTAS DE PARIDAD / HONESTIDAD 40x
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- A) FRESCURA: wh.* son SOMBRAS escritas por WH. La premisa del cutover es que WH escribe DIRECTO a Supabase
--    en vivo (sync hoja→supabase apagado para varias tablas) → la SOMBRA es MÁS fresca que la HOJA. Por eso el
--    GAS migra la FUENTE a estas RPCs; si la RPC falla, cae a la hoja (fallback en el GAS, flag MOS_WH_LECTURA_DIRECTO).
--    NO se incluye _frescura_sombra() en el envoltorio: estos readers son CRUDOS (no agregados) y el GAS decide
--    fuente por flag + fallback-on-error, no por heartbeat (el heartbeat del sync ya no es la verdad — WH escribe directo).
-- B) ORDEN: las hojas devuelven orden físico de inserción; SQL sin ORDER BY no garantiza orden. Se impone orden
--    estable (PK / fecha+PK). Los consumidores del GAS filtran/ordenan por su cuenta (find/filter/sort), así que el
--    orden de entrada no cambia el resultado. (Idéntico criterio que 112 GAP #6.)
-- C) COLUMNAS DE MÁS EN LA SOMBRA: wh.guias tiene OCR_* y ultima_actividad; wh.preingresos tiene snapshot_aviso.
--    La HOJA que MOS lee NO las tiene (son operacionales de WH). Se OMITEN → shape idéntico al de _sheetToObjects
--    sobre la hoja MOS-visible. Si en el futuro MOS necesitara alguna, agregarla es trivial.
-- D) GUIA_DETALLE — DOBLE call-site: Almacen.gs:1339 usa _readSheetPreservandoFecha (ISO) y :2032/:2126 usan
--    _sheetToObjects (date-only). La ÚNICA columna fecha de GUIA_DETALLE es fecha_vencimiento, de tipo DATE (sin
--    hora). En la HOJA esa celda suele ser un Date a medianoche → ambas serializaciones dan la MISMA fecha
--    ('YYYY-MM-DD' en _sheetToObjects; 'YYYY-MM-DDT00:00:00.000Z' en _readSheetPreservandoFecha). Los consumos del
--    GAS solo usan fechaVencimiento como string informativo (línea 2049: `l.fechaVencimiento || ''`) — NO la parsean
--    a Date para cómputo. Se emite 'YYYY-MM-DD' (paridad con el call-site dominante). RIESGO BAJO. Si se exigiera ISO
--    para el call-site :1339, ese path NO consume fechaVencimiento (solo idGuia/codigoProducto/cantidadRecibida/
--    precioUnitario/observacion — ver Almacen.gs:1340-1356), así que la diferencia es inerte ahí.
-- E) NUMÉRICOS/TEXTO CRUDOS (sin coalesce): _sheetToObjects emite el valor crudo de la celda (Number o '' o string),
--    NO 0 ni '' forzados. Aquí los numeric/text van TAL CUAL (null→JSON null). El GAS hace parseFloat(x)||0 y
--    String(x||'') en todos los consumos, por lo que null se neutraliza igual que en la hoja. Se evita coalesce para
--    no introducir 0 donde la hoja tenía vacío (que cambiaría, p.ej., un promedio si alguien sumara sin filtrar).
-- F) cantidad_disponible (wh.stock) y demás numeric se serializan como NÚMERO JSON. (En el cliente node-pg salen
--    como string, pero PostgREST/Supabase REST emite jsonb tal cual: jsonb_build_object con numeric → número JSON.)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
