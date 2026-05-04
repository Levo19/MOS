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
    // Auto-sincronizar jornadas: si hay personal con presencia detectada
    // (ventas, sesiones, cajas) pero sin JORNADA registrada, la crea ahora.
    // Esto garantiza que finanzas, evaluaciones y liquidaciones siempre cuadren.
    try { _sincronizarJornadasAutoDelDia(fecha); } catch(eS) { Logger.log('Sync jornadas: ' + eS.message); }
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
    var tz3 = Session.getScriptTimeZone();
    var jornadasExist = _sheetToObjects(jSheet)
      .filter(function(j) {
        var f = j.fecha instanceof Date
          ? Utilities.formatDate(j.fecha, tz3, 'yyyy-MM-dd')
          : String(j.fecha || '').substring(0, 10);
        return f === fecha;
      })
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

// Parser MIXTO: dado "MIXTO (VIR:0.50/EFE:1.00)" devuelve { efe, vir }.
// Para POR_COBRAR / CREDITO / ANULADO devuelve { efe:0, vir:0 } (no es cash).
function _parseFormaPagoFin(metodo, total) {
  var m = String(metodo || '').toUpperCase().trim();
  if (!m || m === 'POR_COBRAR' || m === 'CREDITO' || m === 'ANULADO') return { efe: 0, vir: 0 };
  if (m === 'EFECTIVO') return { efe: total, vir: 0 };
  if (m === 'VIRTUAL')  return { efe: 0, vir: total };
  if (m.indexOf('MIXTO') === 0) {
    var virM = String(metodo).match(/VIR:([\d.]+)/i);
    var efeM = String(metodo).match(/EFE:([\d.]+)/i);
    var vir  = virM ? parseFloat(virM[1]) : 0;
    var efe  = efeM ? parseFloat(efeM[1]) : Math.round((total - vir) * 100) / 100;
    return { efe: efe, vir: vir };
  }
  return { efe: 0, vir: total }; // fallback: lo trato como virtual
}

function _calcularIngresos(fecha) {
  var cabecera = [];
  try { cabecera = _sheetToObjectsLocal(_abrirMeSheet('VENTAS_CABECERA')); } catch(e) {}

  var del_dia = cabecera.filter(function(v) {
    return String(v.Fecha || '').substring(0, 10) === fecha;
  });

  // ⚠ La fuente de verdad para detectar anulación es FormaPago (no Estado_Envio,
  // que solo indica si fue enviado a NubeFact).
  var noAnuladas = del_dia.filter(function(v){
    return String(v.FormaPago || '').toUpperCase() !== 'ANULADO';
  });
  var anuladas = del_dia.filter(function(v){
    return String(v.FormaPago || '').toUpperCase() === 'ANULADO';
  });

  // Cobrado (cash flow real) vs crédito (cuenta por cobrar)
  var cobrados = noAnuladas.filter(function(v) {
    var m = String(v.FormaPago || '').toUpperCase();
    return m !== 'POR_COBRAR' && m !== 'CREDITO';
  });
  var aCredito = noAnuladas.filter(function(v) {
    var m = String(v.FormaPago || '').toUpperCase();
    return m === 'POR_COBRAR' || m === 'CREDITO';
  });

  // Ventas brutas / netas = todas las NO ANULADAS (incluye crédito).
  // El crédito ES venta del día contablemente, aunque no haya entrado al cash.
  var ventasBrutas = noAnuladas.reduce(function(s, v){ return s + (parseFloat(v.Total) || 0); }, 0);

  // Desglose por tipo de documento
  var byDoc = {};
  noAnuladas.forEach(function(v) {
    var t = String(v.Tipo_Doc || v.tipoDoc || 'NOTA_DE_VENTA');
    byDoc[t] = _r2((byDoc[t] || 0) + (parseFloat(v.Total) || 0));
  });

  // Desglose por método de pago — descompone MIXTO correctamente
  var totalEfectivo = 0, totalVirtual = 0;
  cobrados.forEach(function(v) {
    var t = parseFloat(v.Total) || 0;
    var r = _parseFormaPagoFin(v.FormaPago, t);
    totalEfectivo += r.efe;
    totalVirtual  += r.vir;
  });
  var creditoOtorgado = aCredito.reduce(function(s, v){ return s + (parseFloat(v.Total) || 0); }, 0);
  var cobradoTotal    = _r2(totalEfectivo + totalVirtual);

  var byMetodo = {
    EFECTIVO: _r2(totalEfectivo),
    VIRTUAL:  _r2(totalVirtual)
  };
  if (creditoOtorgado > 0) byMetodo.POR_COBRAR = _r2(creditoOtorgado);

  // IDs para cruzar con DETALLE (incluye crédito — sí vendió, sí descuenta stock)
  var detalleIds = {};
  noAnuladas.forEach(function(v){ detalleIds[String(v.ID_Venta || '')] = true; });

  // Detalle individual de cada ticket (todos los del día, ordenados por hora desc)
  var detalleTickets = del_dia.map(function(v) {
    var f = String(v.Fecha || '');
    var fp = String(v.FormaPago || 'EFECTIVO').toUpperCase();
    var estadoDerivado = fp === 'ANULADO' ? 'ANULADO'
                       : (fp === 'POR_COBRAR' || fp === 'CREDITO') ? 'POR_COBRAR'
                       : 'COBRADO';
    return {
      idVenta:   String(v.ID_Venta || ''),
      total:     parseFloat(v.Total) || 0,
      tipoDoc:   String(v.Tipo_Doc || v.tipoDoc || 'NOTA_DE_VENTA'),
      formaPago: String(v.FormaPago || v.metodo || 'EFECTIVO'),
      estado:    estadoDerivado,
      vendedor:  String(v.Vendedor || ''),
      correlativo: String(v.Correlativo || ''),
      hora:      f.length >= 16 ? f.substring(11, 16) : f.substring(0, 16)
    };
  }).sort(function(a, b) { return a.hora < b.hora ? 1 : -1; });

  return {
    ventasBrutas:    _r2(ventasBrutas),
    ventasNetas:     _r2(ventasBrutas),
    cobrado:         cobradoTotal,        // EFECTIVO + VIRTUAL (incluyendo partes de MIXTO)
    cobradoEfectivo: _r2(totalEfectivo),
    cobradoVirtual:  _r2(totalVirtual),
    creditoOtorgado: _r2(creditoOtorgado), // POR_COBRAR + CREDITO
    tickets:         noAnuladas.length,
    anulados:        anuladas.length,
    creditos:        aCredito.length,
    ticketPromedio:  noAnuladas.length > 0 ? _r2(ventasBrutas / noAnuladas.length) : 0,
    byDoc:           byDoc,
    byMetodo:        byMetodo,
    detalleIds:      detalleIds,
    detalleTickets:  detalleTickets
  };
}

