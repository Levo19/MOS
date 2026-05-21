// ============================================================
// MOS — CentroTributario.gs
// Módulo fiscal para admin/master. Centraliza:
//   - IGV a favor (recuperable de facturas de proveedores en WH)
//   - IGV a pagar (de CPE emitidos boletas/facturas en ME via NubeFact)
//   - Balance neto a pagar SUNAT por mes
//   - Renta estimada (régimen MYPE Tributario 1.5%)
//   - Estado de CPE pendientes/error/rechazados
//   - Histórico 12 meses
//
// Script Properties usadas:
//   ME_GAS_URL   — endpoint del GAS de MosExpress (ventas + NubeFact)
//   WH_GAS_URL   — endpoint del GAS de warehouseMos (guías con IGV recup)
// ============================================================

// Bridge a WH GAS (los endpoints viven en warehouseMos)
function _whBridgeGet(params) {
  var url = _getProp('WH_GAS_URL');
  if (!url) return { ok: false, error: 'WH_GAS_URL no configurado en Script Properties' };
  try {
    var qs = Object.keys(params || {}).map(function(k) {
      return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
    }).join('&');
    var sep = url.indexOf('?') >= 0 ? '&' : '?';
    var res = UrlFetchApp.fetch(url + sep + qs, { followRedirects: true, muteHttpExceptions: true });
    var txt = res.getContentText();
    try { return JSON.parse(txt); }
    catch(_) { return { ok: false, error: 'Respuesta WH no JSON: ' + txt.substring(0, 200) }; }
  } catch(e) {
    return { ok: false, error: 'Bridge WH error: ' + e.message };
  }
}

// ============================================================
// tribResumenMes — KPI hero del Centro Tributario.
// Cruza:
//   - WH: igvFavorMes (IGV recuperable de boletas de proveedores OCR'd)
//   - ME: ventas de boletas/facturas del mes con NF_Estado
//   - calcula balance neto + renta estimada (MYPE 1.5%)
// ============================================================
function tribResumenMes(params) {
  params = params || {};
  var hoy = new Date();
  var mes = parseInt(params.mes, 10) || (hoy.getMonth() + 1);
  var anio = parseInt(params.anio, 10) || hoy.getFullYear();

  // 1. IGV a favor desde WH
  var igvFavorData = _whBridgeGet({ action: 'igvFavorMes', mes: mes, anio: anio });
  var igvFavor = (igvFavorData && igvFavorData.ok && igvFavorData.data) ? igvFavorData.data : null;

  // 2. Ventas + CPE desde ME
  var ventasData = _meBridgeGet({ accion: 'tributario_ventas_mes', mes: mes, anio: anio });
  var ventas = (ventasData && ventasData.status === 'success') ? ventasData : null;

  // 3. Cálculos
  var totalIGVFavor   = igvFavor ? igvFavor.totalIGVFavor : 0;
  var totalIGVEmitido = ventas ? (parseFloat(ventas.totalIGVEmitido) || 0) : 0;
  var totalVentas     = ventas ? (parseFloat(ventas.totalVentas) || 0) : 0;
  var balanceNetoIGV  = Math.round((totalIGVEmitido - totalIGVFavor) * 100) / 100;
  // MYPE Tributario: 1.5% mensual sobre ingresos netos
  var rentaMensual    = Math.round(totalVentas * 0.015 * 100) / 100;

  // 4. Período del mes (para progress bar)
  var ultimoDia = new Date(anio, mes, 0).getDate();
  var diaActual = (hoy.getFullYear() === anio && (hoy.getMonth() + 1) === mes) ? hoy.getDate() : ultimoDia;
  var pctMes = Math.round((diaActual / ultimoDia) * 100);

  // 5. Fecha de declaración mensual (mes siguiente, día depende del último dígito RUC)
  var ruc = PropertiesService.getScriptProperties().getProperty('NUBEFACT_RUC') || '';
  var ultDig = ruc.charAt(ruc.length - 1);
  var diaVence = ({ '0': 14, '1': 15, '2': 16, '3': 17, '4': 18, '5': 21, '6': 22, '7': 23, '8': 14, '9': 15 })[ultDig] || 18;
  var fechaVence = new Date(anio, mes, diaVence); // mes=1-12, new Date espera 0-11 pero +1 mes natural
  var diasParaVencer = Math.ceil((fechaVence.getTime() - hoy.getTime()) / 86400000);

  return {
    ok: true,
    data: {
      mes: mes, anio: anio,
      // KPIs principales
      igvFavor:       totalIGVFavor,
      igvEmitido:     totalIGVEmitido,
      balanceNetoIGV: balanceNetoIGV,
      totalVentas:    totalVentas,
      rentaMensual:   rentaMensual,
      // Período
      diaActual: diaActual,
      ultimoDia: ultimoDia,
      pctMes:    pctMes,
      // Detalles WH
      guiasMes:           igvFavor ? igvFavor.totalGuias : 0,
      guiasConIGV:        igvFavor ? igvFavor.totalGuiasConIGV : 0,
      guiasSinFoto:       igvFavor ? igvFavor.totalGuiasSinFoto : 0,
      guiasSinIGV:        igvFavor ? igvFavor.totalGuiasSinIGV : 0,
      guiasIlegibles:     igvFavor ? igvFavor.totalGuiasIlegibles : 0,
      // Detalles ME
      cpeEmitidos:    ventas ? (ventas.cpeEmitidos || 0) : 0,
      cpePendientes:  ventas ? (ventas.cpePendientes || 0) : 0,
      cpeErrores:     ventas ? (ventas.cpeErrores || 0) : 0,
      cpeAnulados:    ventas ? (ventas.cpeAnulados || 0) : 0,
      cpeTotal:       ventas ? (ventas.cpeTotal || 0) : 0,
      // Declaración
      fechaVencimiento: fechaVence.toISOString(),
      diasParaVencer:   diasParaVencer
    }
  };
}

