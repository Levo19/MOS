// ============================================================
// ProyectoMOS — DeviceState.gs
//
// [v2.42.06] Snapshot remoto de sesión por deviceId. Capa final de
// resiliencia: si la PWA de ME/WH pierde localStorage Y IndexedDB
// (escenario raro pero posible: limpiar datos, reinstalar app), el
// cliente puede recuperar su config + caja_activa consultando MOS.
//
// Cliente PWA llama:
//   - POST {action:'syncDeviceState', deviceId, payload} → guarda
//   - GET  ?action=getDeviceState&deviceId=X        → recupera
//
// El snapshot se actualiza cada vez que ME guarda algo crítico en
// localStorage (config completada, abrir caja, retoma, etc.).
// Persiste en hoja DEVICE_STATE — se autocrea si no existe.
// ============================================================

var DEVICE_STATE_HEADERS = [
  'deviceId', 'app', 'vendedor', 'zona', 'idCaja', 'monto',
  'estacionCodigo', 'estacionNombre', 'printNodeId',
  'configJson', 'cajaActivaJson',
  'fechaSesion', 'lastSync', 'lastFromIp'
];

function _garantizarHojaDeviceState() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName('DEVICE_STATE');
  if (!sh) {
    sh = ss.insertSheet('DEVICE_STATE');
    sh.getRange(1, 1, 1, DEVICE_STATE_HEADERS.length).setValues([DEVICE_STATE_HEADERS]);
    sh.setFrozenRows(1);
    // Forzar texto en deviceId y printNodeId para preservar ceros iniciales
    try {
      sh.getRange(2, 1, sh.getMaxRows() - 1, 1).setNumberFormat('@');
      sh.getRange(2, 9, sh.getMaxRows() - 1, 1).setNumberFormat('@');
    } catch(_){}
  }
  return sh;
}

// ─────────────────────────────────────────────────────────────
// POST: syncDeviceState — el cliente llama después de cambiar
// localStorage. Idempotente: actualiza la fila por deviceId o
// la crea si no existe.
// payload esperado:
//   {
//     deviceId: string,
//     app: 'ME' | 'WH',
//     config: { vendedor, zona, estacion, esCajero, completado },
//     cajaActiva: { idCaja, monto, fecha } | null,
//     fechaSesion: string (toDateString)
//   }
// ─────────────────────────────────────────────────────────────
function syncDeviceState(params) {
  if (!params || !params.deviceId) return { ok: false, error: 'deviceId requerido' };
  var deviceId = String(params.deviceId).trim();
  if (!deviceId) return { ok: false, error: 'deviceId vacío' };

  var lock = LockService.getScriptLock();
  try { lock.waitLock(10000); }
  catch(eL) { return { ok: false, error: 'LOCK_TIMEOUT' }; }

  try {
    var sh = _garantizarHojaDeviceState();
    var data = sh.getDataRange().getValues();
    var hdrs = data[0];
    var iId  = hdrs.indexOf('deviceId');
    if (iId < 0) iId = 0;
    var filaExistente = -1;
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][iId]) === deviceId) { filaExistente = i + 1; break; }
    }
    var cfg = params.config || {};
    var ca  = params.cajaActiva || {};
    var nuevoRow = [
      deviceId,
      String(params.app || 'ME'),
      String(cfg.vendedor || ''),
      String(cfg.zona || ''),
      String(ca.idCaja || ''),
      ca.monto !== undefined ? parseFloat(ca.monto) || 0 : '',
      String((cfg.estacion && cfg.estacion.Estacion_Codigo) || ''),
      String((cfg.estacion && cfg.estacion.Estacion_Nombre) || ''),
      String((cfg.estacion && cfg.estacion.PrintNode_ID) || ''),
      JSON.stringify(cfg).substring(0, 2000),
      JSON.stringify(ca).substring(0, 1000),
      String(params.fechaSesion || ''),
      new Date().toISOString(),
      String(params.fromIp || '')
    ];
    if (filaExistente > 0) {
      sh.getRange(filaExistente, 1, 1, nuevoRow.length).setValues([nuevoRow]);
    } else {
      sh.appendRow(nuevoRow);
    }
    return { ok: true, data: { saved: true, deviceId: deviceId, isUpdate: filaExistente > 0 } };
  } catch(e) {
    return { ok: false, error: 'syncDeviceState: ' + (e && e.message || e) };
  } finally {
    try { lock.releaseLock(); } catch(_){}
  }
}

// ─────────────────────────────────────────────────────────────
// GET: getDeviceState — el cliente PWA pregunta su snapshot al
// arrancar (si localStorage y IDB están vacíos). Devuelve null
// si nunca se sincronizó.
// ─────────────────────────────────────────────────────────────
function getDeviceState(deviceId) {
  if (!deviceId) return { ok: false, error: 'deviceId requerido' };
  var deviceIdStr = String(deviceId).trim();
  try {
    var sh = _garantizarHojaDeviceState();
    var data = sh.getDataRange().getValues();
    var hdrs = data[0];
    var iId          = hdrs.indexOf('deviceId');           if (iId < 0) iId = 0;
    var iApp         = hdrs.indexOf('app');                if (iApp < 0) iApp = 1;
    var iVend        = hdrs.indexOf('vendedor');           if (iVend < 0) iVend = 2;
    var iZona        = hdrs.indexOf('zona');               if (iZona < 0) iZona = 3;
    var iIdCaja      = hdrs.indexOf('idCaja');             if (iIdCaja < 0) iIdCaja = 4;
    var iMonto       = hdrs.indexOf('monto');              if (iMonto < 0) iMonto = 5;
    var iEstCod      = hdrs.indexOf('estacionCodigo');     if (iEstCod < 0) iEstCod = 6;
    var iEstNom      = hdrs.indexOf('estacionNombre');     if (iEstNom < 0) iEstNom = 7;
    var iPN          = hdrs.indexOf('printNodeId');        if (iPN < 0) iPN = 8;
    var iCfgJ        = hdrs.indexOf('configJson');         if (iCfgJ < 0) iCfgJ = 9;
    var iCaJ         = hdrs.indexOf('cajaActivaJson');     if (iCaJ < 0) iCaJ = 10;
    var iFSes        = hdrs.indexOf('fechaSesion');        if (iFSes < 0) iFSes = 11;
    var iLast        = hdrs.indexOf('lastSync');           if (iLast < 0) iLast = 12;
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][iId]) !== deviceIdStr) continue;
      var cfg = null, ca = null;
      try { cfg = JSON.parse(data[i][iCfgJ] || 'null'); } catch(_){}
      try { ca  = JSON.parse(data[i][iCaJ]  || 'null'); } catch(_){}
      return { ok: true, data: {
        encontrado:    true,
        deviceId:      deviceIdStr,
        app:           String(data[i][iApp] || ''),
        vendedor:      String(data[i][iVend] || ''),
        zona:          String(data[i][iZona] || ''),
        idCaja:        String(data[i][iIdCaja] || ''),
        monto:         parseFloat(data[i][iMonto]) || 0,
        estacion: {
          Estacion_Codigo: String(data[i][iEstCod] || ''),
          Estacion_Nombre: String(data[i][iEstNom] || ''),
          PrintNode_ID:    String(data[i][iPN] || '')
        },
        config:        cfg,
        cajaActiva:    ca,
        fechaSesion:   String(data[i][iFSes] || ''),
        lastSync:      String(data[i][iLast] || '')
      }};
    }
    return { ok: true, data: { encontrado: false, deviceId: deviceIdStr } };
  } catch(e) {
    return { ok: false, error: 'getDeviceState: ' + (e && e.message || e) };
  }
}
