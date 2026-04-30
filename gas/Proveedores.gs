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

// ════════════════════════════════════════════════
// HISTÓRICO REAL DE COMPRAS POR PROVEEDOR
// (de GUIAS_INGRESO_PROVEEDOR + GUIA_DETALLE en warehouseMos)
// ════════════════════════════════════════════════
function getHistoricoProveedor(params) {
  if (!params.idProveedor) return { ok: false, error: 'idProveedor requerido' };
  var dias = parseInt(params.dias) || 60;
  var corte = new Date();
  corte.setDate(corte.getDate() - dias);
  var tz = Session.getScriptTimeZone();

  try {
    // 1. Leer GUIAS de WH filtradas por proveedor + INGRESO + cerrada en rango
    var guiasSh = _abrirWhSheet('GUIAS');
    if (!guiasSh) return { ok: false, error: 'Hoja GUIAS no accesible' };
    var gd = guiasSh.getDataRange().getValues();
    var gh = gd[0];
    var iGId    = gh.indexOf('idGuia');
    var iGFecha = gh.indexOf('fecha');
    var iGProv  = gh.indexOf('idProveedor');
    var iGTipo  = gh.indexOf('tipo');
    var iGEst   = gh.indexOf('estado');

    var guiaIds = {};  // idGuia → fecha
    for (var r = 1; r < gd.length; r++) {
      if (String(gd[r][iGProv]) !== String(params.idProveedor)) continue;
      if (String(gd[r][iGTipo] || '').toUpperCase().indexOf('INGRESO') !== 0) continue;
      var fr = gd[r][iGFecha];
      var fStr = fr instanceof Date ? Utilities.formatDate(fr, tz, 'yyyy-MM-dd') : String(fr || '').substring(0, 10);
      var fDate = fr instanceof Date ? fr : new Date(fStr);
      if (fDate < corte) continue;
      guiaIds[gd[r][iGId]] = { fecha: fStr, estado: gd[r][iGEst] };
    }
    var totalGuias = Object.keys(guiaIds).length;

    // 2. Leer GUIA_DETALLE de las guías filtradas
    var detSh = _abrirWhSheet('GUIA_DETALLE');
    if (!detSh) return { ok: false, error: 'Hoja GUIA_DETALLE no accesible' };
    var dd = detSh.getDataRange().getValues();
    var dh = dd[0];
    var iDGuia = dh.indexOf('idGuia');
    var iDCod  = dh.indexOf('codigoProducto');
    var iDCant = dh.indexOf('cantidadRecibida');
    var iDPrec = dh.indexOf('precioUnitario');

    // Acumular por código: cantidad total, suma de precio×cant, contador
    var porCodigo = {};
    var totalGastado = 0;
    for (var d = 1; d < dd.length; d++) {
      var idG = dd[d][iDGuia];
      if (!guiaIds[idG]) continue;
      var cod = String(dd[d][iDCod] || '').trim();
      if (!cod) continue;
      var cant = parseFloat(dd[d][iDCant]) || 0;
      var prec = parseFloat(dd[d][iDPrec]) || 0;
      if (!porCodigo[cod]) {
        porCodigo[cod] = {
          codigoBarra: cod,
          veces: 0,
          cantidadTotal: 0,
          ultimoPrecio: 0,
          ultimaFecha: '',
          sumaPrecio: 0,
          sumaCantParaPromedio: 0
        };
      }
      var item = porCodigo[cod];
      item.veces++;
      item.cantidadTotal += cant;
      if (prec > 0) {
        item.sumaPrecio += prec * cant;
        item.sumaCantParaPromedio += cant;
      }
      totalGastado += prec * cant;
      // Última compra
      var fGuia = guiaIds[idG].fecha;
      if (fGuia > item.ultimaFecha) {
        item.ultimaFecha = fGuia;
        if (prec > 0) item.ultimoPrecio = prec;
      }
    }

    // 3. Enriquecer con descripción del PRODUCTOS_MASTER de MOS
    var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
    var prodByCB  = {};
    var prodBySku = {};
    productos.forEach(function(p){
      if (p.codigoBarra) prodByCB[String(p.codigoBarra).trim()] = p;
      var s = p.skuBase || p.idProducto;
      if (s && !prodBySku[s]) prodBySku[s] = p;
    });

    var resultado = Object.values(porCodigo).map(function(it){
      var p = prodByCB[it.codigoBarra] || null;
      it.descripcion = (p && p.descripcion) || '—';
      it.skuBase     = (p && (p.skuBase || p.idProducto)) || '';
      it.precioPromedio = it.sumaCantParaPromedio > 0
        ? Math.round((it.sumaPrecio / it.sumaCantParaPromedio) * 100) / 100
        : 0;
      // Variación: comparar último vs promedio
      it.variacionPct = (it.precioPromedio > 0 && it.ultimoPrecio > 0)
        ? Math.round(((it.ultimoPrecio - it.precioPromedio) / it.precioPromedio) * 1000) / 10
        : 0;
      // Limpiar campos internos
      delete it.sumaPrecio;
      delete it.sumaCantParaPromedio;
      return it;
    }).sort(function(a, b){ return b.veces - a.veces; });

    // 4. Pagos y por pagar
    var pagos = _sheetToObjects(getSheet('PAGOS_PROVEEDOR')).filter(function(p){
      return String(p.idProveedor) === String(params.idProveedor);
    });
    var totalPagado = pagos.reduce(function(s, p){ return s + (parseFloat(p.monto) || 0); }, 0);

    return {
      ok: true,
      data: {
        idProveedor:  params.idProveedor,
        rangoDias:    dias,
        totalGuias:   totalGuias,
        totalGastado: Math.round(totalGastado * 100) / 100,
        totalPagado:  Math.round(totalPagado * 100) / 100,
        porPagar:     Math.round((totalGastado - totalPagado) * 100) / 100,
        productos:    resultado
      }
    };
  } catch(e) {
    return { ok: false, error: 'Error histórico: ' + e.message };
  }
}

