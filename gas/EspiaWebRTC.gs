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
// [v2.43.59 SEGURIDAD] Requiere claveAdmin tier 3 + rol MASTER explícito.
// [v2.43.66] WRAP DEFENSIVO — capturar TODO error para evitar 500.
// Cuando Apps Script devuelve 500 no manda headers CORS, browser bloquea
// la respuesta y frontend ve "Failed to fetch" sin saber el error real.
function espiaCrearSesion(params) {
  try {
    return _espiaCrearSesionImpl(params);
  } catch(e) {
    Logger.log('[espiaCrearSesion EXCEPCION FATAL] ' + e.message + ' | stack: ' + e.stack);
    return { ok: false, error: 'Excepción interna: ' + e.message, stack: String(e.stack || '').substring(0, 500) };
  }
}

function _espiaCrearSesionImpl(params) {
  params = params || {};
  var masterId = String(params.masterId || '').trim();
  var deviceId = String(params.deviceId || '').trim();
  var claveAdmin = String(params.claveAdmin || '').trim();
  if (!masterId) return { ok: false, error: 'masterId requerido' };
  if (!deviceId) return { ok: false, error: 'deviceId requerido' };
  if (!claveAdmin) return { ok: false, error: 'claveAdmin (8 dígitos) requerida' };
  // Validar clave admin + rol MASTER
  var auth = verificarClaveAdmin({
    clave: claveAdmin,
    accion: 'ESPIA_INICIAR',
    refDocumento: deviceId
  });
  if (!auth.ok) return auth;
  if (!auth.data || !auth.data.autorizado) {
    return { ok: false, error: (auth.data && auth.data.error) || 'Clave incorrecta' };
  }
  if (String(auth.data.rol || '').toUpperCase() !== 'MASTER') {
    return { ok: false, error: 'Solo MASTER puede iniciar espía. Tu rol: ' + auth.data.rol };
  }
  // [v2.43.59] Limpiar sesiones expiradas como mantenimiento on-write
  try { _purgarSesionesAntiguas(); } catch(_){}

  // [v2.43.62] Detectar sesión PENDIENTE/CONECTANDO/EN_VIVO para mismo deviceId
  // (lock al buscar+crear para evitar race entre 2 masters).
  var lockCre = LockService.getScriptLock();
  try { lockCre.waitLock(10000); } catch(_) { return { ok: false, error: 'Lock timeout' }; }
  try {
    var shCheck = _getHojaSignaling();
    var dataC = shCheck.getDataRange().getValues();
    var hdrsC = dataC[0];
    var iDev = hdrsC.indexOf('deviceId');
    var iEst = hdrsC.indexOf('estado');
    var iFch = hdrsC.indexOf('fecha');
    for (var ci = dataC.length - 1; ci >= 1; ci--) {
      if (String(dataC[ci][iDev]) !== deviceId) continue;
      var estC = String(dataC[ci][iEst] || '').toUpperCase();
      if (estC === 'CERRADA') continue;
      var fchC = dataC[ci][iFch];
      var fchMs = fchC instanceof Date ? fchC.getTime() : new Date(fchC).getTime();
      // Si la sesión vieja aún no expiró → bloquear
      if ((Date.now() - fchMs) < ESPIA_TTL_MS) {
        return { ok: false, error: 'Ya hay una sesión activa con este dispositivo. Espera ' + Math.ceil((ESPIA_TTL_MS - (Date.now() - fchMs)) / 60000) + 'min o cierra la anterior.' };
      }
    }
  } finally { try { lockCre.releaseLock(); } catch(_){} }

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
  // [v2.43.67] FLUSH OBLIGATORIO — Apps Script bufferea appendRow y el
  // siguiente HTTP request (espiaSubirOferta) puede leer ANTES del commit.
  // Síntoma: "Sesión no encontrada" en la petición inmediata posterior.
  try { SpreadsheetApp.flush(); } catch(_){}

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
  // [v2.43.62] Validar transición FSM
  var rowChk = _buscarSesion(sesionId);
  if (!rowChk) return { ok: false, error: 'Sesión no encontrada' };
  if (!_validarTransicionEstado(rowChk.estado, 'CONECTANDO')) {
    return { ok: false, error: 'Transición inválida: ' + rowChk.estado + '→CONECTANDO' };
  }
  return _actualizarColumnaSesion(sesionId, 'sdpRespuesta', sdp, { estado: 'CONECTANDO' });
}

