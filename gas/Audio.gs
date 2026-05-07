// ============================================================
// ProyectoMOS — Audio.gs
// Sistema de escucha remota on-demand desde MOS hacia ME/WH.
//
// Flujo:
// 1. Master/Admin click 🎙️ en card de dispositivo en MOS
// 2. iniciarEscuchaAudio crea una sesión + manda push data-only al dispositivo
// 3. SW del dispositivo recibe push, postMessage al cliente
// 4. Cliente activa MediaRecorder con chunks de 15s
// 5. Cada chunk sube via subirChunkAudio (base64) → guarda en Drive
// 6. MOS reproduce los chunks secuencialmente con auto-playback
// 7. Click "Detener" → push audio_stop. Auto-stop a los 30 min.
// 8. Trigger diario limpia chunks > 7 días.
//
// Hojas:
//   AUDIO_SESIONES: idSesion | deviceId | autorizadoPor | inicio | fin | duracionSeg | folderDriveId | estado | motivo
//   AUDIO_CHUNKS:   idChunk  | idSesion | idx | timestamp | driveFileId | sizeBytes
// ============================================================

var AUDIO_FOLDER_NAME = 'MOS_AUDIO';
var AUDIO_MAX_DURACION_SEG = 30 * 60; // 30 min máximo por sesión
var AUDIO_TTL_DIAS = 7;
var AUDIO_SESIONES_HEADERS = ['idSesion', 'deviceId', 'autorizadoPor', 'inicio', 'fin', 'duracionSeg', 'folderDriveId', 'estado', 'motivo'];
var AUDIO_CHUNKS_HEADERS   = ['idChunk', 'idSesion', 'idx', 'timestamp', 'driveFileId', 'sizeBytes'];

function _garantizarHojasAudio() {
  var ss = getSpreadsheet();
  var s1 = ss.getSheetByName('AUDIO_SESIONES');
  if (!s1) {
    s1 = ss.insertSheet('AUDIO_SESIONES');
    s1.getRange(1, 1, 1, AUDIO_SESIONES_HEADERS.length).setValues([AUDIO_SESIONES_HEADERS]);
    s1.getRange(1, 1, 1, AUDIO_SESIONES_HEADERS.length)
      .setFontWeight('bold').setBackground('#1f2937').setFontColor('#fff');
    s1.setFrozenRows(1);
  }
  var s2 = ss.getSheetByName('AUDIO_CHUNKS');
  if (!s2) {
    s2 = ss.insertSheet('AUDIO_CHUNKS');
    s2.getRange(1, 1, 1, AUDIO_CHUNKS_HEADERS.length).setValues([AUDIO_CHUNKS_HEADERS]);
    s2.getRange(1, 1, 1, AUDIO_CHUNKS_HEADERS.length)
      .setFontWeight('bold').setBackground('#1f2937').setFontColor('#fff');
    s2.setFrozenRows(1);
  }
}

// Folder raíz de audio en Drive (auto-crea si no existe)
function _getAudioRootFolder() {
  var props = PropertiesService.getScriptProperties();
  var fid = props.getProperty('AUDIO_DRIVE_FOLDER_ID');
  if (fid) {
    try { return DriveApp.getFolderById(fid); } catch(e) { /* fall through to recreate */ }
  }
  var folder = DriveApp.getRootFolder().createFolder(AUDIO_FOLDER_NAME);
  props.setProperty('AUDIO_DRIVE_FOLDER_ID', folder.getId());
  return folder;
}

