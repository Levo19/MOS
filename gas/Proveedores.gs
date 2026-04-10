// ============================================================
// ProyectoMOS — Proveedores.gs
// CRUD proveedores maestros + pagos + pedidos de compra
// ============================================================

// ── PROVEEDORES MASTER ───────────────────────────────────────
function getProveedoresMaster(params) {
  var rows = _sheetToObjects(getSheet('PROVEEDORES_MASTER'));
  if (params.estado) rows = rows.filter(function(r){ return String(r.estado) === String(params.estado); });
  if (params.q) {
    var q = params.q.toLowerCase();
    rows = rows.filter(function(r){
      return (r.nombre || '').toLowerCase().indexOf(q) >= 0 ||
             (r.ruc    || '').indexOf(q) >= 0;
    });
  }
  return { ok: true, data: rows };
}

function crearProveedorMaster(params) {
  var sheet = getSheet('PROVEEDORES_MASTER');
  var id = _generateId('PROV');
  sheet.appendRow([
    id, params.nombre, params.ruc || '', params.imagen || '',
    params.telefono || '', params.banco || '', params.numeroCuenta || '',
    params.cci || '', params.email || '',
    params.diaPedido || '', params.diaPago || '', params.diaEntrega || '',
    params.formaPago || 'CONTADO', params.plazoCredito || 0,
    params.responsable || '', params.categoriaProducto || '', '1'
  ]);
  return { ok: true, data: { idProveedor: id } };
}

function actualizarProveedorMaster(params) {
  var sheet = getSheet('PROVEEDORES_MASTER');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  for (var i = 1; i < data.length; i++) {
    if (data[i][0] === params.idProveedor) {
      var campos = ['nombre','ruc','telefono','banco','numeroCuenta','cci','email',
                    'diaPedido','diaPago','diaEntrega','formaPago','plazoCredito',
                    'responsable','categoriaProducto','estado'];
      campos.forEach(function(c){
        if (params[c] !== undefined) {
          var col = hdrs.indexOf(c);
          if (col >= 0) sheet.getRange(i+1, col+1).setValue(params[c]);
        }
      });
      return { ok: true };
    }
  }
  return { ok: false, error: 'Proveedor no encontrado' };
}

// ── PAGOS ────────────────────────────────────────────────────
function getPagosProveedor(params) {
  var rows = _sheetToObjects(getSheet('PAGOS_PROVEEDOR'));
  if (params.idProveedor) rows = rows.filter(function(r){ return r.idProveedor === params.idProveedor; });
  if (params.estado)      rows = rows.filter(function(r){ return String(r.estado) === String(params.estado); });
  return { ok: true, data: rows };
}

function registrarPago(params) {
  if (!params.idProveedor || !params.monto) {
    return { ok: false, error: 'Requiere idProveedor y monto' };
  }
  var sheet = getSheet('PAGOS_PROVEEDOR');
  var id = _generateId('PAG');
  var fecha = params.fecha || Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
  sheet.appendRow([
    id, params.idProveedor, parseFloat(params.monto),
    fecha, params.numeroFactura || '',
    params.estado || 'PAGADO',
    params.observacion || '', params.registradoPor || ''
  ]);
  return { ok: true, data: { idPago: id } };
}

// ── PEDIDOS DE COMPRA ────────────────────────────────────────
function getPedidosProveedor(params) {
  var rows = _sheetToObjects(getSheet('PEDIDOS_PROVEEDOR'));
  if (params.idProveedor) rows = rows.filter(function(r){ return r.idProveedor === params.idProveedor; });
  if (params.estado)      rows = rows.filter(function(r){ return String(r.estado) === String(params.estado); });
  return { ok: true, data: rows };
}

function crearPedidoProveedor(params) {
  if (!params.idProveedor) return { ok: false, error: 'Requiere idProveedor' };
  var sheet = getSheet('PEDIDOS_PROVEEDOR');
  var id = _generateId('PED');
  sheet.appendRow([
    id, params.idProveedor,
    JSON.stringify(params.items || []),
    parseFloat(params.montoEstimado) || 0,
    'BORRADOR', new Date(),
    params.fechaEstimada || '',
    params.usuario || '',
    params.notas   || ''
  ]);
  return { ok: true, data: { idPedido: id } };
}

// ── ANÁLISIS: proveedor con mejor precio histórico ───────────
function getMejorPrecioProveedor(skuBase) {
  var historial = _sheetToObjects(getSheet('HISTORIAL_PRECIOS'));
  var porProveedor = historial.filter(function(h){ return h.skuBase === skuBase; });
  // Retorna los últimos N registros del historial de costos
  return { ok: true, data: porProveedor.slice(-10) };
}
