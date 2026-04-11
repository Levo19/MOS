// ============================================================
// ProyectoMOS — Productos.gs
// CRUD catálogo maestro: PRODUCTOS_MASTER + EQUIVALENCIAS
// + historial de precios + publicación de precio
// ============================================================

// ── PRODUCTOS_MASTER ─────────────────────────────────────────
function getProductosMaster(params) {
  var rows = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  if (params.estado)    rows = rows.filter(function(r){ return String(r.estado) === String(params.estado); });
  if (params.skuBase)   rows = rows.filter(function(r){ return r.skuBase === params.skuBase; });
  if (params.categoria) rows = rows.filter(function(r){ return r.idCategoria === params.categoria; });
  if (params.q) {
    var q = params.q.toLowerCase();
    rows = rows.filter(function(r){
      return (r.descripcion || '').toLowerCase().indexOf(q) >= 0 ||
             (r.codigoBarra || '').indexOf(q) >= 0 ||
             (r.skuBase     || '').toLowerCase().indexOf(q) >= 0;
    });
  }
  return { ok: true, data: rows };
}

function getProductoMaster(codigo) {
  var rows = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  var prod = rows.find(function(p){
    return p.idProducto === codigo || p.codigoBarra === codigo || p.skuBase === codigo;
  });
  if (!prod) return { ok: false, error: 'Producto no encontrado: ' + codigo };
  return { ok: true, data: prod };
}

function crearProductoMaster(params) {
  var sheet = getSheet('PRODUCTOS_MASTER');
  var id = params.idProducto || _generateId('P');
  var skuBase = params.skuBase || params.codigoBarra || id;

  // Verificar duplicado
  if (params.codigoBarra) {
    var dup = _sheetToObjects(sheet).find(function(p){ return p.codigoBarra === params.codigoBarra; });
    if (dup) return { ok: false, error: 'Código de barras ya existe: ' + dup.idProducto };
  }

  sheet.appendRow([
    id,
    skuBase,
    params.codigoBarra          || '',
    params.descripcion          || '',
    params.marca                || '',
    params.idCategoria          || '',
    params.unidad               || 'UNIDAD',
    parseFloat(params.precioVenta)   || 0,
    parseFloat(params.precioCosto)   || 0,
    params.Cod_Tributo          || '',
    params.IGV_Porcentaje !== undefined ? parseFloat(params.IGV_Porcentaje) : '',
    params.Cod_SUNAT            || '',
    params.Tipo_IGV             || '',
    params.Unidad_Medida        || 'NIU',
    '1',
    params.esEnvasable          || '0',
    params.codigoProductoBase   || '',
    parseFloat(params.factorConversion)  || '',
    parseFloat(params.mermaEsperadaPct)  || '',
    parseFloat(params.stockMinimo) || 0,
    parseFloat(params.stockMaximo) || 0,
    params.zona                 || '',
    new Date(),
    params.usuario              || ''
  ]);

  if (parseFloat(params.precioVenta) > 0) {
    _registrarHistorialPrecio(id, skuBase, params.codigoBarra || '',
      params.descripcion || '', 0, parseFloat(params.precioVenta),
      params.usuario || '', 'Precio inicial', 'MOS');
  }

  return { ok: true, data: { idProducto: id, skuBase: skuBase } };
}

function actualizarProductoMaster(params) {
  var sheet = getSheet('PRODUCTOS_MASTER');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];

  for (var i = 1; i < data.length; i++) {
    var match = data[i][0] === params.idProducto || data[i][2] === params.codigoBarra;
    if (!match) continue;

    var precioAnterior = data[i][hdrs.indexOf('precioVenta')];

    var campos = ['skuBase','codigoBarra','descripcion','marca','idCategoria','unidad',
                  'precioVenta','precioCosto','Cod_Tributo','IGV_Porcentaje','Cod_SUNAT','Tipo_IGV',
                  'Unidad_Medida','estado','esEnvasable','codigoProductoBase',
                  'factorConversion','mermaEsperadaPct','stockMinimo','stockMaximo','zona'];
    campos.forEach(function(campo) {
      if (params[campo] !== undefined) {
        var col = hdrs.indexOf(campo);
        if (col >= 0) sheet.getRange(i + 1, col + 1).setValue(params[campo]);
      }
    });

    // Historial si cambió el precio
    if (params.precioVenta !== undefined &&
        parseFloat(params.precioVenta) !== parseFloat(precioAnterior)) {
      _registrarHistorialPrecio(
        data[i][0], data[i][1], data[i][2], data[i][3],
        precioAnterior, params.precioVenta,
        params.usuario || '', params.motivoPrecio || 'Actualización', 'MOS'
      );
    }
    return { ok: true };
  }
  return { ok: false, error: 'Producto no encontrado' };
}