// Push data-only al dispositivo destino (sin notificación visible — comando silencioso)
function _pushComandoDispositivo(deviceId, action, extra) {
  // Buscar token del dispositivo
  // headers PUSH_TOKENS: idToken(0) token(1) usuario(2) dispositivo(3) appOrigen(4) fecha(5) ultimaVez(6) activo(7)
  // Necesitamos el token cuyo dispositivo coincida con el ID que tenemos
  // Como deviceId es el UUID, hay que buscarlo por ID_Dispositivo en DISPOSITIVOS
  // y obtener su Ultima_Sesion (nombre del usuario), luego buscar en PUSH_TOKENS.
  var sheetD = getSheet('DISPOSITIVOS');
  var dataD = sheetD.getDataRange().getValues();
  var hdrsD = dataD[0];
  var iId = hdrsD.indexOf('ID_Dispositivo');
  var iSesion = hdrsD.indexOf('Ultima_Sesion');
  var iApp = hdrsD.indexOf('App');
  var nombreUsuario = '', appOrigen = '';
  for (var i = 1; i < dataD.length; i++) {
    if (String(dataD[i][iId]) === String(deviceId)) {
      nombreUsuario = String(dataD[i][iSesion] || '').trim();
      appOrigen = String(dataD[i][iApp] || '').trim();
      break;
    }
  }
  if (!nombreUsuario) {
    Logger.log('[push-cmd] Dispositivo ' + deviceId + ' sin Ultima_Sesion — no se puede direccionar');
    return { ok: false, error: 'El dispositivo no tiene un usuario logueado' };
  }

  // Buscar token: PRIMERO por deviceId (más preciso), después fallback a usuario+app.
  // Tokens viejos no tienen deviceId guardado → match por usuario.
  var sheetT = _getPushTokensSheet();
  var dataT = sheetT.getDataRange().getValues();
  var hdrsT = dataT[0];
  var iDev = hdrsT.indexOf('deviceId');
  var nombreNorm = nombreUsuario.toLowerCase();
  var appNorm = appOrigen.toLowerCase();
  var mejor = null;
  // Pass 1: match exacto por deviceId
  if (iDev >= 0) {
    for (var j = 1; j < dataT.length; j++) {
      var token  = String(dataT[j][1] || '');
      var devRow = String(dataT[j][iDev] || '');
      var activo = dataT[j][7];
      if (!token || !devRow) continue;
      if (activo === false || String(activo) === '0' || String(activo) === 'false') continue;
      if (devRow !== String(deviceId)) continue;
      var ultVez = 0;
      try { ultVez = dataT[j][6] ? new Date(dataT[j][6]).getTime() : 0; } catch(_) {}
      if (!mejor || mejor.ultVez < ultVez) {
        mejor = { token: token, ultVez: ultVez, via: 'deviceId' };
      }
    }
  }
  // Pass 2 (fallback): si no encontramos por deviceId, match por usuario+app (legacy)
  if (!mejor) {
    for (var k = 1; k < dataT.length; k++) {
      var tk     = String(dataT[k][1] || '');
      var u      = String(dataT[k][2] || '').trim().toLowerCase();
      var app    = String(dataT[k][4] || '').trim().toLowerCase();
      var act    = dataT[k][7];
      if (!tk) continue;
      if (act === false || String(act) === '0' || String(act) === 'false') continue;
      if (u !== nombreNorm) continue;
      if (appNorm && app && app !== appNorm) continue;
      var ultV = 0;
      try { ultV = dataT[k][6] ? new Date(dataT[k][6]).getTime() : 0; } catch(_) {}
      if (!mejor || mejor.ultVez < ultV) {
        mejor = { token: tk, ultVez: ultV, via: 'usuario' };
      }
    }
  }
  if (!mejor) {
    return { ok: false, error: 'Sin token activo para device ' + String(deviceId).substring(0, 8) + ' (' + nombreUsuario + ')' };
  }
  Logger.log('[push-cmd] match via ' + mejor.via + ' → ' + nombreUsuario);

  // Enviar push data-only
  var projectId = PropertiesService.getScriptProperties().getProperty('FCM_PROJECT_ID');
  var accessToken = _getFcmAccessToken();
  var url = 'https://fcm.googleapis.com/v1/projects/' + projectId + '/messages:send';
  var dataPayload = { action: String(action) };
  if (extra) Object.keys(extra).forEach(function(k){ dataPayload[k] = String(extra[k]); });

  try {
    var resp = UrlFetchApp.fetch(url, {
      method: 'post',
      contentType: 'application/json',
      headers: { 'Authorization': 'Bearer ' + accessToken },
      payload: JSON.stringify({
        message: {
          token: mejor.token,
          data: dataPayload,
          webpush: { headers: { 'Urgency': 'high', 'TTL': '60' } }
        }
      }),
      muteHttpExceptions: true
    });
    var code = resp.getResponseCode();
    if (code === 200) {
      Logger.log('[push-cmd] OK ' + action + ' → ' + nombreUsuario);
      return { ok: true };
    }
    Logger.log('[push-cmd] HTTP ' + code + ' ' + resp.getContentText().substring(0, 200));
    return { ok: false, error: 'HTTP ' + code };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

// ────────────────────────────────────────────────────────────
// INICIAR sesión de escucha
// ────────────────────────────────────────────────────────────
function iniciarEscuchaAudio(params) {
  if (!params || !params.deviceId) return { ok: false, error: 'Requiere deviceId' };
  if (!params.autorizadoPor) return { ok: false, error: 'Requiere autorizadoPor' };

  _garantizarHojasAudio();

  // ¿Ya hay sesión activa para este dispositivo? Cerrarla primero
  var sheet = getSheet('AUDIO_SESIONES');
  var data = sheet.getDataRange().getValues();
  var hdrs = data[0];
  var iSes = hdrs.indexOf('idSesion');
  var iDev = hdrs.indexOf('deviceId');
  var iEst = hdrs.indexOf('estado');
  var iFin = hdrs.indexOf('fin');
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iDev]) === String(params.deviceId) && String(data[i][iEst]) === 'ACTIVA') {
      sheet.getRange(i + 1, iEst + 1).setValue('CANCELADA');
      sheet.getRange(i + 1, iFin + 1).setValue(new Date());
    }
  }

  // Crear nueva sesión
  var idSesion = 'AS' + new Date().getTime();
  var rootFolder = _getAudioRootFolder();
  var fechaStr = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
  var dayFolder;
  var iter = rootFolder.getFoldersByName(fechaStr);
  if (iter.hasNext()) dayFolder = iter.next();
  else dayFolder = rootFolder.createFolder(fechaStr);
  var sesionFolder = dayFolder.createFolder(idSesion + '_' + String(params.deviceId).substring(0, 8));

  sheet.appendRow([
    idSesion,
    params.deviceId,
    params.autorizadoPor,
    new Date(),
    '',
    0,
    sesionFolder.getId(),
    'ACTIVA',
    params.motivo || ''
  ]);

  // Auditar
  try {
    var audSheet = _garantizarHojaAuditoria();
    audSheet.appendRow([
      _generateId('AUD'), new Date(), 'AUDIO_INICIAR', params.deviceId,
      '', params.autorizadoPor, '', '', 'Sesión ' + idSesion
    ]);
  } catch(e) {}

  // Push al dispositivo
  var pushRes = _pushComandoDispositivo(params.deviceId, 'audio_start', {
    sesionId: idSesion,
    duracionMaxSeg: String(AUDIO_MAX_DURACION_SEG)
  });
  if (!pushRes.ok) {
    // Marcar como fallida pero retornar info igual (admin puede ver el error)
    sheet.getRange(sheet.getLastRow(), iEst + 1).setValue('PUSH_FALLO');
    return { ok: false, error: 'Sesión creada pero push falló: ' + pushRes.error, data: { idSesion: idSesion } };
  }

  return { ok: true, data: { idSesion: idSesion, folderDriveId: sesionFolder.getId() } };
}

