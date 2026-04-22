// ============================================================
// ProyectoMOS — Finanzas.gs
// P&L diario: ingresos, costo de ventas, gastos operativos,
// utilidad neta antes de impuestos + punto de equilibrio.
// ============================================================

// ════════════════════════════════════════════════════════════
// P&L PRINCIPAL
// ════════════════════════════════════════════════════════════

function getFinanzasDia(params) {
  var fecha = params.fecha || _hoy();
  try {
    var ingresos   = _calcularIngresos(fecha);
    var costos     = _calcularCostoVentas(fecha, ingresos.detalleIds);
    var personal   = _calcularPersonal(fecha);
    var gastosList = _calcularGastos(fecha);
    return { ok: true, data: _armarPL(fecha, ingresos, costos, personal, gastosList) };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

function getFinanzasRango(params) {
  if (!params.desde || !params.hasta) return { ok: false, error: 'Requiere desde y hasta (YYYY-MM-DD)' };
  try {
    var dias    = _diasEnRango(params.desde, params.hasta);
    var serie   = dias.map(function(f) {
      var ing  = _calcularIngresos(f);
      var cos  = _calcularCostoVentas(f, ing.detalleIds);
      var per  = _calcularPersonal(f);
      var gas  = _calcularGastos(f);
      var pl   = _armarPL(f, ing, cos, per, gas);
      return { fecha: f, utilidadNeta: pl.utilidadNeta, ventasNetas: pl.ventasNetas,
               costoVentas: pl.costoVentas, totalGastos: pl.totalGastos,
               utilidadBruta: pl.utilidadBruta, margenBrutoPct: pl.margenBrutoPct };
    });
    var totales = serie.reduce(function(acc, d) {
      acc.ventasNetas   += d.ventasNetas;
      acc.costoVentas   += d.costoVentas;
      acc.utilidadBruta += d.utilidadBruta;
      acc.totalGastos   += d.totalGastos;
      acc.utilidadNeta  += d.utilidadNeta;
      return acc;
    }, { ventasNetas:0, costoVentas:0, utilidadBruta:0, totalGastos:0, utilidadNeta:0 });
    totales.margenBrutoPct = totales.ventasNetas > 0
      ? _r2(totales.utilidadBruta / totales.ventasNetas * 100) : 0;
    totales.margenNetoPct  = totales.ventasNetas > 0
      ? _r2(totales.utilidadNeta  / totales.ventasNetas * 100) : 0;
    return { ok: true, data: { serie: serie, totales: totales, desde: params.desde, hasta: params.hasta } };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

// ════════════════════════════════════════════════════════════
// JORNADAS
// ════════════════════════════════════════════════════════════

function getJornadas(params) {
  var rows = _sheetToObjects(getSheet('JORNADAS'));
  if (params.fecha) rows = rows.filter(function(r){ return String(r.fecha).substring(0,10) === params.fecha; });
  return { ok: true, data: rows };
}

function registrarJornada(params) {
  if (!params.nombre || !params.montoJornal) return { ok: false, error: 'Requiere nombre y montoJornal' };
  var sheet = getSheet('JORNADAS');
  var id    = _generateId('JOR');
  var fecha = params.fecha || _hoy();
  sheet.appendRow([
    id, fecha,
    params.idPersonal   || '',
    params.nombre,
    params.rol          || '',
    params.appOrigen    || 'MOS',
    params.zona         || '',
    parseFloat(params.montoJornal),
    params.observacion  || '',
    params.registradoPor || '',
    'MANUAL'
  ]);
  return { ok: true, data: { idJornada: id } };
}

function eliminarJornada(params) {
  if (!params.idJornada) return { ok: false, error: 'Requiere idJornada' };
  var sheet = getSheet('JORNADAS');
  var data  = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === String(params.idJornada)) {
      sheet.deleteRow(i + 1);
      return { ok: true };
    }
  }
  return { ok: false, error: 'Jornada no encontrada' };
}

// Importa automáticamente las jornadas del día desde las aperturas de caja de MosExpress.
// Por cada caja abierta ese día toma: vendedor, zona → busca montoBase en PERSONAL_MASTER.
// Si no está en PERSONAL_MASTER usa el monto por defecto (params.montoDefault).
function importarJornadasDesdeCajas(params) {
  var fecha        = params.fecha || _hoy();
  var montoDefault = parseFloat(params.montoDefault || 0);

  try {
    var cajas    = _sheetToObjectsLocal(_abrirMeSheet('CAJAS'));
    var personal = _sheetToObjects(getSheet('PERSONAL_MASTER'));
    var jSheet   = getSheet('JORNADAS');
    var jornadasExist = _sheetToObjects(jSheet)
      .filter(function(j){ return String(j.fecha).substring(0,10) === fecha; })
      .map(function(j){ return String(j.nombre).toLowerCase(); });

    var cajasHoy = cajas.filter(function(c) {
      var fa = c.Fecha_Apertura || c.fechaApertura || '';
      return String(fa).substring(0,10) === fecha;
    });

    var importados = 0;
    cajasHoy.forEach(function(c) {
      var nombre = String(c.Vendedor || c.vendedor || '').trim();
      if (!nombre) return;
      if (jornadasExist.indexOf(nombre.toLowerCase()) >= 0) return; // ya registrado

      var personal_match = personal.find(function(p){
        return (p.nombre + ' ' + (p.apellido||'')).trim().toLowerCase() === nombre.toLowerCase()
            || p.nombre.toLowerCase() === nombre.toLowerCase();
      });
      var monto  = personal_match ? parseFloat(personal_match.montoBase || montoDefault) : montoDefault;
      var zona   = String(c.Zona || c.zona || c.Estacion || '');

      jSheet.appendRow([
        _generateId('JOR'), fecha,
        personal_match ? personal_match.idPersonal : '',
        nombre,
        personal_match ? personal_match.rol : 'VENDEDOR',
        'mosExpress', zona, monto, '', 'AUTO', 'AUTO_CAJAS'
      ]);
      jornadasExist.push(nombre.toLowerCase());
      importados++;
    });

    return { ok: true, data: { importados: importados, fecha: fecha } };
  } catch(e) {
    return { ok: false, error: 'MosExpress no conectado o sin cajas: ' + e.message };
  }
}

// ════════════════════════════════════════════════════════════
// GASTOS
// ════════════════════════════════════════════════════════════

function getGastos(params) {
  var rows = _sheetToObjects(getSheet('GASTOS'));
  if (params.fecha)     rows = rows.filter(function(r){ return String(r.fecha).substring(0,10) === params.fecha; });
  if (params.categoria) rows = rows.filter(function(r){ return r.categoria === params.categoria; });
  if (params.desde && params.hasta) {
    rows = rows.filter(function(r){
      var f = String(r.fecha).substring(0,10);
      return f >= params.desde && f <= params.hasta;
    });
  }
  return { ok: true, data: rows };
}

function registrarGasto(params) {
  if (!params.descripcion || !params.monto || !params.categoria) {
    return { ok: false, error: 'Requiere descripcion, monto y categoria' };
  }
  var sheet = getSheet('GASTOS');
  var id    = _generateId('GAS');
  sheet.appendRow([
    id,
    params.fecha        || _hoy(),
    params.categoria,
    params.tipo         || 'VARIABLE',
    params.descripcion,
    parseFloat(params.monto),
    params.comprobante  || '',
    params.registradoPor || ''
  ]);
  return { ok: true, data: { idGasto: id } };
}

function eliminarGasto(params) {
  if (!params.idGasto) return { ok: false, error: 'Requiere idGasto' };
  var sheet = getSheet('GASTOS');
  var data  = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === String(params.idGasto)) {
      sheet.deleteRow(i + 1);
      return { ok: true };
    }
  }
  return { ok: false, error: 'Gasto no encontrado' };
}

