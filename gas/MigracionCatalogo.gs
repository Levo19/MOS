/**
 * ============================================================
 * MIGRACIÓN SUPABASE — FASE 0 · Backfill del CATÁLOGO COMPARTIDO
 * (mos.productos / equivalencias / categorias / personal / zonas /
 *  estaciones / impresoras / series_documentales / dispositivos / config)
 * ============================================================
 * Lee las hojas maestras de MOS y hace UPSERT idempotente a Supabase.
 * Idempotente: re-correrlo NO duplica (upsert por PK).
 * Uso:
 *   migrarCatalogoCompartido()                 // todo, real
 *   migrarCatalogoCompartido({dryRun:true})    // no escribe, solo valida y cuenta
 *   migrarCatalogoCompartido({soloTabla:'productos'})
 *   verificarCuadreCatalogo()                  // compara conteos Sheet vs Supabase
 *
 * Requiere: Supabase.gs (helper _sb), Script Properties configuradas,
 *           y haber corrido 01_schema_compartido.sql.
 */

// ---------- conversores defensivos de backfill ----------
function _bfText(v) { return (v == null || v === '') ? null : String(v); }
function _bfNum(v) {
  if (v == null || v === '') return null;
  if (typeof v === 'number') return isNaN(v) ? null : v;   // celda numérica real: sin tocar
  var n = parseFloat(String(v).replace(',', '.'));         // texto: tolera coma decimal simple
  return isNaN(n) ? null : n;
}
function _bfBool(v) {
  var s = String(v == null ? '' : v).trim().toLowerCase();
  if (s === '1' || s === 'true' || s === 'si' || s === 'sí' || s === 'x') return true;
  if (s === '0' || s === 'false' || s === 'no' || s === '') return false;
  return false; // valor inesperado -> false (y se audita aparte si se desea)
}
function _bfDate(v) {
  if (v == null || v === '') return null;
  var d = (v instanceof Date) ? v : new Date(v);
  if (isNaN(d.getTime())) return null;
  // timestamptz con offset Perú explícito
  return Utilities.formatDate(d, 'America/Lima', "yyyy-MM-dd'T'HH:mm:ssXXX");
}
function _bfJson(v) {
  if (v == null || v === '') return null;
  if (typeof v === 'object') return v;                 // ya objeto/array -> se serializa a jsonb
  try {
    var p = JSON.parse(String(v));
    return (p && typeof p === 'object') ? p : null;    // garantiza objeto/array, nunca string suelto
  } catch (e) { return null; }                          // JSON inválido/truncado -> null (deuda: auditar)
}

/** Mapea un objeto-fila de hoja a fila Postgres según spec [pgCol, header, tipo]. */
function _bfRow(obj, spec) {
  var row = {};
  for (var i = 0; i < spec.length; i++) {
    var pg = spec[i][0], src = spec[i][1], t = spec[i][2];
    var raw = obj[src];
    if (t === 'text') row[pg] = _bfText(raw);
    else if (t === 'num') row[pg] = _bfNum(raw);
    else if (t === 'bool') row[pg] = _bfBool(raw);
    else if (t === 'date') row[pg] = _bfDate(raw);
    else if (t === 'json') row[pg] = _bfJson(raw);
    else if (t === 'int') { var n = _bfNum(raw); row[pg] = (n == null ? null : Math.round(n)); }
    else row[pg] = _bfText(raw);
  }
  return row;
}

