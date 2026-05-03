// ============================================================
// ProyectoMOS — Categorias.gs
// Política de precios por categoría + CRUD.
// Migración idempotente: si la hoja CATEGORIAS no existe, la crea
// y la pre-puebla con las categorías que ya están usadas en
// PRODUCTOS_MASTER. Default: MARGEN 25%.
// ============================================================

var _DEFAULT_MARGEN_PCT = 25;
var _DEFAULT_MODO_VENTA = 'MARGEN';
var _MODOS_VALIDOS = ['MARGEN', 'FIJO', 'COMPETITIVO', 'LIBRE'];

// ── Helpers ─────────────────────────────────────────────────

function _normalizarIdCategoria(s) {
  // Slug consistente: MAYÚSCULAS, sin espacios extras (es como están en PRODUCTOS_MASTER hoy)
  return String(s || '').trim().toUpperCase();
}

function _garantizarHojaCategorias() {
  var ss = getSpreadsheet();
  var sheet = ss.getSheetByName('CATEGORIAS');
  if (sheet) return sheet;
  sheet = ss.insertSheet('CATEGORIAS');
  sheet.getRange(1, 1, 1, MOS_HEADERS.CATEGORIAS.length).setValues([MOS_HEADERS.CATEGORIAS]);
  sheet.getRange(1, 1, 1, MOS_HEADERS.CATEGORIAS.length)
       .setBackground('#0f3460').setFontColor('#e2e8f0').setFontWeight('bold').setFontSize(10);
  sheet.setFrozenRows(1);
  sheet.setColumnWidths(1, MOS_HEADERS.CATEGORIAS.length, 150);
  return sheet;
}

// Garantiza que PRODUCTOS_MASTER tenga las columnas modoVenta, margenPct, precioTope.
// Si faltan, las agrega al final (no rompe data existente).
function _garantizarColumnasPoliticaProductos() {
  var sheet = getSheet('PRODUCTOS_MASTER');
  if (!sheet) return;
  var headers = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  var faltantes = [];
  ['modoVenta', 'margenPct', 'precioTope'].forEach(function(col) {
    if (headers.indexOf(col) === -1) faltantes.push(col);
  });
  if (!faltantes.length) return;
  var startCol = sheet.getLastColumn() + 1;
  sheet.getRange(1, startCol, 1, faltantes.length).setValues([faltantes])
       .setBackground('#0f3460').setFontColor('#e2e8f0').setFontWeight('bold').setFontSize(10);
}

// Migración: poblar CATEGORIAS con las categorías que ya están en PRODUCTOS_MASTER.
// Idempotente: solo agrega las que no existan.
function _seedCategoriasDesdeProductos() {
  var shCat = _garantizarHojaCategorias();
  var existentes = _sheetToObjects(shCat);
  var idsExistentes = {};
  existentes.forEach(function(c){ idsExistentes[_normalizarIdCategoria(c.idCategoria)] = true; });

  var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  var nuevas = {};
  productos.forEach(function(p){
    var id = _normalizarIdCategoria(p.idCategoria);
    if (!id) return;
    if (idsExistentes[id]) return;
    nuevas[id] = true;
  });

  var rows = Object.keys(nuevas).map(function(id){
    return [
      id,                          // idCategoria
      id,                          // nombre (mismo string al inicio, editable después)
      _DEFAULT_MODO_VENTA,         // modoVenta
      _DEFAULT_MARGEN_PCT,         // margenPct
      '',                          // precioTope
      '',                          // descripcion
      1,                           // estado activo
      new Date()                   // fechaCreacion
    ];
  });
  if (rows.length) {
    shCat.getRange(shCat.getLastRow() + 1, 1, rows.length, MOS_HEADERS.CATEGORIAS.length).setValues(rows);
  }
  return rows.length;
}

// Endpoint: ejecutar una sola vez para preparar el sistema.
// Idempotente — se puede correr varias veces sin daño.
function migrarPoliticaPrecios() {
  _garantizarHojaCategorias();
  _garantizarColumnasPoliticaProductos();
  var nuevas = _seedCategoriasDesdeProductos();
  return { ok: true, data: { categoriasNuevas: nuevas } };
}

// ── CRUD ────────────────────────────────────────────────────

function getCategorias(params) {
  _garantizarHojaCategorias();
  var rows = _sheetToObjects(getSheet('CATEGORIAS'));
  // Ordenar por nombre, activos primero
  rows.sort(function(a, b){
    var ea = String(a.estado) === '1' ? 0 : 1;
    var eb = String(b.estado) === '1' ? 0 : 1;
    if (ea !== eb) return ea - eb;
    return String(a.nombre || '').localeCompare(String(b.nombre || ''));
  });
  return { ok: true, data: rows };
}

function _validarParamsCategoria(params) {
  var modo = String(params.modoVenta || _DEFAULT_MODO_VENTA).toUpperCase();
  if (_MODOS_VALIDOS.indexOf(modo) === -1) {
    return { ok: false, error: 'modoVenta inválido. Debe ser uno de: ' + _MODOS_VALIDOS.join(', ') };
  }
  var margen = parseFloat(params.margenPct);
  if (modo === 'MARGEN' || modo === 'COMPETITIVO') {
    if (isNaN(margen) || margen < 0 || margen >= 100) {
      return { ok: false, error: 'margenPct inválido (0-99)' };
    }
  }
  var tope = parseFloat(params.precioTope);
  if (modo === 'COMPETITIVO' && (isNaN(tope) || tope <= 0)) {
    return { ok: false, error: 'precioTope requerido para modo COMPETITIVO' };
  }
  return { ok: true, data: { modo: modo, margen: isNaN(margen) ? '' : margen, tope: isNaN(tope) ? '' : tope } };
}

