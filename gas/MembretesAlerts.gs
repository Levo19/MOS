// ============================================================
// ProyectoMOS — MembretesAlerts.gs   [v2.43.125]
// ============================================================
//
// Sistema de alertas de precios cambiados para membretes ME.
// Cuando un precio canónico se publica, se inserta una fila en
// MEMBRETES_ME_PENDIENTES con estado=PENDIENTE.
//
// El ME muestra badge con count(PENDIENTE) y modal con lista.
// Operador elige:
//   - Imprimir seleccionados → marca IMPRESO → dispara lote membrete
//   - Ignorar seleccionados  → marca IGNORADO (no reaparecen)
//   - Cerrar                 → quedan PENDIENTE (siguen alertando)
//
// Trigger diario expira a 7 días → estado EXPIRADO (no aparece en badge).

var MEMBRETES_ME_PENDIENTES_HEADERS = [
  'idAlerta', 'fechaCambio', 'fechaUltimoUpdate',
  'idProducto', 'skuBase', 'codigoBarra', 'descripcion',
  'precioAnterior', 'precioNuevo',
  'usuario', 'estado', 'fechaExpira', 'fechaImpreso', 'idLote'
];

function setupMembretesMePendientes() {
  var ss = SpreadsheetApp.openById(_getMasterSsId());
  var sheet = ss.getSheetByName('MEMBRETES_ME_PENDIENTES');
  if (!sheet) {
    sheet = ss.insertSheet('MEMBRETES_ME_PENDIENTES');
    sheet.getRange(1, 1, 1, MEMBRETES_ME_PENDIENTES_HEADERS.length)
         .setValues([MEMBRETES_ME_PENDIENTES_HEADERS])
         .setFontWeight('bold').setBackground('#1e293b').setFontColor('#fbbf24');
    sheet.setFrozenRows(1);
    // codigoBarra como string para preservar ceros
    sheet.getRange('F:F').setNumberFormat('@');
    sheet.getRange('A:A').setNumberFormat('@');
    Logger.log('[setupMembretesMePendientes] sheet creada');
  } else {
    var existing = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    var missing = MEMBRETES_ME_PENDIENTES_HEADERS.filter(function(h) { return existing.indexOf(h) < 0; });
    if (missing.length) {
      var startCol = sheet.getLastColumn() + 1;
      sheet.getRange(1, startCol, 1, missing.length).setValues([missing]);
      Logger.log('[setupMembretesMePendientes] columnas agregadas: ' + missing.join(', '));
    }
  }
  return { ok: true, headers: MEMBRETES_ME_PENDIENTES_HEADERS };
}

function _getSheetMembretesMePendientes() {
  var ss = SpreadsheetApp.openById(_getMasterSsId());
  var sheet = ss.getSheetByName('MEMBRETES_ME_PENDIENTES');
  if (!sheet) {
    setupMembretesMePendientes();
    sheet = ss.getSheetByName('MEMBRETES_ME_PENDIENTES');
  }
  return sheet;
}

// Helper para obtener el ID del spreadsheet master (MOS).
function _getMasterSsId() {
  // Si SS_ID ya existe como global de MOS, usarlo; sino, ActiveSpreadsheet.
  try {
    if (typeof SS_ID !== 'undefined' && SS_ID) return SS_ID;
  } catch(_) {}
  return SpreadsheetApp.getActiveSpreadsheet().getId();
}