// ============================================================
// tribIGVFavorMes — lista detallada de guías con OCR (proxy a WH)
// ============================================================
function tribIGVFavorMes(params) {
  return _whBridgeGet({ action: 'igvFavorMes', mes: params.mes, anio: params.anio });
}

// ============================================================
// tribIGVEmitidoMes — lista detallada de CPE del mes (proxy a ME)
// ============================================================
function tribIGVEmitidoMes(params) {
  return _meBridgeGet({ accion: 'tributario_cpe_mes', mes: params.mes, anio: params.anio });
}

// ============================================================
// tribReintentarCPE — re-consulta o re-emite un CPE (admin con PIN)
// ============================================================
function tribReintentarCPE(params) {
  if (!params.idVenta) return { ok: false, error: 'idVenta requerido' };
  return _meBridgeGet({ accion: 'tributario_reintentar_cpe', idVenta: params.idVenta });
}

// ============================================================
// tribReprocesarOCR — re-analiza foto de una guía (admin con PIN)
// ============================================================
function tribReprocesarOCR(params) {
  if (!params.idGuia) return { ok: false, error: 'idGuia requerido' };
  return _whBridgeGet({ action: 'reprocesarOCRGuia', idGuia: params.idGuia });
}

// ============================================================
// [v2.41.94] tribOCRMasivo — corre OCR sobre TODAS las guías sin OCR
// del mes especificado. Útil para arranque del módulo (procesar fotos
// históricas) o mensual.
// params: { mes, anio, soloSinProcesar: bool (default true) }
// ============================================================
function tribOCRMasivo(params) {
  return _whBridgeGet({
    action: 'procesarOCRMasivoMes',
    mes: params.mes,
    anio: params.anio || params.año,
    soloSinProcesar: params.soloSinProcesar !== false
  });
}

// ============================================================
// tribHistorico12meses — datos para chart histórico
// ============================================================
function tribHistorico12meses() {
  var hoy = new Date();
  var resultados = [];
  for (var i = 11; i >= 0; i--) {
    var d = new Date(hoy.getFullYear(), hoy.getMonth() - i, 1);
    var resp = tribResumenMes({ mes: d.getMonth() + 1, anio: d.getFullYear() });
    if (resp.ok && resp.data) {
      resultados.push({
        mes: d.getMonth() + 1, anio: d.getFullYear(),
        label: ['ene','feb','mar','abr','may','jun','jul','ago','sep','oct','nov','dic'][d.getMonth()],
        igvFavor:    resp.data.igvFavor,
        igvEmitido:  resp.data.igvEmitido,
        balance:     resp.data.balanceNetoIGV,
        ventas:      resp.data.totalVentas,
        renta:       resp.data.rentaMensual
      });
    }
  }
  return { ok: true, data: resultados };
}

// ============================================================
// tribLimpiarVentasHuerfanas — invoca el cleanup en ME (admin PIN)
// ============================================================
function tribLimpiarVentasHuerfanas() {
  return _meBridgeGet({ accion: 'tributario_limpiar_huerfanas' });
}

// ============================================================
// tribReconciliarCPEsPendientes — fuerza el cron de reconciliación NubeFact
// ============================================================
function tribReconciliarCPEsPendientes() {
  return _meBridgeGet({ accion: 'tributario_reconciliar' });
}

function _getProp(k) {
  return PropertiesService.getScriptProperties().getProperty(k);
}