// ---------- specs por tabla: [pgCol, headerHoja, tipo] ----------
var _CAT_SPECS = {
  productos: {
    sheet: 'PRODUCTOS_MASTER', pk: 'id_producto',
    spec: [
      ['id_producto','idProducto','text'], ['sku_base','skuBase','text'],
      ['codigo_barra','codigoBarra','text'], ['descripcion','descripcion','text'],
      ['marca','marca','text'], ['id_categoria','idCategoria','text'], ['unidad','unidad','text'],
      ['precio_venta','precioVenta','num'], ['precio_costo','precioCosto','num'],
      ['cod_tributo','Cod_Tributo','text'], ['igv_porcentaje','IGV_Porcentaje','num'],
      ['cod_sunat','Cod_SUNAT','text'], ['tipo_igv','Tipo_IGV','int'],
      ['unidad_medida','Unidad_Medida','text'], ['estado','estado','bool'],
      ['es_envasable','esEnvasable','bool'], ['codigo_producto_base','codigoProductoBase','text'],
      ['factor_conversion','factorConversion','num'], ['factor_conversion_base','factorConversionBase','num'],
      ['merma_esperada_pct','mermaEsperadaPct','num'], ['stock_minimo','stockMinimo','num'],
      ['stock_maximo','stockMaximo','num'], ['zona','zona','text'],
      ['fecha_creacion','fechaCreacion','date'], ['creado_por','creadoPor','text'],
      ['modo_venta','modoVenta','text'], ['margen_pct','margenPct','num'],
      ['precio_tope','precioTope','num'], ['foto_url','fotoUrl','text'],
      ['historial_cambios','historialCambios','json'], ['segmentos_precio','segmentos_precio','json']
    ],
    post: function (row, obj) {
      // codigo_producto_base vacío -> null (para FK)
      // tipo_producto calculado
      var base = row.codigo_producto_base;
      var f = row.factor_conversion;
      if (base) row.tipo_producto = 'DERIVADO';
      else if (f != null && f > 0 && f !== 1) row.tipo_producto = 'PRESENTACION'; // factor 0/null/1 = canónico
      else row.tipo_producto = 'CANONICO';
      return row;
    }
  },
  equivalencias: { sheet: 'EQUIVALENCIAS', pk: 'id_equiv', spec: [
    ['id_equiv','idEquiv','text'], ['sku_base','skuBase','text'],
    ['codigo_barra','codigoBarra','text'], ['descripcion','descripcion','text'], ['activo','activo','bool']
  ]},
  categorias: { sheet: 'CATEGORIAS', pk: 'id_categoria', spec: [
    ['id_categoria','idCategoria','text'], ['nombre','nombre','text'], ['modo_venta','modoVenta','text'],
    ['margen_pct','margenPct','num'], ['precio_tope','precioTope','num'], ['descripcion','descripcion','text'],
    ['estado','estado','bool'], ['fecha_creacion','fechaCreacion','date']
  ]},
  personal: { sheet: 'PERSONAL_MASTER', pk: 'id_personal', spec: [
    ['id_personal','idPersonal','text'], ['nombre','nombre','text'], ['apellido','apellido','text'],
    ['tipo','tipo','text'], ['app_origen','appOrigen','text'], ['rol','rol','text'], ['pin','pin','text'],
    ['color','color','text'], ['tarifa_hora','tarifaHora','num'], ['monto_base','montoBase','num'],
    ['estado','estado','bool'], ['fecha_ingreso','fechaIngreso','date'], ['foto','foto','text'],
    ['ultima_conexion','Ultima_Conexion','date']
  ]},
  zonas: { sheet: 'ZONAS', pk: 'id_zona', spec: [
    ['id_zona','idZona','text'], ['nombre','nombre','text'], ['descripcion','descripcion','text'],
    ['direccion','direccion','text'], ['responsable','responsable','text'], ['estado','estado','bool'],
    ['politica_json','politicaJSON','json']
  ]},
  estaciones: { sheet: 'ESTACIONES', pk: 'id_estacion', spec: [
    ['id_estacion','idEstacion','text'], ['id_zona','idZona','text'], ['nombre','nombre','text'],
    ['tipo','tipo','text'], ['app_origen','appOrigen','text'], ['admin_pin','adminPin','text'],
    ['activo','activo','bool'], ['descripcion','descripcion','text']
  ]},
  impresoras: { sheet: 'IMPRESORAS', pk: 'id_impresora', spec: [
    ['id_impresora','idImpresora','text'], ['nombre','nombre','text'], ['printnode_id','printNodeId','text'],
    ['tipo','tipo','text'], ['id_estacion','idEstacion','text'], ['id_zona','idZona','text'],
    ['app_origen','appOrigen','text'], ['activo','activo','bool'], ['descripcion','descripcion','text']
  ]},
  series_documentales: { sheet: 'SERIES_DOCUMENTALES', pk: 'id_serie', spec: [
    ['id_serie','idSerie','text'], ['id_estacion','idEstacion','text'], ['id_zona','idZona','text'],
    ['tipo_documento','tipoDocumento','text'], ['serie','serie','text'], ['correlativo','correlativo','int'],
    ['activo','activo','bool']
  ]},
  config: { sheet: 'CONFIG_MOS', pk: 'clave', spec: [
    ['clave','clave','text'], ['valor','valor','text'], ['descripcion','descripcion','text']
  ]},
  dispositivos: { sheet: 'DISPOSITIVOS', pk: 'id_dispositivo', spec: [
    ['id_dispositivo','ID_Dispositivo','text'], ['nombre_equipo','Nombre_Equipo','text'],
    ['app','App','text'], ['estado','Estado','text'], ['ultima_conexion','Ultima_Conexion','date'],
    ['ultima_zona','Ultima_Zona','text'], ['ultima_estacion','Ultima_Estacion','text'],
    ['ultima_sesion','Ultima_Sesion','text'], ['permisos_json','Permisos_JSON','json'],
    ['permisos_lastupdate','Permisos_LastUpdate','date'], ['forzar_wizard','Forzar_Wizard','bool'],
    ['suspendido_desde','Suspendido_Desde','date'], ['forzar_logout','Forzar_Logout','bool'],
    ['logout_auto_ts','Logout_Auto_Ts','date'], ['forzar_push','Forzar_Push','bool'],
    ['forzar_reverify','Forzar_ReVerify','bool'], ['inactivo_alerta_ts','Inactivo_Alerta_Ts','date'],
    ['cancelado_auto_ts','Cancelado_Auto_Ts','date'], ['user_agent','User_Agent','text']
  ]}
};

