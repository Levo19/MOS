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

// ── Proveedores que venden un producto específico ──────────────
function getProveedoresQueVenden(params) {
  if (!params || (!params.skuBase && !params.codigoBarra)) {
    return { ok: false, error: 'Requiere skuBase o codigoBarra' };
  }
  try {
    var ppSheet = _getProvProdSheet();
    var ppData  = ppSheet.getDataRange().getValues();
    var hdrs    = ppData[0];
    var idxs = {}; hdrs.forEach(function(h, i){ idxs[h] = i; });
    var matches = [];
    for (var i = 1; i < ppData.length; i++) {
      var sku = String(ppData[i][idxs.skuBase] || '').trim();
      var cb  = String(ppData[i][idxs.codigoBarra] || '').trim();
      if ((params.skuBase && sku === String(params.skuBase)) ||
          (params.codigoBarra && cb === String(params.codigoBarra))) {
        matches.push({
          idPP:             ppData[i][idxs.idPP],
          idProveedor:      ppData[i][idxs.idProveedor],
          skuBase:          sku,
          codigoBarra:      cb,
          descripcion:      ppData[i][idxs.descripcion],
          precioReferencia: parseFloat(ppData[i][idxs.precioReferencia]) || 0,
          minimoCompra:     parseFloat(ppData[i][idxs.minimoCompra]) || 0,
          diasEntrega:      parseInt(ppData[i][idxs.diasEntrega]) || 0
        });
      }
    }
    // Enriquecer con nombre del proveedor
    if (matches.length > 0) {
      var provs = _sheetToObjects(getSheet('PROVEEDORES_MASTER'));
      var provMap = {}; provs.forEach(function(p){ provMap[p.idProveedor] = p; });
      matches = matches.map(function(m){
        var p = provMap[m.idProveedor] || {};
        return Object.assign({}, m, {
          nombreProveedor: p.nombre || m.idProveedor,
          ruc:             p.ruc || ''
        });
      });
      // Ordenar por menor precio
      matches.sort(function(a, b){ return a.precioReferencia - b.precioReferencia; });
    }
    return { ok: true, data: matches };
  } catch(e) {
    return { ok: false, error: 'Error: ' + e.message };
  }
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
    // + por día: { fecha → { items: { codigoBarra → { cant, suma, descTmp } }, totalDia, idsGuias } }
    var porCodigo = {};
    var porDia    = {};
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
      // Agregación por día (string yyyy-MM-dd)
      if (!porDia[fGuia]) porDia[fGuia] = { fecha: fGuia, items: {}, totalDia: 0, idsGuias: {} };
      porDia[fGuia].idsGuias[idG] = true;
      if (!porDia[fGuia].items[cod]) {
        porDia[fGuia].items[cod] = { codigoBarra: cod, cantidad: 0, sumaMonto: 0, ultimoPrecio: 0 };
      }
      var dayItem = porDia[fGuia].items[cod];
      dayItem.cantidad += cant;
      dayItem.sumaMonto += prec * cant;
      if (prec > 0) dayItem.ultimoPrecio = prec;
      porDia[fGuia].totalDia += prec * cant;
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

    // 4. Construir array de días con items enriquecidos por descripcion
    var diasArr = Object.keys(porDia).map(function(fecha){
      var d = porDia[fecha];
      var items = Object.keys(d.items).map(function(cod){
        var it = d.items[cod];
        var p = prodByCB[cod] || null;
        return {
          codigoBarra: cod,
          descripcion: (p && p.descripcion) || '—',
          skuBase:     (p && (p.skuBase || p.idProducto)) || '',
          cantidad:    it.cantidad,
          monto:       Math.round(it.sumaMonto * 100) / 100,
          precio:      it.ultimoPrecio
        };
      }).sort(function(a, b){ return b.monto - a.monto; });
      return {
        fecha:    fecha,
        totalDia: Math.round(d.totalDia * 100) / 100,
        numGuias: Object.keys(d.idsGuias).length,
        numItems: items.length,
        items:    items
      };
    }).sort(function(a, b){ return b.fecha.localeCompare(a.fecha); }); // más reciente primero

    // 5. Pagos y por pagar
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
        productos:    resultado,
        guiasPorDia:  diasArr
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
var _PROV_PROD_FORMATTED = false;
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
  // Forzar columnas idPP, idProveedor, skuBase y codigoBarra como TEXTO
  // — preserva ceros a la izquierda y evita conversión a número.
  if (!_PROV_PROD_FORMATTED) {
    try {
      sheet.getRange(1, 1, sheet.getMaxRows(), 4).setNumberFormat('@');
      _PROV_PROD_FORMATTED = true;
    } catch(e) {}
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
    String(id),
    String(params.idProveedor),
    String(params.skuBase),
    String(params.codigoBarra || ''),
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
      if (params.skuBase            !== undefined) set('skuBase',          String(params.skuBase));
      if (params.codigoBarra        !== undefined) {
        var col = idxs.codigoBarra;
        if (col !== undefined) sheet.getRange(fila, col + 1).setNumberFormat('@').setValue(String(params.codigoBarra));
      }
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

// Upsert silencioso: invocado desde WH al cerrar guía INGRESO_PROVEEDOR
// Si la entry (idProveedor + skuBase) existe → actualiza precioReferencia + ultimaActualizacion
// Si no existe → crea nueva fila
function upsertProductoProveedor(params) {
  if (!params.idProveedor) return { ok: false, error: 'idProveedor requerido' };
  var codigoBarra = String(params.codigoBarra || '').trim();
  if (!codigoBarra) return { ok: false, error: 'codigoBarra requerido' };
  var precio = parseFloat(params.precioUnitario) || 0;

  // 1. Buscar skuBase del producto
  var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  var prod = productos.find(function(p){ return String(p.codigoBarra || '').trim() === codigoBarra; });
  // Si no se encuentra por codigoBarra, intentar por idProducto
  if (!prod) prod = productos.find(function(p){ return String(p.idProducto || '').trim() === codigoBarra; });
  if (!prod) {
    // Producto aún no aprobado — silencioso, ignora
    return { ok: true, data: { skipped: 'producto no en master' } };
  }
  var skuBase = prod.skuBase || prod.idProducto;
  var descripcion = params.descripcion || prod.descripcion || '';

  // 2. Buscar entry existente
  var sheet = _getProvProdSheet();
  var data  = sheet.getDataRange().getValues();
  var headers = data[0];
  var idxs = {}; headers.forEach(function(h, i){ idxs[h] = i; });

  for (var i = 1; i < data.length; i++) {
    var sameProv = String(data[i][idxs.idProveedor]) === String(params.idProveedor);
    var sameSku  = String(data[i][idxs.skuBase])     === String(skuBase);
    if (sameProv && sameSku) {
      // Update precioReferencia + descripcion + ultimaActualizacion
      var fila = i + 1;
      if (precio > 0) sheet.getRange(fila, idxs.precioReferencia + 1).setValue(precio);
      sheet.getRange(fila, idxs.descripcion + 1).setValue(descripcion);
      sheet.getRange(fila, idxs.codigoBarra + 1).setNumberFormat('@').setValue(String(codigoBarra));
      sheet.getRange(fila, idxs.ultimaActualizacion + 1).setValue(new Date());
      return { ok: true, data: { idPP: data[i][idxs.idPP], accion: 'actualizado' } };
    }
  }

  // 3. Crear nueva fila
  var id = _generateId('PP');
  sheet.appendRow([
    String(id), String(params.idProveedor), String(skuBase), String(codigoBarra), descripcion,
    precio, 0, 0,
    new Date(), true,
    params.notas || 'Auto desde guía'
  ]);
  return { ok: true, data: { idPP: id, accion: 'creado' } };
}

// ════════════════════════════════════════════════
// CATÁLOGO ENRIQUECIDO DEL PROVEEDOR
// Productos del proveedor + stock por zona/almacén + mín/máx + rotación + sugerencia
// ════════════════════════════════════════════════
function getProductosProveedorConStock(params) {
  if (!params || !params.idProveedor) return { ok: false, error: 'idProveedor requerido' };
  var rangoDias = parseInt(params.rangoDias) || 30;
  try {
    // 1. Productos del proveedor (activos)
    var pp = _sheetToObjects(_getProvProdSheet()).filter(function(r){
      var act = r.activa;
      return String(r.idProveedor) === String(params.idProveedor)
        && (act === true || act === '1' || act === 1 || String(act).toUpperCase() === 'TRUE');
    });
    if (!pp.length) return { ok: true, data: [] };

    // 2. Productos master + indices
    var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
    var prodById = {}, prodByCB = {}, bySku = {};
    productos.forEach(function(p) {
      prodById[p.idProducto] = p;
      if (p.codigoBarra) prodByCB[p.codigoBarra] = p;
      var sku = p.skuBase || p.idProducto;
      if (!bySku[sku]) bySku[sku] = { base: null, presentaciones: [], idsAll: [], barrasAll: [] };
      bySku[sku].presentaciones.push(p);
      bySku[sku].idsAll.push(p.idProducto);
      if (p.codigoBarra) bySku[sku].barrasAll.push(p.codigoBarra);
      var fc = parseFloat(p.factorConversion) || 1;
      if (p.idProducto === sku || (!bySku[sku].base && fc === 1)) bySku[sku].base = p;
    });
    Object.keys(bySku).forEach(function(sku){
      if (!bySku[sku].base) bySku[sku].base = bySku[sku].presentaciones[0];
    });

    // 3. Equivalencias → ampliar barrasAll
    var equiv = _readEquivalencias();
    Object.keys(equiv.porSku || {}).forEach(function(sku){
      if (!bySku[sku]) return;
      (equiv.porSku[sku] || []).forEach(function(eq){
        if (bySku[sku].barrasAll.indexOf(eq.codigoBarra) < 0) {
          bySku[sku].barrasAll.push(eq.codigoBarra);
        }
        if (!prodByCB[eq.codigoBarra]) prodByCB[eq.codigoBarra] = bySku[sku].base;
      });
    });

    // 4. Resolver de zonas + set de zonas REGISTRADAS (tabla ZONAS activa).
    //    Zonas que aparecen en STOCK_ZONAS o ventas pero NO están en master
    //    se agruparán como "Sin zona registrada" en el frontend.
    var resolver = _buildZonaResolver();
    var idsZonasRegistradas = {};
    try {
      _sheetToObjects(getSheet('ZONAS')).forEach(function(z){
        if (!z.idZona) return;
        var act = z.estado;
        var activa = (act === undefined || act === '' || act === 1 || act === '1' || act === true);
        if (!activa) return;
        idsZonasRegistradas[String(z.idZona).trim().toUpperCase()] = z.nombre || z.idZona;
      });
    } catch(_){}

    // 5. Stock WH agregado por sku
    var stockWH = _safeReadWhStock();
    var whBySku = {};
    stockWH.forEach(function(s) {
      var p = prodById[s.codigoProducto] || prodByCB[s.codigoProducto];
      if (!p) return;
      var sku = p.skuBase || p.idProducto;
      whBySku[sku] = (whBySku[sku] || 0) + (parseFloat(s.cantidadDisponible) || 0);
    });

    // 6. Stock zonas (canon-resolved) por sku
    var stockZonas = _safeReadMeStockZonas();
    var zonasBySku = {};
    stockZonas.forEach(function(z) {
      var cb = String(z.Cod_Barras || z.codigoBarra || '').trim();
      var p = prodByCB[cb];
      if (!p) return;
      var sku = p.skuBase || p.idProducto;
      var zid = String(z.Zona_ID || z.zonaId || '').trim();
      if (!zid) return;
      var canon = resolver.resolve(zid);
      if (!zonasBySku[sku]) zonasBySku[sku] = {};
      if (!zonasBySku[sku][canon.id]) zonasBySku[sku][canon.id] = { nombre: canon.nombre, cantidad: 0 };
      zonasBySku[sku][canon.id].cantidad += parseFloat(z.Cantidad || z.cantidad) || 0;
    });

    // 7. Ventas en rango por sku Y por zona (una sola pasada de VENTAS)
    var hoy = new Date();
    var desde = new Date(hoy.getTime() - rangoDias * 86400000);
    var ventasBySku = {};
    var ventasBySkuByZona = {};   // sku → { canonZonaId: cantidad }
    var nombreZonaCanon = {};      // canonZonaId → nombre legible (cache)
    try {
      var ssMe = SpreadsheetApp.openById(_getProp('ME_SS_ID'));
      var shVC = ssMe.getSheetByName('VENTAS_CABECERA');
      var shVD = ssMe.getSheetByName('VENTAS_DETALLE');
      if (shVC && shVD) {
        var dataVC = shVC.getDataRange().getValues();
        var idsValidas = {};   // idV → estacion (sin canonizar todavía)
        for (var i = 1; i < dataVC.length; i++) {
          var fecha = dataVC[i][1] ? new Date(dataVC[i][1]) : null;
          if (!fecha || fecha < desde) continue;
          if (String(dataVC[i][8] || '').toUpperCase() === 'ANULADO') continue;
          var estacion = String(dataVC[i][3] || '').trim();
          idsValidas[String(dataVC[i][0] || '').trim()] = estacion || '';
        }
        var dataVD = shVD.getDataRange().getValues();
        for (var j = 1; j < dataVD.length; j++) {
          var idV = String(dataVD[j][0] || '').trim();
          if (idsValidas[idV] === undefined) continue;
          var sku2 = String(dataVD[j][1] || '').trim();
          var cb2  = String(dataVD[j][6] || '').trim();
          var p = prodById[sku2] || prodByCB[cb2];
          if (!p) continue;
          var skuKey = p.skuBase || p.idProducto;
          var cant = parseFloat(dataVD[j][3]) || 0;
          ventasBySku[skuKey] = (ventasBySku[skuKey] || 0) + cant;
          // Acumular por zona (canonizando estacion → zona canónica)
          var est = idsValidas[idV];
          if (est) {
            var canonZ = resolver.resolve(est);
            var zKey = canonZ.id;
            nombreZonaCanon[zKey] = canonZ.nombre || zKey;
            if (!ventasBySkuByZona[skuKey]) ventasBySkuByZona[skuKey] = {};
            ventasBySkuByZona[skuKey][zKey] = (ventasBySkuByZona[skuKey][zKey] || 0) + cant;
          }
        }
      }
    } catch(_){}

    // 8. Enriquecer
    var resultado = pp.map(function(item){
      var sku = item.skuBase;
      var grupo = bySku[sku];
      var p = (grupo && grupo.base) || prodById[sku] || {};
      var whQ = whBySku[sku] || 0;
      // Mergir zonas: incluir las que tienen stock O ventas.
      // Separar las REGISTRADAS (en tabla ZONAS) vs HUÉRFANAS (zonas inventadas
      // que aparecen en stock o ventas pero no están en master).
      var zonasMap = {};
      var huerfanas = { cantidad: 0, ventasRango: 0 };
      function _addZona(zid, src) {
        if (!idsZonasRegistradas[zid]) {
          // Zona no registrada — acumular en huérfanas y omitir chip individual
          huerfanas.cantidad    += src.cantidad    || 0;
          huerfanas.ventasRango += src.ventasRango || 0;
          return;
        }
        if (!zonasMap[zid]) {
          zonasMap[zid] = {
            idZona:      zid,
            nombre:      idsZonasRegistradas[zid] || src.nombre || zid,
            cantidad:    0,
            ventasRango: 0
          };
        }
        zonasMap[zid].cantidad    += src.cantidad    || 0;
        zonasMap[zid].ventasRango += src.ventasRango || 0;
      }
      if (zonasBySku[sku]) {
        Object.keys(zonasBySku[sku]).forEach(function(zid){
          _addZona(zid, { cantidad: zonasBySku[sku][zid].cantidad, nombre: zonasBySku[sku][zid].nombre });
        });
      }
      if (ventasBySkuByZona[sku]) {
        Object.keys(ventasBySkuByZona[sku]).forEach(function(zid){
          _addZona(zid, { ventasRango: ventasBySkuByZona[sku][zid], nombre: nombreZonaCanon[zid] });
        });
      }
      var zonas = Object.keys(zonasMap).map(function(zid){
        var z = zonasMap[zid];
        z.rotacionDia = rangoDias > 0 ? Math.round((z.ventasRango / rangoDias) * 10) / 10 : 0;
        return z;
      });
      // Stock + ventas en zonas SI registradas + huérfanas (para el TOTAL)
      var zonasRegistradasStock = zonas.reduce(function(s,z){ return s + z.cantidad; }, 0);
      var zonasTotal = zonasRegistradasStock + (huerfanas.cantidad || 0);
      var ventasZonasTotal = zonas.reduce(function(s,z){ return s + z.ventasRango; }, 0) + (huerfanas.ventasRango || 0);
      // Rotación huérfana
      var huerfanasRotDia = rangoDias > 0 ? Math.round((huerfanas.ventasRango / rangoDias) * 10) / 10 : 0;
      var total = whQ + zonasTotal;
      var ventas = ventasBySku[sku] || 0;
      var rotDia = rangoDias > 0 ? ventas / rangoDias : 0;
      var minimo = parseFloat(p.stockMinimo) || 0;
      var maximo = parseFloat(p.stockMaximo) || 0;

      // Sugerencia de pedido
      var sugerencia = 0;
      var razonSugerencia = '';
      if (minimo > 0 && total < minimo) {
        var objetivo = maximo > minimo ? maximo : minimo * 2;
        sugerencia = Math.max(0, Math.ceil(objetivo - total));
        razonSugerencia = 'Reponer hasta ' + (maximo > minimo ? 'máx (' + objetivo + ')' : '2× mín (' + objetivo + ')');
      } else if (rotDia > 0) {
        var cobertura14 = Math.ceil(rotDia * 14);
        sugerencia = Math.max(0, cobertura14 - Math.floor(total));
        razonSugerencia = sugerencia > 0 ? 'Cobertura 14d (rot ' + rotDia.toFixed(1) + '/d)' : 'Stock cubre 14d';
      } else if (total <= 0 && minimo === 0) {
        razonSugerencia = 'Sin rotación · sin mín — define mínimo';
      }

      // Alerta
      var alerta = 'OK';
      if (total < 0) alerta = 'NEGATIVO';
      else if (minimo > 0 && total < minimo) alerta = 'BAJO_MINIMO';
      else if (rotDia > 0 && total > 0 && (total / rotDia) < 7) alerta = 'AGOTAR_PRONTO';
      else if (minimo > 0 && total < minimo * 1.2) alerta = 'CERCA_MINIMO';
      else if (total > 0 && ventas === 0) alerta = 'SIN_ROTACION';

      return {
        idPP:            item.idPP,
        idProveedor:     item.idProveedor,
        skuBase:         sku,
        idProducto:      p.idProducto || sku,
        descripcion:     item.descripcion || p.descripcion || sku,
        codigoBarra:     String(item.codigoBarra || p.codigoBarra || ''),
        precioReferencia: parseFloat(item.precioReferencia) || 0,
        minimoCompra:    parseFloat(item.minimoCompra) || 0,
        diasEntrega:     parseInt(item.diasEntrega) || 0,
        notas:           item.notas || '',
        stockWh:         whQ,
        stockTienda:     zonasTotal,
        stockTotal:      total,
        zonas:           zonas.sort(function(a,b){ return b.cantidad - a.cantidad; }),
        zonasHuerfanas:  (huerfanas.cantidad > 0 || huerfanas.ventasRango > 0) ? {
          cantidad:    huerfanas.cantidad,
          ventasRango: huerfanas.ventasRango,
          rotacionDia: huerfanasRotDia
        } : null,
        stockMinimo:     minimo,
        stockMaximo:     maximo,
        ventasRango:     ventas,
        rotacionDia:     Math.round(rotDia * 10) / 10,
        rangoDias:       rangoDias,
        sugerencia:      sugerencia,
        razonSugerencia: razonSugerencia,
        alerta:          alerta,
        countPresentaciones: grupo ? grupo.presentaciones.length : 1,
        countEquivalencias:  (equiv.porSku && equiv.porSku[sku]) ? equiv.porSku[sku].length : 0
      };
    });

    // Ordenar: alertas primero
    var sevOrden = { NEGATIVO: 0, BAJO_MINIMO: 1, AGOTAR_PRONTO: 2, CERCA_MINIMO: 3, SIN_ROTACION: 4, OK: 5 };
    resultado.sort(function(a, b){
      var dx = (sevOrden[a.alerta] || 9) - (sevOrden[b.alerta] || 9);
      if (dx !== 0) return dx;
      return (a.descripcion || '').localeCompare(b.descripcion || '');
    });

    return { ok: true, data: resultado };
  } catch(e) {
    return { ok: false, error: 'Error: ' + e.message };
  }
}

// ════════════════════════════════════════════════
// JALAR productos al catálogo del proveedor desde
// el histórico de GUIAS (warehouseMos). Útil cuando
// hay guías cerradas antes del auto-upsert o cuando
// faltó algún producto.
// ════════════════════════════════════════════════
function jalarProductosProveedor(params) {
  if (!params || !params.idProveedor) return { ok: false, error: 'idProveedor requerido' };
  try {
    var guiasSh = _abrirWhSheet('GUIAS');
    if (!guiasSh) return { ok: false, error: 'Hoja GUIAS no accesible' };
    var gd = guiasSh.getDataRange().getValues();
    var gh = gd[0];
    var iGId    = gh.indexOf('idGuia');
    var iGProv  = gh.indexOf('idProveedor');
    var iGTipo  = gh.indexOf('tipo');
    var iGFecha = gh.indexOf('fecha');
    var guiaIds = {};
    for (var r = 1; r < gd.length; r++) {
      if (String(gd[r][iGProv]) !== String(params.idProveedor)) continue;
      if (String(gd[r][iGTipo] || '').toUpperCase().indexOf('INGRESO') !== 0) continue;
      guiaIds[gd[r][iGId]] = gd[r][iGFecha];
    }
    var totalGuias = Object.keys(guiaIds).length;
    if (!totalGuias) return { ok: true, data: { creados: 0, actualizados: 0, total: 0, totalGuias: 0 } };

    var detSh = _abrirWhSheet('GUIA_DETALLE');
    if (!detSh) return { ok: false, error: 'Hoja GUIA_DETALLE no accesible' };
    var dd = detSh.getDataRange().getValues();
    var dh = dd[0];
    var iDGuia = dh.indexOf('idGuia');
    var iDCod  = dh.indexOf('codigoProducto');
    var iDPrec = dh.indexOf('precioUnitario');
    var iDDesc = dh.indexOf('descripcion');

    // Quedarnos con el último precio por código
    var porCodigo = {};
    for (var d = 1; d < dd.length; d++) {
      var idG = dd[d][iDGuia];
      if (!guiaIds[idG]) continue;
      var cod = String(dd[d][iDCod] || '').trim();
      if (!cod) continue;
      var prec = parseFloat(dd[d][iDPrec]) || 0;
      var desc = dd[d][iDDesc] || '';
      var prev = porCodigo[cod];
      if (!prev || prec > 0) {
        porCodigo[cod] = { codigoBarra: cod, precioUnitario: prec, descripcion: desc };
      }
    }

    var creados = 0, actualizados = 0, omitidos = 0;
    Object.keys(porCodigo).forEach(function(cod){
      var entry = porCodigo[cod];
      var res = upsertProductoProveedor({
        idProveedor:    params.idProveedor,
        codigoBarra:    cod,
        precioUnitario: entry.precioUnitario,
        descripcion:    entry.descripcion,
        notas:          'Jalado manualmente'
      });
      if (res.ok && res.data) {
        if (res.data.accion === 'creado')           creados++;
        else if (res.data.accion === 'actualizado') actualizados++;
        else omitidos++;
      } else {
        omitidos++;
      }
    });
    return {
      ok: true,
      data: {
        creados:      creados,
        actualizados: actualizados,
        omitidos:     omitidos,
        total:        Object.keys(porCodigo).length,
        totalGuias:   totalGuias
      }
    };
  } catch(e) {
    return { ok: false, error: 'Error: ' + e.message };
  }
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
