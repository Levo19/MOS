// ============================================================
// ProyectoMOS — SeguridadAlerts.gs   [v2.43.129]
// ============================================================
//
// Sistema centralizado de alertas de seguridad para el admin.
//
// Sheet SEGURIDAD_ALERTAS:
//   idAlerta · tipo · idDispositivo · idPersonal · fecha · descripcion ·
//   prioridad · estado · revisada_por · revisada_en · datos_extra_json
//
// Tipos:
//   DISPOSITIVO_PENDIENTE      → nuevo dispositivo solicitando acceso
//   DISPOSITIVO_SUSPENDIDO_AUTO → inactividad >7 días
//   DESBLOQUEO_TEMPORAL        → admin usó desbloqueo emergencia
//   USUARIO_INACTIVO           → operador sin sesion >7d (sugerir limpieza)
//   EXTENSION_HORARIO_PENDIENTE → operador solicita extensión
//
// Estados:
//   PENDIENTE | REVISADA | DESCARTADA | EXPIRADA

var SEGURIDAD_ALERTAS_HEADERS = [
  'idAlerta', 'tipo', 'idDispositivo', 'idPersonal',
  'fecha', 'descripcion', 'prioridad', 'estado',
  'revisada_por', 'revisada_en', 'datos_extra_json'
];

function setupSeguridadAlertas() {
  var ss = SpreadsheetApp.openById(SS_ID);
  var sheet = ss.getSheetByName('SEGURIDAD_ALERTAS');
  if (!sheet) {
    sheet = ss.insertSheet('SEGURIDAD_ALERTAS');
    sheet.getRange(1, 1, 1, SEGURIDAD_ALERTAS_HEADERS.length)
         .setValues([SEGURIDAD_ALERTAS_HEADERS])
         .setFontWeight('bold').setBackground('#0f172a').setFontColor('#fca5a5');
    sheet.setFrozenRows(1);
    sheet.getRange('A:A').setNumberFormat('@');
    Logger.log('[setupSeguridadAlertas] sheet creada');
  } else {
    var existing = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    var missing = SEGURIDAD_ALERTAS_HEADERS.filter(function(h) { return existing.indexOf(h) < 0; });
    if (missing.length) {
      var startCol = sheet.getLastColumn() + 1;
      sheet.getRange(1, startCol, 1, missing.length).setValues([missing]);
      Logger.log('[setupSeguridadAlertas] cols agregadas: ' + missing.join(', '));
    }
  }
  return { ok: true };
}

function _getSheetSegAlertas() {
  var ss = SpreadsheetApp.openById(SS_ID);
  var sh = ss.getSheetByName('SEGURIDAD_ALERTAS');
  if (!sh) { setupSeguridadAlertas(); sh = ss.getSheetByName('SEGURIDAD_ALERTAS'); }
  return sh;
}

// [SF3] Crear alerta nueva (usado por hooks de otros endpoints)
function _crearAlertaSeg(tipo, params) {
  try {
    var sheet = _getSheetSegAlertas();
    var now = new Date().toISOString();
    var idAlerta = 'SEG' + new Date().getTime() + Math.random().toString(36).substr(2, 4).toUpperCase();
    var fila = SEGURIDAD_ALERTAS_HEADERS.map(function(h) {
      var v = ({
        idAlerta:         idAlerta,
        tipo:             String(tipo || ''),
        idDispositivo:    String((params && params.idDispositivo) || ''),
        idPersonal:       String((params && params.idPersonal) || ''),
        fecha:            now,
        descripcion:      String((params && params.descripcion) || ''),
        prioridad:        String((params && params.prioridad) || 'MEDIA'),
        estado:           'PENDIENTE',
        revisada_por:     '',
        revisada_en:      '',
        datos_extra_json: params && params.datosExtra ? JSON.stringify(params.datosExtra) : ''
      })[h];
      return v === undefined ? '' : v;
    });
    sheet.appendRow(fila);
    return { ok: true, idAlerta: idAlerta };
  } catch(e) {
    Logger.log('[_crearAlertaSeg] ' + e.message);
    return { ok: false, error: e.message };
  }
}