// ── EQUIVALENCIAS ─────────────────────────────────────────────
function getEquivalencias(params) {
  var rows = _sheetToObjects(getSheet('EQUIVALENCIAS'));
  if (params.skuBase)     rows = rows.filter(function(r){ return r.skuBase === params.skuBase; });
  if (params.codigoBarra) rows = rows.filter(function(r){ return r.codigoBarra === params.codigoBarra; });
  if (params.activo)      rows = rows.filter(function(r){ return String(r.activo) === String(params.activo); });
  return { ok: true, data: rows };
}

function crearEquivalencia(params) {
  if (!params.skuBase || !params.codigoBarra) {
    return { ok: false, error: 'Requiere skuBase y codigoBarra' };
  }
  var sheet = getSheet('EQUIVALENCIAS');
  var id = _generateId('EQ');
  sheet.appendRow([id, params.skuBase, params.codigoBarra, params.descripcion || '', '1']);
  return { ok: true, data: { idEquiv: id } };
}

// ── HISTORIAL DE PRECIOS ─────────────────────────────────────
function getHistorialPrecios(params) {
  var rows = _sheetToObjects(getSheet('HISTORIAL_PRECIOS'));
  if (params.skuBase)     rows = rows.filter(function(r){ return r.skuBase === params.skuBase; });
  if (params.codigoBarra) rows = rows.filter(function(r){ return r.codigoBarra === params.codigoBarra; });
  if (params.limit)       rows = rows.slice(-parseInt(params.limit));
  return { ok: true, data: rows };
}

// Publicar precio: actualiza catálogo + registra historial + genera alerta para imprimir membretes
function publicarPrecio(params) {
  if (!params.precioNuevo) return { ok: false, error: 'Requiere precioNuevo' };
  if (!params.idProducto && !params.codigoBarra && !params.skuBase) {
    return { ok: false, error: 'Requiere idProducto, codigoBarra o skuBase' };
  }

  var res = actualizarProductoMaster({
    idProducto:   params.idProducto,
    codigoBarra:  params.codigoBarra,
    precioVenta:  params.precioNuevo,
    usuario:      params.usuario,
    motivoPrecio: params.motivo || 'Publicación de precio'
  });
  if (!res.ok) return res;

  // Alerta para imprimir membretes de precio en almacén
  if (params.imprimirMembretes === 'true' || params.imprimirMembretes === true) {
    _registrarAlerta('PRECIO_CAMBIADO', 'ALTA',
      'Nuevo precio: S/. ' + params.precioNuevo + ' — ' + (params.descripcion || params.skuBase || ''),
      'MOS',
      JSON.stringify({ skuBase: params.skuBase, codigoBarra: params.codigoBarra,
                       precio: params.precioNuevo, zonas: params.zonas || 'TODAS' })
    );
  }

  return { ok: true, data: { precioNuevo: params.precioNuevo, alertaGenerada: !!params.imprimirMembretes } };
}

function _registrarHistorialPrecio(idProd, skuBase, codBarra, desc, anterior, nuevo, usuario, motivo, app) {
  var sheet = getSheet('HISTORIAL_PRECIOS');
  sheet.appendRow([_generateId('HP'), skuBase, codBarra, desc, anterior, nuevo, usuario, motivo, app, new Date()]);
}

function _registrarAlerta(tipo, urgencia, mensaje, appOrigen, datos) {
  var sheet = getSheet('ALERTAS_LOG');
  sheet.appendRow([_generateId('AL'), tipo, urgencia, mensaje, appOrigen, datos || '', new Date(), '0']);
}