// ════════════════════════════════════════════════════════════
// CÁLCULOS INTERNOS
// ════════════════════════════════════════════════════════════

function _calcularIngresos(fecha) {
  var cabecera = [];
  try { cabecera = _sheetToObjectsLocal(_abrirMeSheet('VENTAS_CABECERA')); } catch(e) {}

  var del_dia = cabecera.filter(function(v) {
    return String(v.Fecha || '').substring(0, 10) === fecha;
  });

  var completadas = del_dia.filter(function(v){ return String(v.Estado_Envio||'') !== 'ANULADO'; });
  var anuladas    = del_dia.filter(function(v){ return String(v.Estado_Envio||'') === 'ANULADO'; });

  var ventasBrutas = completadas.reduce(function(s, v){ return s + (parseFloat(v.Total) || 0); }, 0);

  // Desglose por tipo de documento
  var byDoc = {};
  completadas.forEach(function(v) {
    var t = String(v.Tipo_Doc || v.tipoDoc || 'NOTA_DE_VENTA');
    byDoc[t] = _r2((byDoc[t] || 0) + (parseFloat(v.Total) || 0));
  });

  // Desglose por método de pago
  var byMetodo = {};
  completadas.forEach(function(v) {
    var m = String(v.FormaPago || v.metodo || 'EFECTIVO');
    byMetodo[m] = _r2((byMetodo[m] || 0) + (parseFloat(v.Total) || 0));
  });

  // IDs de ventas del día para cruzar con DETALLE
  var detalleIds = {};
  completadas.forEach(function(v){ detalleIds[String(v.ID_Venta || '')] = true; });

  // Detalle individual de cada ticket (completadas + anuladas, más recientes primero)
  var detalleTickets = del_dia.map(function(v) {
    var f = String(v.Fecha || '');
    return {
      idVenta:   String(v.ID_Venta || ''),
      total:     parseFloat(v.Total) || 0,
      tipoDoc:   String(v.Tipo_Doc || v.tipoDoc || 'NOTA_DE_VENTA'),
      formaPago: String(v.FormaPago || v.metodo || 'EFECTIVO'),
      estado:    String(v.Estado_Envio || 'COMPLETADO'),
      vendedor:  String(v.Vendedor || ''),
      correlativo: String(v.Correlativo || ''),
      hora:      f.length >= 16 ? f.substring(11, 16) : f.substring(0, 16)
    };
  }).sort(function(a, b) { return a.hora < b.hora ? 1 : -1; });

  return {
    ventasBrutas:   _r2(ventasBrutas),
    ventasNetas:    _r2(ventasBrutas),
    tickets:        completadas.length,
    anulados:       anuladas.length,
    ticketPromedio: completadas.length > 0 ? _r2(ventasBrutas / completadas.length) : 0,
    byDoc:          byDoc,
    byMetodo:       byMetodo,
    detalleIds:     detalleIds,
    detalleTickets: detalleTickets
  };
}