// [SF3] Diagnóstico del setup de seguridad — endpoint público
function diagnosticoSetupSeguridad() {
  var checks = [];
  // Check 1: Sheet SEGURIDAD_ALERTAS
  try {
    var sh = SpreadsheetApp.openById(SS_ID).getSheetByName('SEGURIDAD_ALERTAS');
    checks.push({ check: 'sheet_seguridad_alertas', ok: !!sh });
  } catch(_) { checks.push({ check: 'sheet_seguridad_alertas', ok: false }); }
  // Check 2: Trigger purgarDispositivosInactivos7d
  try {
    var triggers = ScriptApp.getProjectTriggers();
    var hayTrigger = triggers.some(function(t) {
      return t.getHandlerFunction() === 'purgarDispositivosInactivos7d';
    });
    checks.push({ check: 'trigger_purgar_inactivos', ok: hayTrigger });
  } catch(_) { checks.push({ check: 'trigger_purgar_inactivos', ok: false }); }
  // Check 3: WH_GAS_URL configurada en MOS (para invalidar cache)
  try {
    var url = PropertiesService.getScriptProperties().getProperty('WH_GAS_URL') || '';
    checks.push({ check: 'WH_GAS_URL_en_mos', ok: !!url, valor: url ? url.substring(0, 30) + '...' : '' });
  } catch(_) { checks.push({ check: 'WH_GAS_URL_en_mos', ok: false }); }
  // Check 4: Sheet CONFIG_HORARIOS_APPS
  try {
    var shH = SpreadsheetApp.openById(SS_ID).getSheetByName('CONFIG_HORARIOS_APPS');
    checks.push({ check: 'sheet_horarios_apps', ok: !!shH });
  } catch(_) { checks.push({ check: 'sheet_horarios_apps', ok: false }); }
  // Check 5: Columna horarioCustom en PERSONAL_MASTER
  try {
    var pSh = SpreadsheetApp.openById(SS_ID).getSheetByName('PERSONAL_MASTER');
    var phdrs = pSh.getRange(1, 1, 1, pSh.getLastColumn()).getValues()[0];
    checks.push({ check: 'columna_horarioCustom', ok: phdrs.indexOf('horarioCustom') >= 0 });
  } catch(_) { checks.push({ check: 'columna_horarioCustom', ok: false }); }
  // Check 6: Columnas nuevas en DISPOSITIVOS (Fecha_Caducidad, Desbloqueo_Temporal_Hasta)
  try {
    var dSh = SpreadsheetApp.openById(SS_ID).getSheetByName('DISPOSITIVOS');
    var dhdrs = dSh.getRange(1, 1, 1, dSh.getLastColumn()).getValues()[0];
    checks.push({ check: 'columna_fecha_caducidad',          ok: dhdrs.indexOf('Fecha_Caducidad') >= 0 });
    checks.push({ check: 'columna_desbloqueo_temporal',      ok: dhdrs.indexOf('Desbloqueo_Temporal_Hasta') >= 0 });
  } catch(_) {
    checks.push({ check: 'columna_fecha_caducidad', ok: false });
    checks.push({ check: 'columna_desbloqueo_temporal', ok: false });
  }
  var allOk = checks.every(function(c) { return c.ok; });
  return { ok: true, data: { allOk: allOk, checks: checks } };
}

// [v2.43.131] Helper: corre el diagnóstico y LOGUEA el resultado completo
// (el return de funciones no aparece en el "Registro de ejecución").
function verDiagnosticoSeguridad() {
  var r = diagnosticoSetupSeguridad();
  Logger.log('═══ DIAGNÓSTICO SEGURIDAD ═══');
  Logger.log('allOk: ' + (r.data && r.data.allOk));
  (r.data && r.data.checks || []).forEach(function(c) {
    Logger.log((c.ok ? '✅' : '❌') + ' ' + c.check + (c.valor ? ' [' + c.valor + ']' : ''));
  });
  Logger.log('═══════════════════════════════');
  return r;
}

function setupTodoSeguridad() {
  setupSeguridadAlertas();
  _garantizarColumnasDispositivosExtendidas();
  // [v2.43.130 FIX] Instalar TODOS los triggers necesarios automáticamente
  try { instalarTriggerPurgarDispositivos(); } catch(e) { Logger.log('purgar: ' + e.message); }
  try { instalarTriggerRevertirDesbloqueos(); } catch(e) { Logger.log('desbloq: ' + e.message); }
  try { instalarTriggerRevertirExtensiones(); } catch(e) { Logger.log('ext: ' + e.message); }
  try { instalarTriggerNotificacionesApertura(); } catch(e) { Logger.log('notifApert: ' + e.message); }
  return diagnosticoSetupSeguridad();
}

// Auto-añade Fecha_Caducidad + Desbloqueo_Temporal_Hasta a DISPOSITIVOS
function _garantizarColumnasDispositivosExtendidas() {
  var sheet = SpreadsheetApp.openById(SS_ID).getSheetByName('DISPOSITIVOS');
  if (!sheet) return;
  var hdrs = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  var needed = ['Fecha_Caducidad', 'Desbloqueo_Temporal_Hasta'];
  var missing = needed.filter(function(h) { return hdrs.indexOf(h) < 0; });
  if (missing.length) {
    var startCol = sheet.getLastColumn() + 1;
    sheet.getRange(1, startCol, 1, missing.length).setValues([missing]);
    Logger.log('[_garantizarColumnasDispositivosExtendidas] agregadas: ' + missing.join(', '));
  }
}

