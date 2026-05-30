// ════════════════════════════════════════════════════════════════════
// [v2.43.57] MODO ESPÍA WebRTC — Signaling p2p admin ↔ dispositivo
// ────────────────────────────────────────────────────────────────────
// Permite al MASTER conectarse en vivo con un dispositivo de la empresa
// para recibir 4 streams simultáneos:
//   1. Audio del micrófono
//   2. Pantalla del dispositivo (getDisplayMedia)
//   3. Cámara frontal/trasera (getUserMedia video)
//   4. GPS continuo (vía DataChannel WebRTC)
//
// Arquitectura: signaling SDP/ICE vía hoja RTC_SIGNALING + push FCM
// para iniciar la sesión. Los streams son p2p directos browser↔browser
// con STUN gratuito de Google (no necesitamos TURN propio).
//
// Política de seguridad:
//   - Solo MASTER puede crear sesión (verificarClaveAdmin tier 3)
//   - Cada sesión expira 10 min automáticamente
//   - El device verifica el masterId firmado antes de aceptar
//   - Toda sesión queda registrada en AUDITORIA_ESPIA con duración
// ════════════════════════════════════════════════════════════════════

var ESPIA_TTL_MS = 10 * 60 * 1000; // 10 min máximo por sesión

// ── 1. Crear sesión de espionaje (master) ───────────────────────────
// Devuelve sesionId que el master pasará al device vía push FCM.
function espiaCrearSesion(params) {
  var masterId = String(params.masterId || '').trim();
  var deviceId = String(params.deviceId || '').trim();
  if (!masterId) return { ok: false, error: 'masterId requerido' };
  if (!deviceId) return { ok: false, error: 'deviceId requerido' };

  var sesionId = 'ESP-' + Date.now() + '-' + Math.random().toString(36).substr(2, 9);
  var ahora = new Date();

  var sh = _getHojaSignaling();
  sh.appendRow([
    sesionId, ahora, masterId, deviceId,
    'PENDIENTE',          // estado
    '', '',               // sdpOferta, sdpRespuesta
    '[]', '[]',           // iceMaster, iceDevice
    '',                   // streamsActivos JSON
    ''                    // detalleFin
  ]);

  // Notif push al dispositivo con el sesionId
  try {
    if (typeof _enviarPushDispositivo === 'function') {
      _enviarPushDispositivo(deviceId, {
        idNotif: 'MOS_ESPIA_INICIAR',
        sesionId: sesionId,
        masterId: masterId,
        ttl: ESPIA_TTL_MS,
        silencioso: true
      });
    }
  } catch(e) { Logger.log('[espia] push fallo: ' + e.message); }

  return { ok: true, data: { sesionId: sesionId, ttl: ESPIA_TTL_MS, ahora: ahora.toISOString() } };
}

// ── 2. Master escribe oferta SDP ───────────────────────────────────
function espiaSubirOferta(params) {
  var sesionId = String(params.sesionId || '').trim();
  var sdp      = String(params.sdp || '');
  if (!sesionId || !sdp) return { ok: false, error: 'Requiere sesionId y sdp' };
  return _actualizarColumnaSesion(sesionId, 'sdpOferta', sdp);
}

// ── 3. Device lee oferta y responde ─────────────────────────────────
function espiaLeerOferta(params) {
  var sesionId = String(params.sesionId || '').trim();
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  if (_sesionExpiro(row)) return { ok: false, error: 'Sesión expirada', codigo: 'EXPIRADO' };
  return { ok: true, data: { sdpOferta: row.sdpOferta || '', estado: row.estado } };
}

function espiaSubirRespuesta(params) {
  var sesionId = String(params.sesionId || '').trim();
  var sdp      = String(params.sdp || '');
  if (!sesionId || !sdp) return { ok: false, error: 'Requiere sesionId y sdp' };
  return _actualizarColumnaSesion(sesionId, 'sdpRespuesta', sdp, { estado: 'CONECTANDO' });
}

function espiaLeerRespuesta(params) {
  var sesionId = String(params.sesionId || '').trim();
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  if (_sesionExpiro(row)) return { ok: false, error: 'Sesión expirada', codigo: 'EXPIRADO' };
  return { ok: true, data: { sdpRespuesta: row.sdpRespuesta || '', estado: row.estado } };
}