// ════════════════════════════════════════════════
// CATÁLOGO PROVEEDORES_PRODUCTOS
// (cotizaciones manuales: qué productos ofrece cada proveedor)
// ════════════════════════════════════════════════
function _getProvProdSheet() {
  var ss    = getSpreadsheet();
  var sheet = ss.getSheetByName('PROVEEDORES_PRODUCTOS');
  if (!sheet) {
    sheet = ss.insertSheet('PROVEEDORES_PRODUCTOS');
    sheet.appendRow([
      'idPP', 'idProveedor', 'skuBase', 'codigoBarra', 'descripcion',
      'precioReferencia', 'minimoCompra', 'diasEntrega',
      'ultimaActualizacion', 'activa', 'notas'
    ]);
    sheet.setFrozenRows(1);
  }
  return sheet;
}

function getProveedorProductos(params) {
  if (!params.idProveedor) return { ok: false, error: 'idProveedor requerido' };
  var rows = _sheetToObjects(_getProvProdSheet()).filter(function(r){
    return String(r.idProveedor) === String(params.idProveedor)
        && (r.activa === true || String(r.activa) === '1' || String(r.activa).toLowerCase() === 'true');
  });
  return { ok: true, data: rows };
}

function agregarProductoProveedor(params) {
  if (!params.idProveedor) return { ok: false, error: 'idProveedor requerido' };
  if (!params.skuBase)     return { ok: false, error: 'skuBase requerido' };
  var sheet = _getProvProdSheet();
  var id = _generateId('PP');
  sheet.appendRow([
    id,
    params.idProveedor,
    params.skuBase,
    params.codigoBarra      || '',
    params.descripcion      || '',
    parseFloat(params.precioReferencia) || 0,
    parseFloat(params.minimoCompra)     || 0,
    parseInt(params.diasEntrega)        || 0,
    new Date(),
    true,
    params.notas || ''
  ]);
  return { ok: true, data: { idPP: id } };
}

function actualizarProductoProveedor(params) {
  if (!params.idPP) return { ok: false, error: 'idPP requerido' };
  var sheet = _getProvProdSheet();
  var data  = sheet.getDataRange().getValues();
  var headers = data[0];
  var idxs = {}; headers.forEach(function(h, i){ idxs[h] = i; });
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === String(params.idPP)) {
      var fila = i + 1;
      function set(col, val) {
        if (idxs[col] !== undefined && val !== undefined) {
          sheet.getRange(fila, idxs[col] + 1).setValue(val);
        }
      }
      if (params.skuBase            !== undefined) set('skuBase',          params.skuBase);
      if (params.codigoBarra        !== undefined) set('codigoBarra',      params.codigoBarra);
      if (params.descripcion        !== undefined) set('descripcion',      params.descripcion);
      if (params.precioReferencia   !== undefined) set('precioReferencia', parseFloat(params.precioReferencia) || 0);
      if (params.minimoCompra       !== undefined) set('minimoCompra',     parseFloat(params.minimoCompra) || 0);
      if (params.diasEntrega        !== undefined) set('diasEntrega',      parseInt(params.diasEntrega) || 0);
      if (params.activa             !== undefined) set('activa',           params.activa === false || String(params.activa) === 'false' ? false : true);
      if (params.notas              !== undefined) set('notas',            params.notas);
      set('ultimaActualizacion', new Date());
      return { ok: true };
    }
  }
  return { ok: false, error: 'Producto-proveedor no encontrado' };
}

function eliminarProductoProveedor(params) {
  if (!params.idPP) return { ok: false, error: 'idPP requerido' };
  var sheet = _getProvProdSheet();
  var data  = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === String(params.idPP)) {
      sheet.deleteRow(i + 1);
      return { ok: true };
    }
  }
  return { ok: false, error: 'No encontrado' };
}