function instalarTriggerPurgarDispositivos() {
  var TRG = 'purgarDispositivosInactivos7d';
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === TRG) ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger(TRG).timeBased().atHour(2).everyDays(1).create();
  Logger.log('[Trigger] ' + TRG + ' instalado · diario 2:00');
  return { ok: true };
}

// ────────────────────────────────────────────────────────────────────
// Endpoint público: get alertas activas
// ────────────────────────────────────────────────────────────────────
function getSeguridadAlertas(params) {
  try {
    params = params || {};
    var sheet = _getSheetSegAlertas();
    if (sheet.getLastRow() < 2) {
      return { ok: true, data: { items: [], count: 0, porTipo: {} } };
    }
    var values = sheet.getRange(2, 1, sheet.getLastRow() - 1, SEGURIDAD_ALERTAS_HEADERS.length).getValues();
    var items = values.map(function(row) {
      var obj = {};
      SEGURIDAD_ALERTAS_HEADERS.forEach(function(h, i) { obj[h] = row[i]; });
      return obj;
    }).filter(function(it) { return String(it.estado || '').trim().toUpperCase() === 'PENDIENTE'; });
    if (params.tipo) items = items.filter(function(it) { return String(it.tipo) === String(params.tipo); });
    // Ordenar por fecha desc (más nuevas primero)
    items.sort(function(a, b) { return String(b.fecha).localeCompare(String(a.fecha)); });
    if (params.limit) items = items.slice(0, parseInt(params.limit));
    var porTipo = {};
    items.forEach(function(it) {
      var k = String(it.tipo || 'OTRO');
      porTipo[k] = (porTipo[k] || 0) + 1;
    });
    return { ok: true, data: { items: items, count: items.length, porTipo: porTipo } };
  } catch(e) { return { ok: false, error: e.message }; }
}

// ────────────────────────────────────────────────────────────────────
// Desbloqueo temporal de emergencia
// ────────────────────────────────────────────────────────────────────
function desbloquearTemporalDispositivo(params) {
  var _lock = LockService.getScriptLock();
  try { _lock.waitLock(15000); } catch(e) { return { ok: false, error: 'Sistema ocupado, reintenta' }; }
  try {
    if (!params.deviceId)   return { ok: false, error: 'deviceId requerido' };
    if (!params.claveAdmin) return { ok: false, error: 'claveAdmin requerida' };
    if (!params.razon)      return { ok: false, error: 'razón requerida' };
    var auth = verificarClaveAdmin({
      clave: params.claveAdmin, accion: 'DESBLOQUEO_TEMPORAL',
      refDocumento: params.deviceId, appOrigen: params.app || '',
      detalle: 'Desbloqueo temp: ' + String(params.razon).substring(0, 200)
    });
    if (!auth.ok) return auth;
    if (!auth.data || !auth.data.autorizado) {
      return { ok: true, data: { autorizado: false, error: auth.data?.error || 'Clave incorrecta' } };
    }
    var duracionHoras = parseFloat(params.duracionHoras) || 2;
    if (duracionHoras < 0.5 || duracionHoras > 12) {
      return { ok: false, error: 'duracionHoras debe estar entre 0.5 y 12' };
    }
    _garantizarColumnasDispositivosExtendidas();
    var sheet = SpreadsheetApp.openById(SS_ID).getSheetByName('DISPOSITIVOS');
    var data  = sheet.getDataRange().getValues();
    var hdrs  = data[0];
    var iId   = hdrs.indexOf('ID_Dispositivo');
    var iEst  = hdrs.indexOf('Estado');
    var iDT   = hdrs.indexOf('Desbloqueo_Temporal_Hasta');
    var hasta = new Date(Date.now() + duracionHoras * 60 * 60 * 1000);
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][iId]) !== params.deviceId) continue;
      sheet.getRange(i + 1, iEst + 1).setValue('ACTIVO');
      if (iDT >= 0) sheet.getRange(i + 1, iDT + 1).setValue(hasta.toISOString());
      _crearAlertaSeg('DESBLOQUEO_TEMPORAL', {
        idDispositivo: params.deviceId,
        descripcion: 'Desbloqueo temp ' + duracionHoras + 'h · razón: ' + String(params.razon).substring(0, 150),
        prioridad: 'ALTA',
        datosExtra: { hastaIso: hasta.toISOString(), autorizadoPor: auth.data.validadoPor, razon: params.razon }
      });
      try {
        if (typeof _enviarPushTodos === 'function') {
          _enviarPushTodos(
            '🚨 Desbloqueo TEMPORAL de dispositivo',
            'Hasta ' + Utilities.formatDate(hasta, Session.getScriptTimeZone(), 'HH:mm') + ' · ' + (auth.data.validadoPor || ''),
            { idNotif: 'MOS_DESBLOQUEO_TEMP', soloRolesMOS: true }
          );
        }
      } catch(_) {}
      return { ok: true, data: {
        autorizado: true,
        hasta: hasta.toISOString(),
        duracionHoras: duracionHoras,
        autorizadoPor: auth.data.validadoPor
      }};
    }
    return { ok: false, error: 'Dispositivo no encontrado' };
  } catch(e) { return { ok: false, error: e.message }; }
  finally { try { _lock.releaseLock(); } catch(_){} }
}