function _calcularCostoVentas(fecha, detalleIds) {
  var detalle  = [];
  var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  try { detalle = _sheetToObjectsLocal(_abrirMeSheet('VENTAS_DETALLE')); } catch(e) {}

  // Margen default global para estimar costo de productos sin precioCosto.
  // Usa CONFIG_MOS clave 'finMargenDefault' (default 20% sobre venta).
  var defaultMargen = 20;
  try {
    var cfg = _sheetToObjects(getSheet('CONFIG_MOS')).find(function(r){ return r.clave === 'finMargenDefault'; });
    if (cfg && parseFloat(cfg.valor) >= 0 && parseFloat(cfg.valor) < 100) defaultMargen = parseFloat(cfg.valor);
  } catch(_){}

  // VENTAS_DETALLE no tiene fecha propia → filtrar por ID_Venta del día
  var items_dia = detalle.filter(function(d){ return detalleIds[String(d.ID_Venta || '')]; });

  var costoTotal      = 0;
  var costoReal       = 0;     // suma con precioCosto explícito
  var costoEstimado   = 0;     // suma con margen default
  var ingresoTotal    = 0;     // para calcular margen promedio
  var sinCostoSet     = {};    // skus únicos sin costo
  var unidades        = 0;
  var skusSet         = {};
  var bySkuMap        = {};

  items_dia.forEach(function(d) {
    var sku    = String(d.SKU || '');
    var nombre = String(d.Nombre || '');
    var cant   = parseFloat(d.Cantidad || 0);
    var precio = parseFloat(d.Precio || 0);
    var prod   = productos.find(function(p){ return p.skuBase === sku || p.codigoBarra === sku || p.idProducto === sku; });
    var costoUnitReal = prod ? parseFloat(prod.precioCosto || 0) : 0;

    // Si no hay precioCosto, estimar con margen default sobre venta
    var costoUnit;
    var esEstimado;
    if (costoUnitReal > 0) {
      costoUnit  = costoUnitReal;
      esEstimado = false;
    } else {
      costoUnit  = precio * (1 - defaultMargen / 100);  // costo = venta × (1 − m%)
      esEstimado = true;
      if (sku) sinCostoSet[sku] = true;
    }

    var costoLinea   = costoUnit * cant;
    var ingresoLinea = precio    * cant;
    costoTotal   += costoLinea;
    ingresoTotal += ingresoLinea;
    if (esEstimado) costoEstimado += costoLinea;
    else            costoReal     += costoLinea;
    unidades += cant;
    if (sku) skusSet[sku] = true;

    if (sku) {
      if (!bySkuMap[sku]) {
        bySkuMap[sku] = {
          sku: sku, nombre: nombre, cantidad: 0,
          precio: precio, costoUnit: costoUnit,
          esEstimado: esEstimado, sinCosto: esEstimado  // alias retro-compat
        };
      }
      bySkuMap[sku].cantidad += cant;
      if (!bySkuMap[sku].nombre && nombre) bySkuMap[sku].nombre = nombre;
    }
  });

  var detalleProductos = Object.keys(bySkuMap).map(function(k) {
    var p = bySkuMap[k];
    return {
      sku: p.sku, nombre: p.nombre,
      cantidad:   Math.round(p.cantidad * 100) / 100,
      precio:     p.precio,
      costoUnit:  Math.round(p.costoUnit * 100) / 100,
      costoTotal: _r2(p.costoUnit * p.cantidad),
      esEstimado: p.esEstimado,
      sinCosto:   p.sinCosto
    };
  }).sort(function(a, b) { return b.cantidad - a.cantidad; });

  // Margen promedio del día (usando costos mezclados real + estimado)
  var margenPromedioPct = ingresoTotal > 0
    ? Math.round(((ingresoTotal - costoTotal) / ingresoTotal) * 1000) / 10
    : 0;

  return {
    total:           _r2(costoTotal),
    totalReal:       _r2(costoReal),
    totalEstimado:   _r2(costoEstimado),
    items:           items_dia.length,
    sinCosto:        Object.keys(sinCostoSet),
    cantidadEstimados: Object.keys(sinCostoSet).length,
    unidades:        Math.round(unidades),
    skusDistintos:   Object.keys(skusSet).length,
    detalleProductos: detalleProductos,
    margenPromedioPct: margenPromedioPct,
    defaultMargenUsado: defaultMargen
  };
}