function _calcularCostoVentas(fecha, detalleIds) {
  var detalle  = [];
  var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  try { detalle = _sheetToObjectsLocal(_abrirMeSheet('VENTAS_DETALLE')); } catch(e) {}

  // VENTAS_DETALLE no tiene fecha propia → filtrar por ID_Venta del día
  var items_dia = detalle.filter(function(d){ return detalleIds[String(d.ID_Venta || '')]; });

  var costoTotal = 0;
  var sinCosto   = [];
  var unidades   = 0;
  var skusSet    = {};
  var bySkuMap   = {};

  items_dia.forEach(function(d) {
    var sku    = String(d.SKU || '');
    var nombre = String(d.Nombre || '');
    var cant   = parseFloat(d.Cantidad || 0);
    var precio = parseFloat(d.Precio || 0);
    var prod   = productos.find(function(p){ return p.skuBase === sku || p.codigoBarra === sku || p.idProducto === sku; });
    var costo  = prod ? parseFloat(prod.precioCosto || 0) : 0;
    costoTotal += costo * cant;
    unidades   += cant;
    if (sku) skusSet[sku] = true;
    if (!prod || !costo) sinCosto.push(sku);
    // Agrupado por SKU para detalleProductos
    if (sku) {
      if (!bySkuMap[sku]) bySkuMap[sku] = { sku: sku, nombre: nombre, cantidad: 0, precio: precio, costoUnit: costo, sinCosto: !costo };
      bySkuMap[sku].cantidad += cant;
      if (!bySkuMap[sku].nombre && nombre) bySkuMap[sku].nombre = nombre;
    }
  });

  var detalleProductos = Object.keys(bySkuMap).map(function(k) {
    var p = bySkuMap[k];
    return { sku: p.sku, nombre: p.nombre, cantidad: Math.round(p.cantidad * 100) / 100,
             precio: p.precio, costoUnit: p.costoUnit,
             costoTotal: _r2(p.costoUnit * p.cantidad), sinCosto: p.sinCosto };
  }).sort(function(a, b) { return b.cantidad - a.cantidad; });

  return {
    total:           _r2(costoTotal),
    items:           items_dia.length,
    sinCosto:        sinCosto.filter(function(v,i,a){ return v && a.indexOf(v)===i; }),
    unidades:        Math.round(unidades),
    skusDistintos:   Object.keys(skusSet).length,
    detalleProductos: detalleProductos
  };
}

