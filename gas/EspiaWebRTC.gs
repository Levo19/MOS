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
// [v2.43.88] Límites de seguridad para evitar payloads gigantes que rompen Sheets
// (celda max ~50000 chars). SDP normal es 3-8KB; reneg con video puede llegar a 15KB.
var ESPIA_SDP_MAX_CHARS = 45000;
// ICE candidates: limitar array a 300 últimos por lado (~60KB JSON). Trickle ICE típico
// genera 5-15 candidates por endpoint; con restartIce x N puede crecer. Cortamos viejos.
var ESPIA_ICE_MAX_ITEMS = 300;

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

  // [v2.43.90] Push con reintentos. Devolvemos pushOk al master para que
  // muestre error claro si los 3 intentos fallaron (en vez de loader infinito).
  var pushOk = false;
  var pushIntentos = 0;
  try {
    var pushRes = _enviarPushDispositivoConRetry(deviceId, {
      idNotif: 'MOS_ESPIA_INICIAR',
      sesionId: sesionId,
      masterId: masterId,
      ttl: ESPIA_TTL_MS,
      silencioso: true
    }, 3);
    pushOk = !!(pushRes && pushRes.ok);
    pushIntentos = (pushRes && pushRes.data && pushRes.data.intentos) || 0;
    if (!pushOk) Logger.log('[espia] push fallo definitivo: ' + (pushRes && pushRes.error));
  } catch(e) { Logger.log('[espia] push excepción: ' + e.message); }

  // [v2.43.90] Token HMAC del master — el frontend lo guarda y lo manda en
  // cada call subsiguiente. sesionId ya no es secreto suficiente.
  var tokenMaster = _firmarToken(sesionId, 'master', deviceId);

  return { ok: true, data: {
    sesionId: sesionId,
    token: tokenMaster,
    ttl: ESPIA_TTL_MS,
    ahora: ahora.toISOString(),
    pushOk: pushOk,
    pushIntentos: pushIntentos
  } };
}

// ── 2. Master escribe oferta SDP ───────────────────────────────────
function espiaSubirOferta(params) {
  var sesionId = String(params.sesionId || '').trim();
  var sdp      = String(params.sdp || '');
  if (!sesionId || !sdp) return { ok: false, error: 'Requiere sesionId y sdp' };
  if (sdp.length > ESPIA_SDP_MAX_CHARS) return { ok: false, error: 'SDP demasiado grande (' + sdp.length + ' > ' + ESPIA_SDP_MAX_CHARS + ')' };
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  var authErr = _autenticarEndpoint(params, row);
  if (authErr) return authErr;
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
  if (sdp.length > ESPIA_SDP_MAX_CHARS) return { ok: false, error: 'SDP demasiado grande (' + sdp.length + ' > ' + ESPIA_SDP_MAX_CHARS + ')' };
  var rowChk = _buscarSesion(sesionId);
  if (!rowChk) return { ok: false, error: 'Sesión no encontrada' };
  var authErr = _autenticarEndpoint(params, rowChk);
  if (authErr) return authErr;
  if (!_validarTransicionEstado(rowChk.estado, 'CONECTANDO')) {
    return { ok: false, error: 'Transición inválida: ' + rowChk.estado + '→CONECTANDO' };
  }
  return _actualizarColumnaSesion(sesionId, 'sdpRespuesta', sdp, { estado: 'CONECTANDO' });
}