// ────────────────────────────────────────────────────────────
// DETENER sesión
// ────────────────────────────────────────────────────────────
function detenerEscuchaAudio(params) {
  if (!params || (!params.idSesion && !params.deviceId)) {
    return { ok: false, error: 'Requiere idSesion o deviceId' };
  }
  _garantizarHojasAudio();
  var sheet = getSheet('AUDIO_SESIONES');
  var data = sheet.getDataRange().getValues();
  var hdrs = data[0];
  var iSes = hdrs.indexOf('idSesion');
  var iDev = hdrs.indexOf('deviceId');
  var iEst = hdrs.indexOf('estado');
  var iFin = hdrs.indexOf('fin');
  var iIni = hdrs.indexOf('inicio');
  var iDur = hdrs.indexOf('duracionSeg');

  var deviceParaPush = null;
  for (var i = data.length - 1; i >= 1; i--) {
    var matchSes = params.idSesion && String(data[i][iSes]) === String(params.idSesion);
    var matchDev = params.deviceId && String(data[i][iDev]) === String(params.deviceId)
                   && String(data[i][iEst]) === 'ACTIVA';
    if (matchSes || matchDev) {
      var fin = new Date();
      var ini = data[i][iIni] ? new Date(data[i][iIni]) : fin;
      var dur = Math.round((fin.getTime() - ini.getTime()) / 1000);
      sheet.getRange(i + 1, iEst + 1).setValue('CERRADA');
      sheet.getRange(i + 1, iFin + 1).setValue(fin);
      sheet.getRange(i + 1, iDur + 1).setValue(dur);
      deviceParaPush = data[i][iDev];
      break;
    }
  }

  if (deviceParaPush) {
    _pushComandoDispositivo(deviceParaPush, 'audio_stop', {});
  }

  return { ok: true };
}

