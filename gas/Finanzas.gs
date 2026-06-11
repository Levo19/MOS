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
    // ⚡ Asegurar materialización LIQUIDACIONES_DIA antes de calcular personal.
    // Si fecha = hoy: throttle 60s (cron-style). Si fecha pasada: sólo si
    // explícitamente se pide refresh (params.forceLiqSync).
    try {
      var esHoy = (fecha === _hoy());
      if (esHoy) {
        var cache = CacheService.getScriptCache();
        var lastSync = cache.get('fin_ldia_sync_' + fecha);
        if (!lastSync) {
          _liqDiaSync(fecha);
          cache.put('fin_ldia_sync_' + fecha, '' + Date.now(), 60);
        }
      } else if (params && params.forceLiqSync) {
        _liqDiaSync(fecha);
      }
    } catch(eMat) { Logger.log('Sync LIQ_DIA: ' + eMat.message); }

    // Auto-sincronizar jornadas legacy (algunos flujos manuales aún las usan).
    // _calcularPersonal ya lee de LIQUIDACIONES_DIA, pero las jornadas siguen
    // existiendo para vetos/rehabilitaciones manuales.
    try { _sincronizarJornadasAutoDelDia(fecha); } catch(eS) { Logger.log('Sync jornadas: ' + eS.message); }
    var ingresos   = _calcularIngresos(fecha);
    var costos     = _calcularCostoVentas(fecha, ingresos.cobradosIds);
    var personal   = _calcularPersonal(fecha);
    var gastosList = _calcularGastos(fecha);

    // ── Ajuste de costo REAL del personal ──
    // _calcularPersonal devuelve solo el monto base (de JORNADAS). El costo
    // real incluye: + pago envasado + bono por meta − sanciones del día.
    // Cruzamos con getResumenTodosDia (que ya computa totalDia por persona)
    // para que utilidad neta, margen neto y "Gasto Personal" reflejen la
    // liquidación real, no solo los jornales.
    try {
      if (typeof getResumenTodosDia === 'function') {
        var rsm = getResumenTodosDia({ fecha: fecha });
        if (rsm && rsm.ok && Array.isArray(rsm.data)) {
          var byNombre = {};
          rsm.data.forEach(function(r){
            var n = String(r.nombre || '').toLowerCase().trim();
            if (n) byNombre[n] = r;
          });
          var totalReal = 0;
          (personal.detalle || []).forEach(function(p){
            if (p.vetada) return; // tombstones no cuentan
            var n = String(p.nombre || '').toLowerCase().trim();
            var r = byNombre[n];
            if (r && typeof r.totalDia === 'number') {
              p.monto = Math.round(r.totalDia * 100) / 100;
              p.montoBaseJornal = parseFloat(p.monto) || 0; // info
            }
            totalReal += parseFloat(p.monto) || 0;
          });
          personal.total = Math.round(totalReal * 100) / 100;
        }
      }
    } catch(eAj) { Logger.log('Ajuste personal real falló: ' + eAj.message); }

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
      var cos  = _calcularCostoVentas(f, ing.cobradosIds);  // solo cobrados — alinea margen con ventasNetas
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

// Veto de pago: marca la jornada como tombstone (fuente='ELIMINADA') con
// timestamp en observación con prefijo 'VETO_TS:<ISO>'. La auto-sync respeta
// este veto hasta que detecte actividad posterior al timestamp.
function eliminarJornada(params) {
  if (!params.idJornada) return { ok: false, error: 'Requiere idJornada' };
  var sheet = getSheet('JORNADAS');
  var data  = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === String(params.idJornada)) {
      // Columnas: 0=id 1=fecha 2=idPersonal 3=nombre 4=rol 5=appOrigen 6=zona
      //           7=montoJornal 8=observacion 9=registradoPor 10=fuente
      var rowNum = i + 1;
      var nowIso = new Date().toISOString();
      var actor  = String(params.actor || params.registradoPor || 'admin');
      sheet.getRange(rowNum, 8).setValue(0);
      sheet.getRange(rowNum, 9).setValue('VETO_TS:' + nowIso + ' · por ' + actor);
      sheet.getRange(rowNum, 11).setValue('ELIMINADA');
      return { ok: true, data: { vetoTs: nowIso, idJornada: params.idJornada } };
    }
  }
  return { ok: false, error: 'Jornada no encontrada' };
}

// Helper: extrae el ISO timestamp de la observación 'VETO_TS:<ISO> · por X'
function _parseVetoTs(obs) {
  if (!obs) return 0;
  var m = String(obs).match(/VETO_TS:([0-9T:.\-Z]+)/);
  if (!m) return 0;
  var t = new Date(m[1]).getTime();
  return isNaN(t) ? 0 : t;
}