// ============================================================
// [dual-write CATÁLOGO] Espejo en tiempo real hoja → sombra Supabase
// ============================================================
// Gemelo de _dualWriteMOS (MigracionMOS.gs) pero para las tablas del CATÁLOGO compartido
// (mos.productos / mos.equivalencias / ...), que viven en _CAT_SPECS y se mapean con _bfRow
// (NO _MOS_SPECS / _mosRowMap). Tras escribir una fila a su HOJA (la verdad), espeja ESA fila a
// mos.<tabla> AL INSTANTE reusando el MISMO mapeo del sync batch (_bfRow + cfg.spec + cfg.post)
// → fila BYTE-IDÉNTICA a la que produciría migrarCatalogoCompartido/syncCatalogoSupabase.
// Upsert por cfg.pk (clave natural) = IDEMPOTENTE: re-guardar el mismo registro actualiza la misma
// fila, nunca duplica; si el sync corre después no genera una fila distinta (409 = éxito en _sbOnce_).
//
// `obj` = objeto keyed por las CABECERAS de la hoja (mismas keys que _sheetToObjects produce, ej.
// idProducto/skuBase/codigoBarra/...), con los valores YA escritos a la hoja.
//
// Best-effort y SEGURO: usa _sbOnce_ (1 SOLO intento, sin backoff/sleep) para no colgar al admin si
// Supabase está degradado; el sync horario reconcilia si falla. El CALLER lo envuelve en try/catch →
// si esto lanza, la escritura a la hoja NO se rompe (Sheets = verdad). NO requiere flag: solo espeja
// a la sombra lo que ya fue a la hoja (invisible al usuario; acelera la frescura del catálogo).
function _dualWriteCAT(tabla, obj) {
  var cfg = _CAT_SPECS[tabla];
  if (!cfg) { Logger.log('[dualWrite CAT] tabla desconocida (no está en _CAT_SPECS): ' + tabla); return { ok: false, error: 'tabla desconocida: ' + tabla }; }
  // Mapeo idéntico al batch: _bfRow(o, spec) + cfg.post (si existe) — misma fuente de verdad.
  var row = _bfRow(obj, cfg.spec); if (cfg.post) row = cfg.post(row, obj);
  // Validar PK: sin PK no se puede upsert por clave natural → omitir (el sync horario lo subirá).
  if (row[cfg.pk] == null || row[cfg.pk] === '') { Logger.log('[dualWrite CAT ' + tabla + '] sin PK (' + cfg.pk + ') — omitido'); return { ok: false, error: 'sin PK: ' + cfg.pk }; }
  var r = _sbOnce_('POST', 'mos.' + tabla, { data: [row], upsert: true, onConflict: cfg.pk });
  if (!r.ok) Logger.log('[dualWrite CAT ' + tabla + '] upsert falló: HTTP ' + (r.code) + ' ' + (r.error || ''));
  return r;
}