// [v2.43.62] FSM válida del espía
function _validarTransicionEstado(actual, nuevo) {
  var a = String(actual || '').toUpperCase();
  var n = String(nuevo || '').toUpperCase();
  var TRANS = {
    'PENDIENTE':  ['CONECTANDO', 'CERRADA'],
    'CONECTANDO': ['EN_VIVO', 'CERRADA'],
    'EN_VIVO':    ['CERRADA'],
    'CERRADA':    []
  };
  return (TRANS[a] || []).indexOf(n) >= 0;
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
  // [v2.43.61] Usar helper atómico que lee + agrega + escribe bajo lock
  var col = (lado === 'master') ? 'iceMaster' : 'iceDevice';
  return _agregarAArrayJsonSesion(sesionId, col, { ts: Date.now(), ice: ice });
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
  var tipo     = String(params.tipo || '').toLowerCase();
  var ts       = parseInt(params.ts) || Date.now();
  var b64      = String(params.contenido || '');
  var sesionId = String(params.sesionId || '').trim();
  if (!deviceId || !tipo || !b64) return { ok: false, error: 'Requiere deviceId, tipo, contenido' };

  // [v2.43.59] Validar tamaño máximo: 20MB decodificado ≈ 27MB base64
  if (b64.length > 28 * 1024 * 1024) {
    return { ok: false, error: 'Chunk demasiado grande (>20MB decodificado)' };
  }
  // [v2.43.59] Validar que el deviceId existe + que hay sesión activa para él
  try {
    var dispShs = getSheet('DISPOSITIVOS');
    if (dispShs) {
      var dispData = dispShs.getDataRange().getValues();
      var dispHdrs = dispData[0];
      var idxDevId = dispHdrs.indexOf('ID_Dispositivo');
      if (idxDevId < 0) idxDevId = dispHdrs.indexOf('deviceId');
      var existe = false;
      if (idxDevId >= 0) {
        for (var di = 1; di < dispData.length; di++) {
          if (String(dispData[di][idxDevId]).trim() === deviceId) { existe = true; break; }
        }
      }
      if (!existe) return { ok: false, error: 'deviceId no autorizado' };
    }
  } catch(_){}
  // Validar sesión activa si vino sesionId
  if (sesionId) {
    var row = _buscarSesion(sesionId);
    if (!row || String(row.deviceId) !== deviceId) {
      return { ok: false, error: 'sesionId no corresponde a este deviceId' };
    }
    if (_sesionExpiro(row)) return { ok: false, error: 'sesión expirada' };
  }

  try {
    var carpeta = _getCarpetaEspiaBuffer(deviceId);
    var nombre = deviceId + '_' + tipo + '_' + ts + '.webm';
    var bytes;
    try { bytes = Utilities.base64Decode(b64); }
    catch(eD) { return { ok: false, error: 'Base64 inválido: ' + eD.message }; }
    var blob = Utilities.newBlob(bytes, 'video/webm', nombre);
    var file = carpeta.createFile(blob);
    return { ok: true, data: { fileId: file.getId(), nombre: nombre } };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

// [v2.43.59] Limpieza automática de sesiones viejas (>24h cerradas o expiradas).
// Llamado on-write en espiaCrearSesion (mantenimiento ligero).
function _purgarSesionesAntiguas() {
  var sh = _getHojaSignaling();
  if (sh.getLastRow() < 2) return 0;
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var idxFecha  = hdrs.indexOf('fecha');
  var idxEstado = hdrs.indexOf('estado');
  var ahora = Date.now();
  var limite24h = 24 * 60 * 60 * 1000;
  var borradas = 0;
  // Iterar desde el final para no desincronizar
  for (var i = data.length - 1; i >= 1; i--) {
    var fechaVal = data[i][idxFecha];
    var fechaMs = fechaVal instanceof Date ? fechaVal.getTime() : new Date(fechaVal).getTime();
    if (isNaN(fechaMs)) continue;
    var diffH = (ahora - fechaMs);
    var est = String(data[i][idxEstado] || '').toUpperCase();
    // Borrar si: cerrada hace >24h, o expirada (TTL+24h), o orfana >24h
    if (diffH > limite24h || (est === 'CERRADA' && diffH > 2 * 60 * 60 * 1000)) {
      // Auditar antes de borrar si era PENDIENTE/EN_VIVO (sesión zombi)
      if (est !== 'CERRADA') {
        var obj = {};
        hdrs.forEach(function(h, j) { obj[h] = data[i][j]; });
        try { _logAuditoriaEspia(obj, 0, JSON.stringify({ motivo: 'TTL_EXPIRADA', lado: 'cleanup' })); } catch(_){}
      }
      sh.deleteRow(i + 1);
      borradas++;
    }
  }
  return borradas;
}

// ── Helpers internos ────────────────────────────────────────────────
function _getHojaSignaling() {
  // [v2.43.65] BUG FIX: getActiveSpreadsheet() devuelve NULL si el GAS es
  // standalone (no bound al SS). Usar getSpreadsheet() (Code.gs) que abre
  // por SPREADSHEET_ID de Properties — funciona en ambos casos.
  // Síntoma del bug: "Cannot read properties of null (reading 'getSheetByName')"
  // disparado al crear sesión espía → frontend cerraba modal con toast.
  var ss = getSpreadsheet();
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
  // [v2.43.67] Tolerante a nombres distintos de cabecera. Si la hoja fue
  // creada con un nombre viejo (idSesion, session_id, etc.) o si la cabecera
  // está desfazada, igual encontramos por COLUMNA 0 (donde siempre va el ID).
  var idxId = hdrs.indexOf('sesionId');
  if (idxId < 0) idxId = hdrs.indexOf('idSesion');
  if (idxId < 0) idxId = hdrs.indexOf('session_id');
  if (idxId < 0) idxId = 0; // fallback duro a la primera columna
  for (var i = data.length - 1; i >= 1; i--) {
    if (String(data[i][idxId]).trim() === String(sesionId).trim()) {
      var obj = {};
      hdrs.forEach(function(h, j) { obj[h] = data[i][j]; });
      obj._row = i + 1;
      return obj;
    }
  }
  // [v2.43.67] LOG diagnóstico — anotar qué se buscaba y qué hay
  try {
    var preview = [];
    for (var k = Math.max(1, data.length - 3); k < data.length; k++) {
      preview.push('[' + k + '] "' + data[k][idxId] + '"');
    }
    Logger.log('[_buscarSesion] NO ENCONTRADA · busqué="' + sesionId + '" idxId=' + idxId +
               ' hdrs=' + JSON.stringify(hdrs) + ' últimas3=' + preview.join(' | ') +
               ' totalFilas=' + data.length);
  } catch(_){}
  return null;
}

// [v2.43.67] Diagnóstico: dump del contenido actual de RTC_SIGNALING
// Ejecutar desde el editor para ver QUÉ tiene la hoja realmente.
function diagnosticarHojaEspia() {
  var sh = _getHojaSignaling();
  var data = sh.getDataRange().getValues();
  Logger.log('═══ HOJA RTC_SIGNALING — ' + data.length + ' filas (incluye cabecera) ═══');
  if (data.length === 0) { Logger.log('VACÍA'); return { ok: true, data: { filas: 0 } }; }
  Logger.log('Cabeceras: ' + JSON.stringify(data[0]));
  var max = Math.min(data.length, 6);
  for (var i = 1; i < max; i++) {
    Logger.log('Fila ' + i + ': sesionId="' + data[i][0] + '" estado="' + data[i][4] + '" fecha=' + data[i][1]);
  }
  if (data.length > max) Logger.log('... +' + (data.length - max) + ' más');
  return { ok: true, data: { filas: data.length, cabeceras: data[0] } };
}

function _actualizarColumnaSesion(sesionId, columna, valor, extras) {
  // [v2.43.61 LockService] Antes había race condition al hacer leer→modificar→escribir
  // sobre arrays JSON (iceMaster/iceDevice). Si master y device subían ICE al mismo
  // tiempo, uno sobreescribía al otro → pérdida de candidatos → conexión inicial
  // fallaba 5-15% del tiempo. Lock garantiza atomicidad.
  var lock = LockService.getScriptLock();
  try { lock.waitLock(15000); } catch(_) { return { ok: false, error: 'Lock timeout' }; }
  try {
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
    // [v2.43.67] Flush para que el polling del otro lado vea el cambio inmediato
    try { SpreadsheetApp.flush(); } catch(_){}
    return { ok: true };
  } finally {
    try { lock.releaseLock(); } catch(_){}
  }
}

// [v2.43.61] Versión atómica de append a array JSON — para ICE candidates.
// Lee la celda, agrega elemento, escribe — todo bajo lock para evitar perder ICE.
function _agregarAArrayJsonSesion(sesionId, columna, elemento) {
  var lock = LockService.getScriptLock();
  try { lock.waitLock(15000); } catch(_) { return { ok: false, error: 'Lock timeout' }; }
  try {
    var row = _buscarSesion(sesionId);
    if (!row) return { ok: false, error: 'Sesión no encontrada' };
    var sh = _getHojaSignaling();
    var hdrs = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
    var col = hdrs.indexOf(columna);
    if (col < 0) return { ok: false, error: 'Columna no existe: ' + columna };
    // Re-leer la celda DENTRO del lock (el row.X puede estar stale)
    var actualVal = sh.getRange(row._row, col + 1).getValue();
    var arr = [];
    try { arr = JSON.parse(actualVal || '[]'); } catch(_) { arr = []; }
    arr.push(elemento);
    sh.getRange(row._row, col + 1).setValue(JSON.stringify(arr));
    // [v2.43.67] Flush para que el polling del otro lado vea el ICE candidate inmediato
    try { SpreadsheetApp.flush(); } catch(_){}
    return { ok: true, data: { totalElementos: arr.length } };
  } finally {
    try { lock.releaseLock(); } catch(_){}
  }
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
    // [v2.43.65] Mismo bug que _getHojaSignaling — usar getSpreadsheet()
    var ss = getSpreadsheet();
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

// [v2.43.61] Cron semanal — borra chunks de buffer >7 días + sesiones RTC >24h.
// Sin esto Drive se llenaba 1.8GB/device/día y RTC_SIGNALING crecía O(n).
function cronLimpiarBufferEspia() {
  var resultado = { chunks_borrados: 0, sesiones_borradas: 0, errores: [] };
  try {
    var sesionesBorradas = _purgarSesionesAntiguas();
    resultado.sesiones_borradas = sesionesBorradas;
  } catch(eS) { resultado.errores.push('purga sesiones: ' + eS.message); }
  // Limpiar chunks viejos de Drive
  try {
    var rootName = 'MOS Espia Buffer';
    var folders = DriveApp.getFoldersByName(rootName);
    if (folders.hasNext()) {
      var root = folders.next();
      var subs = root.getFolders();
      var hace7d = Date.now() - 7 * 86400000;
      while (subs.hasNext()) {
        var sub = subs.next();
        var files = sub.getFiles();
        while (files.hasNext()) {
          var f = files.next();
          var creado = f.getDateCreated().getTime();
          if (creado < hace7d) {
            try { f.setTrashed(true); resultado.chunks_borrados++; }
            catch(eF) { resultado.errores.push(f.getName() + ': ' + eF.message); }
          }
        }
      }
    }
  } catch(eD) { resultado.errores.push('cleanup drive: ' + eD.message); }
  Logger.log('[cronLimpiarBufferEspia] ' + JSON.stringify(resultado));
  return { ok: true, data: resultado };
}

function setupEspiaCleanupTrigger() {
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === 'cronLimpiarBufferEspia') ScriptApp.deleteTrigger(t);
  });
  // Domingos a las 3 AM
  ScriptApp.newTrigger('cronLimpiarBufferEspia')
           .timeBased().onWeekDay(ScriptApp.WeekDay.SUNDAY).atHour(3).create();
  Logger.log('[espia cleanup] cron instalado domingos 3AM');
  return { ok: true, data: { instalado: true, schedule: 'domingos 3AM' } };
}