// Trigger horario: revierte desbloqueos temporales vencidos
function revertirDesbloqueosVencidos() {
  var _lock = LockService.getScriptLock();
  try { _lock.waitLock(15000); } catch(e) { return { ok: false, error: 'Sistema ocupado' }; }
  try {
    var sheet = SpreadsheetApp.openById(SS_ID).getSheetByName('DISPOSITIVOS');
    if (!sheet) return { ok: true, revertidos: 0 };
    var data = sheet.getDataRange().getValues();
    var hdrs = data[0];
    var iEst = hdrs.indexOf('Estado');
    var iDT  = hdrs.indexOf('Desbloqueo_Temporal_Hasta');
    var iSus = hdrs.indexOf('Suspendido_Desde');
    if (iDT < 0) return { ok: true, revertidos: 0 };
    var nowMs = Date.now();
    var nowIso = new Date(nowMs).toISOString();
    var rev = 0;
    for (var i = 1; i < data.length; i++) {
      var rawDT = data[i][iDT];
      if (!rawDT) continue;
      var hastaMs = 0;
      if (rawDT instanceof Date) hastaMs = rawDT.getTime();
      else { var d = new Date(rawDT); if (!isNaN(d.getTime())) hastaMs = d.getTime(); }
      if (!hastaMs || hastaMs > nowMs) continue;
      // [v2.43.130 FIX] Vencido → re-suspender + limpiar DT + setear Suspendido_Desde
      sheet.getRange(i + 1, iEst + 1).setValue('SUSPENDIDO');
      sheet.getRange(i + 1, iDT + 1).setValue('');
      if (iSus >= 0) sheet.getRange(i + 1, iSus + 1).setValue(nowIso);
      rev++;
    }
    return { ok: true, revertidos: rev };
  } catch(e) { return { ok: false, error: e.message }; }
  finally { try { _lock.releaseLock(); } catch(_){} }
}

function instalarTriggerRevertirDesbloqueos() {
  var TRG = 'revertirDesbloqueosVencidos';
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === TRG) ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger(TRG).timeBased().everyHours(1).create();
  Logger.log('[Trigger] ' + TRG + ' instalado · cada 1h');
  return { ok: true };
}

// ────────────────────────────────────────────────────────────────────
// Reactivar dispositivo suspendido (admin)
// ────────────────────────────────────────────────────────────────────
function reactivarDispositivoSuspendido(params) {
  var _lock = LockService.getScriptLock();
  try { _lock.waitLock(15000); } catch(e) { return { ok: false, error: 'Sistema ocupado' }; }
  try {
    if (!params.deviceId) return { ok: false, error: 'deviceId requerido' };
    // [v2.43.132 FIX] verificarClaveAdmin si viene clave (admin remoto desde MOS)
    if (params.claveAdmin) {
      var authR = verificarClaveAdmin({ clave: params.claveAdmin, accion: 'REACTIVAR_DISPOSITIVO', refDocumento: params.deviceId });
      if (!authR.ok) return authR;
      if (!authR.data || !authR.data.autorizado) {
        return { ok: true, data: { autorizado: false, error: (authR.data && authR.data.error) || 'Clave incorrecta' } };
      }
    }
    var sheet = SpreadsheetApp.openById(SS_ID).getSheetByName('DISPOSITIVOS');
    var data = sheet.getDataRange().getValues();
    var hdrs = data[0];
    var iId = hdrs.indexOf('ID_Dispositivo');
    var iEst = hdrs.indexOf('Estado');
    var iSus = hdrs.indexOf('Suspendido_Desde');
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][iId]) !== String(params.deviceId)) continue;
      sheet.getRange(i + 1, iEst + 1).setValue('ACTIVO');
      if (iSus >= 0) sheet.getRange(i + 1, iSus + 1).setValue('');
      return { ok: true };
    }
    return { ok: false, error: 'Dispositivo no encontrado' };
  } catch(e) { return { ok: false, error: e.message }; }
  finally { try { _lock.releaseLock(); } catch(_){} }
}

