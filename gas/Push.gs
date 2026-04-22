// ============================================================
// ProyectoMOS — Push.gs
// Notificaciones push via Firebase Cloud Messaging (FCM v1 API)
//
// Script Properties requeridas (⚙ Project Settings → Script Properties):
//   FCM_PROJECT_ID   → proyectomos-push
//   FCM_CLIENT_EMAIL → firebase-adminsdk-fbsvc@proyectomos-push.iam.gserviceaccount.com
//   FCM_PRIVATE_KEY  → -----BEGIN PRIVATE KEY-----\n...-----END PRIVATE KEY-----\n
// ============================================================

// ── JWT → OAuth2 access token usando el service account ────────
function _getFcmAccessToken() {
  var p     = PropertiesService.getScriptProperties();
  var email = p.getProperty('FCM_CLIENT_EMAIL');
  var key   = p.getProperty('FCM_PRIVATE_KEY').replace(/\\n/g, '\n');
  if (!email || !key) throw new Error('Faltan FCM_CLIENT_EMAIL o FCM_PRIVATE_KEY en Script Properties');

  var now    = Math.floor(Date.now() / 1000);
  var hdr    = Utilities.base64EncodeWebSafe(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).replace(/=+$/, '');
  var claim  = Utilities.base64EncodeWebSafe(JSON.stringify({
    iss:   email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud:   'https://oauth2.googleapis.com/token',
    exp:   now + 3600,
    iat:   now
  })).replace(/=+$/, '');

  var input = hdr + '.' + claim;
  var sig   = Utilities.base64EncodeWebSafe(Utilities.computeRsaSha256Signature(input, key)).replace(/=+$/, '');
  var jwt   = input + '.' + sig;

  var resp  = UrlFetchApp.fetch('https://oauth2.googleapis.com/token', {
    method: 'post',
    contentType: 'application/x-www-form-urlencoded',
    payload: 'grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=' + jwt,
    muteHttpExceptions: true
  });
  var json = JSON.parse(resp.getContentText());
  if (!json.access_token) throw new Error('FCM auth failed: ' + resp.getContentText());
  return json.access_token;
}

// ── Enviar push a una lista de tokens ──────────────────────────
function _enviarPushTokens(titulo, cuerpo, tokens) {
  if (!tokens || tokens.length === 0) return;
  var projectId   = PropertiesService.getScriptProperties().getProperty('FCM_PROJECT_ID');
  var accessToken = _getFcmAccessToken();
  var url = 'https://fcm.googleapis.com/v1/projects/' + projectId + '/messages:send';

  tokens.forEach(function(token) {
    if (!token) return;
    try {
      UrlFetchApp.fetch(url, {
        method: 'post',
        contentType: 'application/json',
        headers: { 'Authorization': 'Bearer ' + accessToken },
        payload: JSON.stringify({
          message: {
            token: token,
            notification: { title: titulo, body: cuerpo },
            webpush: {
              notification: {
                title: titulo,
                body:  cuerpo,
                icon:  'https://levo19.github.io/MOS/icon-192.png',
                badge: 'https://levo19.github.io/MOS/icon-192.png',
                vibrate: [200, 100, 200]
              }
            }
          }
        }),
        muteHttpExceptions: true
      });
    } catch(e) {
      Logger.log('Push error: ' + e.message);
    }
  });
}

// ── Enviar a TODOS los tokens registrados ──────────────────────
function _enviarPushTodos(titulo, cuerpo) {
  try {
    var sheet = _getPushTokensSheet();
    var rows  = _sheetToObjects(sheet).filter(function(r) {
      return r.activo !== false && String(r.activo) !== '0' && String(r.activo) !== 'false';
    });
    var tokens = rows.map(function(r) { return String(r.token || ''); }).filter(Boolean);
    if (tokens.length > 0) _enviarPushTokens(titulo, cuerpo, tokens);
  } catch(e) {
    Logger.log('_enviarPushTodos error: ' + e.message);
  }
}

