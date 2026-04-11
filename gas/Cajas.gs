// ============================================================
// ProyectoMOS — Cajas.gs
// Lee los cierres de caja desde MosExpress (vía ME_GAS_URL)
// y sirve la URL del reporte HTML para abrir en el navegador.
// ============================================================

function getCierresCaja(params) {
  // Obtener ME_GAS_URL desde CONEXIONES
  var ss       = getSpreadsheet();
  var conSheet = ss.getSheetByName('CONEXIONES');
  var meGasUrl = '';
  if (conSheet) {
    var rows = _sheetToObjects(conSheet);
    var meRow = rows.filter(function(r){ return String(r.idApp) === 'mosExpress' || String(r.nombre).toLowerCase().indexOf('mosexpress') >= 0; })[0];
    if (meRow) meGasUrl = String(meRow.gasUrl || '');
  }

  if (!meGasUrl) return { ok: false, error: 'ME_GAS_URL no configurada en CONEXIONES. Ejecuta setConexion con los datos de MosExpress.' };

  try {
    var url    = meGasUrl + '?accion=listar_cierres' + (params.zona ? '&zona=' + encodeURIComponent(params.zona) : '');
    var resp   = UrlFetchApp.fetch(url, { muteHttpExceptions: true, followRedirects: true });
    var code   = resp.getResponseCode();
    if (code !== 200) return { ok: false, error: 'ME respondió HTTP ' + code };

    var json = JSON.parse(resp.getContentText());
    if (json.status !== 'success') return { ok: false, error: json.mensaje || 'Error en ME' };

    // Agregar URL del reporte HTML a cada cierre
    json.data.forEach(function(c) {
      c.urlReporte = meGasUrl + '?accion=ver_cierre&id_caja=' + encodeURIComponent(c.idCaja);
    });

    return { ok: true, data: json.data, meGasUrl: meGasUrl };
  } catch(err) {
    return { ok: false, error: err.message };
  }
}