/**
 * Backfill del catálogo. Devuelve un resumen por tabla.
 * @param {{dryRun?:boolean, soloTabla?:string}} opts
 */
function migrarCatalogoCompartido(opts) {
  opts = opts || {};
  var resumen = {};
  var tablas = opts.soloTabla ? [opts.soloTabla] : Object.keys(_CAT_SPECS);

  // [CATÁLOGO DELETE-SAFE] Honrar MOS_SYNC_OFF_TABLAS también en el sync del CATÁLOGO (este sync usa _CAT_SPECS,
  // distinto del _MOS_SPECS de _syncMOSImpl, pero el mismo CSV de config gobierna AMBOS). Tras el cutover de
  // escritura directa del catálogo (flag MOS_CATALOGO_DIRECTO=1 + 'productos,equivalencias' en el CSV), la PWA
  // escribe productos/equivalencias DIRECTO a la sombra; si este sync las re-subiera desde la HOJA cada hora,
  // PISARÍA esos writes directos (la Hoja queda atrás porque ya nadie la escribe). Excluirlas aquí cierra ese hueco.
  // Default: CSV vacío para catálogo → no excluye nada → sync IDÉNTICO a hoy. opts.forzarTabla ignora la exclusión
  // (para un backfill manual puntual). Best-effort: si la lectura de config falla, _mosSyncOffTablas devuelve {}.
  var _off = {};
  try { if (typeof _mosSyncOffTablas === 'function' && !opts.ignorarSyncOff) _off = _mosSyncOffTablas(); } catch (_) {}

  tablas.forEach(function (tabla) {
    var cfg = _CAT_SPECS[tabla];
    if (!cfg) { resumen[tabla] = { error: 'spec desconocida' }; return; }
    if (_off[String(tabla).toLowerCase()] && tabla !== opts.forzarTabla) {
      resumen[tabla] = { omitido: 'MOS_SYNC_OFF_TABLAS (escritura directa) — la HOJA ya no es la verdad de esta tabla' };
      return;
    }
    try {
      var sheet = getSheet(cfg.sheet);
      var objs = _sheetToObjects(sheet);
      var rows = objs.map(function (o) {
        var r = _bfRow(o, cfg.spec);
        if (cfg.post) r = cfg.post(r, o);
        return r;
      }).filter(function (r) { return r[cfg.pk] != null && r[cfg.pk] !== ''; }); // descarta filas sin PK (no descarta '0')

      // dedupe por PK (gana el último) — evita "ON CONFLICT cannot affect row a second time"
      var _seen = {};
      rows.forEach(function (r) { _seen[String(r[cfg.pk])] = r; });
      var _dups = rows.length - Object.keys(_seen).length;
      rows = Object.keys(_seen).map(function (k) { return _seen[k]; });

      // [Reparación #7 · anti-resurrección] NO re-subir filas con LÁPIDA (purgadas vía la RPC
      // mos.eliminar_items_catalogo). El sync es SOLO-UPSERT: sin esto, un producto borrado en
      // Supabase pero aún presente en la Hoja revivía cada hora. Las lápidas viven en
      // mos.purgas_historicas (mos.purga_tombstones devuelve sus ids). Idempotente y barato.
      if (tabla === 'productos' || tabla === 'equivalencias') {
        try {
          var _tomb = {};
          var _rt = _sbRpc('mos', 'purga_tombstones', { p_tabla: 'mos.' + tabla });
          if (_rt && _rt.ok && Array.isArray(_rt.data)) {
            _rt.data.forEach(function (x) {
              var id = (typeof x === 'string') ? x : (x && (x.purga_tombstones || x.id_fila));
              if (id != null && id !== '') _tomb[String(id)] = 1;
            });
          }
          if (Object.keys(_tomb).length) {
            var _antes = rows.length;
            rows = rows.filter(function (r) { return !_tomb[String(r[cfg.pk])]; });
            if (rows.length !== _antes) Logger.log('[migrarCatalogoCompartido] ' + tabla + ': ' + (_antes - rows.length) + ' fila(s) con lápida omitidas (no resucitar)');
          }
        } catch (eT) { Logger.log('[migrarCatalogoCompartido] tombstone ' + tabla + ' WARN: ' + (eT && eT.message)); }
      }

      if (opts.dryRun) {
        resumen[tabla] = { dryRun: true, filasLeidas: objs.length, filasValidas: rows.length, duplicadosPk: _dups, muestra: rows[0] || null };
        return;
      }

      // upsert por lotes de 100 (productos pueden traer jsonb grande -> evita payload excesivo)
      var insertadas = 0, errores = [];
      for (var i = 0; i < rows.length; i += 100) {
        var lote = rows.slice(i, i + 100);
        if (JSON.stringify(lote).length > 10000000) { // ~10M chars (≈40MB UTF-8 peor caso) < límite UrlFetchApp
          errores.push('lote ' + i + ': payload muy grande, omitido (reducir lote o limpiar jsonb)'); continue;
        }
        var r = _sbUpsert('mos.' + tabla, lote, cfg.pk);
        if (r.ok) insertadas += lote.length;
        else errores.push('lote ' + i + ': HTTP ' + r.code + ' ' + (r.error || ''));
      }
      resumen[tabla] = { filas: rows.length, upserted: insertadas, duplicadosPk: _dups, errores: errores };
    } catch (e) {
      resumen[tabla] = { error: String(e && e.message || e) };
    }
  });

  Logger.log(JSON.stringify(resumen, null, 2));
  return resumen;
}