// ────────────────────────────────────────────────────────────
// SUBIR chunk de audio (llamado por el dispositivo)
// audioBase64: contenido del Blob convertido a base64
// ────────────────────────────────────────────────────────────
function subirChunkAudio(params) {
  if (!params || !params.idSesion) return { ok: false, error: 'Requiere idSesion' };
  if (!params.audioBase64) return { ok: false, error: 'Requiere audioBase64' };
  _garantizarHojasAudio();

  // Buscar sesión activa
  var sheet = getSheet('AUDIO_SESIONES');
  var data = sheet.getDataRange().getValues();
  var hdrs = data[0];
  var iSes = hdrs.indexOf('idSesion');
  var iEst = hdrs.indexOf('estado');
  var iFol = hdrs.indexOf('folderDriveId');
  var folderId = null, estado = null;
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iSes]) === String(params.idSesion)) {
      folderId = data[i][iFol];
      estado = String(data[i][iEst]);
      break;
    }
  }
  if (!folderId) return { ok: false, error: 'Sesión no encontrada: ' + params.idSesion };
  if (estado !== 'ACTIVA') return { ok: false, error: 'Sesión no activa: ' + estado };

  // Decodificar base64 y guardar en Drive
  try {
    var folder = DriveApp.getFolderById(folderId);
    var bytes = Utilities.base64Decode(params.audioBase64);
    var mime = params.mimeType || 'audio/webm';
    var idx = parseInt(params.idx, 10) || 0;
    var ext = mime.indexOf('mp4') >= 0 ? 'mp4' : (mime.indexOf('ogg') >= 0 ? 'ogg' : 'webm');
    var blob = Utilities.newBlob(bytes, mime, 'chunk_' + String(idx).padStart(4, '0') + '.' + ext);
    var file = folder.createFile(blob);

    // Registrar chunk
    var sheetC = getSheet('AUDIO_CHUNKS');
    var idChunk = 'AC' + new Date().getTime() + '_' + idx;
    sheetC.appendRow([idChunk, params.idSesion, idx, new Date(), file.getId(), bytes.length]);

    return { ok: true, data: { idChunk: idChunk, fileId: file.getId() } };
  } catch(e) {
    return { ok: false, error: 'Error guardando chunk: ' + e.message };
  }
}

