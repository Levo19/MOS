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
    // [v2.43.75] Cambio de política: si la sesión vieja es PENDIENTE
    // (nunca conectó) o CONECTANDO (no llegó a EN_VIVO), la cerramos
    // automáticamente. Solo bloqueamos si está realmente EN_VIVO.
    // Antes: cualquier sesión <10min bloqueaba al master por sesiones
    // zombie que quedaron de intentos anteriores fallidos.
    for (var ci = dataC.length - 1; ci >= 1; ci--) {
      if (String(dataC[ci][iDev]) !== deviceId) continue;
      var estC = String(dataC[ci][iEst] || '').toUpperCase();
      if (estC === 'CERRADA') continue;
      var fchC = dataC[ci][iFch];
      var fchMs = fchC instanceof Date ? fchC.getTime() : new Date(fchC).getTime();
      if ((Date.now() - fchMs) >= ESPIA_TTL_MS) continue; // ya expiró
      // Si es EN_VIVO de OTRO master → bloquear (real conflicto)
      var masterOtra = String(dataC[ci][hdrsC.indexOf('masterId')] || '');
      if (estC === 'EN_VIVO' && masterOtra !== masterId) {
        return { ok: false, error: 'Hay una sesión EN VIVO con este dispositivo (otro master). Espera ' + Math.ceil((ESPIA_TTL_MS - (Date.now() - fchMs)) / 60000) + 'min o cierra la anterior.' };
      }
      // PENDIENTE/CONECTANDO o mismo master → autocerrar la zombie
      try {
        var iEstCol = hdrsC.indexOf('estado');
        var iDetFin = hdrsC.indexOf('detalleFin');
        shCheck.getRange(ci + 1, iEstCol + 1).setValue('CERRADA');
        if (iDetFin >= 0) shCheck.getRange(ci + 1, iDetFin + 1).setValue(JSON.stringify({ motivo: 'autocerrada_zombie', lado: 'crear_sesion', estadoAnterior: estC }));
        Logger.log('[espia] sesión zombi ' + dataC[ci][hdrsC.indexOf('sesionId')] + ' autocerrada (estado anterior: ' + estC + ')');
      } catch(eZ) { Logger.log('[espia] no pude autocerrar zombie: ' + eZ.message); }
    }
    try { SpreadsheetApp.flush(); } catch(_){}
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
    // [v2.43.71 GDPR] Cada chunk nuevo en PRIVATE (solo OWNER puede ver)
    try { file.setSharing(DriveApp.Access.PRIVATE, DriveApp.Permission.NONE); } catch(_){}
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
  var ss = getSpreadsheet();
  var sh = ss.getSheetByName('RTC_SIGNALING');
  if (!sh) {
    sh = ss.insertSheet('RTC_SIGNALING');
    sh.appendRow([
      'sesionId', 'fecha', 'masterId', 'deviceId',
      'estado', 'sdpOferta', 'sdpRespuesta',
      'iceMaster', 'iceDevice', 'streamsActivos', 'detalleFin',
      'sdpRenegOferta', 'sdpRenegRespuesta'
    ]);
    sh.getRange(1, 1, 1, 13).setFontWeight('bold')
      .setBackground('#0f172a').setFontColor('#a5b4fc');
    sh.setFrozenRows(1);
  } else {
    // [v2.43.82] Auto-agregar columnas de renegociación a hojas viejas
    var hdrs = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
    var nuevas = ['sdpRenegOferta', 'sdpRenegRespuesta'].filter(function(c){
      return hdrs.indexOf(c) < 0;
    });
    if (nuevas.length > 0) {
      var startCol = sh.getLastColumn() + 1;
      sh.getRange(1, startCol, 1, nuevas.length).setValues([nuevas])
        .setFontWeight('bold').setBackground('#0f172a').setFontColor('#a5b4fc');
    }
  }
  return sh;
}

// [v2.43.82] RENEGOCIACIÓN SDP — cliente WH/ME cuando agrega pantalla
// despues del PC inicial. Permite que cam/mic/GPS sean 100% independientes
// del momento en que el user acepta compartir pantalla.

function espiaSubirRenegOferta(params) {
  var sesionId = String(params.sesionId || '').trim();
  var sdp      = String(params.sdp || '');
  if (!sesionId || !sdp) return { ok: false, error: 'Requiere sesionId y sdp' };
  return _actualizarColumnaSesion(sesionId, 'sdpRenegOferta', sdp);
}