/** Wrappers sin argumentos para ejecutar desde el editor de Apps Script. */
function dryRunCatalogo()   { return migrarCatalogoCompartido({ dryRun: true }); }
function backfillCatalogo() { return migrarCatalogoCompartido(); }

/**
 * Re-sincroniza el catálogo a Supabase (idempotente). Para trigger horario.
 * Mantiene mos.* al día SIN tocar los endpoints de producción (cero riesgo).
 * Lag máx ~1h, suficiente porque ME/WH aún leen el catálogo por bridge (hasta Fase 1/2).
 */
function syncCatalogoSupabase() {
  try {
    var r = migrarCatalogoCompartido();
    Logger.log('[syncCatalogoSupabase] ' + JSON.stringify(r));
    // [FASE 1 · gate de frescura] Estampar el LATIDO de la corrida en mos.config[CATALOGO_SYNC_HEARTBEAT].
    // La RPC mos.productos_master_rls() lo compara contra now()+TTL para decidir si la sombra está fresca;
    // si el trigger muere (Google desactiva los time-based), el latido se congela → la RPC marca _fresh=false
    // → el frontend de MOS cae a GAS (no sirve catálogo viejo). updated_at NO sirve de latido (el upsert
    // merge-duplicates no lo bumpea en filas sin cambios). Solo se estampa si productos sincronizó sin errores.
    try { _estamparLatidoCatalogo(r); } catch (eHb) { Logger.log('[syncCatalogoSupabase] heartbeat WARN: ' + (eHb && eHb.message || eHb)); }
    return r;
  } catch (e) {
    Logger.log('[syncCatalogoSupabase] ERROR: ' + (e && e.message || e));
    return { ok: false, error: String(e && e.message || e) };
  }
}

