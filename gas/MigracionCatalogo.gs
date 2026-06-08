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

/**
 * Backfill del catálogo. Devuelve un resumen por tabla.
 * @param {{dryRun?:boolean, soloTabla?:string}} opts
 */
function migrarCatalogoCompartido(opts) {
  opts = opts || {};
  var resumen = {};
  var tablas = opts.soloTabla ? [opts.soloTabla] : Object.keys(_CAT_SPECS);

  tablas.forEach(function (tabla) {
    var cfg = _CAT_SPECS[tabla];
    if (!cfg) { resumen[tabla] = { error: 'spec desconocida' }; return; }
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