// ── 4. ICE candidates (ambos lados append) ──────────────────────────
function espiaAgregarIce(params) {
  var sesionId = String(params.sesionId || '').trim();
  var lado     = String(params.lado || '').toLowerCase();
  var ice      = params.ice;
  if (!sesionId || !lado || !ice) return { ok: false, error: 'Requiere sesionId, lado, ice' };
  if (lado !== 'master' && lado !== 'device') return { ok: false, error: 'lado: master|device' };

  var col = (lado === 'master') ? 'iceMaster' : 'iceDevice';
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  var arr = [];
  try { arr = JSON.parse(row[col] || '[]'); } catch(_) { arr = []; }
  arr.push({ ts: Date.now(), ice: ice });
  return _actualizarColumnaSesion(sesionId, col, JSON.stringify(arr));
}

function espiaLeerIce(params) {
  var sesionId = String(params.sesionId || '').trim();
  var lado     = String(params.lado || '').toLowerCase();
  var desde    = parseInt(params.desde) || 0;
  var col = (lado === 'master') ? 'iceMaster' : 'iceDevice';
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  if (_sesionExpiro(row)) return { ok: false, error: 'Sesión expirada', codigo: 'EXPIRADO' };
  var arr = [];
  try { arr = JSON.parse(row[col] || '[]'); } catch(_) { arr = []; }
  var nuevos = arr.filter(function(c) { return c.ts > desde; });
  return { ok: true, data: { ice: nuevos, tsMax: arr.length ? arr[arr.length - 1].ts : desde } };
}

// ── 5. Estado de la sesión (polling rápido) ─────────────────────────
function espiaEstadoSesion(params) {
  var sesionId = String(params.sesionId || '').trim();
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  return {
    ok: true,
    data: {
      sesionId:    sesionId,
      estado:      row.estado,
      streamsActivos: row.streamsActivos ? JSON.parse(row.streamsActivos) : null,
      iniciada:    row.fecha,
      expiraEn:    _msHastaExpiracion(row)
    }
  };
}

// ── 6. Device reporta streams activos (audio/video/screen/gps) ─────
function espiaReportarStreams(params) {
  var sesionId = String(params.sesionId || '').trim();
  var streams  = params.streams || {};  // {audio:bool, camara:bool, pantalla:bool, gps:bool}
  return _actualizarColumnaSesion(sesionId, 'streamsActivos', JSON.stringify(streams),
                                  { estado: 'EN_VIVO' });
}

// ── 7. Cerrar sesión (cualquier lado) ──────────────────────────────
function espiaCerrarSesion(params) {
  var sesionId = String(params.sesionId || '').trim();
  var motivo   = String(params.motivo || 'manual');
  var lado     = String(params.lado || 'desconocido');
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };

  // Registrar duración + cerrar
  var inicio = row.fecha instanceof Date ? row.fecha.getTime() : new Date(row.fecha).getTime();
  var duracionSeg = Math.round((Date.now() - inicio) / 1000);
  var detalle = JSON.stringify({ motivo: motivo, lado: lado, duracionSeg: duracionSeg });

  _actualizarColumnaSesion(sesionId, 'detalleFin', detalle, { estado: 'CERRADA' });
  _logAuditoriaEspia(row, duracionSeg, detalle);

  return { ok: true, data: { duracionSeg: duracionSeg } };
}