/**
 * Escribe mos.config[CATALOGO_SYNC_HEARTBEAT] = ISO now() SOLO si la corrida de productos fue limpia
 * (sin errores en el lote de productos). Best-effort: cualquier fallo se loguea y NO rompe el sync.
 * Que el latido NO se estampe ante un sync de productos fallido es DELIBERADO: así la RPC ve el latido
 * viejo → _fresh=false → MOS cae a GAS, en vez de servir una sombra a medio actualizar.
 */
function _estamparLatidoCatalogo(resumen) {
  var prod = resumen && resumen.productos;
  // Si no hubo info de productos, o hubo errores en sus lotes, NO estampar (sombra dudosa → mantener latido viejo).
  if (!prod || (prod.errores && prod.errores.length)) {
    Logger.log('[_estamparLatidoCatalogo] productos con errores o ausente → NO se estampa latido');
    return;
  }
  var iso = new Date().toISOString();
  var rUp = _sbUpsert('mos.config', [{
    clave: 'CATALOGO_SYNC_HEARTBEAT',
    valor: iso,
    descripcion: 'FASE1 lectura directa MOS: ISO de la ULTIMA corrida OK de syncCatalogoSupabase (latido de frescura de la sombra mos.productos).'
  }], 'clave');
  if (!rUp || !rUp.ok) {
    Logger.log('[_estamparLatidoCatalogo] upsert latido FALLO: ' + JSON.stringify(rUp));
  } else {
    Logger.log('[_estamparLatidoCatalogo] latido estampado: ' + iso);
  }
}

/** Instala (idempotente) el trigger horario de sincronización. Ejecutar 1 vez desde el editor. */
function instalarTriggerCatalogo() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'syncCatalogoSupabase') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('syncCatalogoSupabase').timeBased().everyHours(1).create();
  Logger.log('Trigger horario instalado: syncCatalogoSupabase (cada 1h)');
  return { ok: true, msg: 'Trigger horario instalado: syncCatalogoSupabase' };
}

/** Quita el trigger del catálogo (por si quieres detenerlo). */
function desinstalarTriggerCatalogo() {
  var n = 0;
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'syncCatalogoSupabase') { ScriptApp.deleteTrigger(t); n++; }
  });
  Logger.log('Triggers eliminados: ' + n);
  return { ok: true, eliminados: n };
}

/** Compara conteos Sheet vs Supabase por tabla del catálogo. */
function verificarCuadreCatalogo() {
  var out = {};
  Object.keys(_CAT_SPECS).forEach(function (tabla) {
    var cfg = _CAT_SPECS[tabla];
    var nSheet = -1;
    try {
      // header de la hoja que corresponde al PK (robusto si el spec se reordena)
      var pkHeader = cfg.spec[0][1];
      for (var k = 0; k < cfg.spec.length; k++) { if (cfg.spec[k][0] === cfg.pk) { pkHeader = cfg.spec[k][1]; break; } }
      var objs = _sheetToObjects(getSheet(cfg.sheet));
      nSheet = objs.filter(function (o) { return o[pkHeader] != null && o[pkHeader] !== ''; }).length;
    } catch (e) { nSheet = -1; }
    var nPg = _sbCount('mos.' + tabla, null);
    out[tabla] = { sheet: nSheet, supabase: nPg, cuadra: (nSheet === nPg) };
  });
  Logger.log(JSON.stringify(out, null, 2));
  return out;
}