// ────────────────────────────────────────────────────────────────────
// Extensión de horario solicitada por operador
// ────────────────────────────────────────────────────────────────────
function solicitarExtensionHorario(params) {
  try {
    if (!params.idPersonal) return { ok: false, error: 'idPersonal requerido' };
    var minutos = parseInt(params.minutos) || 60;
    var motivo  = String(params.motivo || 'Sin motivo');
    var alerta = _crearAlertaSeg('EXTENSION_HORARIO_PENDIENTE', {
      idPersonal: params.idPersonal,
      descripcion: 'Solicita extensión ' + minutos + 'min · ' + motivo.substring(0, 100),
      prioridad: 'MEDIA',
      datosExtra: { minutos: minutos, motivo: motivo, solicitadoEn: new Date().toISOString() }
    });
    try {
      if (typeof _enviarPushTodos === 'function') {
        _enviarPushTodos(
          '⏰ Extensión de horario solicitada',
          minutos + ' min · motivo: ' + motivo.substring(0, 60),
          { idNotif: 'MOS_EXTENSION_PEND', soloRolesMOS: true }
        );
      }
    } catch(_) {}
    return { ok: true, data: { idAlerta: alerta.idAlerta, pendiente: true } };
  } catch(e) { return { ok: false, error: e.message }; }
}

// Aprueba la extensión y la aplica como horarioCustom temporal
function aprobarExtensionHorario(params) {
  var _lock = LockService.getScriptLock();
  try { _lock.waitLock(15000); } catch(e) { return { ok: false, error: 'Sistema ocupado' }; }
  try {
    if (!params.idAlerta) return { ok: false, error: 'idAlerta requerido' };
    // [v2.43.133 FIX] Clave admin REQUERIDA: aprobar una extensión muta horario;
    // no se puede confiar en params.aprobadoPor enviado por el cliente.
    if (!params.claveAdmin) return { ok: false, error: 'claveAdmin requerida para aprobar extensión' };
    var authE = verificarClaveAdmin({ clave: params.claveAdmin, accion: 'APROBAR_EXTENSION', refDocumento: params.idAlerta });
    if (!authE.ok) return authE;
    if (!authE.data || !authE.data.autorizado) {
      return { ok: true, data: { autorizado: false, error: (authE.data && authE.data.error) || 'Clave incorrecta' } };
    }
    var aprobadoPorReal = authE.data.validadoPor || 'admin';
    var sheet = _getSheetSegAlertas();
    var data = sheet.getDataRange().getValues();
    var hdrs = data[0];
    var iId = hdrs.indexOf('idAlerta');
    var iEst = hdrs.indexOf('estado');
    var iRev = hdrs.indexOf('revisada_por');
    var iRevTs = hdrs.indexOf('revisada_en');
    var iDx = hdrs.indexOf('datos_extra_json');
    var iIdP = hdrs.indexOf('idPersonal');
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][iId]) !== String(params.idAlerta)) continue;
      var idPersonal = String(data[i][iIdP] || '');
      var dx = {};
      try { dx = JSON.parse(data[i][iDx] || '{}'); } catch(_) {}
      var minutos = parseInt(dx.minutos) || 60;
      // Marcar como REVISADA
      sheet.getRange(i + 1, iEst + 1).setValue('REVISADA');
      sheet.getRange(i + 1, iRev + 1).setValue(aprobadoPorReal);
      sheet.getRange(i + 1, iRevTs + 1).setValue(new Date().toISOString());
      // Aplicar extensión usando extenderHorarioHoy (más abajo)
      var ext = extenderHorarioHoy({ idPersonal: idPersonal, minutos: minutos });
      // Notificar al operador
      try {
        _enviarPushSegmentado(idPersonal,
          '✅ Tu extensión fue aprobada',
          '+' + minutos + ' min para hoy. Refresca la app.');
      } catch(_) {}
      return { ok: true, data: { idPersonal: idPersonal, aplicada: ext.ok } };
    }
    return { ok: false, error: 'Alerta no encontrada' };
  } catch(e) { return { ok: false, error: e.message }; }
  finally { try { _lock.releaseLock(); } catch(_){} }
}