function _calcularPersonal(fecha) {
  var rows = _sheetToObjects(getSheet('JORNADAS'))
    .filter(function(r){ return String(r.fecha).substring(0,10) === fecha; });

  var total = rows.reduce(function(s, r){ return s + (parseFloat(r.montoJornal) || 0); }, 0);

  var detalle = rows.map(function(r){
    return { idJornada: r.idJornada || '', nombre: r.nombre, rol: r.rol || '',
             zona: r.zona || '', monto: parseFloat(r.montoJornal) || 0, fuente: r.fuente || 'MANUAL' };
  });

  return { total: _r2(total), personas: rows.length, detalle: detalle };
}

function _calcularGastos(fecha) {
  var rows = _sheetToObjects(getSheet('GASTOS'))
    .filter(function(r){ return String(r.fecha).substring(0,10) === fecha; });

  var total  = rows.reduce(function(s, r){ return s + (parseFloat(r.monto) || 0); }, 0);
  var fijos  = rows.filter(function(r){ return r.tipo === 'FIJO'; })
                   .reduce(function(s,r){ return s + (parseFloat(r.monto)||0); }, 0);
  var variables = total - fijos;

  // Por categoría
  var byCategoria = {};
  rows.forEach(function(r) {
    var cat = r.categoria || 'OTROS';
    byCategoria[cat] = _r2((byCategoria[cat] || 0) + (parseFloat(r.monto) || 0));
  });

  return { total: _r2(total), fijos: _r2(fijos), variables: _r2(variables),
           byCategoria: byCategoria, detalle: rows };
}

function _armarPL(fecha, ing, cos, per, gas) {
  var ventasNetas   = ing.ventasNetas;
  var costoVentas   = cos.total;
  var utilidadBruta = _r2(ventasNetas - costoVentas);
  var gastoPersonal = per.total;
  var gastoOtros    = gas.total;
  var totalGastos   = _r2(gastoPersonal + gastoOtros);
  var utilidadNeta  = _r2(utilidadBruta - totalGastos);

  var margenBrutoPct = ventasNetas > 0 ? _r2(utilidadBruta / ventasNetas * 100) : 0;
  var margenNetoPct  = ventasNetas > 0 ? _r2(utilidadNeta  / ventasNetas * 100) : 0;

  // ── Punto de equilibrio ──────────────────────────────────
  // Costos fijos = gastos tipo FIJO del día + personal (siempre fijo en este modelo)
  var costosFijos = _r2(gastoPersonal + gas.fijos);
  var margenContrib = ventasNetas > 0 ? (ventasNetas - costoVentas) / ventasNetas : 0;
  var breakEvenVentas = margenContrib > 0 ? _r2(costosFijos / margenContrib) : null;
  var breakEvenPct    = (breakEvenVentas && ventasNetas > 0)
    ? _r2(Math.min(breakEvenVentas / ventasNetas * 100, 100)) : 0;
  var superaBreakEven = breakEvenVentas !== null && ventasNetas >= breakEvenVentas;

  return {
    fecha:          fecha,
    // Ingresos
    ventasBrutas:   ing.ventasBrutas,
    ventasNetas:    ventasNetas,
    tickets:        ing.tickets,
    anulados:       ing.anulados,
    ticketPromedio: ing.ticketPromedio,
    byDoc:          ing.byDoc,
    byMetodo:       ing.byMetodo,
    detalleTickets: ing.detalleTickets,
    // Costos
    costoVentas:    costoVentas,
    itemsVendidos:  cos.items,
    unidadesVendidas: cos.unidades,
    skusDistintos:  cos.skusDistintos,
    productosSinCosto:  cos.sinCosto,
    detalleProductos:   cos.detalleProductos,
    // Utilidad bruta
    utilidadBruta:  utilidadBruta,
    margenBrutoPct: margenBrutoPct,
    // Gastos
    gastoPersonal:  gastoPersonal,
    personalDetalle:per.detalle,
    personas:       per.personas,
    gastoOtros:     gastoOtros,
    gastosFijos:    gas.fijos,
    gastosVariables:gas.variables,
    gastosByCategoria: gas.byCategoria,
    gastosDetalle:  gas.detalle,
    totalGastos:    totalGastos,
    // Resultado
    utilidadNeta:   utilidadNeta,
    margenNetoPct:  margenNetoPct,
    // Punto de equilibrio
    costosFijos:       costosFijos,
    margenContribPct:  _r2(margenContrib * 100),
    breakEvenVentas:   breakEvenVentas,
    breakEvenPct:      breakEvenPct,
    superaBreakEven:   superaBreakEven
  };
}