function _calcularPersonal(fecha) {
  var tz   = Session.getScriptTimeZone();
  var rows = _sheetToObjects(getSheet('JORNADAS'))
    .filter(function(r) {
      var f = r.fecha instanceof Date
        ? Utilities.formatDate(r.fecha, tz, 'yyyy-MM-dd')
        : String(r.fecha || '').substring(0, 10);
      if (f !== fecha) return false;
      // Filtrar jornadas legacy de MASTER/ADMINISTRADOR/MOS (no se les paga)
      var rol = String(r.rol || '').toUpperCase();
      var app = String(r.appOrigen || '');
      if (app === 'MOS' || rol === 'MASTER' || rol === 'ADMINISTRADOR' || rol === 'ADMIN') return false;
      return true;
    });

  // Deduplicar: mismo nombre puede aparecer por AUTO_VENTA + AUTO_CAJAS + manual.
  // Prioridad: MANUAL(0) > AUTO_CAJAS(1) > AUTO_VENTA(2) > AUTO_LOGIN(3)
  var prioridad = { 'MANUAL': 0, 'AUTO_CAJAS': 1, 'AUTO_VENTA': 2, 'AUTO_LOGIN': 3 };
  var seen = {};
  rows.forEach(function(r) {
    var key = String(r.nombre || '').trim().toLowerCase();
    if (!key) return;
    var p = prioridad[String(r.fuente || '')] !== undefined ? prioridad[String(r.fuente)] : 99;
    if (!seen[key] || p < seen[key].p) seen[key] = { r: r, p: p };
  });
  var deduped = Object.keys(seen).map(function(k) { return seen[k].r; });

  var total   = deduped.reduce(function(s, r){ return s + (parseFloat(r.montoJornal) || 0); }, 0);
  var detalle = deduped.map(function(r){
    return { idJornada: r.idJornada || '', nombre: r.nombre, rol: r.rol || '',
             zona: r.zona || '', monto: parseFloat(r.montoJornal) || 0, fuente: r.fuente || 'MANUAL' };
  });

  return { total: _r2(total), personas: deduped.length, detalle: detalle };
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
    creditos:       ing.creditos,
    ticketPromedio: ing.ticketPromedio,
    cobrado:        ing.cobrado,
    cobradoEfectivo: ing.cobradoEfectivo,
    cobradoVirtual:  ing.cobradoVirtual,
    creditoOtorgado: ing.creditoOtorgado,
    byDoc:          ing.byDoc,
    byMetodo:       ing.byMetodo,
    detalleTickets: ing.detalleTickets,
    // Costos
    costoVentas:        costoVentas,
    costoVentasReal:    cos.totalReal,
    costoVentasEstimado:cos.totalEstimado,
    itemsVendidos:      cos.items,
    unidadesVendidas:   cos.unidades,
    skusDistintos:      cos.skusDistintos,
    productosSinCosto:  cos.sinCosto,
    cantidadEstimados:  cos.cantidadEstimados,
    margenPromedioPct:  cos.margenPromedioPct,
    defaultMargenUsado: cos.defaultMargenUsado,
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
  var tz2   = Session.getScriptTimeZone();
  var data  = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    var fechaFila = data[i][1] instanceof Date
      ? Utilities.formatDate(data[i][1], tz2, 'yyyy-MM-dd')
      : String(data[i][1] || '').substring(0, 10);
    if (String(data[i][3]).toLowerCase() === nombre.toLowerCase() && fechaFila === fecha) return;
  }
  sheet.appendRow([
    _generateId('JOR'), fecha, '', nombre,
    rol || 'VENDEDOR', appOrigen || 'AUTO', '',
    parseFloat(montoJornal) || 0, '', 'AUTO',
    appOrigen === 'warehouseMos' ? 'AUTO_LOGIN' : 'AUTO_VENTA'
  ]);
}