// Extiende el horario HOY. Dos modos:
//   A) Por USUARIO (params: idPersonal + minutos) → patch horarioCustom hoy
//   B) Por APP    (params: app + cierre + razon)  → patch CONFIG_HORARIOS_APPS hoy
// El trigger revertirExtensionesDiarias 00:01 quita ambos.
function extenderHorarioHoy(params) {
  try {
    // [v2.43.130 FIX] Modo APP: el admin extiende cierre global hasta HH:MM
    if (params.app && params.cierre && !params.idPersonal) {
      return _extenderHorarioHoyApp(params);
    }
    if (!params.idPersonal) return { ok: false, error: 'idPersonal o app+cierre requeridos' };
    var minutos = parseInt(params.minutos) || 60;
    var tz = Session.getScriptTimeZone();
    var hoy = new Date();
    var diaIdx = parseInt(Utilities.formatDate(hoy, tz, 'u'), 10);
    var diaKey = _HOR_DIAS[Math.max(0, Math.min(6, diaIdx - 1))];

    // [v2.43.130 FIX] No hardcodear app; permitir override desde params
    var appUsuario = String(params.app || 'warehouseMos');
    var res = resolverHorarioPersonal({ idPersonal: params.idPersonal, rol: '', app: appUsuario });
    var cierreActual = res && res.data ? res.data.cierre : null;
    if (!cierreActual) return { ok: false, error: 'No se pudo determinar el cierre actual' };
    // [v2.43.133 FIX] Validar formato HH:MM antes de split (evita NaN si cierreActual está corrupto)
    var matchCierre = String(cierreActual).match(/^(\d{1,2}):(\d{2})$/);
    if (!matchCierre) return { ok: false, error: 'Cierre actual corrupto: ' + cierreActual };
    var hh = parseInt(matchCierre[1], 10);
    var mm = parseInt(matchCierre[2], 10);
    var totalMin = hh * 60 + mm + minutos;
    var nuevoHH = Math.floor(totalMin / 60);
    var nuevoMM = totalMin % 60;
    if (nuevoHH >= 24) { nuevoHH = 23; nuevoMM = 59; }
    var nuevoCierre = String(nuevoHH).padStart(2, '0') + ':' + String(nuevoMM).padStart(2, '0');

    // Guardar como horarioCustom HOY (sobre el existente)
    var pSh = getSheet('PERSONAL_MASTER');
    var pd = pSh.getDataRange().getValues();
    var ph = pd[0];
    var iIdP = ph.indexOf('idPersonal');
    var iHC = ph.indexOf('horarioCustom');
    if (iHC < 0) {
      var newCol = ph.length + 1;
      pSh.getRange(1, newCol).setValue('horarioCustom');
      iHC = newCol - 1;
    }
    for (var i = 1; i < pd.length; i++) {
      if (String(pd[i][iIdP]) !== String(params.idPersonal)) continue;
      var hcExisting = {};
      try { hcExisting = pd[i][iHC] ? JSON.parse(pd[i][iHC]) : {}; } catch(_) {}
      var dias = (hcExisting.dias || {});
      // Reemplazar HOY
      dias[diaKey] = { activo: true, apertura: (res.data.apertura || '07:00'), cierre: nuevoCierre };
      hcExisting.activo = true;
      hcExisting.dias = dias;
      hcExisting.extensionHoy = { dia: diaKey, hasta: nuevoCierre, ts: new Date().toISOString() };
      pSh.getRange(i + 1, iHC + 1).setValue(JSON.stringify(hcExisting));
      try { _invalidarCacheHorarioUsuario(params.idPersonal); } catch(_) {}
      return { ok: true, data: { idPersonal: params.idPersonal, nuevoCierre: nuevoCierre, dia: diaKey } };
    }
    return { ok: false, error: 'idPersonal no encontrado' };
  } catch(e) { return { ok: false, error: e.message }; }
}

// [v2.43.130] Helper modo B: extender cierre HOY de la APP global.
// Guarda un patch en Script Properties `EXT_HORARIO_HOY_<app>` = `{dia,cierre,ts,razon}`.
// El trigger 00:01 lo revierte. Mientras tanto, _resolverHorarioPersonal y getHorariosApps
// deberían consultar este patch — pero por simplicidad guardamos el cierre original
// en el mismo patch para restaurar después.
function _extenderHorarioHoyApp(params) {
  var app = String(params.app || '');
  var cierre = String(params.cierre || '');
  var razon = String(params.razon || 'sin razón');
  if (!/^\d{2}:\d{2}$/.test(cierre)) return { ok: false, error: 'cierre inválido (HH:MM)' };

  var sh = _asegurarHojaHorariosApps();
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var iApp = hdrs.indexOf('app');
  var iHor = hdrs.indexOf('horarioJson');
  var filaFound = -1;
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iApp]) === app) { filaFound = i + 1; break; }
  }
  if (filaFound < 0) return { ok: false, error: 'app no encontrada' };

  var horarioActual = {};
  try { horarioActual = JSON.parse(data[filaFound - 1][iHor] || '{}'); } catch(_) {}

  var tz = Session.getScriptTimeZone();
  var diaIdx = parseInt(Utilities.formatDate(new Date(), tz, 'u'), 10);
  var diaKey = _HOR_DIAS[Math.max(0, Math.min(6, diaIdx - 1))];

  var configDia = horarioActual[diaKey] || { activo: true, apertura: '07:00', cierre: '19:00' };
  var cierreOriginal = String(configDia.cierre || '19:00');

  // Backup en Properties para revertir
  PropertiesService.getScriptProperties().setProperty(
    'EXT_HORARIO_HOY_' + app,
    JSON.stringify({ dia: diaKey, cierreOriginal: cierreOriginal, cierreNuevo: cierre, razon: razon, ts: new Date().toISOString() })
  );

  // Patch del día actual con nuevo cierre
  horarioActual[diaKey] = {
    activo: true,
    apertura: String(configDia.apertura || '07:00'),
    cierre: cierre
  };
  sh.getRange(filaFound, iHor + 1).setValue(JSON.stringify(horarioActual));

  // Alerta + invalidar cache + push
  _crearAlertaSeg('EXTENSION_HORARIO_APP', {
    descripcion: 'Cierre ' + app + ' extendido hoy ' + cierreOriginal + '→' + cierre + ' · ' + razon.substring(0, 100),
    prioridad: 'MEDIA',
    datosExtra: { app: app, cierreOriginal: cierreOriginal, cierreNuevo: cierre, razon: razon }
  });
  try { _invalidarCacheHorarioApp(app); } catch(_) {}
  try {
    if (typeof _enviarPushTodos === 'function') {
      _enviarPushTodos('🕐 Cierre extendido', app + ' cierra hoy ' + cierre + ' (' + razon + ')',
        { idNotif: 'MOS_EXT_APP_' + app });
    }
  } catch(_) {}

  return { ok: true, data: { app: app, cierreNuevo: cierre, cierreOriginal: cierreOriginal, dia: diaKey } };
}