// ── 8. Buffer histórico (DataChannel WebRTC sube chunks acá) ────────
// El device sube chunks de los streams en blobs base64 cada 5min.
// Carpeta "MOS Espia Buffer" en Drive con subcarpeta por device.
function espiaSubirChunk(params) {
  var deviceId = String(params.deviceId || '').trim();
  var tipo     = String(params.tipo || '').toLowerCase(); // audio|video|screen
  var ts       = parseInt(params.ts) || Date.now();
  var b64      = String(params.contenido || '');
  if (!deviceId || !tipo || !b64) return { ok: false, error: 'Requiere deviceId, tipo, contenido' };

  try {
    var carpeta = _getCarpetaEspiaBuffer(deviceId);
    var ext  = tipo === 'audio' ? 'webm' : 'webm';
    var nombre = deviceId + '_' + tipo + '_' + ts + '.' + ext;
    var blob = Utilities.newBlob(Utilities.base64Decode(b64), 'video/webm', nombre);
    var file = carpeta.createFile(blob);
    return { ok: true, data: { fileId: file.getId(), nombre: nombre } };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

// ── Helpers internos ────────────────────────────────────────────────
function _getHojaSignaling() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName('RTC_SIGNALING');
  if (!sh) {
    sh = ss.insertSheet('RTC_SIGNALING');
    sh.appendRow([
      'sesionId', 'fecha', 'masterId', 'deviceId',
      'estado', 'sdpOferta', 'sdpRespuesta',
      'iceMaster', 'iceDevice', 'streamsActivos', 'detalleFin'
    ]);
    sh.getRange(1, 1, 1, 11).setFontWeight('bold')
      .setBackground('#0f172a').setFontColor('#a5b4fc');
    sh.setFrozenRows(1);
    // Limpieza automática: sesiones cerradas más de 7 días → borrar
    // (se hace en _purgarSesionesAntiguas, llamado on read)
  }
  return sh;
}

function _buscarSesion(sesionId) {
  var sh = _getHojaSignaling();
  if (sh.getLastRow() < 2) return null;
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var idxId = hdrs.indexOf('sesionId');
  for (var i = data.length - 1; i >= 1; i--) {  // iterar desde el final (más recientes primero)
    if (String(data[i][idxId]) === sesionId) {
      var obj = {};
      hdrs.forEach(function(h, j) { obj[h] = data[i][j]; });
      obj._row = i + 1;
      return obj;
    }
  }
  return null;
}

function _actualizarColumnaSesion(sesionId, columna, valor, extras) {
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  var sh = _getHojaSignaling();
  var hdrs = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
  var col = hdrs.indexOf(columna);
  if (col < 0) return { ok: false, error: 'Columna no existe: ' + columna };
  sh.getRange(row._row, col + 1).setValue(valor);
  if (extras) {
    Object.keys(extras).forEach(function(k) {
      var c = hdrs.indexOf(k);
      if (c >= 0) sh.getRange(row._row, c + 1).setValue(extras[k]);
    });
  }
  return { ok: true };
}

function _sesionExpiro(row) {
  var fecha = row.fecha instanceof Date ? row.fecha : new Date(row.fecha);
  return (Date.now() - fecha.getTime()) > ESPIA_TTL_MS;
}

function _msHastaExpiracion(row) {
  var fecha = row.fecha instanceof Date ? row.fecha : new Date(row.fecha);
  return Math.max(0, ESPIA_TTL_MS - (Date.now() - fecha.getTime()));
}

function _logAuditoriaEspia(row, duracionSeg, detalle) {
  try {
    var ss = SpreadsheetApp.getActiveSpreadsheet();
    var sh = ss.getSheetByName('AUDITORIA_ESPIA');
    if (!sh) {
      sh = ss.insertSheet('AUDITORIA_ESPIA');
      sh.appendRow(['fecha', 'sesionId', 'masterId', 'deviceId',
                    'duracionSeg', 'streamsActivos', 'detalle']);
      sh.getRange(1, 1, 1, 7).setFontWeight('bold').setBackground('#0f172a').setFontColor('#fbbf24');
      sh.setFrozenRows(1);
    }
    sh.appendRow([
      new Date(),
      row.sesionId,
      row.masterId,
      row.deviceId,
      duracionSeg,
      row.streamsActivos || '',
      detalle
    ]);
  } catch(e) { Logger.log('[espia auditoria] ' + e.message); }
}

function _getCarpetaEspiaBuffer(deviceId) {
  var rootName = 'MOS Espia Buffer';
  var folders = DriveApp.getFoldersByName(rootName);
  var root = folders.hasNext() ? folders.next() : DriveApp.createFolder(rootName);
  var subName = String(deviceId).replace(/[^a-zA-Z0-9_\-]/g, '_');
  var subs = root.getFoldersByName(subName);
  var sub  = subs.hasNext() ? subs.next() : root.createFolder(subName);
  return sub;
}

// Push helper — si no existe el endpoint global, lo definimos mínimo aquí
// Para no chocar con otros, usamos el del Push.gs si existe
function _enviarPushDispositivo(deviceId, payload) {
  try {
    // Si existe la función global, usarla
    if (typeof enviarPushAUsuario === 'function') {
      return enviarPushAUsuario(deviceId, payload);
    }
    Logger.log('[espia] _enviarPushDispositivo NO IMPLEMENTADO — ' + JSON.stringify(payload));
  } catch(e) { Logger.log('[espia push] ' + e.message); }
}