// _sheetToObjectsLocal está definida en Conexiones.gs (compartida en el mismo proyecto GAS)

// ════════════════════════════════════════════════════════════
// SINCRONIZACIÓN AUTO: presencia detectada → JORNADA registrada
// ════════════════════════════════════════════════════════════
// Para cada personal activo:
//   - Si _estaPresente(p, fecha) === true (vendió, abrió caja, inició sesión WH)
//   - Y NO tiene una JORNADA en la fecha → crea una con monto = montoBase
// Idempotente: nunca duplica. Garantiza que finanzas, evaluaciones y liquidaciones
// vean el mismo conjunto de "personas que trabajaron hoy".
function _sincronizarJornadasAutoDelDia(fecha) {
  fecha = fecha || _hoy();
  var personal = _sheetToObjects(getSheet('PERSONAL_MASTER')).filter(function(p) {
    var ac = p.estado;
    var activo = (ac === undefined || ac === '' || ac === 1 || ac === '1' || ac === true);
    if (!activo) return false;
    // Excluir MASTER/ADMINISTRADOR y appOrigen=MOS (auditores, no se les paga jornada)
    if (typeof _esPersonalEvaluable === 'function') return _esPersonalEvaluable(p);
    return true;
  });

  // Cargar jornadas existentes del día (idempotencia por nombre)
  var sheet = getSheet('JORNADAS');
  var data  = sheet.getDataRange().getValues();
  var tz    = Session.getScriptTimeZone();
  var existentesPorNombre = {};
  for (var i = 1; i < data.length; i++) {
    var f = data[i][1] instanceof Date
      ? Utilities.formatDate(data[i][1], tz, 'yyyy-MM-dd')
      : String(data[i][1] || '').substring(0, 10);
    if (f !== fecha) continue;
    var n = String(data[i][3] || '').toLowerCase().trim();
    if (n) existentesPorNombre[n] = true;
  }

  var creadas = 0, errores = [];
  personal.forEach(function(p) {
    var nombreFull = (p.nombre + ' ' + (p.apellido || '')).trim();
    var nLow = nombreFull.toLowerCase().trim();
    if (!nLow) return;
    if (existentesPorNombre[nLow]) return;
    try {
      // _estaPresente vive en Evaluaciones.gs; mismo proyecto GAS lo expone.
      if (typeof _estaPresente !== 'function') return;
      if (!_estaPresente(p, fecha)) return;
      var montoBase = parseFloat(p.montoBase) || 0;
      var fuente    = p.appOrigen === 'warehouseMos' ? 'AUTO_LOGIN' : 'AUTO_VENTA';
      // Schema: idJornada | fecha | idPersonal | nombre | rol | appOrigen | zona | montoJornal | observacion | registradoPor | fuente
      sheet.appendRow([
        _generateId('JOR'),
        fecha,
        p.idPersonal || '',
        nombreFull,
        p.rol || '',
        p.appOrigen || '',
        '',                  // zona (vacía en sync auto)
        montoBase,
        'Sincronizado automático: presencia detectada',
        'AUTO',
        fuente
      ]);
      creadas++;
    } catch(eP) { errores.push({ nombre: nombreFull, error: eP.message }); }
  });
  return { creadas: creadas, errores: errores };
}