function crearCategoria(params) {
  if (!params.nombre || !String(params.nombre).trim()) {
    return { ok: false, error: 'nombre requerido' };
  }
  var v = _validarParamsCategoria(params);
  if (!v.ok) return v;

  var sheet = _garantizarHojaCategorias();
  var rows = _sheetToObjects(sheet);
  var id = _normalizarIdCategoria(params.idCategoria || params.nombre);
  if (rows.some(function(r){ return _normalizarIdCategoria(r.idCategoria) === id; })) {
    return { ok: false, error: 'Ya existe una categoría con ese ID: ' + id };
  }
  sheet.appendRow([
    id,
    String(params.nombre).trim(),
    v.data.modo,
    v.data.margen,
    v.data.tope,
    String(params.descripcion || '').trim(),
    1,
    new Date()
  ]);
  return { ok: true, data: { idCategoria: id } };
}

function actualizarCategoria(params) {
  if (!params.idCategoria) return { ok: false, error: 'idCategoria requerido' };
  var v = _validarParamsCategoria(params);
  if (!v.ok) return v;
  var sheet = _garantizarHojaCategorias();
  var data = sheet.getDataRange().getValues();
  var hdrs = data[0];
  var idxId  = hdrs.indexOf('idCategoria');
  if (idxId < 0) return { ok: false, error: 'Schema inválido en CATEGORIAS' };
  var idBuscado = _normalizarIdCategoria(params.idCategoria);
  for (var i = 1; i < data.length; i++) {
    if (_normalizarIdCategoria(data[i][idxId]) !== idBuscado) continue;
    var actualizar = {
      nombre:      params.nombre,
      modoVenta:   v.data.modo,
      margenPct:   v.data.margen,
      precioTope:  v.data.tope,
      descripcion: params.descripcion,
      estado:      params.estado !== undefined ? params.estado : data[i][hdrs.indexOf('estado')]
    };
    Object.keys(actualizar).forEach(function(campo) {
      var col = hdrs.indexOf(campo);
      if (col < 0) return;
      var nuevoValor = actualizar[campo];
      if (nuevoValor === undefined) return;
      sheet.getRange(i + 1, col + 1).setValue(nuevoValor);
    });
    return { ok: true };
  }
  return { ok: false, error: 'Categoría no encontrada: ' + idBuscado };
}

// ── Política efectiva (override producto > categoría > default) ──

// Construye un mapa idCategoria → política, listo para resolver rápido.
function _cargarMapaPoliticaCategorias() {
  _garantizarHojaCategorias();
  var rows = _sheetToObjects(getSheet('CATEGORIAS'));
  var map = {};
  rows.forEach(function(c){
    var id = _normalizarIdCategoria(c.idCategoria);
    if (!id) return;
    map[id] = {
      modoVenta:  String(c.modoVenta  || _DEFAULT_MODO_VENTA).toUpperCase(),
      margenPct:  parseFloat(c.margenPct)  || _DEFAULT_MARGEN_PCT,
      precioTope: parseFloat(c.precioTope) || 0,
      activo:     String(c.estado) === '1'
    };
  });
  return map;
}

// Resuelve la política efectiva para un producto: override > categoría > default global.
function _resolverPoliticaProducto(producto, mapaCategorias) {
  var idCat = _normalizarIdCategoria(producto.idCategoria);
  var cat = mapaCategorias[idCat] || null;

  // Override del producto (si tiene)
  var oModo  = String(producto.modoVenta || '').toUpperCase();
  var oMarg  = producto.margenPct  !== '' && producto.margenPct  !== undefined && producto.margenPct  !== null ? parseFloat(producto.margenPct)  : null;
  var oTope  = producto.precioTope !== '' && producto.precioTope !== undefined && producto.precioTope !== null ? parseFloat(producto.precioTope) : null;

  var modoEf  = (_MODOS_VALIDOS.indexOf(oModo) >= 0) ? oModo : (cat ? cat.modoVenta : _DEFAULT_MODO_VENTA);
  var margEf  = (oMarg !== null && !isNaN(oMarg)) ? oMarg : (cat ? cat.margenPct : _DEFAULT_MARGEN_PCT);
  var topeEf  = (oTope !== null && !isNaN(oTope) && oTope > 0) ? oTope : (cat ? cat.precioTope : 0);

  var origen = oModo ? 'PRODUCTO' : (cat ? 'CATEGORIA' : 'DEFAULT');

  return { modoVenta: modoEf, margenPct: margEf, precioTope: topeEf, origen: origen };
}

// Calcula el precio venta sugerido según política. Retorna null si no aplica (FIJO/LIBRE).
function _calcularPrecioVentaSugerido(costoConIgv, politica) {
  var costo = parseFloat(costoConIgv) || 0;
  if (costo <= 0) return null;
  if (politica.modoVenta === 'FIJO' || politica.modoVenta === 'LIBRE') return null;
  var margen = parseFloat(politica.margenPct) || 0;
  if (margen >= 100) return null;
  var sugerido = costo / (1 - margen / 100);
  if (politica.modoVenta === 'COMPETITIVO' && politica.precioTope > 0) {
    sugerido = Math.min(sugerido, politica.precioTope);
  }
  return Math.round(sugerido * 100) / 100;
}

// Calcula margen real actual: (venta - costo) / venta * 100. Si venta <= 0, retorna null.
function _calcularMargenReal(precioVenta, precioCosto) {
  var pv = parseFloat(precioVenta) || 0;
  var pc = parseFloat(precioCosto) || 0;
  if (pv <= 0) return null;
  return Math.round(((pv - pc) / pv) * 1000) / 10; // 1 decimal
}