// [v2.43.61] Lista chunks de buffer para timeline en admin.
// params: { deviceId, desde (ts ms), hasta (ts ms), tipo (opcional) }
// Retorna [{ fileId, nombre, tipo, ts, tamMB, url }] ordenado por ts DESC.
function espiaListarChunks(params) {
  var deviceId = String(params.deviceId || '').trim();
  if (!deviceId) return { ok: false, error: 'Requiere deviceId' };
  var desde = parseInt(params.desde) || (Date.now() - 12 * 3600000); // 12h por default
  var hasta = parseInt(params.hasta) || Date.now();
  var tipoFiltro = String(params.tipo || '').toLowerCase();
  try {
    var sub = _getCarpetaEspiaBuffer(deviceId);
    var files = sub.getFiles();
    var arr = [];
    while (files.hasNext()) {
      var f = files.next();
      var nombre = f.getName();
      // Parsear timestamp del nombre: "deviceId_tipo_TIMESTAMP.webm"
      var m = nombre.match(/_(audio_video|screen|audio)_(\d+)\./);
      if (!m) continue;
      var tipoArchivo = m[1];
      var ts = parseInt(m[2]);
      if (isNaN(ts)) continue;
      if (ts < desde || ts > hasta) continue;
      if (tipoFiltro && tipoArchivo !== tipoFiltro) continue;
      arr.push({
        fileId:  f.getId(),
        nombre:  nombre,
        tipo:    tipoArchivo,
        ts:      ts,
        tamMB:   Math.round(f.getSize() / (1024 * 1024) * 10) / 10,
        url:     'https://drive.google.com/file/d/' + f.getId() + '/preview'
      });
    }
    arr.sort(function(a, b) { return b.ts - a.ts; });
    return { ok: true, data: { chunks: arr, total: arr.length, desde: desde, hasta: hasta } };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

// Push helper — si no existe el endpoint global, lo definimos mínimo aquí
// Para no chocar con otros, usamos el del Push.gs si existe
function _enviarPushDispositivo(deviceId, payload) {
  // [v2.43.59 FIX] Nombre correcto: enviarPushUsuario (NO enviarPushAUsuario).
  // Antes el push al device fallaba silencioso → master creía notificar pero device nunca se enteraba.
  // Buscamos el token FCM del dispositivo y mandamos data-only via _enviarPushFCM si existe,
  // o caemos a enviarPushUsuario con usuario=deviceId si esta función existe.
  try {
    // 1) Intentar buscar token FCM del device en DISPOSITIVOS
    // [v2.43.65] Mismo bug que _getHojaSignaling — usar getSpreadsheet()
    var sh = getSpreadsheet().getSheetByName('DISPOSITIVOS');
    if (sh) {
      var data = sh.getDataRange().getValues();
      var hdrs = data[0];
      var idxId  = hdrs.indexOf('ID_Dispositivo');
      if (idxId < 0) idxId = hdrs.indexOf('deviceId');
      var idxTok = hdrs.indexOf('FCM_Token');
      if (idxTok < 0) idxTok = hdrs.indexOf('fcmToken');
      if (idxId >= 0 && idxTok >= 0) {
        for (var i = 1; i < data.length; i++) {
          if (String(data[i][idxId]).trim() === String(deviceId)) {
            var tok = String(data[i][idxTok] || '').trim();
            if (tok && typeof _enviarPushFCM === 'function') {
              return _enviarPushFCM(tok, payload, { dataOnly: true });
            }
            break;
          }
        }
      }
    }
    // Fallback: usar enviarPushUsuario si existe (formato distinto)
    if (typeof enviarPushUsuario === 'function') {
      return enviarPushUsuario({
        usuario: deviceId,
        titulo:  'Sesión de monitoreo iniciada',
        cuerpo:  '',
        data:    payload
      });
    }
    Logger.log('[espia push] NO se encontró función push compatible. Payload: ' + JSON.stringify(payload));
    return { ok: false, error: 'No hay función push disponible' };
  } catch(e) {
    Logger.log('[espia push] ERROR: ' + e.message);
    return { ok: false, error: e.message };
  }
}