// ════════════════════════════════════════════════════════════
// HELPERS LOCALES
// ════════════════════════════════════════════════════════════

function _hoy() {
  return Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
}

function _r2(n) { return Math.round((n || 0) * 100) / 100; }

function _diasEnRango(desde, hasta) {
  var dias = [];
  var cur  = new Date(desde + 'T00:00:00');
  var end  = new Date(hasta  + 'T00:00:00');
  while (cur <= end) {
    dias.push(Utilities.formatDate(cur, Session.getScriptTimeZone(), 'yyyy-MM-dd'));
    cur.setDate(cur.getDate() + 1);
  }
  return dias;
}

// ════════════════════════════════════════════════════════════
// COSTOS MANUALES
// ════════════════════════════════════════════════════════════

// Permite asignar precioCosto a un producto desde el módulo Finanzas,
// buscando por SKU / codigoBarra / idProducto en PRODUCTOS_MASTER.
function actualizarCostoPorSku(params) {
  var sku   = String(params.sku || '').trim();
  var costo = parseFloat(params.precioCosto);
  if (!sku || isNaN(costo) || costo < 0) return { ok: false, error: 'Requiere sku y precioCosto >= 0' };

  var sheet = getSheet('PRODUCTOS_MASTER');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0].map(function(h){ return String(h).trim(); });
  var idxSku   = hdrs.indexOf('skuBase');
  var idxCod   = hdrs.indexOf('codigoBarra');
  var idxId    = hdrs.indexOf('idProducto');
  var idxCosto = hdrs.indexOf('precioCosto');

  if (idxCosto < 0) return { ok: false, error: 'Columna precioCosto no encontrada en PRODUCTOS_MASTER' };

  for (var i = 1; i < data.length; i++) {
    var match = (idxSku >= 0 && String(data[i][idxSku]) === sku)
             || (idxCod >= 0 && String(data[i][idxCod]) === sku)
             || (idxId  >= 0 && String(data[i][idxId])  === sku);
    if (match) {
      sheet.getRange(i + 1, idxCosto + 1).setValue(costo);
      return { ok: true };
    }
  }
  return { ok: false, error: 'Producto no encontrado: ' + sku };
}

// ════════════════════════════════════════════════════════════
// REGISTRO AUTOMÁTICO DE JORNADAS (llamado desde apps hijas)
// ════════════════════════════════════════════════════════════

// Registra una jornada en JORNADAS de este spreadsheet con idempotencia por (nombre + fecha).
// Las apps hijas (MosExpress, warehouseMos) lo llaman directamente abriendo este spreadsheet
// via MOS_SS_ID en sus Script Properties.
function _registrarJornadaIdempotente(nombre, rol, montoJornal, appOrigen, fecha) {
  nombre = String(nombre || '').trim();
  if (!nombre) return;
  fecha  = fecha || _hoy();

  var sheet = getSheet('JORNADAS');
  var data  = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][3]).toLowerCase() === nombre.toLowerCase() &&
        String(data[i][1]).substring(0, 10) === fecha) return; // ya existe
  }
  sheet.appendRow([
    _generateId('JOR'), fecha, '', nombre,
    rol || 'VENDEDOR', appOrigen || 'AUTO', '',
    parseFloat(montoJornal) || 0, '', 'AUTO',
    appOrigen === 'warehouseMos' ? 'AUTO_LOGIN' : 'AUTO_VENTA'
  ]);
}

// _sheetToObjectsLocal está definida en Conexiones.gs (compartida en el mismo proyecto GAS)