// ────────────────────────────────────────────────────────────
// Listar sesiones de un dispositivo (panel admin)
// ────────────────────────────────────────────────────────────
function getSesionesAudio(params) {
  _garantizarHojasAudio();
  var rows = _sheetToObjects(getSheet('AUDIO_SESIONES'));
  if (params && params.deviceId) {
    rows = rows.filter(function(r){ return String(r.deviceId) === String(params.deviceId); });
  }
  // Ordenar más recientes primero
  rows.sort(function(a, b) {
    var ta = new Date(a.inicio).getTime() || 0;
    var tb = new Date(b.inicio).getTime() || 0;
    return tb - ta;
  });
  var limit = parseInt((params && params.limit), 10) || 30;
  rows = rows.slice(0, limit);
  return { ok: true, data: rows };
}

// Lista los chunks de una sesión, ordenados por idx
function getChunksAudioSesion(params) {
  if (!params || !params.idSesion) return { ok: false, error: 'Requiere idSesion' };
  _garantizarHojasAudio();
  var rows = _sheetToObjects(getSheet('AUDIO_CHUNKS'))
    .filter(function(r){ return String(r.idSesion) === String(params.idSesion); });
  rows.sort(function(a, b) { return (parseInt(a.idx, 10) || 0) - (parseInt(b.idx, 10) || 0); });
  return { ok: true, data: rows };
}

// Obtener un chunk individual como base64 (para reproducción en navegador)
function getChunkAudioContent(params) {
  if (!params || !params.fileId) return { ok: false, error: 'Requiere fileId' };
  try {
    var file = DriveApp.getFileById(params.fileId);
    var blob = file.getBlob();
    var bytes = blob.getBytes();
    var b64 = Utilities.base64Encode(bytes);
    return {
      ok: true,
      data: {
        base64: b64,
        mimeType: blob.getContentType(),
        size: bytes.length
      }
    };
  } catch(e) {
    return { ok: false, error: 'No se pudo leer chunk: ' + e.message };
  }
}

// Estado actual: ¿hay sesión activa para este dispositivo?
function getEstadoAudio(params) {
  if (!params || !params.deviceId) return { ok: false, error: 'Requiere deviceId' };
  _garantizarHojasAudio();
  var rows = _sheetToObjects(getSheet('AUDIO_SESIONES'))
    .filter(function(r){ return String(r.deviceId) === String(params.deviceId) && String(r.estado) === 'ACTIVA'; });
  if (rows.length === 0) return { ok: true, data: { activa: false } };
  return { ok: true, data: { activa: true, sesion: rows[0] } };
}

// ────────────────────────────────────────────────────────────
// Limpieza diaria — borra chunks > 7 días + folders vacíos
// Configurar en triggers: limpiarAudioViejo diario
// ────────────────────────────────────────────────────────────
function limpiarAudioViejo() {
  _garantizarHojasAudio();
  var sheetC = getSheet('AUDIO_CHUNKS');
  var data = sheetC.getDataRange().getValues();
  var hdrs = data[0];
  var iTs = hdrs.indexOf('timestamp');
  var iFile = hdrs.indexOf('driveFileId');
  var corte = Date.now() - (AUDIO_TTL_DIAS * 24 * 60 * 60 * 1000);
  var filasABorrar = [];
  for (var i = 1; i < data.length; i++) {
    var ts = data[i][iTs] ? new Date(data[i][iTs]).getTime() : 0;
    if (ts && ts < corte) {
      try { DriveApp.getFileById(data[i][iFile]).setTrashed(true); } catch(_){}
      filasABorrar.push(i + 1);
    }
  }
  // Borrar filas en reverso
  for (var k = filasABorrar.length - 1; k >= 0; k--) {
    sheetC.deleteRow(filasABorrar[k]);
  }
  Logger.log('[Audio] Limpieza: ' + filasABorrar.length + ' chunks > ' + AUDIO_TTL_DIAS + 'd eliminados');
  return { ok: true, data: { eliminados: filasABorrar.length } };
}