// [v2.43.130] Trigger diario 00:01 — revierte todos los patches del día anterior.
// Revisa Properties EXT_HORARIO_HOY_<app> y restaura cierreOriginal; revisa
// PERSONAL_MASTER.horarioCustom.extensionHoy y limpia el día extendido.
function revertirExtensionesDiarias() {
  // [v2.43.132 FIX] Guard contra doble ejecución el mismo día (re-deploys, retry manual)
  var _props = PropertiesService.getScriptProperties();
  var _tz = Session.getScriptTimeZone();
  var _hoyKey = Utilities.formatDate(new Date(), _tz, 'yyyy-MM-dd');
  var _ult = _props.getProperty('REVERTIR_EXT_ULTIMA_FECHA') || '';
  if (_ult === _hoyKey) {
    Logger.log('[revertirExtensionesDiarias] Ya ejecutado hoy (' + _hoyKey + '), skip');
    return { ok: true, revertidas: 0, skipped: true };
  }
  var _lock = LockService.getScriptLock();
  try { _lock.waitLock(15000); } catch(e) { return { ok: false, error: 'Sistema ocupado' }; }
  var revertidas = 0;
  try {
    // A) Apps
    var props = PropertiesService.getScriptProperties();
    var all = props.getProperties();
    Object.keys(all).forEach(function(key) {
      if (key.indexOf('EXT_HORARIO_HOY_') !== 0) return;
      var app = key.substring('EXT_HORARIO_HOY_'.length);
      try {
        var patch = JSON.parse(all[key]);
        var sh = _asegurarHojaHorariosApps();
        var data = sh.getDataRange().getValues();
        var hdrs = data[0];
        var iApp = hdrs.indexOf('app');
        var iHor = hdrs.indexOf('horarioJson');
        for (var i = 1; i < data.length; i++) {
          if (String(data[i][iApp]) !== app) continue;
          var hor = {};
          try { hor = JSON.parse(data[i][iHor] || '{}'); } catch(_) {}
          if (hor[patch.dia]) {
            hor[patch.dia].cierre = patch.cierreOriginal;
            sh.getRange(i + 1, iHor + 1).setValue(JSON.stringify(hor));
            revertidas++;
          }
          break;
        }
        try { _invalidarCacheHorarioApp(app); } catch(_) {}
      } catch(_) {}
      props.deleteProperty(key);
    });

    // B) Usuarios (PERSONAL_MASTER.horarioCustom.extensionHoy)
    var pSh = getSheet('PERSONAL_MASTER');
    if (pSh) {
      var pd = pSh.getDataRange().getValues();
      var ph = pd[0];
      var iHC = ph.indexOf('horarioCustom');
      var iId = ph.indexOf('idPersonal');
      if (iHC >= 0) {
        for (var j = 1; j < pd.length; j++) {
          var raw = pd[j][iHC];
          if (!raw) continue;
          try {
            var hc = JSON.parse(raw);
            if (hc && hc.extensionHoy) {
              // Si tenía extensión: quitar el día patcheado y el flag
              if (hc.dias && hc.extensionHoy.dia) delete hc.dias[hc.extensionHoy.dia];
              delete hc.extensionHoy;
              // Si ya no quedan días custom, quitar todo
              if (!hc.dias || Object.keys(hc.dias).length === 0) {
                pSh.getRange(j + 1, iHC + 1).setValue('');
              } else {
                pSh.getRange(j + 1, iHC + 1).setValue(JSON.stringify(hc));
              }
              try { _invalidarCacheHorarioUsuario(String(pd[j][iId])); } catch(_) {}
              revertidas++;
            }
          } catch(_) {}
        }
      }
    }
  } catch(e) { Logger.log('[revertirExtensionesDiarias] ' + e.message); }
  finally { try { _lock.releaseLock(); } catch(_){} }
  // Marcar fecha de ejecución para guard
  try { _props.setProperty('REVERTIR_EXT_ULTIMA_FECHA', _hoyKey); } catch(_){}
  return { ok: true, revertidas: revertidas };
}