// ── Registrar / actualizar token desde el frontend ─────────────
function registrarPushToken(params) {
  if (!params.token) return { ok: false, error: 'token requerido' };
  var sheet = _getPushTokensSheet();
  var data  = sheet.getDataRange().getValues();

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][1]) === String(params.token)) {
      sheet.getRange(i + 1, 3).setValue(params.usuario    || data[i][2]);
      sheet.getRange(i + 1, 7).setValue(new Date());
      return { ok: true, data: { accion: 'actualizado' } };
    }
  }

  sheet.appendRow([
    _generateId('PTK'),
    params.token,
    params.usuario    || '',
    params.dispositivo || '',
    params.appOrigen  || 'MOS',
    _hoy(),
    new Date(),
    true
  ]);
  return { ok: true, data: { accion: 'registrado' } };
}

// ── Enviar push desde apps hijas (MosExpress, warehouseMos) ────
function enviarPushNotif(params) {
  if (!params.titulo) return { ok: false, error: 'titulo requerido' };
  _enviarPushTodos(params.titulo, params.cuerpo || '');
  return { ok: true };
}

// ── Resumen diario (llamado por el trigger de GAS) ─────────────
function enviarResumenDiario() {
  try {
    var fecha = _hoy();
    var ing   = _calcularIngresos(fecha);
    var cos   = _calcularCostoVentas(fecha, ing.detalleIds);
    var per   = _calcularPersonal(fecha);

    var titulo = '📊 Resumen ' + fecha;
    var cuerpo = [
      '💰 Ventas: S/ ' + ing.ventasNetas.toFixed(2) + '  (' + ing.tickets + ' tickets)',
      '📦 ' + cos.unidades + ' uds · ' + cos.skusDistintos + ' SKUs',
      '👥 Personal: ' + per.personas + ' persona' + (per.personas !== 1 ? 's' : '')
    ].join('\n');

    _enviarPushTodos(titulo, cuerpo);
    return { ok: true };
  } catch(e) {
    Logger.log('enviarResumenDiario error: ' + e.message);
    return { ok: false, error: e.message };
  }
}

// ── Configurar trigger diario (corre UNA VEZ desde el editor) ──
function configurarTriggerResumen() {
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === 'enviarResumenDiario') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('enviarResumenDiario')
    .timeBased()
    .everyDays(1)
    .atHour(22)   // ← 10 PM hora del script (ajusta aquí si quieres otra hora)
    .create();
  Logger.log('✅ Trigger configurado: enviarResumenDiario todos los días a las 10 PM');
}

// ── Test manual desde el editor GAS ───────────────────────────
function testPush() {
  var sheet = _getPushTokensSheet();
  var rows  = sheet.getDataRange().getValues();
  Logger.log('PUSH_TOKENS filas (sin header): ' + (rows.length - 1));
  for (var i = 1; i < rows.length; i++) {
    Logger.log('  [' + i + '] usuario=' + rows[i][2] + '  token=' + String(rows[i][1]).substring(0, 30) + '...');
  }
  _enviarPushTodos('🔔 Test MOS', 'Si ves esto, las notificaciones funcionan correctamente ✅');
  Logger.log('Push de prueba enviado a ' + (rows.length - 1) + ' token(s)');
}

// ── Helper: obtener/crear hoja PUSH_TOKENS ─────────────────────
function _getPushTokensSheet() {
  var ss    = getSpreadsheet();
  var sheet = ss.getSheetByName('PUSH_TOKENS');
  if (!sheet) {
    sheet = ss.insertSheet('PUSH_TOKENS');
    sheet.appendRow(['idToken','token','usuario','dispositivo','appOrigen','fecha','ultimaVez','activo']);
    sheet.setFrozenRows(1);
  }
  return sheet;
}

// _hoy() y _sheetToObjects están definidos en otros archivos del proyecto