// ────────────────────────────────────────────────────────────────────
// _hookPrecioCambiadoParaMembreteME — llamar desde publicarPrecio()
// después del éxito del actualizarProductoMaster.
//
// params: { idProducto, codigoBarra, skuBase, descripcion,
//           precioAnterior, precioNuevo, usuario }
// ────────────────────────────────────────────────────────────────────
function _hookPrecioCambiadoParaMembreteME(params) {
  try {
    var precioAnt = parseFloat(params.precioAnterior) || 0;
    var precioNvo = parseFloat(params.precioNuevo)    || 0;
    // No alertar si el precio efectivamente NO cambió
    if (precioAnt === precioNvo) return { ok: true, skipped: 'precio_igual' };
    var sheet = _getSheetMembretesMePendientes();
    var now = new Date();
    var nowIso = now.toISOString();
    var expira = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000).toISOString();
    var idAlerta = 'MEM' + now.getTime() + Math.random().toString(36).substr(2, 4).toUpperCase();

    var fila = MEMBRETES_ME_PENDIENTES_HEADERS.map(function(h) {
      var v = ({
        idAlerta:         idAlerta,
        fechaCambio:      nowIso,
        fechaUltimoUpdate: nowIso,
        idProducto:       String(params.idProducto || ''),
        skuBase:          String(params.skuBase || ''),
        codigoBarra:      String(params.codigoBarra || ''),
        descripcion:      String(params.descripcion || ''),
        precioAnterior:   precioAnt,
        precioNuevo:      precioNvo,
        usuario:          String(params.usuario || ''),
        estado:           'PENDIENTE',
        fechaExpira:      expira,
        fechaImpreso:     '',
        idLote:           ''
      })[h];
      return v === undefined ? '' : v;
    });
    sheet.appendRow(fila);
    return { ok: true, idAlerta: idAlerta };
  } catch(e) {
    Logger.log('[_hookPrecioCambiadoParaMembreteME] error: ' + e.message);
    return { ok: false, error: e.message };
  }
}