function instalarTriggerRevertirExtensiones() {
  var TRG = 'revertirExtensionesDiarias';
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === TRG) ScriptApp.deleteTrigger(t);
  });
  // Apps Script no soporta nearMinute; corre alguna vez entre 0:00-0:59
  ScriptApp.newTrigger(TRG).timeBased().atHour(0).everyDays(1).create();
  Logger.log('[Trigger] ' + TRG + ' instalado · diario 0:00-0:59');
  return { ok: true };
}

// ────────────────────────────────────────────────────────────────────
// "Notificarme cuando abra" — el operador setea un recordatorio
// ────────────────────────────────────────────────────────────────────
function notificarmeCuandoAbra(params) {
  try {
    if (!params.idPersonal) return { ok: false, error: 'idPersonal requerido' };
    _crearAlertaSeg('NOTIFICAR_APERTURA', {
      idPersonal: params.idPersonal,
      descripcion: 'Operador pidió notificación cuando abra horario',
      prioridad: 'BAJA',
      datosExtra: { apertura: params.apertura || '', solicitadoEn: new Date().toISOString() }
    });
    return { ok: true };
  } catch(e) { return { ok: false, error: e.message }; }
}

// [v2.43.134] Trigger horario: procesa alertas NOTIFICAR_APERTURA y dispara
// push al operador cuando su horario ya está abierto. Marca la alerta como
// REVISADA para no volver a notificar.
function procesarNotificacionesApertura() {
  try {
    var sheet = _getSheetSegAlertas();
    if (sheet.getLastRow() < 2) return { ok: true, procesadas: 0 };
    var values = sheet.getRange(2, 1, sheet.getLastRow() - 1, SEGURIDAD_ALERTAS_HEADERS.length).getValues();
    var iIdAl = SEGURIDAD_ALERTAS_HEADERS.indexOf('idAlerta');
    var iTipo = SEGURIDAD_ALERTAS_HEADERS.indexOf('tipo');
    var iIdP  = SEGURIDAD_ALERTAS_HEADERS.indexOf('idPersonal');
    var iEst  = SEGURIDAD_ALERTAS_HEADERS.indexOf('estado');
    var iRev  = SEGURIDAD_ALERTAS_HEADERS.indexOf('revisada_por');
    var iRevT = SEGURIDAD_ALERTAS_HEADERS.indexOf('revisada_en');
    var procesadas = 0;
    for (var i = 0; i < values.length; i++) {
      var row = values[i];
      if (String(row[iTipo] || '').trim() !== 'NOTIFICAR_APERTURA') continue;
      if (String(row[iEst]  || '').trim().toUpperCase() !== 'PENDIENTE') continue;
      var idPersonal = String(row[iIdP] || '');
      if (!idPersonal) continue;
      // Inferir app del usuario (WH por defecto si rol envasador/operador, sino mosExpress)
      // Para simplicidad: probar ambas apps; si alguna permite ahora, notificar.
      var apps = ['warehouseMos', 'mosExpress'];
      var permitidoAhora = false;
      for (var a = 0; a < apps.length; a++) {
        var r = resolverHorarioPersonal({ idPersonal: idPersonal, rol: '', app: apps[a] });
        if (r && r.data && r.data.permitido) { permitidoAhora = true; break; }
      }
      if (!permitidoAhora) continue;
      // Notificar al operador + marcar REVISADA
      try { _enviarPushSegmentado(idPersonal, '🔔 Tu horario ya abrió', 'Podés entrar a la app ahora.'); } catch(_){}
      var filaSh = i + 2;  // offset header + 0-based to 1-based
      sheet.getRange(filaSh, iEst  + 1).setValue('REVISADA');
      sheet.getRange(filaSh, iRev  + 1).setValue('cron_apertura');
      sheet.getRange(filaSh, iRevT + 1).setValue(new Date().toISOString());
      procesadas++;
    }
    return { ok: true, procesadas: procesadas };
  } catch(e) { Logger.log('[procesarNotificacionesApertura] ' + e.message); return { ok: false, error: e.message }; }
}

function instalarTriggerNotificacionesApertura() {
  var TRG = 'procesarNotificacionesApertura';
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === TRG) ScriptApp.deleteTrigger(t);
  });
  // Cada 15 min: balance entre latencia (notificar pronto al abrir) y carga
  ScriptApp.newTrigger(TRG).timeBased().everyMinutes(15).create();
  Logger.log('[Trigger] ' + TRG + ' instalado · cada 15 min');
  return { ok: true };
}