// [v2.43.87] FSM válida del espía + IDEMPOTENCIA.
// Antes: si cliente reintentaba subir respuesta (porque la primera falló o el
// master no la procesó), el segundo intento daba "Transición inválida: CONECTANDO→CONECTANDO".
// Ahora permitimos transición a sí mismo (operación idempotente).
function _validarTransicionEstado(actual, nuevo) {
  var a = String(actual || '').toUpperCase();
  var n = String(nuevo || '').toUpperCase();
  if (a === n) return true; // idempotente
  var TRANS = {
    'PENDIENTE':  ['CONECTANDO', 'EN_VIVO', 'CERRADA'],
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
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  var authErr = _autenticarEndpoint(params, row);
  if (authErr) return authErr;
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
  var streams  = params.streams || {};
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  var authErr = _autenticarEndpoint(params, row);
  if (authErr) return authErr;
  var estActual = String(row.estado || '').toUpperCase();
  if (estActual === 'CERRADA') {
    return { ok: false, error: 'Sesión ya cerrada · no se reportan streams' };
  }
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
  // [v2.43.90] Auth — sin esto, cualquiera con sesionId podía cerrar sesión ajena
  var authErr = _autenticarEndpoint(params, row);
  if (authErr) return authErr;
  // [v2.43.87] Idempotente: si ya está CERRADA, no auditar otra vez
  if (String(row.estado || '').toUpperCase() === 'CERRADA') {
    return { ok: true, data: { yaCerrada: true } };
  }

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
  // [CERO-GAS] verdad = mos.dispositivos. FAIL-CLOSED: si la validación no se puede resolver
  // (Supabase caído), se RECHAZA — no se deja pasar un chunk con deviceId sin verificar.
  try {
    var dsp = _dispositivoDesdeSombra(deviceId);
    if (!dsp) return { ok: false, error: 'deviceId no autorizado' };
  } catch(eDsp){ return { ok: false, error: 'validación de dispositivo no disponible' }; }
  // Validar sesión activa si vino sesionId
  if (sesionId) {
    var row = _buscarSesion(sesionId);
    if (!row || String(row.deviceId) !== deviceId) {
      return { ok: false, error: 'sesionId no corresponde a este deviceId' };
    }
    var authErrChk = _autenticarEndpoint(params, row);
    if (authErrChk) return authErrChk;
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
  if (sdp.length > ESPIA_SDP_MAX_CHARS) return { ok: false, error: 'SDP demasiado grande (' + sdp.length + ' > ' + ESPIA_SDP_MAX_CHARS + ')' };
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  var authErr = _autenticarEndpoint(params, row);
  if (authErr) return authErr;
  var est = String(row.estado || '').toUpperCase();
  if (est === 'CERRADA') return { ok: false, error: 'Sesión cerrada · no se acepta reneg' };
  if (_sesionExpiro(row)) return { ok: false, error: 'Sesión expirada', codigo: 'EXPIRADO' };
  return _actualizarColumnaSesion(sesionId, 'sdpRenegOferta', sdp, { sdpRenegRespuesta: '' });
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
  if (sdp.length > ESPIA_SDP_MAX_CHARS) return { ok: false, error: 'SDP demasiado grande (' + sdp.length + ' > ' + ESPIA_SDP_MAX_CHARS + ')' };
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  var authErr = _autenticarEndpoint(params, row);
  if (authErr) return authErr;
  var est = String(row.estado || '').toUpperCase();
  if (est === 'CERRADA') return { ok: false, error: 'Sesión cerrada' };
  return _actualizarColumnaSesion(sesionId, 'sdpRenegRespuesta', sdp, { sdpRenegOferta: '' });
}

function espiaLeerRenegRespuesta(params) {
  var sesionId = String(params.sesionId || '').trim();
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  return { ok: true, data: { sdpRenegRespuesta: row.sdpRenegRespuesta || '' } };
}

// ════════════════════════════════════════════════════════════════════
// [v2.43.89] BATCH SYNC — endpoint único de lectura
// ────────────────────────────────────────────────────────────────────
// Reemplaza los 3 setInterval del cliente (oferta + ice + estado) por 1.
// Antes: 3 polls × N devices × duración → ~7500 req/h por device EN_VIVO.
// Ahora: 1 poll consolidado → ~1500 req/h por device EN_VIVO. Reducción 80%.
//
// El lado pide solo lo que necesita vía flags `necesito` (booleans).
// Backend devuelve un snapshot atómico — 1 sola lectura de la fila + filter
// de ICE. Sin locks (read-only, eventually-consistent es ok para polling).
//
// Compat: los endpoints viejos siguen disponibles. Frontend nuevo migra a sync.
// ════════════════════════════════════════════════════════════════════
function espiaSync(params) {
  try {
    return _espiaSyncImpl(params);
  } catch(e) {
    _registrarExcepcionEspia('espiaSync', e, params);
    return { ok: false, error: 'Excepción interna: ' + e.message, codigo: 'EXCEPCION' };
  }
}

function _espiaSyncImpl(params) {
  var sesionId = String(params.sesionId || '').trim();
  var lado     = String(params.lado || '').toLowerCase();
  var iceDesde = parseInt(params.iceDesde) || 0;
  var necesito = params.necesito || {};
  if (!sesionId) return { ok: false, error: 'sesionId requerido' };
  if (lado !== 'master' && lado !== 'device') return { ok: false, error: 'lado: master|device' };

  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada', codigo: 'NO_EXISTE' };
  var authErr = _autenticarEndpoint(params, row);
  if (authErr) return authErr;
  if (_sesionExpiro(row)) return { ok: false, error: 'Sesión expirada', codigo: 'EXPIRADO' };

  var snap = {
    estado:   row.estado,
    expiraEn: _msHastaExpiracion(row),
    ahora:    Date.now()
  };
  if (row.streamsActivos) {
    try { snap.streamsActivos = JSON.parse(row.streamsActivos); } catch(_) { snap.streamsActivos = null; }
  }
  // [v2.43.93] Si está CERRADA, exponer motivo para que el peer muestre toast claro
  if (String(row.estado || '').toUpperCase() === 'CERRADA' && row.detalleFin) {
    try {
      var det = JSON.parse(row.detalleFin);
      snap.motivoFin = det.motivo || '';
      snap.ladoCierre = det.lado || '';
      snap.duracionSeg = det.duracionSeg || 0;
    } catch(_){}
  }

  // SDPs selectivos (solo los pedidos, no inflar respuesta)
  if (necesito.sdpOferta)         snap.sdpOferta         = row.sdpOferta         || '';
  if (necesito.sdpRespuesta)      snap.sdpRespuesta      = row.sdpRespuesta      || '';
  if (necesito.sdpRenegOferta)    snap.sdpRenegOferta    = row.sdpRenegOferta    || '';
  if (necesito.sdpRenegRespuesta) snap.sdpRenegRespuesta = row.sdpRenegRespuesta || '';

  // ICE del OTRO lado (yo leo lo que el otro publicó)
  if (necesito.ice) {
    var colIce = (lado === 'master') ? 'iceDevice' : 'iceMaster';
    var arr = [];
    try { arr = JSON.parse(row[colIce] || '[]'); } catch(_) { arr = []; }
    snap.ice = arr.filter(function(c) { return c && typeof c.ts === 'number' && c.ts > iceDesde; });
    snap.tsMax = arr.length ? arr[arr.length - 1].ts : iceDesde;
  }

  return { ok: true, data: snap };
}

// ════════════════════════════════════════════════════════════════════
// [v2.43.89] BATCH PUSH — endpoint único de escritura
// ────────────────────────────────────────────────────────────────────
// Sube múltiples cambios en una sola transacción (1 lock, 1 flush).
// Antes el cliente hacía 1 espiaAgregarIce por candidate → si ICE gathering
// emite 10 candidates en 100ms, eran 10 locks + 10 flushes consecutivos.
// Ahora batched: 1 sola escritura con el array merged.
//
// Acepta cualquier combinación de:
//   - ice: [{ts, ice}, ...] — array de candidates
//   - sdpOferta / sdpRespuesta / sdpRenegOferta / sdpRenegRespuesta
//   - streamsActivos: {audio, camara, pantalla}
//   - cerrar: { motivo } — atómico con el resto
//
// Devuelve `aplicado` con conteo de cada campo escrito.
// ════════════════════════════════════════════════════════════════════
function espiaPushBatch(params) {
  try {
    return _espiaPushBatchImpl(params);
  } catch(e) {
    _registrarExcepcionEspia('espiaPushBatch', e, params);
    return { ok: false, error: 'Excepción interna: ' + e.message, codigo: 'EXCEPCION' };
  }
}

function _espiaPushBatchImpl(params) {
  var sesionId = String(params.sesionId || '').trim();
  var lado     = String(params.lado || '').toLowerCase();
  if (!sesionId) return { ok: false, error: 'sesionId requerido' };
  if (lado !== 'master' && lado !== 'device') return { ok: false, error: 'lado: master|device' };

  // Validar tamaños de SDP fuera del lock (cheap)
  var camposSdp = ['sdpOferta', 'sdpRespuesta', 'sdpRenegOferta', 'sdpRenegRespuesta'];
  for (var ci = 0; ci < camposSdp.length; ci++) {
    var v = params[camposSdp[ci]];
    if (v != null && String(v).length > ESPIA_SDP_MAX_CHARS) {
      return { ok: false, error: camposSdp[ci] + ' demasiado grande (' + v.length + ')' };
    }
  }

  var lock = LockService.getScriptLock();
  try { lock.waitLock(15000); } catch(_) { return { ok: false, error: 'Lock timeout' }; }
  try {
    var row = _buscarSesion(sesionId);
    if (!row) return { ok: false, error: 'Sesión no encontrada' };
    var authErr = _autenticarEndpoint(params, row);
    if (authErr) return authErr;
    var estActual = String(row.estado || '').toUpperCase();
    if (estActual === 'CERRADA' && !params.cerrar) {
      return { ok: false, error: 'Sesión cerrada' };
    }

    var sh = _getHojaSignaling();
    var hdrs = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
    var updates = {}; // { columna: valor }
    var aplicado = {};

    // ── ICE batch (lado actual) ─────────────────────────────────
    if (Array.isArray(params.ice) && params.ice.length > 0) {
      var colIce = (lado === 'master') ? 'iceMaster' : 'iceDevice';
      var iIce = hdrs.indexOf(colIce);
      if (iIce >= 0) {
        var actualVal = sh.getRange(row._row, iIce + 1).getValue();
        var arr = [];
        try { arr = JSON.parse(actualVal || '[]'); } catch(_) { arr = []; }
        var now = Date.now();
        for (var k = 0; k < params.ice.length; k++) {
          var item = params.ice[k];
          // Permitir formato corto {ice} (auto-ts) o completo {ts, ice}
          if (item && item.ice) {
            arr.push({ ts: item.ts || (now + k), ice: item.ice });
          }
        }
        // Cap al límite global
        if (arr.length > ESPIA_ICE_MAX_ITEMS) arr = arr.slice(arr.length - ESPIA_ICE_MAX_ITEMS);
        updates[colIce] = JSON.stringify(arr);
        aplicado.ice = params.ice.length;
      }
    }

    // ── SDPs ────────────────────────────────────────────────────
    camposSdp.forEach(function(campo) {
      if (params[campo] != null) {
        updates[campo] = String(params[campo]);
        aplicado[campo] = true;
      }
    });
    // Política: subir reneg oferta limpia respuesta vieja; subir reneg respuesta limpia oferta
    if (updates.sdpRenegOferta && updates.sdpRenegRespuesta == null) updates.sdpRenegRespuesta = '';
    if (updates.sdpRenegRespuesta && updates.sdpRenegOferta == null) updates.sdpRenegOferta = '';

    // ── streamsActivos (device only) ────────────────────────────
    if (params.streamsActivos != null && lado === 'device') {
      updates.streamsActivos = JSON.stringify(params.streamsActivos);
      aplicado.streamsActivos = true;
      // Transición a EN_VIVO si veníamos de PENDIENTE/CONECTANDO
      if (estActual !== 'EN_VIVO' && estActual !== 'CERRADA') updates.estado = 'EN_VIVO';
    }

    // ── Subir respuesta de handshake inicial → CONECTANDO (compat con FSM) ──
    if (updates.sdpRespuesta && estActual === 'PENDIENTE') updates.estado = 'CONECTANDO';

    // ── Cierre atómico opcional ─────────────────────────────────
    var detalleCierre = null;
    if (params.cerrar && estActual !== 'CERRADA') {
      updates.estado = 'CERRADA';
      var inicio = row.fecha instanceof Date ? row.fecha.getTime() : new Date(row.fecha).getTime();
      detalleCierre = {
        motivo: String(params.cerrar.motivo || 'manual'),
        lado:   lado,
        duracionSeg: Math.round((Date.now() - inicio) / 1000)
      };
      updates.detalleFin = JSON.stringify(detalleCierre);
      aplicado.cerrado = true;
    }

    // ── Aplicar TODOS los updates ──────────────────────────────
    Object.keys(updates).forEach(function(col) {
      var idx = hdrs.indexOf(col);
      if (idx >= 0) sh.getRange(row._row, idx + 1).setValue(updates[col]);
    });
    try { SpreadsheetApp.flush(); } catch(_){}

    // Auditoría post-cierre fuera del lock (no demorar el unlock)
    var rowParaAudit = null;
    if (detalleCierre) {
      rowParaAudit = row;
      hdrs.forEach(function(h) { if (updates[h] != null) rowParaAudit[h] = updates[h]; });
    }

    var estFinal = updates.estado || estActual;
    if (rowParaAudit) {
      try { _logAuditoriaEspia(rowParaAudit, detalleCierre.duracionSeg, JSON.stringify(detalleCierre)); } catch(_){}
    }

    return { ok: true, data: { estado: estFinal, aplicado: aplicado } };
  } finally {
    try { lock.releaseLock(); } catch(_){}
  }
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
  // [CERO-GAS 2026-07-18] Lee la hoja DISPOSITIVOS, ORFANADA (frozen) tras matar el reverse-sync → estado/tokens
  // pueden estar stale. La verdad es mos.dispositivos (sombra). Diagnóstico editor-only, sin impacto runtime.
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
  // [v2.43.88] Incluir columnas de renegociación (no perderlas al reparar)
  var cabeceras = [
    'sesionId', 'fecha', 'masterId', 'deviceId',
    'estado', 'sdpOferta', 'sdpRespuesta',
    'iceMaster', 'iceDevice', 'streamsActivos', 'detalleFin',
    'sdpRenegOferta', 'sdpRenegRespuesta'
  ];
  var nCols = cabeceras.length;
  if (sh.getMaxColumns() < nCols) {
    sh.insertColumnsAfter(sh.getMaxColumns(), nCols - sh.getMaxColumns());
  }
  // Escribir cabeceras directo en fila 1 (overwrite si había algo)
  sh.getRange(1, 1, 1, nCols).setValues([cabeceras])
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
  // [v2.43.88] Recrear con cabeceras correctas (incluye reneg)
  var nueva = ss.insertSheet('RTC_SIGNALING');
  nueva.appendRow([
    'sesionId', 'fecha', 'masterId', 'deviceId',
    'estado', 'sdpOferta', 'sdpRespuesta',
    'iceMaster', 'iceDevice', 'streamsActivos', 'detalleFin',
    'sdpRenegOferta', 'sdpRenegRespuesta'
  ]);
  nueva.getRange(1, 1, 1, 13).setFontWeight('bold')
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
    // [v2.43.88] Tope de tamaño — con restartIce repetido el array puede crecer
    // sin techo y eventualmente romper la celda Sheets (max ~50K chars).
    if (arr.length > ESPIA_ICE_MAX_ITEMS) {
      arr = arr.slice(arr.length - ESPIA_ICE_MAX_ITEMS);
    }
    sh.getRange(row._row, col + 1).setValue(JSON.stringify(arr));
    // [v2.43.67] Flush para que el polling del otro lado vea el ICE candidate inmediato
    try { SpreadsheetApp.flush(); } catch(_){}
    return { ok: true, data: { totalElementos: arr.length } };
  } finally {
    try { lock.releaseLock(); } catch(_){}
  }
}

// [v2.43.88] TTL dinámico por estado para no matar sesiones EN_VIVO activas.
// Antes: ESPIA_TTL_MS=10min mataba cualquier sesión a los 10' aunque master
// estuviera monitoreando activamente → polling devolvía "Sesión expirada" y
// el WebRTC seguía vivo pero el signaling moría → fallaban renegs/ICE post-10'.
// Ahora: PENDIENTE (sin handshake) = 10min, CONECTANDO = 20min, EN_VIVO = 60min.
function _ttlPorEstado(estado) {
  var e = String(estado || '').toUpperCase();
  if (e === 'EN_VIVO')    return 6 * ESPIA_TTL_MS;  // 60 min
  if (e === 'CONECTANDO') return 2 * ESPIA_TTL_MS;  // 20 min
  return ESPIA_TTL_MS;                              // 10 min (PENDIENTE default)
}

function _sesionExpiro(row) {
  var fecha = row.fecha instanceof Date ? row.fecha : new Date(row.fecha);
  return (Date.now() - fecha.getTime()) > _ttlPorEstado(row.estado);
}

function _msHastaExpiracion(row) {
  var fecha = row.fecha instanceof Date ? row.fecha : new Date(row.fecha);
  return Math.max(0, _ttlPorEstado(row.estado) - (Date.now() - fecha.getTime()));
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
                icon:  'https://levo19.github.io/MOS/icons/icon-192.png',
                badge: 'https://levo19.github.io/MOS/icons/icon-192.png',
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

// ════════════════════════════════════════════════════════════════════
// [v2.43.90] PRODUCTION HARDENING — Auth HMAC + TURN + FCM retry
// ────────────────────────────────────────────────────────────────────
// Migra el sistema a producción robusta:
//   1. Tokens HMAC firmados — cada side (master/device) recibe su token al
//      iniciar; los endpoints lo exigen. sesionId deja de ser secreto.
//   2. ICE config endpoint — provee TURN si está configurado en Properties.
//   3. FCM con reintentos — 3 intentos exponenciales antes de rendirse.
//   4. Compat hacia atrás — durante deprecation window, requests sin token
//      siguen pasando con WARNING en logs. Sunset a las 2 semanas.
// ════════════════════════════════════════════════════════════════════

// ── Auth HMAC ────────────────────────────────────────────────────────
function _obtenerHmacKey() {
  var props = PropertiesService.getScriptProperties();
  var key = props.getProperty('ESPIA_HMAC_KEY');
  if (!key || key.length < 32) {
    // Auto-generar la primera vez. Borrar el property invalida todos los
    // tokens existentes (forzando re-handshake) — útil ante leak sospechado.
    var raw = Utilities.getUuid() + Utilities.getUuid() + Date.now();
    key = Utilities.base64Encode(Utilities.computeDigest(
      Utilities.DigestAlgorithm.SHA_256,
      raw, Utilities.Charset.UTF_8
    ));
    props.setProperty('ESPIA_HMAC_KEY', key);
    Logger.log('[espia auth] ESPIA_HMAC_KEY auto-generada · ' + key.substring(0, 8) + '...');
  }
  return key;
}

// Firma "sesionId|lado|deviceId" → token base64url corto (~44 chars).
// `deviceId` se incluye para que un token de master no sirva para device.
function _firmarToken(sesionId, lado, deviceId) {
  var key = _obtenerHmacKey();
  var payload = String(sesionId) + '|' + String(lado) + '|' + String(deviceId || '');
  var raw = Utilities.computeHmacSha256Signature(payload, key);
  return Utilities.base64Encode(raw).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// Verifica token contra el payload esperado.
//   null  = sin token (caller decide si permitir por compat)
//   true  = token válido
//   false = token presente pero inválido (rechazar)
function _verificarToken(sesionId, lado, deviceId, token) {
  if (!token) return null;
  try {
    var esperado = _firmarToken(sesionId, lado, deviceId);
    if (esperado.length !== token.length) return false;
    // Comparación constante-tiempo (defensa débil contra timing pero best-effort en GAS)
    var diff = 0;
    for (var i = 0; i < esperado.length; i++) {
      diff |= esperado.charCodeAt(i) ^ token.charCodeAt(i);
    }
    return diff === 0;
  } catch(_) { return false; }
}

// Helper que cada endpoint usa al comienzo. Devuelve null si OK, o {ok:false,...}
// si auth falló. Durante compat window: sin token → log warning + permitir.
function _autenticarEndpoint(params, row) {
  var token = params && params.token ? String(params.token).trim() : '';
  var lado  = String((params && params.lado) || '').toLowerCase();
  var deviceId = row ? String(row.deviceId || '') : '';
  if (lado === 'master' || lado === 'device') {
    var ok = _verificarToken(row.sesionId, lado, deviceId, token);
    if (ok === false) return { ok: false, error: 'Token inválido', codigo: 'AUTH_FAIL' };
    if (ok === null) {
      Logger.log('[espia auth WARN] endpoint sin token (compat) sesionId=' + row.sesionId + ' lado=' + lado);
    }
    return null;
  }
  // Lado no declarado: aceptar token de master O device
  if (token) {
    var okM = _verificarToken(row.sesionId, 'master', deviceId, token);
    var okD = _verificarToken(row.sesionId, 'device', deviceId, token);
    if (!okM && !okD) return { ok: false, error: 'Token inválido', codigo: 'AUTH_FAIL' };
  } else {
    Logger.log('[espia auth WARN] endpoint sin token + sin lado (compat) sesionId=' + row.sesionId);
  }
  return null;
}

// ── Endpoint: ICE config (STUN + TURN si está) ───────────────────────
function espiaConfig() {
  var props = PropertiesService.getScriptProperties();
  var iceServers = [
    { urls: ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'] }
  ];
  var turnUrl  = props.getProperty('ESPIA_TURN_URL');
  var turnUser = props.getProperty('ESPIA_TURN_USER');
  var turnCred = props.getProperty('ESPIA_TURN_CRED');
  if (turnUrl && turnUser && turnCred) {
    iceServers.push({
      urls: turnUrl.split(',').map(function(u){ return u.trim(); }).filter(Boolean),
      username: turnUser,
      credential: turnCred
    });
  }
  return { ok: true, data: {
    iceServers: iceServers,
    tieneTurn: !!(turnUrl && turnUser && turnCred),
    ttlSesionMs: ESPIA_TTL_MS,
    ahora: Date.now()
  } };
}

// ── Endpoint: device activa su sesión (devuelve token específico) ────
function espiaIniciarDispositivo(params) {
  var sesionId = String((params && params.sesionId) || '').trim();
  var deviceId = String((params && params.deviceId) || '').trim();
  if (!sesionId) return { ok: false, error: 'sesionId requerido' };
  if (!deviceId) return { ok: false, error: 'deviceId requerido' };
  var row = _buscarSesion(sesionId);
  if (!row) return { ok: false, error: 'Sesión no encontrada' };
  if (String(row.deviceId || '').trim() !== deviceId) {
    return { ok: false, error: 'deviceId no coincide con la sesión' };
  }
  if (_sesionExpiro(row)) return { ok: false, error: 'Sesión expirada', codigo: 'EXPIRADO' };
  var token = _firmarToken(sesionId, 'device', deviceId);
  return { ok: true, data: {
    token: token,
    masterId: row.masterId,
    estado: row.estado,
    expiraEn: _msHastaExpiracion(row)
  } };
}

// ── FCM Push con reintentos ──────────────────────────────────────────
function _enviarPushDispositivoConRetry(deviceId, payload, intentos) {
  var maxIntentos = intentos || 3;
  var ultimoError = '';
  var espera = [0, 400, 1400]; // backoff entre intentos
  for (var i = 0; i < maxIntentos; i++) {
    if (i > 0 && espera[i]) Utilities.sleep(espera[i]);
    try {
      var r = _enviarPushDispositivo(deviceId, payload);
      if (r && r.ok && r.data && r.data.enviados > 0) {
        if (i > 0) Logger.log('[espia push retry] OK en intento ' + (i + 1));
        return { ok: true, data: { intentos: i + 1, enviados: r.data.enviados } };
      }
      ultimoError = (r && r.error) || 'sin tokens / 0 enviados';
    } catch(e) {
      ultimoError = e.message;
    }
    Logger.log('[espia push retry] intento ' + (i + 1) + '/' + maxIntentos + ' fallo: ' + ultimoError);
  }
  return { ok: false, error: ultimoError, data: { intentos: maxIntentos, enviados: 0 } };
}

// ════════════════════════════════════════════════════════════════════
// [v2.43.94] AUDITORÍA DE PUSH TOKENS — diagnóstico end-to-end
// ────────────────────────────────────────────────────────────────────
// Cruza DISPOSITIVOS × PUSH_TOKENS y reporta cuáles devices están listos
// para recibir push del espía. Ejecutar manualmente desde el editor:
//   1. Abrir Apps Script editor
//   2. Seleccionar `reporteTokensEspia` en el dropdown de funciones
//   3. Click ▶ (Ejecutar)
//   4. Ver/Logs (Ctrl+Enter)
// El return es para inspección programática; los logs son legibles.
// ════════════════════════════════════════════════════════════════════
function reporteTokensEspia() {
  // [CERO-GAS 2026-07-18] Lee la hoja DISPOSITIVOS ORFANADA (frozen) → estado stale. Verdad = mos.dispositivos (sombra). Editor-only.
  var ss = getSpreadsheet();
  var shDisp = ss.getSheetByName('DISPOSITIVOS');
  var shTok  = ss.getSheetByName('PUSH_TOKENS');
  if (!shDisp) { Logger.log('❌ Hoja DISPOSITIVOS no existe'); return { ok: false }; }
  if (!shTok)  { Logger.log('❌ Hoja PUSH_TOKENS no existe'); return { ok: false }; }

  var datDisp = shDisp.getDataRange().getValues();
  var hdrDisp = datDisp[0];
  var iDevId  = hdrDisp.indexOf('ID_Dispositivo'); if (iDevId < 0) iDevId = hdrDisp.indexOf('deviceId');
  var iNom    = hdrDisp.indexOf('Nombre_Equipo');
  var iApp    = hdrDisp.indexOf('App');
  var iEst    = hdrDisp.indexOf('Estado');
  var iSes    = hdrDisp.indexOf('Ultima_Sesion');
  var iCon    = hdrDisp.indexOf('Ultima_Conexion');

  var datTok = shTok.getDataRange().getValues();
  var hdrTok = datTok[0];
  var iTokDev = hdrTok.indexOf('deviceId');
  var iTok    = hdrTok.indexOf('token');
  var iAct    = hdrTok.indexOf('activo');
  var iUlt    = hdrTok.indexOf('ultima_actualizacion');
  if (iUlt < 0) iUlt = hdrTok.indexOf('ultimaActualizacion');

  // Construir índice deviceId → [{token, activo, ultUpdate}]
  var idx = {};
  for (var i = 1; i < datTok.length; i++) {
    var d = String(datTok[i][iTokDev] || '').trim();
    if (!d) continue;
    if (!idx[d]) idx[d] = [];
    var act = datTok[i][iAct];
    var actBool = !(act === false || String(act) === '0' || String(act).toLowerCase() === 'false');
    var tok = String(datTok[i][iTok] || '').trim();
    var ts = 0;
    if (iUlt >= 0) {
      try { ts = new Date(datTok[i][iUlt]).getTime() || 0; } catch(_){}
    }
    idx[d].push({ token: tok, activo: actBool, ts: ts });
  }

  Logger.log('═══ AUDITORÍA PUSH TOKENS PARA ESPÍA ═══');
  Logger.log('Total dispositivos en DISPOSITIVOS: ' + (datDisp.length - 1));
  Logger.log('Total filas en PUSH_TOKENS: ' + (datTok.length - 1));
  Logger.log('───');

  var reporte = { listosParaEspia: [], sinToken: [], soloTokensInactivos: [], rechazadosPorEstado: [] };
  for (var j = 1; j < datDisp.length; j++) {
    var did = String(datDisp[j][iDevId] || '').trim();
    if (!did) continue;
    var nom = String(datDisp[j][iNom] || '');
    var app = String(datDisp[j][iApp] || '').toUpperCase();
    var est = String(datDisp[j][iEst] || '').toUpperCase();
    var ses = String(datDisp[j][iSes] || '');

    var tokens = idx[did] || [];
    var activos = tokens.filter(function(t){ return t.activo && t.token; });
    var inactivos = tokens.filter(function(t){ return !t.activo && t.token; });

    var fila = {
      deviceId: did,
      nombre:   nom,
      app:      app,
      estado:   est,
      ultimoUser: ses,
      tokensActivos:   activos.length,
      tokensInactivos: inactivos.length
    };

    // MOS Admin no es target legítimo del espía (es el master)
    if (app === 'MOS') {
      Logger.log('⚪ ' + did.substring(0,8) + ' [' + nom + '] · APP=MOS · es MASTER, no target');
      continue;
    }
    if (est !== 'ACTIVO' && est !== 'ACTIVA' && est !== '') {
      Logger.log('⛔ ' + did.substring(0,8) + ' [' + nom + '] · estado=' + est + ' · no recibe push');
      reporte.rechazadosPorEstado.push(fila);
      continue;
    }
    if (activos.length === 0 && inactivos.length === 0) {
      Logger.log('🚨 ' + did.substring(0,8) + ' [' + nom + ' / ' + app + '] · SIN TOKENS · espía no llegará');
      reporte.sinToken.push(fila);
    } else if (activos.length === 0) {
      Logger.log('⚠ ' + did.substring(0,8) + ' [' + nom + ' / ' + app + '] · ' + inactivos.length + ' token(s) INACTIVOS · device debe reabrir app');
      reporte.soloTokensInactivos.push(fila);
    } else {
      Logger.log('✅ ' + did.substring(0,8) + ' [' + nom + ' / ' + app + '] · ' + activos.length + ' token(s) activo(s) · LISTO');
      reporte.listosParaEspia.push(fila);
    }
  }

  Logger.log('───');
  Logger.log('RESUMEN:');
  Logger.log('  ✅ Listos para espía:        ' + reporte.listosParaEspia.length);
  Logger.log('  ⚠  Solo tokens inactivos:    ' + reporte.soloTokensInactivos.length);
  Logger.log('  🚨 Sin ningún token:         ' + reporte.sinToken.length);
  Logger.log('  ⛔ Rechazados por estado:    ' + reporte.rechazadosPorEstado.length);

  if (reporte.sinToken.length) {
    Logger.log('───');
    Logger.log('SIN TOKEN (acción: cada uno debe abrir su PWA y aceptar notificaciones):');
    reporte.sinToken.forEach(function(f){
      Logger.log('  • ' + f.nombre + ' (' + f.app + ') · user=' + (f.ultimoUser || 'sin login'));
    });
  }
  if (reporte.soloTokensInactivos.length) {
    Logger.log('───');
    Logger.log('TOKENS INACTIVOS (registrarPushToken los reactiva al próximo abrir):');
    reporte.soloTokensInactivos.forEach(function(f){
      Logger.log('  • ' + f.nombre + ' (' + f.app + ')');
    });
  }

  return { ok: true, data: reporte };
}

// ════════════════════════════════════════════════════════════════════
// [v2.43.96] DIAGNÓSTICO AUTOMATIZADO DE EXCEPCIONES
// ────────────────────────────────────────────────────────────────────
// Captura, clasifica y diagnostica errores que disparan 500/EXCEPCION
// sin necesidad de leer la UI de Ejecuciones manualmente.
//
// Flujo:
//   1. Cada excepción en espiaSync/espiaPushBatch → _registrarExcepcionEspia
//      persiste en hoja DIAGNOSTICO_ESPIA (rotativa, máx 200 filas).
//   2. Ejecutar diagnosticarErroresEspia() en el editor → agrupa por patrón,
//      identifica causa raíz, sugiere fix con función específica.
// ════════════════════════════════════════════════════════════════════

function _registrarExcepcionEspia(endpoint, error, params) {
  try {
    var ss = getSpreadsheet();
    var sh = ss.getSheetByName('DIAGNOSTICO_ESPIA');
    if (!sh) {
      sh = ss.insertSheet('DIAGNOSTICO_ESPIA');
      sh.appendRow(['ts', 'endpoint', 'mensaje', 'stack', 'sesionId', 'lado', 'paramsResumen']);
      sh.getRange(1, 1, 1, 7).setFontWeight('bold').setBackground('#0f172a').setFontColor('#f87171');
      sh.setFrozenRows(1);
    }
    // Sanear params: NUNCA loguear sdp (ruido), token (secret) ni ice (gigante)
    var p = params || {};
    var resumen = {};
    Object.keys(p).forEach(function(k) {
      if (k === 'sdp' || k === 'token' || k === 'ice' || k === 'sdpOferta' ||
          k === 'sdpRespuesta' || k === 'sdpRenegOferta' || k === 'sdpRenegRespuesta' ||
          k === 'contenido') {
        resumen[k] = '<' + (typeof p[k] === 'string' ? p[k].length + ' chars' : 'present') + '>';
      } else if (k === 'necesito') {
        resumen[k] = Object.keys(p[k] || {}).filter(function(f){ return p[k][f]; }).join(',');
      } else {
        resumen[k] = p[k];
      }
    });
    var msg = String((error && error.message) || error);
    var stk = String((error && error.stack) || '').substring(0, 800);
    sh.appendRow([
      new Date(),
      String(endpoint),
      msg.substring(0, 300),
      stk,
      String(p.sesionId || ''),
      String(p.lado || ''),
      JSON.stringify(resumen).substring(0, 500)
    ]);
    // Rolling: si pasa de 200 filas (+1 header), borrar las viejas en bloque
    var ult = sh.getLastRow();
    if (ult > 201) {
      sh.deleteRows(2, ult - 201);
    }
    // También console.log para Cloud Logging
    Logger.log('[ESPIA EXCEPCION] ' + endpoint + ': ' + msg + ' | params=' + JSON.stringify(resumen));
  } catch(eReg) {
    // No queremos que el logger explote si Sheets está roto
    Logger.log('[_registrarExcepcionEspia FALLO] ' + eReg.message);
  }
}

/**
 * Diagnóstico automatizado: lee últimas N excepciones, agrupa por patrón,
 * identifica causa raíz y sugiere acción concreta.
 *
 * Ejecutar desde Apps Script editor → ▶ → Ctrl+Enter (logs).
 */
function diagnosticarErroresEspia() {
  var ss = getSpreadsheet();
  var sh = ss.getSheetByName('DIAGNOSTICO_ESPIA');
  if (!sh || sh.getLastRow() < 2) {
    Logger.log('✅ No hay excepciones registradas en DIAGNOSTICO_ESPIA.');
    Logger.log('   Si tu cliente sigue viendo 500, el problema está fuera del wrap defensivo.');
    return { ok: true, data: { errores: 0 } };
  }

  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var iTs   = hdrs.indexOf('ts');
  var iEnd  = hdrs.indexOf('endpoint');
  var iMsg  = hdrs.indexOf('mensaje');
  var iStk  = hdrs.indexOf('stack');
  var iSes  = hdrs.indexOf('sesionId');
  var iLado = hdrs.indexOf('lado');

  // Solo últimos 30 min — ignorar histórico viejo
  var ahora = Date.now();
  var ventana = 30 * 60 * 1000;
  var recientes = [];
  for (var i = data.length - 1; i >= 1; i--) {
    var ts = data[i][iTs] instanceof Date ? data[i][iTs].getTime() : new Date(data[i][iTs]).getTime();
    if (isNaN(ts)) continue;
    if (ahora - ts > ventana) break; // filas antiguas: data está ordenada cronológicamente
    recientes.push({
      ts: ts, endpoint: data[i][iEnd], mensaje: data[i][iMsg],
      stack: data[i][iStk], sesionId: data[i][iSes], lado: data[i][iLado]
    });
  }

  Logger.log('═══ DIAGNÓSTICO ESPÍA — últimos 30 min ═══');
  Logger.log('Excepciones encontradas: ' + recientes.length);
  if (recientes.length === 0) {
    Logger.log('✅ Sin excepciones recientes. Si seguís viendo problemas, el cliente puede tener cache vieja.');
    return { ok: true, data: { errores: 0 } };
  }

  // Agrupar por mensaje (normalizado: quitar números/uuids)
  var grupos = {};
  recientes.forEach(function(r) {
    var key = String(r.mensaje || '')
      .replace(/[0-9a-f-]{8,}/gi, '<id>')
      .replace(/\d+/g, '<N>')
      .substring(0, 120);
    var g = grupos[key] || { mensaje: r.mensaje, endpoints: {}, sesiones: {}, lados: {}, count: 0, ejemploStack: r.stack };
    g.count++;
    g.endpoints[r.endpoint] = (g.endpoints[r.endpoint] || 0) + 1;
    if (r.sesionId) g.sesiones[r.sesionId] = (g.sesiones[r.sesionId] || 0) + 1;
    if (r.lado) g.lados[r.lado] = (g.lados[r.lado] || 0) + 1;
    grupos[key] = g;
  });

  Logger.log('───');
  Logger.log('GRUPOS por patrón:');
  Object.keys(grupos).forEach(function(key, idx) {
    var g = grupos[key];
    Logger.log('');
    Logger.log('  [' + (idx + 1) + '] ✗ "' + key + '"');
    Logger.log('      ocurrencias: ' + g.count);
    Logger.log('      endpoints:   ' + Object.keys(g.endpoints).map(function(e){return e+'×'+g.endpoints[e];}).join(', '));
    Logger.log('      lados:       ' + Object.keys(g.lados).map(function(l){return l+'×'+g.lados[l];}).join(', '));
    Logger.log('      sesiones:    ' + Object.keys(g.sesiones).length + ' distintas');
    if (g.ejemploStack) {
      Logger.log('      stack (1ª línea): ' + String(g.ejemploStack).split('\n')[0]);
    }
    // Diagnóstico + sugerencia
    var sug = _sugerirFix(g.mensaje, g.ejemploStack);
    Logger.log('      → DIAGNÓSTICO: ' + sug.diagnostico);
    Logger.log('      → ACCIÓN:      ' + sug.accion);
  });

  Logger.log('───');
  Logger.log('Para limpiar el histórico de DIAGNOSTICO_ESPIA: ejecutá limpiarDiagnosticoEspia()');
  return { ok: true, data: { errores: recientes.length, grupos: Object.keys(grupos).length } };
}

function _sugerirFix(mensaje, stack) {
  var m = String(mensaje || '').toLowerCase();
  var s = String(stack || '').toLowerCase();
  if (/cannot read.*null|cannot read.*undefined/.test(m) || /getvalues/.test(s)) {
    if (/_buscarsesion|_gethojasignaling/.test(s)) {
      return {
        diagnostico: 'Cabeceras de RTC_SIGNALING corruptas o columna faltante.',
        accion: 'Ejecutá repararCabecerasSignaling() — restaura las 13 cabeceras incl. reneg.'
      };
    }
    return {
      diagnostico: 'Acceso a valor null/undefined en una columna esperada.',
      accion: 'Mirá el stack completo en DIAGNOSTICO_ESPIA col D. Probablemente una columna falta en alguna hoja.'
    };
  }
  if (/columna no existe/i.test(m)) {
    return {
      diagnostico: 'Columna referenciada no existe en RTC_SIGNALING.',
      accion: 'repararCabecerasSignaling() agrega todas las cabeceras incl. reneg.'
    };
  }
  if (/lock timeout/i.test(m)) {
    return {
      diagnostico: 'LockService contention (varios writes simultáneos a la misma fila).',
      accion: 'Transitorio. Si recurre constante, hay polling demasiado agresivo. El backoff exponencial del frontend lo mitiga.'
    };
  }
  if (/sesión no encontrada|sesion no encontrada/i.test(m)) {
    return {
      diagnostico: 'Cliente sigue polleando una sesión purgada (cleanup 24h).',
      accion: 'Esperado para sesiones viejas. Si recurre: cliente tiene cache vieja del sesionId, debe reabrir el espía.'
    };
  }
  if (/sesión expirada|sesion expirada/i.test(m)) {
    return {
      diagnostico: 'TTL de sesión cumplido (PENDIENTE=10min, CONECTANDO=20min, EN_VIVO=60min).',
      accion: 'Esperado. El master debe reiniciar la sesión.'
    };
  }
  if (/token inválido|token invalido|auth_fail/i.test(m)) {
    return {
      diagnostico: 'HMAC token recibido no matchea el firmado por backend.',
      accion: 'Causa común: el cliente tiene token de una sesión vieja, o ESPIA_HMAC_KEY fue rotada. Cliente debe reabrir espía.'
    };
  }
  if (/hmac|computehmac/i.test(m + s)) {
    return {
      diagnostico: 'Fallo en computeHmacSha256Signature.',
      accion: 'ESPIA_HMAC_KEY puede estar malformada en Properties. Borrarla fuerza auto-regen (todos los tokens activos se invalidan).'
    };
  }
  if (/lado.*master.*device|lado: master\|device/i.test(m)) {
    return {
      diagnostico: 'Request sin parámetro lado (frontend viejo cacheado).',
      accion: 'Cliente con código pre-v2.13.79 que llamó endpoint batch nuevo. Hard refresh del cliente.'
    };
  }
  if (/sdp.*demasiado grande|sdp.*max/i.test(m)) {
    return {
      diagnostico: 'SDP > 45000 chars (limit Sheets celda).',
      accion: 'No típico salvo intento de inyección. Si recurre legítimo, subir ESPIA_SDP_MAX_CHARS.'
    };
  }
  if (/quota|rate/i.test(m)) {
    return {
      diagnostico: 'Cuota Apps Script excedida (20k req/día gratuito).',
      accion: 'Frontends están polling demasiado. Considerá aumentar intervals o el backoff exponencial.'
    };
  }
  return {
    diagnostico: 'No clasificado.',
    accion: 'Pega stack completo (col D de DIAGNOSTICO_ESPIA) para análisis manual.'
  };
}

function limpiarDiagnosticoEspia() {
  var ss = getSpreadsheet();
  var sh = ss.getSheetByName('DIAGNOSTICO_ESPIA');
  if (!sh) { Logger.log('No existe DIAGNOSTICO_ESPIA'); return; }
  var ult = sh.getLastRow();
  if (ult < 2) { Logger.log('Ya vacía'); return; }
  sh.deleteRows(2, ult - 1);
  Logger.log('✓ Limpiados ' + (ult - 1) + ' registros de DIAGNOSTICO_ESPIA');
}

// ════════════════════════════════════════════════════════════════════
// [v2.43.105] VERIFICADOR DE CONFIG TURN
// ────────────────────────────────────────────────────────────────────
// Ejecutar desde el editor Apps Script después de configurar las
// Properties ESPIA_TURN_URL / ESPIA_TURN_USER / ESPIA_TURN_CRED.
// Reporta si está OK, si falta algo, o si el formato es inválido.
// ════════════════════════════════════════════════════════════════════
function verificarConfigTurn() {
  var props = PropertiesService.getScriptProperties();
  var url  = props.getProperty('ESPIA_TURN_URL');
  var user = props.getProperty('ESPIA_TURN_USER');
  var cred = props.getProperty('ESPIA_TURN_CRED');

  Logger.log('═══ VERIFICACIÓN CONFIG TURN ═══');

  var problemas = [];
  if (!url)  problemas.push('ESPIA_TURN_URL no configurada');
  if (!user) problemas.push('ESPIA_TURN_USER no configurada');
  if (!cred) problemas.push('ESPIA_TURN_CRED no configurada');

  if (problemas.length === 3) {
    Logger.log('❌ NINGUNA property configurada todavía.');
    Logger.log('   Pasos:');
    Logger.log('   1. Crear cuenta en https://www.metered.ca/tools/openrelay/');
    Logger.log('   2. Copiar las credenciales que te dan');
    Logger.log('   3. Acá en el editor: ⚙ Configuración del proyecto → Propiedades del script');
    Logger.log('   4. Agregar las 3 properties con los valores');
    Logger.log('   5. Volver a ejecutar verificarConfigTurn()');
    return { ok: false, faltantes: ['ESPIA_TURN_URL', 'ESPIA_TURN_USER', 'ESPIA_TURN_CRED'] };
  }

  if (problemas.length > 0) {
    Logger.log('⚠ Configuración INCOMPLETA:');
    problemas.forEach(function(p) { Logger.log('   • ' + p); });
    return { ok: false, faltantes: problemas };
  }

  // Verificar formato
  Logger.log('✓ Las 3 properties existen.');
  Logger.log('───');
  Logger.log('ESPIA_TURN_URL  = ' + url);
  Logger.log('ESPIA_TURN_USER = ' + user);
  Logger.log('ESPIA_TURN_CRED = ' + cred.substring(0, 3) + '••• (' + cred.length + ' chars)');
  Logger.log('───');

  var warnings = [];
  // [v2.43.106] Validación estricta de CADA URL separada por coma.
  // Antes solo verificaba la primera. Si copiabas texto explicativo extra
  // (paréntesis con notas, espacios sueltos), el validador decía OK pero
  // el cliente WebRTC fallaba al intentar conectarse.
  var urlsSeparadas = url.split(',').map(function(s) { return s.trim(); });
  urlsSeparadas.forEach(function(u, idx) {
    if (!u) {
      warnings.push('URL [' + (idx + 1) + '] está vacía (¿coma de más?)');
    } else if (!/^(turn|stun|turns):[a-z0-9.-]+:\d+(\?[a-z=]+)?$/i.test(u)) {
      warnings.push('URL [' + (idx + 1) + '] inválida: "' + u + '" — debe ser turn:host:puerto[?transport=tcp] (sin paréntesis ni texto extra)');
    }
  });
  if (user.length < 3) {
    warnings.push('Username parece muy corto');
  }
  if (cred.length < 6) {
    warnings.push('Credential parece muy corta — Metered te da una contraseña larga');
  }

  // [v2.43.106] Si hay warnings de URL inválida → ABORTAR antes de declarar OK
  var tieneUrlInvalida = warnings.some(function(w) { return /URL \[/.test(w); });
  if (warnings.length > 0) {
    Logger.log(tieneUrlInvalida ? '❌ PROBLEMAS DE FORMATO (CRÍTICOS):' : '⚠ Warnings menores:');
    warnings.forEach(function(w) { Logger.log('   • ' + w); });
    if (tieneUrlInvalida) {
      Logger.log('───');
      Logger.log('🚨 NO declarar "TODO LISTO" — el cliente WebRTC va a rechazar estas URLs.');
      Logger.log('   Corregí ESPIA_TURN_URL en Properties y volvé a ejecutar verificarConfigTurn.');
      return { ok: false, error: 'URLs malformadas', warnings: warnings };
    }
  } else {
    Logger.log('✓ Formato correcto en las ' + urlsSeparadas.length + ' URL(s).');
  }

  // Probar el endpoint espiaConfig que es lo que el cliente va a recibir
  Logger.log('───');
  Logger.log('Probando endpoint espiaConfig()...');
  try {
    var cfg = espiaConfig();
    if (cfg && cfg.ok && cfg.data) {
      Logger.log('✓ espiaConfig() OK');
      Logger.log('  tieneTurn: ' + cfg.data.tieneTurn);
      Logger.log('  servers totales: ' + cfg.data.iceServers.length);
      cfg.data.iceServers.forEach(function(srv, i) {
        var urls = Array.isArray(srv.urls) ? srv.urls.join(', ') : srv.urls;
        Logger.log('  [' + (i+1) + '] ' + urls + (srv.username ? ' (con auth)' : ' (sin auth · STUN)'));
      });
      if (cfg.data.tieneTurn) {
        Logger.log('───');
        Logger.log('🎉 TODO LISTO — los clientes nuevos van a usar TURN automáticamente.');
        Logger.log('   Test real: prueba espía sobre un device con DATOS MÓVILES (no WiFi).');
        return { ok: true, data: { tieneTurn: true, servers: cfg.data.iceServers.length } };
      } else {
        Logger.log('⚠ tieneTurn=false a pesar de las properties. Algo del formato no cuadra.');
        return { ok: false, error: 'espiaConfig devolvió tieneTurn=false' };
      }
    } else {
      Logger.log('❌ espiaConfig devolvió respuesta inválida: ' + JSON.stringify(cfg));
      return { ok: false, error: 'respuesta inválida de espiaConfig' };
    }
  } catch(e) {
    Logger.log('❌ excepción en espiaConfig(): ' + e.message);
    return { ok: false, error: e.message };
  }
}