// ────────────────────────────────────────────────────────────────────
// getMembretesMePendientes — para badge + modal en ME
// ────────────────────────────────────────────────────────────────────
function getMembretesMePendientes(params) {
  try {
    params = params || {};
    var sheet = _getSheetMembretesMePendientes();
    if (sheet.getLastRow() < 2) return { ok: true, data: { items: [], count: 0 } };
    var range = sheet.getRange(2, 1, sheet.getLastRow() - 1, MEMBRETES_ME_PENDIENTES_HEADERS.length);
    var values = range.getValues();
    var items = values.map(function(row) {
      var obj = {};
      MEMBRETES_ME_PENDIENTES_HEADERS.forEach(function(h, i) { obj[h] = row[i]; });
      return obj;
    }).filter(function(it) {
      return String(it.estado || '').toUpperCase() === 'PENDIENTE';
    });
    if (params.limit) items = items.slice(0, parseInt(params.limit));
    return { ok: true, data: { items: items, count: items.length } };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

// ────────────────────────────────────────────────────────────────────
// marcarMembreteMeImpreso — tras crear lote membrete, marcar alertas
//
// params: { idAlertas: [<id>, ...], idLote: '<idLote>' }
// ────────────────────────────────────────────────────────────────────
function marcarMembreteMeImpreso(params) {
  try {
    params = params || {};
    var ids = Array.isArray(params.idAlertas) ? params.idAlertas : [];
    if (ids.length === 0) return { ok: false, error: 'idAlertas requerido' };
    var idLote = String(params.idLote || '');
    var sheet = _getSheetMembretesMePendientes();
    var data = sheet.getRange(2, 1, sheet.getLastRow() - 1, MEMBRETES_ME_PENDIENTES_HEADERS.length).getValues();
    var nowIso = new Date().toISOString();
    var actualizados = 0;
    var colEstado    = MEMBRETES_ME_PENDIENTES_HEADERS.indexOf('estado')          + 1;
    var colImpreso   = MEMBRETES_ME_PENDIENTES_HEADERS.indexOf('fechaImpreso')    + 1;
    var colLote      = MEMBRETES_ME_PENDIENTES_HEADERS.indexOf('idLote')          + 1;
    var colUpdate    = MEMBRETES_ME_PENDIENTES_HEADERS.indexOf('fechaUltimoUpdate') + 1;
    for (var i = 0; i < data.length; i++) {
      var rowIdx = i + 2;
      if (ids.indexOf(String(data[i][0])) >= 0) {
        sheet.getRange(rowIdx, colEstado).setValue('IMPRESO');
        sheet.getRange(rowIdx, colImpreso).setValue(nowIso);
        sheet.getRange(rowIdx, colLote).setValue(idLote);
        sheet.getRange(rowIdx, colUpdate).setValue(nowIso);
        actualizados++;
      }
    }
    return { ok: true, actualizados: actualizados };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

// ────────────────────────────────────────────────────────────────────
// ignorarMembreteMe — operario decide no imprimir este cambio puntual
// ────────────────────────────────────────────────────────────────────
function ignorarMembreteMe(params) {
  try {
    params = params || {};
    var ids = Array.isArray(params.idAlertas) ? params.idAlertas : [];
    if (ids.length === 0) return { ok: false, error: 'idAlertas requerido' };
    var sheet = _getSheetMembretesMePendientes();
    var data = sheet.getRange(2, 1, sheet.getLastRow() - 1, MEMBRETES_ME_PENDIENTES_HEADERS.length).getValues();
    var nowIso = new Date().toISOString();
    var actualizados = 0;
    var colEstado = MEMBRETES_ME_PENDIENTES_HEADERS.indexOf('estado')            + 1;
    var colUpdate = MEMBRETES_ME_PENDIENTES_HEADERS.indexOf('fechaUltimoUpdate') + 1;
    for (var i = 0; i < data.length; i++) {
      var rowIdx = i + 2;
      if (ids.indexOf(String(data[i][0])) >= 0) {
        sheet.getRange(rowIdx, colEstado).setValue('IGNORADO');
        sheet.getRange(rowIdx, colUpdate).setValue(nowIso);
        actualizados++;
      }
    }
    return { ok: true, actualizados: actualizados };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

// ────────────────────────────────────────────────────────────────────
// expirarMembretesMePendientes — trigger diario
// Marca como EXPIRADO los PENDIENTE con fechaExpira < hoy.
// ────────────────────────────────────────────────────────────────────
function expirarMembretesMePendientes() {
  try {
    var sheet = _getSheetMembretesMePendientes();
    if (sheet.getLastRow() < 2) return { ok: true, expirados: 0 };
    var data = sheet.getRange(2, 1, sheet.getLastRow() - 1, MEMBRETES_ME_PENDIENTES_HEADERS.length).getValues();
    var nowIso = new Date().toISOString();
    var colEstado     = MEMBRETES_ME_PENDIENTES_HEADERS.indexOf('estado')            + 1;
    var colUpdate     = MEMBRETES_ME_PENDIENTES_HEADERS.indexOf('fechaUltimoUpdate') + 1;
    var idxFechaExp   = MEMBRETES_ME_PENDIENTES_HEADERS.indexOf('fechaExpira');
    var idxEstado     = MEMBRETES_ME_PENDIENTES_HEADERS.indexOf('estado');
    var expirados = 0;
    for (var i = 0; i < data.length; i++) {
      var rowIdx = i + 2;
      var estado = String(data[i][idxEstado] || '').toUpperCase();
      var fechaExp = String(data[i][idxFechaExp] || '');
      if (estado === 'PENDIENTE' && fechaExp && fechaExp < nowIso) {
        sheet.getRange(rowIdx, colEstado).setValue('EXPIRADO');
        sheet.getRange(rowIdx, colUpdate).setValue(nowIso);
        expirados++;
      }
    }
    Logger.log('[expirarMembretesMePendientes] expirados: ' + expirados);
    return { ok: true, expirados: expirados };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

function instalarTriggerExpirarMembretes() {
  var TRG = 'expirarMembretesMePendientes';
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === TRG) ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger(TRG).timeBased().atHour(3).everyDays(1).create();
  Logger.log('[Trigger] ' + TRG + ' instalado · diario 3:00');
  return { ok: true };
}
