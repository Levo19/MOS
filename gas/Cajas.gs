// ============================================================
// ProyectoMOS — Cajas.gs
// Consulta el estado en tiempo real de todas las cajas de ME.
// ============================================================

function getCierresCaja(params) {
  var ss       = getSpreadsheet();
  var conSheet = ss.getSheetByName('CONEXIONES');
  var meGasUrl = '';
  if (conSheet) {
    var rows  = _sheetToObjects(conSheet);
    var meRow = rows.filter(function(r){
      return String(r.idApp) === 'mosExpress' ||
             String(r.nombre).toLowerCase().indexOf('mosexpress') >= 0;
    })[0];
    if (meRow) meGasUrl = String(meRow.gasUrl || '');
  }
  if (!meGasUrl) return { ok: false, error: 'ME_GAS_URL no configurada en CONEXIONES.' };

  try {
    var url  = meGasUrl + '?accion=estado_cajas';
    var resp = UrlFetchApp.fetch(url, { muteHttpExceptions: true, followRedirects: true });
    if (resp.getResponseCode() !== 200) return { ok: false, error: 'ME respondió HTTP ' + resp.getResponseCode() };

    var json = JSON.parse(resp.getContentText());
    if (json.status !== 'success') return { ok: false, error: json.mensaje || 'Error en ME' };

    // Agregar URL de reporte a cada caja cerrada
    json.cerradas.forEach(function(c) {
      c.urlReporte = meGasUrl + '?accion=ver_cierre&id_caja=' + encodeURIComponent(c.idCaja);
    });

    return { ok: true, data: { kpis: json.kpis, abiertas: json.abiertas,
             cerradas: json.cerradas, generadoEn: json.generadoEn } };
  } catch(err) {
    return { ok: false, error: err.message };
  }
}