// Rehabilita una jornada vetada: limpia el tombstone, restaura monto desde
// PERSONAL_MASTER (o monto provisto), reescribe fuente. Deja rastro en
// observación con prefijo 'REHAB_TS:<ISO> · por X' para auditoría.
function rehabilitarJornada(params) {
  if (!params.idJornada) return { ok: false, error: 'Requiere idJornada' };
  var sheet = getSheet('JORNADAS');
  var data  = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === String(params.idJornada)) {
      var rowNum = i + 1;
      // Si no está vetada, no hacer nada
      var fuenteActual = String(data[i][10] || '').toUpperCase();
      if (fuenteActual !== 'ELIMINADA') {
        return { ok: false, error: 'La jornada no está vetada' };
      }
      var nowIso = new Date().toISOString();
      var actor  = String(params.actor || params.registradoPor || 'admin');
      var nombre = String(data[i][3] || '');
      var idPersonal = String(data[i][2] || '');
      // Resolver monto: prioridad → params.monto → PERSONAL_MASTER.montoBase
      var monto = parseFloat(params.monto || 0);
      if (!monto || monto <= 0) {
        try {
          var pers = _sheetToObjects(getSheet('PERSONAL_MASTER'));
          var match = pers.find(function(p){
            if (idPersonal && String(p.idPersonal) === idPersonal) return true;
            return String(p.nombre || '').toLowerCase() === nombre.toLowerCase();
          });
          if (match) monto = parseFloat(match.montoBase || 0);
        } catch(_) {}
      }
      if (!monto || monto <= 0) monto = parseFloat(params.montoDefault || 0);
      sheet.getRange(rowNum, 8).setValue(monto);
      // Mantener rastro: REHAB_TS reemplaza VETO_TS
      sheet.getRange(rowNum, 9).setValue('REHAB_TS:' + nowIso + ' · por ' + actor);
      // Restaurar fuente — preferir 'MANUAL' (admin la rehabilitó)
      sheet.getRange(rowNum, 11).setValue('MANUAL');
      return { ok: true, data: { rehabTs: nowIso, idJornada: params.idJornada, monto: monto } };
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
      // [fix C3] propagar el borrado a la sombra. Sin esto el gasto queda HUÉRFANO en
      // mos.gastos (el sync es solo-upsert) y getFinanzasRango (flip) sobre-cuenta gastos
      // de forma permanente. Best-effort: Sheets es la verdad; si falla se loguea.
      try { _sbDelete('mos.gastos', { id_gasto: String(params.idGasto) }); }
      catch (e) { Logger.log('eliminarGasto: _sbDelete mos.gastos falló: ' + e); }
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

  // ⚠ Definiciones selladas (FormaPago):
  //   EFECTIVO/VIRTUAL/MIXTO = dinero recibido (cobrado real)
  //   POR_COBRAR             = vendedor emitió, pendiente de cajero (cobro futuro inmediato)
  //   CREDITO                = admin aprobó cobro futuro formal (deuda)
  //   ANULADO                = ticket descartado, no cuenta
  var fp = function(v){ return String(v.FormaPago || '').toUpperCase(); };
  var anuladas    = del_dia.filter(function(v){ return fp(v) === 'ANULADO'; });
  var noAnuladas  = del_dia.filter(function(v){ return fp(v) !== 'ANULADO'; });
  var cobrados    = noAnuladas.filter(function(v) {
    var m = fp(v);
    return m !== 'POR_COBRAR' && m !== 'CREDITO';
  });
  var porCobrarLs = noAnuladas.filter(function(v){ return fp(v) === 'POR_COBRAR'; });
  var creditoLs   = noAnuladas.filter(function(v){ return fp(v) === 'CREDITO'; });

  // Ventas brutas (devengado): todo lo facturado del día menos anulados
  var ventasBrutas = noAnuladas.reduce(function(s, v){ return s + (parseFloat(v.Total) || 0); }, 0);

  // Desglose por método (cobrados) + cantidades pendientes
  var totalEfectivo = 0, totalVirtual = 0, totalMixto = 0;
  cobrados.forEach(function(v) {
    var t = parseFloat(v.Total) || 0;
    var m = fp(v);
    var r = _parseFormaPagoFin(v.FormaPago, t);
    totalEfectivo += r.efe;
    totalVirtual  += r.vir;
    if (m.indexOf('MIXTO') === 0) totalMixto += t;
  });
  var porCobrarMonto = porCobrarLs.reduce(function(s, v){ return s + (parseFloat(v.Total) || 0); }, 0);
  var creditoMonto   = creditoLs.reduce(function(s, v){ return s + (parseFloat(v.Total) || 0); }, 0);

  // ✅ ventasNetas = SOLO COBRADO REAL (regla del negocio).
  // Aplica a Margen Bruto, Neto, Contribución, Break-Even, Tendencia 7d, etc.
  var cobradoTotal = _r2(totalEfectivo + totalVirtual);

  // Desglose por tipo de documento (sobre TODO no anulado)
  var byDoc = {};
  noAnuladas.forEach(function(v) {
    var t = String(v.Tipo_Doc || v.tipoDoc || 'NOTA_DE_VENTA');
    byDoc[t] = _r2((byDoc[t] || 0) + (parseFloat(v.Total) || 0));
  });

  var byMetodo = {
    EFECTIVO:   _r2(totalEfectivo),
    VIRTUAL:    _r2(totalVirtual),
    MIXTO:      _r2(totalMixto),
    POR_COBRAR: _r2(porCobrarMonto),
    CREDITO:    _r2(creditoMonto)
  };

  // IDs para cruzar con DETALLE (incluye pendientes y créditos — sí vendió)
  var detalleIds = {};
  noAnuladas.forEach(function(v){ detalleIds[String(v.ID_Venta || '')] = true; });

  // IDs SOLO de cobrados (EFE/VIR/MIXTO). Útil para calcular el costo de
  // ventas en sintonía con "ventasNetas" (que es solo lo cobrado). Antes
  // el costo se calculaba sobre todas las no-anuladas (incluyendo
  // POR_COBRAR y CRÉDITO), produciendo márgenes aparentes menores al
  // estimado del 15%.
  var cobradosIds = {};
  cobrados.forEach(function(v){ cobradosIds[String(v.ID_Venta || '')] = true; });

  // Detalle individual de cada ticket: estado distingue 4 valores
  var detalleTickets = del_dia.map(function(v) {
    var f = String(v.Fecha || '');
    var m = fp(v);
    var estadoDerivado = m === 'ANULADO'    ? 'ANULADO'
                       : m === 'POR_COBRAR' ? 'POR_COBRAR'
                       : m === 'CREDITO'    ? 'CREDITO'
                       : 'COBRADO';
    return {
      idVenta:     String(v.ID_Venta || ''),
      total:       parseFloat(v.Total) || 0,
      tipoDoc:     String(v.Tipo_Doc || v.tipoDoc || 'NOTA_DE_VENTA'),
      formaPago:   String(v.FormaPago || v.metodo || 'EFECTIVO'),
      estado:      estadoDerivado,
      vendedor:    String(v.Vendedor || ''),
      correlativo: String(v.Correlativo || ''),
      cliente:     String(v.Cliente_Nombre || ''),
      clienteDoc:  String(v.Cliente_Doc || ''),
      hora:        f.length >= 16 ? f.substring(11, 16) : f.substring(0, 16)
    };
  }).sort(function(a, b) { return a.hora < b.hora ? 1 : -1; });

  return {
    // Cifras principales (regla "ventas netas = solo cobrado real")
    ventasNetas:     cobradoTotal,        // ✅ EFE + VIR + MIX (incluye partes de MIXTO)
    ventasBrutas:    _r2(ventasBrutas),   // referencia: todo lo facturado (sin anulado)
    cobrado:         cobradoTotal,        // alias de ventasNetas para claridad
    cobradoEfectivo: _r2(totalEfectivo),
    cobradoVirtual:  _r2(totalVirtual),
    cobradoMixto:    _r2(totalMixto),

    // Pendientes separados (no suman a ventasNetas)
    porCobrarTotal:  _r2(porCobrarMonto),
    creditoTotal:    _r2(creditoMonto),
    // Compat: campo viejo `creditoOtorgado` = suma de los dos pendientes (para callers legacy)
    creditoOtorgado: _r2(porCobrarMonto + creditoMonto),

    // Conteos
    tickets:         cobrados.length,        // solo cobrados (los que generaron cash)
    ticketsTotales:  noAnuladas.length,      // todos los no anulados
    porCobrar:       porCobrarLs.length,
    creditos:        creditoLs.length,
    anulados:        anuladas.length,
    ticketPromedio:  cobrados.length > 0 ? _r2(cobradoTotal / cobrados.length) : 0,

    byDoc:           byDoc,
    byMetodo:        byMetodo,
    detalleIds:      detalleIds,
    cobradosIds:     cobradosIds,
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

  // ════════════════════════════════════════════════════════════════
  // [v2.41.80] AGRUPACIÓN POR skuBase (clave canónica única)
  // ════════════════════════════════════════════════════════════════
  // El idProducto (IDPRO0001708) es solo un id técnico de fila.
  // La VERDADERA clave es skuBase: todas las presentaciones del mismo
  // producto comparten skuBase (ej: LEV009 para Ajinomoto).
  //
  // Estructura típica:
  //   skuBase=LEV009
  //     ├─ canónico  · factor=1  · precioCosto=13.20
  //     ├─ pres 10UN · factor=10 · precioCosto=0 (heredado de canónico)
  //     └─ pres 18UN · factor=18 · precioCosto=0 (heredado de canónico)
  //
  // Regla de cálculo:
  //   1. Agrupar todas las ventas por skuBase
  //   2. Cantidad agrupada = Σ(cant_línea × factor_línea) → uds base
  //   3. Costo unitario = precioCosto del canónico (factor=1)
  //   4. Costo total agrupado = cantidad × costoUnitario
  function _norm(s) { return String(s || '').trim().toUpperCase(); }
  var idxPorId  = {};
  var idxPorCod = {};
  var idxPorSku = {};         // primer producto con ese skuBase (cualquiera)
  var gruposPorSku = {};       // skuBase → { canonico, productos[] }
  productos.forEach(function(p) {
    var id  = _norm(p.idProducto);
    var cod = _norm(p.codigoBarra);
    var sku = _norm(p.skuBase);
    if (id)  idxPorId[id]   = p;
    if (cod) idxPorCod[cod] = p;
    if (sku) {
      if (!idxPorSku[sku]) idxPorSku[sku] = p;
      if (!gruposPorSku[sku]) gruposPorSku[sku] = { canonico: null, productos: [] };
      gruposPorSku[sku].productos.push(p);
      // El canónico es la fila con factor=1 (o factor vacío → 1)
      var f = parseFloat(p.factorConversion) || 1;
      if (f === 1 && !gruposPorSku[sku].canonico) {
        gruposPorSku[sku].canonico = p;
      }
    }
  });
  // Fallback: si un grupo no tiene canónico con factor=1, usar el primero
  Object.keys(gruposPorSku).forEach(function(k) {
    var g = gruposPorSku[k];
    if (!g.canonico && g.productos.length) g.canonico = g.productos[0];
  });

  var costoTotal      = 0;
  var costoReal       = 0;
  var costoEstimado   = 0;
  var ingresoTotal    = 0;
  var unidadesBaseTotal = 0;
  var sinCostoSet     = {};
  var bySkuMap        = {};

  items_dia.forEach(function(d) {
    var skuLinea = String(d.SKU || '');
    var nombre   = String(d.Nombre || '');
    var cant     = parseFloat(d.Cantidad || 0);
    var precio   = parseFloat(d.Precio || 0);
    var skuN     = _norm(skuLinea);
    var codN     = _norm(d.Cod_Barras || d.codBarras || '');

    // Lookup producto vendido: idProducto → codigoBarra → skuBase
    var prod = idxPorId[skuN] || idxPorCod[skuN] || idxPorCod[codN] || idxPorSku[skuN] || null;

    var factor, grupoSku, canonico = null;
    if (prod) {
      factor   = parseFloat(prod.factorConversion) || 1;
      grupoSku = _norm(prod.skuBase);
      canonico = gruposPorSku[grupoSku] ? gruposPorSku[grupoSku].canonico : prod;
    } else {
      // Sin match en PRODUCTOS_MASTER → fallback: usa SKU de línea como clave
      factor = 1;
      grupoSku = skuN || codN || _norm(nombre).substring(0, 30);
    }

    // Costo del CANÓNICO (S/13.20 para Ajinomoto) — fuente de verdad
    var costoCanonicoUnit = canonico ? (parseFloat(canonico.precioCosto || 0) || 0) : 0;

    // Unidades base de esta línea = cant_línea × factor
    var unidadesBase = cant * factor;
    var ingresoLinea = precio * cant;

    var costoLinea, esEstimado;
    if (costoCanonicoUnit > 0) {
      costoLinea  = unidadesBase * costoCanonicoUnit;
      esEstimado  = false;
    } else {
      // Sin costo canónico → estimar al margen default sobre venta
      costoLinea = ingresoLinea * (1 - defaultMargen / 100);
      esEstimado = true;
      sinCostoSet[grupoSku] = true;
    }

    costoTotal        += costoLinea;
    ingresoTotal      += ingresoLinea;
    unidadesBaseTotal += unidadesBase;
    if (esEstimado) costoEstimado += costoLinea;
    else            costoReal     += costoLinea;

    // ── AGRUPAR POR skuBase (no por SKU técnico de la línea) ──
    var clave = grupoSku;
    if (!bySkuMap[clave]) {
      bySkuMap[clave] = {
        sku:               clave,           // skuBase canónico (LEV009)
        nombre:            canonico ? canonico.descripcion : nombre,
        cantidad:          0,                // suma de UNIDADES BASE
        cantPresentaciones: 0,                // suma de cantidades de línea
        ingreso:           0,                // suma de ingresos
        costoUnit:         costoCanonicoUnit, // costo canónico (sin factor)
        esEstimado:        esEstimado,
        sinCosto:          esEstimado,
        codigoCanonico:    canonico ? canonico.codigoBarra : '',
        precioCanonico:    canonico ? parseFloat(canonico.precioVenta || 0) : 0
      };
    }
    bySkuMap[clave].cantidad           += unidadesBase;
    bySkuMap[clave].cantPresentaciones += cant;
    bySkuMap[clave].ingreso            += ingresoLinea;
    // Si alguna línea del grupo es estimada → el grupo entero queda "mixto"
    if (esEstimado) {
      bySkuMap[clave].esEstimado = true;
      bySkuMap[clave].sinCosto   = true;
    }
  });

  var detalleProductos = Object.keys(bySkuMap).map(function(k) {
    var p = bySkuMap[k];
    return {
      sku:        p.sku,                                  // skuBase canónico
      nombre:     p.nombre,
      cantidad:   Math.round(p.cantidad * 100) / 100,     // unidades base
      cantPresent:Math.round(p.cantPresentaciones * 100) / 100,
      precio:     p.cantidad > 0 ? _r2(p.ingreso / p.cantidad) : 0,  // promedio por uds base
      costoUnit:  _r2(p.costoUnit),                       // canonico.precioCosto
      costoTotal: _r2(p.costoUnit * p.cantidad),          // qty × costo canónico
      esEstimado: p.esEstimado,
      sinCosto:   p.sinCosto,
      codigoCanonico: p.codigoCanonico,
      precioCanonico: p.precioCanonico
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
    // [v2.41.80] unidades en BASE (cant × factor) — refleja uds reales movidas
    unidades:        Math.round(unidadesBaseTotal),
    // SKUs distintos = grupos canónicos (skuBase únicos), no SKUs de línea
    skusDistintos:   Object.keys(bySkuMap).length,
    detalleProductos: detalleProductos,
    margenPromedioPct: margenPromedioPct,
    defaultMargenUsado: defaultMargen
  };
}

function _calcularPersonal(fecha) {
  var tz = Session.getScriptTimeZone();

  // ════════════════════════════════════════════════════════════════
  // FUENTE PRIMARIA: LIQUIDACIONES_DIA (tabla materializada)
  // ════════════════════════════════════════════════════════════════
  // Antes esto leía JORNADAS y dependía de _sincronizarJornadasAutoDelDia
  // para crear filas. Eso fallaba silenciosamente y la card mostraba sólo
  // gente con jornada manual o ya escrita. Ahora leemos directo de la
  // tabla materializada que ya tiene todos los presentes (alimentada
  // por _liqDiaSync cada 60s desde getLiquidacionesPendientesDia, +
  // forzado al inicio de getFinanzasDia).
  //
  // JORNADAS queda como hoja secundaria SÓLO para detectar VETOS
  // (rows con fuente=ELIMINADA por nombre) — ahí vive el toggle 💸.

  // 1) Cargar PERSONAL_MASTER para cross-check de roles admin/excluidos.
  //    REGLA: solo indexar por nombre solo si el master NO tiene apellido.
  //    Si tiene apellido → indexar SOLO por nombre+apellido. Esto evita el
  //    falso positivo donde "javier" vendedor real era excluido porque
  //    "Javier Vasquez" admin matcheaba por primer nombre.
  var personalMaster = _sheetToObjects(getSheet('PERSONAL_MASTER'));
  var personalByNombre = {};
  personalMaster.forEach(function(p) {
    var nombreLow = String(p.nombre || '').trim().toLowerCase();
    var apellLow  = String(p.apellido || '').trim().toLowerCase();
    if (!nombreLow) return;
    if (apellLow) {
      // Tiene apellido → matching seguro requiere nombre+apellido
      personalByNombre[nombreLow + ' ' + apellLow] = p;
    } else {
      // Sin apellido → indexar por nombre solo es legítimo (ej. virtuales)
      personalByNombre[nombreLow] = p;
    }
  });

  function _esRolValido(rol) {
    var r = String(rol || '').toUpperCase();
    return r === 'ALMACENERO' || r === 'ENVASADOR' || r === 'OPERADOR'
        || r === 'CAJERO'     || r === 'VENDEDOR';
  }
  function _esExcluido(rolM, appM) {
    if (String(appM || '') === 'MOS') return true;
    var r = String(rolM || '').toUpperCase();
    if (r === 'MASTER' || r === 'ADMINISTRADOR' || r === 'ADMIN') return true;
    if (r && !_esRolValido(r)) return true;
    return false;
  }

  // 2) Leer tombstones de JORNADAS por nombre+fecha (para detectar vetos)
  //    Se preserva nombre del veto + idJornada para que el botón 💵
  //    Rehabilitar siga funcionando.
  var tombstonesByNombre = {};
  var activasByNombre = {};
  try {
    _sheetToObjects(getSheet('JORNADAS')).forEach(function(j) {
      var f = j.fecha instanceof Date
        ? Utilities.formatDate(j.fecha, tz, 'yyyy-MM-dd')
        : String(j.fecha || '').substring(0, 10);
      if (f !== fecha) return;
      var k = String(j.nombre || '').trim().toLowerCase();
      if (!k) return;
      var fuente = String(j.fuente || '').toUpperCase();
      if (fuente === 'ELIMINADA') {
        // Quedarse con el último tombstone si hay varios
        var prev = tombstonesByNombre[k];
        var prevTs = prev ? (_parseVetoTs(prev.observacion) || 0) : 0;
        var thisTs = _parseVetoTs(j.observacion) || 0;
        if (!prev || thisTs > prevTs) tombstonesByNombre[k] = j;
      } else {
        activasByNombre[k] = j;
      }
    });
  } catch(eJ) { Logger.log('Lectura JORNADAS para tombstones: ' + eJ.message); }

  // 3) Leer LIQUIDACIONES_DIA filtrado por fecha (fuente de verdad)
  var ldiaRows = [];
  try {
    var ldiaSh = _liqDiaGetSheet();
    ldiaRows = _sheetToObjects(ldiaSh).filter(function(r) {
      var f = r.fecha instanceof Date
        ? Utilities.formatDate(r.fecha, tz, 'yyyy-MM-dd')
        : String(r.fecha || '').substring(0, 10);
      if (f !== fecha) return false;
      var presente = (r.presente === true) || (String(r.presente).toLowerCase() === 'true');
      return presente;
    });
  } catch(eL) { Logger.log('Lectura LIQUIDACIONES_DIA: ' + eL.message); }

  // 4) Helpers de resolución
  function _resolverRol(nombre, rolRaw) {
    var k = String(nombre || '').trim().toLowerCase();
    var pm = personalByNombre[k];
    if (pm && pm.rol) return String(pm.rol).toUpperCase();
    return String(rolRaw || '').toUpperCase();
  }

  // 5) Armar detalle desde LIQUIDACIONES_DIA + cruzar con tombstones
  var procesados = {};
  var total = 0;
  var detalle = [];
  var personasPagadas = 0;

  ldiaRows.forEach(function(r) {
    var nombre = String(r.nombre || '').trim();
    var key = nombre.toLowerCase();
    if (!key || procesados[key]) return;
    procesados[key] = true;

    // Cross-check: excluir admins/MOS aunque hayan caído en la tabla
    var pm = personalByNombre[key];
    if (pm && _esExcluido(pm.rol, pm.appOrigen)) return;

    var rolFinal = _resolverRol(nombre, r.rol);
    var appFinal = String(r.appOrigen || (pm ? pm.appOrigen : ''));

    // [v2.41.46] ÚNICA fuente de verdad: LIQUIDACIONES_DIA.estado.
    // Tombstones de JORNADAS son legacy (pre-LIQUIDACIONES_DIA) y solo
    // se usan para idJornada/vetoObs si la fila está VETADA.
    var liqEstado = String(r.estado || 'PENDIENTE').toUpperCase();
    var esVetada = (liqEstado === 'VETADA');
    var tomb = tombstonesByNombre[key];

    if (esVetada) {
      detalle.push({
        idJornada:  tomb ? (tomb.idJornada || '') : '',
        idPersonal: String(r.idPersonal || ''),
        nombre:     nombre,
        rol:        rolFinal,
        zona:       tomb ? String(tomb.zona || '') : '',
        appOrigen:  appFinal,
        monto:      0,
        fuente:     'ELIMINADA',
        vetada:     true,
        vetoTs:     tomb ? (_parseVetoTs(tomb.observacion) || 0) : 0,
        vetoObs:    tomb ? String(tomb.observacion || '') : '',
        presente:   true,
        liqEstado:  liqEstado
      });
    } else {
      // PENDIENTE / PAGADA — persona presente activa (ignorar tombstone legacy)
      var jornAct = activasByNombre[key];
      var idJornada = jornAct ? (jornAct.idJornada || '') : '';
      var monto = parseFloat(r.totalDia) || 0;
      if (!monto || monto <= 0) monto = parseFloat(r.montoBase) || 0;

      detalle.push({
        idJornada:  idJornada,
        idPersonal: String(r.idPersonal || ''),
        nombre:     nombre,
        rol:        rolFinal,
        zona:       jornAct ? String(jornAct.zona || '') : '',
        appOrigen:  appFinal,
        monto:      monto,
        fuente:     jornAct ? String(jornAct.fuente || 'AUTO') : 'AUTO_VENTA',
        vetada:     false,
        presente:   true,
        liqEstado:  liqEstado
      });
      total += monto;
      personasPagadas++;
    }
  });

  // 6) Tombstones HUÉRFANOS — vetados que ya no aparecen en LIQUIDACIONES_DIA
  //    (ej. user vetado retroactivamente sin actividad ese día). Igual los
  //    mostramos para auditoría visual.
  Object.keys(tombstonesByNombre).forEach(function(key) {
    if (procesados[key]) return;
    procesados[key] = true;
    var tomb = tombstonesByNombre[key];
    var pm = personalByNombre[key];
    if (pm && _esExcluido(pm.rol, pm.appOrigen)) return;
    detalle.push({
      idJornada:  tomb.idJornada || '',
      idPersonal: '',
      nombre:     String(tomb.nombre || ''),
      rol:        _resolverRol(tomb.nombre, tomb.rol),
      zona:       String(tomb.zona || ''),
      appOrigen:  String(tomb.appOrigen || (pm ? pm.appOrigen : '')),
      monto:      0,
      fuente:     'ELIMINADA',
      vetada:     true,
      vetoTs:     _parseVetoTs(tomb.observacion) || 0,
      vetoObs:    String(tomb.observacion || ''),
      presente:   false
    });
  });

  return { total: _r2(total), personas: personasPagadas, detalle: detalle };
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
  var idxSku    = hdrs.indexOf('skuBase');
  var idxCod    = hdrs.indexOf('codigoBarra');
  var idxId     = hdrs.indexOf('idProducto');
  var idxCosto  = hdrs.indexOf('precioCosto');
  var idxFactor = hdrs.indexOf('factorConversion');

  if (idxCosto < 0) return { ok: false, error: 'Columna precioCosto no encontrada en PRODUCTOS_MASTER' };

  // [v2.41.80] Buscar siempre el CANÓNICO (fila con factor=1) cuando el match
  // viene por skuBase. Las presentaciones NO deben tener precioCosto propio —
  // el costo lo hereda del canónico vía factorConversion en el cálculo.
  // Prioridad de matching:
  //   1. idProducto exacto → actualiza esa fila puntual (override directo)
  //   2. codigoBarra exacto → actualiza esa fila (caso código de barras real)
  //   3. skuBase + factor=1 → el canónico del grupo (caso común)
  var rowCanonico = -1;
  var rowExacto   = -1;
  for (var i = 1; i < data.length; i++) {
    if (idxId >= 0 && String(data[i][idxId]) === sku) { rowExacto = i; break; }
    if (idxCod >= 0 && String(data[i][idxCod]) === sku && rowExacto < 0) { rowExacto = i; }
    if (idxSku >= 0 && String(data[i][idxSku]) === sku) {
      var f = idxFactor >= 0 ? (parseFloat(data[i][idxFactor]) || 1) : 1;
      if (f === 1 && rowCanonico < 0) rowCanonico = i;
    }
  }
  var rowTarget = rowExacto >= 0 ? rowExacto : rowCanonico;
  if (rowTarget < 0) return { ok: false, error: 'Producto no encontrado: ' + sku };
  sheet.getRange(rowTarget + 1, idxCosto + 1).setValue(costo);
  return { ok: true, fila: rowTarget + 1 };
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
  // Reusa getResumenTodosDia: ya devuelve a todos los presentes evaluables del día
  // con su montoBase resuelto (real para personal en MASTER, plantilla genérica
  // para virtuales detectados en VENTAS_CABECERA). Esto garantiza que la jornada
  // se cree con el monto CORRECTO, no con S/ 0 cuando el master tiene montoBase=0.
  if (typeof getResumenTodosDia !== 'function') return { creadas: 0 };
  var rsm = getResumenTodosDia({ fecha: fecha });
  if (!rsm || !rsm.ok || !Array.isArray(rsm.data)) return { creadas: 0 };
  var presentes = rsm.data.filter(function(r){ return r && r.presente; });

  // ── Cargar jornadas existentes del día (idempotencia por nombre) ──
  // Tombstones (fuente=ELIMINADA) son DEFINITIVOS para ese día: aunque la persona
  // vuelva a operar después del veto, NO se le crea nueva jornada. El veto vale
  // todo el día. Si master quiere "rehabilitar", debe hacerlo manualmente.
  var sheet = getSheet('JORNADAS');
  var data  = sheet.getDataRange().getValues();
  var tz    = Session.getScriptTimeZone();
  var bloqueadasPorNombre = {}; // activas + tombstones (no recrear nunca)
  for (var i = 1; i < data.length; i++) {
    var f = data[i][1] instanceof Date
      ? Utilities.formatDate(data[i][1], tz, 'yyyy-MM-dd')
      : String(data[i][1] || '').substring(0, 10);
    if (f !== fecha) continue;
    var n = String(data[i][3] || '').toLowerCase().trim();
    if (!n) continue;
    bloqueadasPorNombre[n] = true;
  }

  var creadas = 0, errores = [];
  presentes.forEach(function(r) {
    var nombre = String(r.nombre || '').trim();
    var nLow   = nombre.toLowerCase();
    if (!nLow) return;
    if (bloqueadasPorNombre[nLow]) return; // ya hay jornada (activa o tombstone)
    try {
      var montoBase = parseFloat(r.montoBase) || 0;
      var fuente    = r.appOrigen === 'warehouseMos' ? 'AUTO_LOGIN' : 'AUTO_VENTA';
      var idPersonal = String(r.idPersonal || '');
      var idPersonalFinal = idPersonal.indexOf('MEX:') === 0 ? '' : idPersonal;
      var obs = 'Sincronizado automático: presencia detectada';
      sheet.appendRow([
        _generateId('JOR'),
        fecha,
        idPersonalFinal,
        nombre,
        r.rol || '',
        r.appOrigen || '',
        '',
        montoBase,
        obs,
        'AUTO',
        fuente
      ]);
      creadas++;
    } catch(eP) { errores.push({ nombre: nombre, error: eP.message }); }
  });
  return { creadas: creadas, errores: errores };
}

// Devuelve { nombreLow: timestampMsMasReciente } combinando VENTAS_CABECERA + SESIONES
// para la fecha dada. Usado por _sincronizarJornadasAutoDelDia para auto-rehab.
function _ultimaActividadPorNombre(fecha, tz) {
  var out = {};
  function _bumpTs(nombre, ts) {
    if (!nombre || !ts) return;
    var k = String(nombre).toLowerCase().trim();
    if (!out[k] || ts > out[k]) out[k] = ts;
  }
  // VENTAS_CABECERA (col 1=Fecha, col 2=Vendedor)
  try {
    var v = _abrirMeSheet('VENTAS_CABECERA');
    if (v) {
      var vd = v.getDataRange().getValues();
      for (var rv = 1; rv < vd.length; rv++) {
        var fr = vd[rv][1];
        var fStr;
        if (fr instanceof Date) fStr = Utilities.formatDate(fr, tz, 'yyyy-MM-dd');
        else fStr = String(fr || '').substring(0, 10);
        if (fStr !== fecha) continue;
        var ts = fr instanceof Date ? fr.getTime() : new Date(fr).getTime();
        if (isNaN(ts)) ts = 0;
        _bumpTs(vd[rv][2], ts);
      }
    }
  } catch(e) { Logger.log('ultActividad VENTAS: ' + e.message); }
  // SESIONES WH (col 1=idPersonal, col 2=fechaInicio, col 3=horaInicio)
  // Para resolver nombre del idPersonal, usar PERSONAL_MASTER.
  try {
    var s = _abrirWhSheet('SESIONES');
    if (s) {
      var sd = s.getDataRange().getValues();
      var personal = _sheetToObjects(getSheet('PERSONAL_MASTER'));
      var nombrePorId = {};
      personal.forEach(function(p){ nombrePorId[String(p.idPersonal)] = p.nombre; });
      for (var rs = 1; rs < sd.length; rs++) {
        var fs = sd[rs][2];
        var fsStr = fs instanceof Date ? Utilities.formatDate(fs, tz, 'yyyy-MM-dd') : String(fs || '').substring(0, 10);
        if (fsStr !== fecha) continue;
        var idP = String(sd[rs][1] || '');
        var nombreP = nombrePorId[idP];
        // hora puede venir aparte; si tenemos fs Date+ hora separada, combinar
        var ts = 0;
        var hi = sd[rs][3];
        if (fs instanceof Date) {
          ts = fs.getTime();
          if (hi instanceof Date) {
            ts += (hi.getHours() * 3600 + hi.getMinutes() * 60 + hi.getSeconds()) * 1000;
          }
        } else if (typeof fs === 'string' && hi) {
          ts = new Date(fsStr + 'T' + hi).getTime();
        }
        if (!isNaN(ts) && ts > 0) _bumpTs(nombreP, ts);
      }
    }
  } catch(e) { Logger.log('ultActividad SESIONES: ' + e.message); }
  return out;
}