function espiaLeerRenegOferta(params) {
  var sesionId = String(params.sesionId || '').trim();
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  return { ok: true, data: { sdpRenegOferta: row.sdpRenegOferta || '' } };
}

function espiaSubirRenegRespuesta(params) {
  var sesionId = String(params.sesionId || '').trim();
  var sdp      = String(params.sdp || '');
  if (!sesionId || !sdp) return { ok: false, error: 'Requiere sesionId y sdp' };
  // Limpiar la oferta para que el cliente no la vuelva a leer
  return _actualizarColumnaSesion(sesionId, 'sdpRenegRespuesta', sdp, { sdpRenegOferta: '' });
}

function espiaLeerRenegRespuesta(params) {
  var sesionId = String(params.sesionId || '').trim();
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  return { ok: true, data: { sdpRenegRespuesta: row.sdpRenegRespuesta || '' } };
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

// [v2.43.68] Diagnóstico completo de un dispositivo target del espía.
// Verifica TODO lo que el espía necesita para funcionar end-to-end.
// Editar PRIMERO el nombre/id del dispositivo target y luego ejecutar.
function diagnosticarDeviceEspia() {
  // ⬇⬇⬇ EDITAR ESTE ID con el que vas a espiar ⬇⬇⬇
  var deviceIdTarget = ''; // ej: 'df61a710-1e4f-4fee-bcc8-89759bd02b17'
  var nombreParcial  = 'Tablet zona2'; // si dejás deviceIdTarget vacío, busca por nombre
  // ⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆

  var sh = getSpreadsheet().getSheetByName('DISPOSITIVOS');
  if (!sh) { Logger.log('❌ Hoja DISPOSITIVOS no existe'); return { ok: false }; }
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var iId  = hdrs.indexOf('ID_Dispositivo'); if (iId < 0) iId = hdrs.indexOf('deviceId');
  var iNom = hdrs.indexOf('Nombre_Equipo');
  var iApp = hdrs.indexOf('App');
  var iEst = hdrs.indexOf('Estado');
  var iTok = hdrs.indexOf('FCM_Token'); if (iTok < 0) iTok = hdrs.indexOf('fcmToken');
  var iSes = hdrs.indexOf('Ultima_Sesion');
  var iCon = hdrs.indexOf('Ultima_Conexion');

  var found = null;
  for (var i = 1; i < data.length; i++) {
    var did = String(data[i][iId]);
    var nom = String(data[i][iNom] || '');
    if (deviceIdTarget && did === deviceIdTarget) { found = i; break; }
    if (!deviceIdTarget && nombreParcial && nom.toLowerCase().indexOf(nombreParcial.toLowerCase()) >= 0) {
      found = i; break;
    }
  }
  if (found === null) {
    Logger.log('❌ Dispositivo no encontrado. Buscado: ' + (deviceIdTarget || nombreParcial));
    return { ok: false };
  }

  var d = data[found];
  Logger.log('═══ DIAGNÓSTICO DEVICE ESPÍA ═══');
  Logger.log('Nombre:    ' + d[iNom]);
  Logger.log('ID:        ' + d[iId]);
  Logger.log('App:       ' + d[iApp] + ' ' + (String(d[iApp]).toLowerCase() === 'mos' ? '⚠ MOS Admin NO puede ser target del espía' : ''));
  Logger.log('Estado:    ' + d[iEst]);
  Logger.log('Usuario:   ' + (d[iSes] || '(sin login)'));
  Logger.log('Última conexión: ' + d[iCon]);
  var tok = String(d[iTok] || '').trim();
  if (tok) {
    Logger.log('FCM_Token (DISPOSITIVOS): [' + tok.length + ' chars] · ' + tok.substring(0, 20) + '...');
  } else {
    Logger.log('FCM_Token (DISPOSITIVOS): vacío (esto es OK — los tokens reales viven en PUSH_TOKENS)');
  }
  // [v2.43.68b] Verificar PUSH_TOKENS — es donde REALMENTE viven los tokens
  var tokensPushTokens = _buscarTokensPushPorDeviceId(d[iId]);
  if (tokensPushTokens.length === 0) {
    Logger.log('🚨 PUSH_TOKENS: NINGÚN token activo encontrado para este deviceId');
    Logger.log('   → El device tiene que abrir MosExpress/WH y aprobar notifs para registrar.');
    Logger.log('   → Verifica que la columna deviceId de PUSH_TOKENS esté llena para este dispositivo.');
  } else {
    Logger.log('✅ PUSH_TOKENS: ' + tokensPushTokens.length + ' token(s) activo(s) registrados');
    tokensPushTokens.forEach(function(t, i) {
      Logger.log('   [' + (i+1) + '] ' + t.substring(0, 20) + '... (' + t.length + ' chars)');
    });
  }
  // Verificar Permisos_JSON (cam/mic/screen)
  var iPerm = hdrs.indexOf('Permisos_JSON');
  if (iPerm >= 0) {
    var permRaw = String(d[iPerm] || '');
    if (!permRaw) {
      Logger.log('⚠ Permisos_JSON vacío — el device NO ha autorizado cam/mic/pantalla');
    } else {
      Logger.log('Permisos:  ' + permRaw);
    }
  }
  return { ok: true, found: found };
}

// [v2.43.69e] REPARAR cabeceras de RTC_SIGNALING — operación liviana sin
// borrar la hoja. Útil cuando resetearHojaSignaling timeoutea entre borrar
// e insertar — queda la hoja con cabeceras vacías. Esta función solo
// escribe las cabeceras correctas en la fila 1 (overwrite). 1 sola operación.
function repararCabecerasSignaling() {
  var ss = getSpreadsheet();
  var sh = ss.getSheetByName('RTC_SIGNALING');
  if (!sh) {
    // No existe → crear con cabeceras
    sh = ss.insertSheet('RTC_SIGNALING');
    Logger.log('[reparar signaling] hoja no existía — creada');
  }
  var cabeceras = [
    'sesionId', 'fecha', 'masterId', 'deviceId',
    'estado', 'sdpOferta', 'sdpRespuesta',
    'iceMaster', 'iceDevice', 'streamsActivos', 'detalleFin'
  ];
  // Forzar 11 columnas mínimo
  if (sh.getMaxColumns() < 11) {
    sh.insertColumnsAfter(sh.getMaxColumns(), 11 - sh.getMaxColumns());
  }
  // Escribir cabeceras directo en fila 1 (overwrite si había algo)
  sh.getRange(1, 1, 1, 11).setValues([cabeceras])
    .setFontWeight('bold').setBackground('#0f172a').setFontColor('#a5b4fc');
  sh.setFrozenRows(1);
  Logger.log('[reparar signaling] cabeceras escritas correctamente: ' + JSON.stringify(cabeceras));
  return { ok: true, data: { mensaje: 'Cabeceras OK', cabeceras: cabeceras } };
}

// [v2.43.69] RESET de la hoja RTC_SIGNALING — borra TODAS las sesiones
// (que no sirven igual porque el WebRTC es efímero) y la recrea con cabeceras
// correctas. Útil cuando se corrompieron las cabeceras o existían sesiones
// históricas con esquema viejo (síntoma: "Columna no existe: sdpOferta").
// Ejecutar desde el editor UNA vez.
function resetearHojaSignaling() {
  var ss = getSpreadsheet();
  var sh = ss.getSheetByName('RTC_SIGNALING');
  var sesionesAntes = 0;
  if (sh) {
    sesionesAntes = Math.max(0, sh.getLastRow() - 1);
    ss.deleteSheet(sh);
    Logger.log('[reset signaling] borrada hoja vieja con ' + sesionesAntes + ' sesiones');
  }
  // Recrear con cabeceras correctas
  var nueva = ss.insertSheet('RTC_SIGNALING');
  nueva.appendRow([
    'sesionId', 'fecha', 'masterId', 'deviceId',
    'estado', 'sdpOferta', 'sdpRespuesta',
    'iceMaster', 'iceDevice', 'streamsActivos', 'detalleFin'
  ]);
  nueva.getRange(1, 1, 1, 11).setFontWeight('bold')
       .setBackground('#0f172a').setFontColor('#a5b4fc');
  nueva.setFrozenRows(1);
  Logger.log('[reset signaling] hoja recreada con cabeceras correctas');
  return { ok: true, data: { sesionesAntes: sesionesAntes, mensaje: 'Hoja RTC_SIGNALING reseteada' } };
}

// [v2.43.72c] Dump de PUSH_TOKENS para ver TODAS las filas que tocan un deviceId
// o token. Detecta espacios invisibles, mismo token en filas distintas, etc.
function dumpPushTokens() {
  var deviceIdBuscar = 'ff2c5833-c69b-4db4-bbe2-beb32920911f';
  var tokenSubstring = 'cuDAte7p';  // las primeras letras del token (lo que viste en console)

  var sh = getSpreadsheet().getSheetByName('PUSH_TOKENS');
  if (!sh) { Logger.log('Hoja PUSH_TOKENS no existe'); return; }
  var data = sh.getDataRange().getValues();
  Logger.log('═══ DUMP PUSH_TOKENS — ' + (data.length - 1) + ' filas ═══');
  Logger.log('Cabeceras: ' + JSON.stringify(data[0]));
  Logger.log('───');
  var hdrs = data[0];
  var iTok = hdrs.indexOf('token');
  var iUser = hdrs.indexOf('usuario');
  var iApp = hdrs.indexOf('appOrigen');
  var iAct = hdrs.indexOf('activo');
  var iDev = hdrs.indexOf('deviceId');
  var iUlt = hdrs.indexOf('ultimaVez');
  Logger.log('Buscando: deviceId=' + deviceIdBuscar + ' OR token contiene ' + tokenSubstring);
  Logger.log('───');
  var encontrados = 0;
  for (var i = 1; i < data.length; i++) {
    var dev = String(data[i][iDev] || '');
    var tok = String(data[i][iTok] || '');
    var matchDev = dev.indexOf(deviceIdBuscar.substring(0, 8)) >= 0;
    var matchTok = tok.indexOf(tokenSubstring) >= 0;
    if (matchDev || matchTok) {
      encontrados++;
      Logger.log('FILA ' + (i + 1) + ':');
      Logger.log('  token:     ' + tok.substring(0, 40) + '...');
      Logger.log('  usuario:   "' + data[i][iUser] + '"');
      Logger.log('  appOrigen: "' + data[i][iApp] + '"');
      Logger.log('  activo:    ' + data[i][iAct] + ' (typeof: ' + typeof data[i][iAct] + ')');
      Logger.log('  deviceId:  "' + dev + '" (length: ' + dev.length + ')');
      Logger.log('  ultimaVez: ' + data[i][iUlt]);
      Logger.log('  matchDev=' + matchDev + ' matchTok=' + matchTok);
    }
  }
  if (encontrados === 0) {
    Logger.log('🚨 NINGUNA fila matchea ni el deviceId ni el token. El registro NUNCA llegó.');
  } else {
    Logger.log('───');
    Logger.log('Total filas con ese device/token: ' + encontrados);
  }
  return { ok: true, data: { encontrados: encontrados } };
}

// [v2.43.72] Diagnóstico COMPLETO del último intento de espía de un device.
// Lee última sesión en RTC_SIGNALING + auditoria + simula push (sin enviar).
// Reemplaza la necesidad de mirar logs de Apps Script (que pueden ser difíciles
// de encontrar). Editar deviceIdTarget y ejecutar.
function diagnosticarUltimoEspia() {
  // ⬇⬇⬇ EDITAR ⬇⬇⬇
  var deviceIdTarget = 'ff2c5833-c69b-4db4-bbe2-beb32920911f';
  // ⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆

  Logger.log('═══ DIAGNÓSTICO ÚLTIMO ESPÍA · ' + deviceIdTarget + ' ═══');

  // 1. Buscar última sesión en RTC_SIGNALING
  try {
    var sh = _getHojaSignaling();
    var data = sh.getDataRange().getValues();
    if (data.length < 2) {
      Logger.log('🚨 RTC_SIGNALING está VACÍA (solo cabecera). Nunca se creó una sesión.');
      Logger.log('   → El master nunca llamó espiaCrearSesion exitosamente.');
    } else {
      var hdrs = data[0];
      var iDev = hdrs.indexOf('deviceId');
      var iSes = hdrs.indexOf('sesionId');
      var iFec = hdrs.indexOf('fecha');
      var iEst = hdrs.indexOf('estado');
      var iSdpO = hdrs.indexOf('sdpOferta');
      var iSdpR = hdrs.indexOf('sdpRespuesta');
      var iIceM = hdrs.indexOf('iceMaster');
      var iIceD = hdrs.indexOf('iceDevice');
      var ultima = null;
      for (var i = data.length - 1; i >= 1; i--) {
        if (String(data[i][iDev]) === deviceIdTarget) { ultima = data[i]; break; }
      }
      if (!ultima) {
        Logger.log('🚨 NO HAY ninguna sesión en RTC_SIGNALING para este device.');
        Logger.log('   → El master clickeó 🛰️ pero espiaCrearSesion NO se ejecutó completamente.');
        Logger.log('   → Causas: clave admin incorrecta, lock timeout, excepción interna.');
      } else {
        Logger.log('📋 Última sesión:');
        Logger.log('   sesionId: ' + ultima[iSes]);
        Logger.log('   fecha:    ' + ultima[iFec]);
        Logger.log('   estado:   ' + ultima[iEst]);
        Logger.log('   sdpOferta:    ' + (ultima[iSdpO] ? '✓ presente (' + String(ultima[iSdpO]).length + ' chars)' : '✗ vacío'));
        Logger.log('   sdpRespuesta: ' + (ultima[iSdpR] ? '✓ presente (' + String(ultima[iSdpR]).length + ' chars)' : '✗ vacío'));
        try {
          var iceM = JSON.parse(ultima[iIceM] || '[]');
          var iceD = JSON.parse(ultima[iIceD] || '[]');
          Logger.log('   iceMaster: ' + iceM.length + ' candidates');
          Logger.log('   iceDevice: ' + iceD.length + ' candidates · ' + (iceD.length === 0 ? '🚨 device NUNCA respondió' : '✓'));
        } catch(_){}
        var fechaMs = ultima[iFec] instanceof Date ? ultima[iFec].getTime() : new Date(ultima[iFec]).getTime();
        var hace = Math.round((Date.now() - fechaMs) / 1000);
        Logger.log('   hace: ' + hace + ' segundos');
      }
    }
  } catch(eS) { Logger.log('Error leyendo RTC_SIGNALING: ' + eS.message); }

  // 2. Simular búsqueda de tokens (no envía push)
  Logger.log('───');
  var tokens = _buscarTokensPushPorDeviceId(deviceIdTarget);
  if (tokens.length === 0) {
    Logger.log('🚨 NO hay tokens FCM activos para este deviceId en PUSH_TOKENS');
    Logger.log('   → El push NUNCA puede llegar al device');
  } else {
    Logger.log('✅ ' + tokens.length + ' token(s) FCM activo(s)');
    tokens.forEach(function(t, i) { Logger.log('   [' + (i+1) + '] ' + t.substring(0, 30) + '...'); });
  }

  // 3. Test de envío REAL de push silencioso (data-only) — sin sesión
  Logger.log('───');
  Logger.log('🧪 Enviando push de PRUEBA al device (data-only, ignorado por SW)...');
  try {
    var result = _enviarPushDispositivo(deviceIdTarget, {
      idNotif: 'TEST_DIAG',
      sesionId: 'TEST-' + Date.now(),
      masterId: 'diagnostic',
      ttl: 0,
      silencioso: true,
      _esTest: true
    });
    Logger.log('   resultado: ' + JSON.stringify(result));
    if (result.ok) {
      Logger.log('✅ Push enviado exitosamente. Si el device no lo recibe → problema del cliente.');
      Logger.log('   → Verificá en consola del target: "[SW msg] cmd recibido:" o "[Push] comando foreground"');
    } else {
      Logger.log('🚨 Push FALLÓ: ' + result.error);
    }
  } catch(eP) { Logger.log('Excepción enviando push: ' + eP.message); }

  return { ok: true, data: { mensaje: 'Mirá los logs arriba' } };
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
    var ss = getSpreadsheet();
    var sh = ss.getSheetByName('AUDITORIA_ESPIA');
    if (!sh) {
      sh = ss.insertSheet('AUDITORIA_ESPIA');
      sh.appendRow(['fecha', 'sesionId', 'masterId', 'deviceId',
                    'duracionSeg', 'streamsActivos', 'detalle',
                    'chunksCount', 'chunksPesoMB', 'iceCountMaster', 'iceCountDevice',
                    'sdpOK', 'motivoFin', 'streamsConectados']);
      sh.getRange(1, 1, 1, 14).setFontWeight('bold').setBackground('#0f172a').setFontColor('#fbbf24');
      sh.setFrozenRows(1);
    } else {
      // [v2.43.71] Agregar cabeceras nuevas a hojas viejas sin perderse
      var hdrs = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
      var faltan = ['chunksCount', 'chunksPesoMB', 'iceCountMaster', 'iceCountDevice',
                    'sdpOK', 'motivoFin', 'streamsConectados'].filter(function(c){ return hdrs.indexOf(c) < 0; });
      if (faltan.length > 0) {
        var startCol = sh.getLastColumn() + 1;
        sh.getRange(1, startCol, 1, faltan.length).setValues([faltan])
          .setFontWeight('bold').setBackground('#0f172a').setFontColor('#fbbf24');
      }
    }
    // [v2.43.71] Métricas granulares calculadas desde la fila de RTC_SIGNALING
    var iceM = 0, iceD = 0, sdpOK = false;
    try {
      iceM = (JSON.parse(row.iceMaster || '[]') || []).length;
      iceD = (JSON.parse(row.iceDevice || '[]') || []).length;
      sdpOK = !!(row.sdpOferta && row.sdpRespuesta);
    } catch(_){}
    // Contar chunks en Drive para este device durante la sesión
    var chunksCount = 0, chunksPesoMB = 0;
    try {
      if (row.deviceId && row.fecha) {
        var inicioMs = row.fecha instanceof Date ? row.fecha.getTime() : new Date(row.fecha).getTime();
        var finMs = inicioMs + (duracionSeg * 1000);
        var sub = _getCarpetaEspiaBuffer(row.deviceId);
        var files = sub.getFiles();
        while (files.hasNext()) {
          var f = files.next();
          var created = f.getDateCreated().getTime();
          if (created >= inicioMs && created <= finMs + 30000) { // +30s buffer
            chunksCount++;
            chunksPesoMB += f.getSize() / (1024 * 1024);
          }
        }
      }
    } catch(_){}
    var streamsConectados = '';
    try {
      var s = row.streamsActivos ? JSON.parse(row.streamsActivos) : null;
      if (s) streamsConectados = Object.keys(s).filter(function(k){ return s[k]; }).join('+');
    } catch(_){}
    var motivoFin = '';
    try {
      var d = detalle ? JSON.parse(detalle) : null;
      if (d && d.motivo) motivoFin = d.motivo;
    } catch(_){}
    sh.appendRow([
      new Date(),
      row.sesionId,
      row.masterId,
      row.deviceId,
      duracionSeg,
      row.streamsActivos || '',
      detalle,
      chunksCount,
      Math.round(chunksPesoMB * 10) / 10,
      iceM,
      iceD,
      sdpOK ? 1 : 0,
      motivoFin,
      streamsConectados
    ]);
  } catch(e) { Logger.log('[espia auditoria] ' + e.message); }
}

function _getCarpetaEspiaBuffer(deviceId) {
  var rootName = 'MOS Espia Buffer';
  var folders = DriveApp.getFoldersByName(rootName);
  var root;
  if (folders.hasNext()) {
    root = folders.next();
  } else {
    root = DriveApp.createFolder(rootName);
    // [v2.43.71 GDPR] Bloquear compartición externa del folder root.
    // Solo el OWNER (el dueño del script) y usuarios que se le agreguen
    // manualmente como editor pueden acceder. No es ANYONE_WITH_LINK.
    try {
      root.setSharing(DriveApp.Access.PRIVATE, DriveApp.Permission.NONE);
    } catch(eS) { Logger.log('[espia GDPR] setSharing fallo: ' + eS.message); }
  }
  var subName = String(deviceId).replace(/[^a-zA-Z0-9_\-]/g, '_');
  var subs = root.getFoldersByName(subName);
  var sub;
  if (subs.hasNext()) {
    sub = subs.next();
  } else {
    sub = root.createFolder(subName);
    try { sub.setSharing(DriveApp.Access.PRIVATE, DriveApp.Permission.NONE); } catch(_){}
  }
  return sub;
}

// [v2.43.71] Endurecer permisos de TODOS los chunks ya existentes
// (one-shot manual desde editor o llamado por trigger semanal).
// Para folders viejos creados antes del fix, los pone PRIVATE.
function endurecerPermisosBufferEspia() {
  var resultado = { foldersAjustados: 0, chunksAjustados: 0, errores: [] };
  try {
    var folders = DriveApp.getFoldersByName('MOS Espia Buffer');
    if (!folders.hasNext()) {
      Logger.log('[GDPR] No existe el folder MOS Espia Buffer (sin chunks aún)');
      return { ok: true, data: resultado };
    }
    var root = folders.next();
    try { root.setSharing(DriveApp.Access.PRIVATE, DriveApp.Permission.NONE); resultado.foldersAjustados++; }
    catch(eR) { resultado.errores.push('root: ' + eR.message); }
    var subs = root.getFolders();
    while (subs.hasNext()) {
      var sub = subs.next();
      try { sub.setSharing(DriveApp.Access.PRIVATE, DriveApp.Permission.NONE); resultado.foldersAjustados++; }
      catch(eSb) { resultado.errores.push(sub.getName() + ': ' + eSb.message); }
      var files = sub.getFiles();
      while (files.hasNext()) {
        var f = files.next();
        try { f.setSharing(DriveApp.Access.PRIVATE, DriveApp.Permission.NONE); resultado.chunksAjustados++; }
        catch(eF) { resultado.errores.push(f.getName() + ': ' + eF.message); }
      }
    }
    Logger.log('[GDPR] ' + JSON.stringify(resultado));
    return { ok: true, data: resultado };
  } catch(e) {
    return { ok: false, error: e.message };
  }
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

// [v2.43.73 BUG FIX FUNDAMENTAL] Push del espía usa AHORA _enviarPushTokens
// (que SÍ existe en Push.gs y funciona). Antes intentaba usar _enviarPushFCM
// que NUNCA fue definida en ningún archivo → el espía SIEMPRE fallaba con
// "_enviarPushFCM no disponible" silenciosamente → device nunca recibía.
//
// Además: usar el MÁS RECIENTE token aunque esté marcado activo=false. FCM
// puede haberlos marcado UNREGISTERED por rotación pero el último registrado
// probablemente está vivo (es el que el cliente WH acaba de registrar).
function _enviarPushDispositivo(deviceId, payload) {
  try {
    var tokens = _buscarTokensPushPorDeviceId(deviceId);
    if (tokens.length === 0) {
      // [v2.43.73] Fallback: si no hay activos, intentar con el último
      // registrado aunque esté como activo=false. Mejor intentar que
      // rendirse — si FCM lo rechaza, no perdimos nada.
      tokens = _ultimoTokenRegistradoPorDeviceId(deviceId);
      if (tokens.length === 0) {
        Logger.log('[espia push] NO hay NINGÚN token FCM (ni activo ni inactivo) para deviceId=' + deviceId);
        return { ok: false, error: 'No hay tokens FCM registrados para este dispositivo' };
      }
      Logger.log('[espia push] Sin activos · usando último token (puede estar UNREGISTERED). Si funciona, reactivamos.');
    }
    // Usar _enviarPushTokens de Push.gs que SÍ existe
    var titulo = String(payload.titulo || 'MOS Espía');
    var cuerpo = String(payload.cuerpo || '');
    // _enviarPushTokens hace UrlFetchApp directo a FCM, con notification + webpush
    // Esto envía notif visible al device + data payload para que el SW lo intercepte
    var beforeCount = tokens.length;
    var dataPayload = {
      action:    String(payload.action || payload.idNotif || 'MOS_ESPIA_INICIAR'),
      idNotif:   String(payload.idNotif || 'MOS_ESPIA_INICIAR'),
      sesionId:  String(payload.sesionId || ''),
      masterId:  String(payload.masterId || ''),
      ttl:       String(payload.ttl || ''),
      silencioso: String(payload.silencioso || 'true')
    };
    _enviarPushTokensData(titulo, cuerpo, tokens, dataPayload);
    Logger.log('[espia push] enviado a ' + beforeCount + ' tokens del device ' + deviceId);
    return { ok: true, data: { enviados: beforeCount, totalTokens: beforeCount } };
  } catch(e) {
    Logger.log('[espia push] ERROR: ' + e.message);
    return { ok: false, error: e.message };
  }
}

// [v2.43.73] Versión con data payload (para que SW intercepte como mos_command).
// _enviarPushTokens original NO acepta data — solo notification visible.
// Esto es lo que faltaba: el push del espía necesita data.action para que
// el SW haga postMessage({type:'mos_command', data:...}) al cliente.
function _enviarPushTokensData(titulo, cuerpo, tokens, dataPayload) {
  if (!tokens || tokens.length === 0) return;
  var projectId   = PropertiesService.getScriptProperties().getProperty('FCM_PROJECT_ID');
  var accessToken = _getFcmAccessToken();
  var url = 'https://fcm.googleapis.com/v1/projects/' + projectId + '/messages:send';
  tokens.forEach(function(token, idx) {
    if (!token) return;
    try {
      var resp = UrlFetchApp.fetch(url, {
        method: 'post',
        contentType: 'application/json',
        headers: { 'Authorization': 'Bearer ' + accessToken },
        payload: JSON.stringify({
          message: {
            token: token,
            data: dataPayload, // ← clave: el SW lee payload.data.action
            // Notification ALSO para que sea visible si la app no está activa
            notification: { title: titulo, body: cuerpo },
            webpush: {
              notification: {
                title: titulo, body: cuerpo,
                icon:  'https://levo19.github.io/MOS/icon-192.png',
                badge: 'https://levo19.github.io/MOS/icon-192.png',
                vibrate: [100, 50, 100]
              }
            }
          }
        }),
        muteHttpExceptions: true
      });
      var code = resp.getResponseCode();
      if (code === 200) {
        Logger.log('[Push data] OK token[' + idx + ']');
      } else {
        Logger.log('[Push data] Error HTTP ' + code + ' token[' + idx + ']: ' + resp.getContentText().substring(0, 200));
      }
    } catch(e) {
      Logger.log('[Push data] excepción token[' + idx + ']: ' + e.message);
    }
  });
}

// [v2.43.68b] Helper que devuelve tokens FCM ACTIVOS del device
function _buscarTokensPushPorDeviceId(deviceId) {
  var resultado = [];
  try {
    var sh = getSpreadsheet().getSheetByName('PUSH_TOKENS');
    if (!sh) return resultado;
    var data = sh.getDataRange().getValues();
    if (data.length < 2) return resultado;
    var hdrs = data[0];
    var iTok    = hdrs.indexOf('token');
    var iActivo = hdrs.indexOf('activo');
    var iDev    = hdrs.indexOf('deviceId');
    if (iDev < 0 || iTok < 0) return resultado;
    var devStr = String(deviceId).trim();
    for (var i = 1; i < data.length; i++) {
      var rowDev = String(data[i][iDev] || '').trim();
      if (rowDev !== devStr) continue;
      var act = data[i][iActivo];
      if (act === false || String(act) === '0' || String(act).toLowerCase() === 'false') continue;
      var tok = String(data[i][iTok] || '').trim();
      if (tok) resultado.push(tok);
    }
  } catch(e) { Logger.log('[_buscarTokensPushPorDeviceId] ' + e.message); }
  return resultado;
}

// [v2.43.73] Devuelve SOLO el último token registrado para un device, sin
// filtrar por activo. Para fallback cuando todos están UNREGISTERED.
function _ultimoTokenRegistradoPorDeviceId(deviceId) {
  try {
    var sh = getSpreadsheet().getSheetByName('PUSH_TOKENS');
    if (!sh) return [];
    var data = sh.getDataRange().getValues();
    if (data.length < 2) return [];
    var hdrs = data[0];
    var iTok = hdrs.indexOf('token');
    var iDev = hdrs.indexOf('deviceId');
    var iUlt = hdrs.indexOf('ultimaVez');
    if (iDev < 0 || iTok < 0) return [];
    var devStr = String(deviceId).trim();
    var mejor = null;
    var mejorTs = 0;
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][iDev] || '').trim() !== devStr) continue;
      var tok = String(data[i][iTok] || '').trim();
      if (!tok) continue;
      var ts = 0;
      try { ts = new Date(data[i][iUlt]).getTime() || 0; } catch(_){}
      if (ts > mejorTs) { mejorTs = ts; mejor = tok; }
    }
    return mejor ? [mejor] : [];
  } catch(_) { return []; }
}
