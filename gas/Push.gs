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
  if (!tokens || tokens.length === 0) { Logger.log('[Push] Sin tokens — abortando'); return; }
  var projectId   = PropertiesService.getScriptProperties().getProperty('FCM_PROJECT_ID');
  var accessToken = _getFcmAccessToken();
  var url = 'https://fcm.googleapis.com/v1/projects/' + projectId + '/messages:send';
  Logger.log('[Push] Enviando "' + titulo + '" a ' + tokens.length + ' token(s)');

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
      var code = resp.getResponseCode();
      if (code !== 200) {
        Logger.log('[Push] Token[' + idx + '] HTTP ' + code + ': ' + resp.getContentText());
      } else {
        Logger.log('[Push] Token[' + idx + '] OK');
      }
    } catch(e) {
      Logger.log('[Push] Token[' + idx + '] excepcion: ' + e.message);
    }
  });
}

// ── Selección de tokens "más activos" por usuario ──────────────
// Cada usuario puede tener varios dispositivos registrados. Solo enviamos
// al más reciente (mayor ultimaVez), evitando duplicar la notificación
// en laptop+celular+tablet del mismo admin.
//
// opciones (todas opcionales):
//   excluirUsuario: nombre del usuario a no notificar (ej: él mismo originó la acción)
//   soloRolesAdmin: true → solo MASTER + ADMIN/ADMINISTRADOR
//   soloRolesMaster: true → solo MASTER (más restrictivo que soloRolesAdmin)
//   soloAppOrigen: 'WH'|'ME'|'MOS' → solo tokens registrados desde esa app
//   soloRolesWH: true → alias de soloAppOrigen='WH' (compat con apps hijas)
function _seleccionarTokensActivos(data, opciones) {
  opciones = opciones || {};
  // headers: idToken(0) token(1) usuario(2) dispositivo(3) appOrigen(4) fecha(5) ultimaVez(6) activo(7)
  var porUsuario = {};
  var excNorm = opciones.excluirUsuario ? String(opciones.excluirUsuario).trim().toLowerCase() : null;

  // Filtro appOrigen — alias soloRolesWH = soloAppOrigen:'WH'
  var appOrigenFiltro = '';
  if (opciones.soloAppOrigen) appOrigenFiltro = String(opciones.soloAppOrigen).toUpperCase().trim();
  else if (opciones.soloRolesWH) appOrigenFiltro = 'WH';
  else if (opciones.soloRolesME) appOrigenFiltro = 'ME';

  // Match flexible — los tokens se registran con variaciones en appOrigen:
  //   warehouseMos · WH · WAREHOUSE → todos cuentan como WH
  //   mosExpress · ME · MOSEXPRESS  → todos cuentan como ME
  //   MOS · ProyectoMOS              → ambos cuentan como MOS
  function _matchApp(appOrig, filtro) {
    if (!filtro) return true;
    var a = String(appOrig || '').toUpperCase().trim();
    var f = String(filtro).toUpperCase().trim();
    if (!a) return false;          // sin appOrigen no se asume nada
    if (a === f) return true;
    if (f === 'WH'  && (a.indexOf('WAREHOUSE') === 0 || a === 'WHM' || a.indexOf('WH') === 0 && a.length <= 4)) return true;
    if (f === 'ME'  && (a.indexOf('MOSEXPRESS') === 0 || a.indexOf('MOSE') === 0)) return true;
    if (f === 'MOS' && (a === 'MOS' || a.indexOf('PROYECTOMOS') === 0)) return true;
    return false;
  }

  // Si filtramos por rol, cargar set de usuarios permitidos
  var rolSet = null;
  if (opciones.soloRolesMaster || opciones.soloRolesAdmin) {
    rolSet = {};
    try {
      var personas = _sheetToObjects(getSheet('PERSONAL_MASTER'));
      personas.forEach(function(p) {
        var rol = String(p.rol || '').toUpperCase();
        var permitido = false;
        if (opciones.soloRolesMaster) {
          permitido = (rol === 'MASTER');
        } else if (opciones.soloRolesAdmin) {
          permitido = (rol === 'MASTER' || rol === 'ADMIN' || rol === 'ADMINISTRADOR');
        }
        if (permitido && String(p.estado) === '1') {
          var n = (String(p.nombre || '') + ' ' + String(p.apellido || '')).trim().toLowerCase();
          rolSet[n] = true;
          // También aceptar solo nombre (si el token se registró sin apellido)
          rolSet[String(p.nombre || '').trim().toLowerCase()] = true;
        }
      });
    } catch(e) { Logger.log('filtro rol: ' + e.message); }
  }

  for (var i = 1; i < data.length; i++) {
    var token  = String(data[i][1] || '');
    var usuarioRaw = String(data[i][2] || '');
    var usuario = usuarioRaw.trim().toLowerCase();
    var appOrig = String(data[i][4] || '').toUpperCase().trim();
    var activo = data[i][7];
    if (!token) continue;
    if (activo === false || String(activo) === '0' || String(activo) === 'false') continue;
    if (excNorm && usuario === excNorm) continue; // excluir al sender
    if (rolSet && !rolSet[usuario]) continue;     // filtro por rol (master o admin+master)
    if (appOrigenFiltro && !_matchApp(appOrig, appOrigenFiltro)) continue; // filtro por app (WH/ME/MOS)
    var ultVezRaw = data[i][6];
    var ultVez = 0;
    try { ultVez = ultVezRaw ? new Date(ultVezRaw).getTime() : 0; } catch(_) {}
    // Cuando filtramos por appOrigen, la clave incluye la app para no colapsar
    // tokens del mismo usuario en distintas apps (ej: el mismo MASTER tiene
    // token WH y token ME; al filtrar WH solo queda el WH).
    var key = (usuario || ('__sinusuario__' + i)) + (appOrigenFiltro ? '@' + appOrig : '');
    if (!porUsuario[key] || porUsuario[key].ultVez < ultVez) {
      porUsuario[key] = { token: token, usuario: data[i][2], row: i, ultVez: ultVez };
    }
  }
  return Object.keys(porUsuario).map(function(k){ return porUsuario[k]; });
}

// ── Enviar a tokens activos (1 por usuario) + opciones de filtro ─
// opciones (todas opcionales):
//   excluirUsuario: nombre del que originó la acción (no auto-notificarse)
//   soloRolesAdmin: true → solo MASTER/ADMIN/ADMINISTRADOR
function _enviarPushTodos(titulo, cuerpo, opciones) {
  try {
    var sheet       = _getPushTokensSheet();
    var data        = sheet.getDataRange().getValues();
    var projectId   = PropertiesService.getScriptProperties().getProperty('FCM_PROJECT_ID');
    var accessToken = _getFcmAccessToken();
    var url = 'https://fcm.googleapis.com/v1/projects/' + projectId + '/messages:send';

    // Seleccionar solo 1 token por usuario (el más activo) + filtros opcionales
    var seleccion = _seleccionarTokensActivos(data, opciones || {});
    var sent = 0, cleaned = 0;

    seleccion.forEach(function(item) {
      var token = item.token;
      var i = item.row;
      // dummy variable para mantener la estructura del bloque catch original
      if (!token) return;
      var activo = data[i][7];
      if (!token || activo === false || String(activo) === '0' || String(activo) === 'false') return;

      try {
        var resp = UrlFetchApp.fetch(url, {
          method: 'post',
          contentType: 'application/json',
          headers: { 'Authorization': 'Bearer ' + accessToken },
          payload: JSON.stringify({
            message: {
              token: token,
              notification: { title: titulo, body: cuerpo },
              webpush: {
                notification: {
                  title: titulo, body: cuerpo,
                  icon:  'https://levo19.github.io/MOS/icon-192.png',
                  badge: 'https://levo19.github.io/MOS/icon-192.png',
                  vibrate: [200, 100, 200]
                }
              }
            }
          }),
          muteHttpExceptions: true
        });

        var code = resp.getResponseCode();
        if (code === 200) {
          sent++;
          Logger.log('[Push] OK → ' + (data[i][2] || 'desconocido') + ' (' + (data[i][3] || '') + ')');
        } else {
          var errCode = '';
          try {
            var body = JSON.parse(resp.getContentText());
            errCode = (body.error && body.error.details && body.error.details[0] && body.error.details[0].errorCode) || '';
          } catch(_) {}
          if (errCode === 'UNREGISTERED' || code === 404) {
            // Token expirado/inválido — marcar como inactivo para no volver a usarlo
            sheet.getRange(i + 1, 8).setValue(false);
            cleaned++;
            Logger.log('[Push] UNREGISTERED → desactivado: ' + token.substring(0, 20) + '...');
          } else {
            Logger.log('[Push] Error HTTP ' + code + ': ' + resp.getContentText().substring(0, 120));
          }
        }
      } catch(e) {
        Logger.log('[Push] excepcion token[' + i + ']: ' + e.message);
      }
    });
    Logger.log('[Push] Resumen: ' + sent + ' enviados (1 por usuario), ' + cleaned + ' tokens limpiados');
  } catch(e) {
    Logger.log('_enviarPushTodos error: ' + e.message);
  }
}

// ── Registrar / actualizar token desde el frontend ─────────────
function registrarPushToken(params) {
  if (!params.token) return { ok: false, error: 'token requerido' };
  var sheet = _getPushTokensSheet();
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iDev  = hdrs.indexOf('deviceId');

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][1]) === String(params.token)) {
      sheet.getRange(i + 1, 3).setValue(params.usuario    || data[i][2]);
      sheet.getRange(i + 1, 7).setValue(new Date());
      // Actualizar deviceId si nos pasan uno (token reusado en otro device es raro pero posible)
      if (iDev >= 0 && params.deviceId) {
        sheet.getRange(i + 1, iDev + 1).setValue(params.deviceId);
      }
      return { ok: true, data: { accion: 'actualizado' } };
    }
  }

  var fila = [
    _generateId('PTK'),
    params.token,
    params.usuario    || '',
    params.dispositivo || '',
    params.appOrigen  || 'MOS',
    _hoy(),
    new Date(),
    true
  ];
  if (iDev >= 0) fila[iDev] = params.deviceId || '';
  sheet.appendRow(fila);
  return { ok: true, data: { accion: 'registrado' } };
}

// ── Enviar push desde apps hijas (MosExpress, warehouseMos) ────
// Acepta opciones:
//   excluirUsuario: nombre del usuario a no notificar (auto-exclusión del sender)
//   soloRolesAdmin: true → solo a MASTER + ADMIN
//   soloRolesMaster: true → solo a MASTER (más restrictivo)
function enviarPushNotif(params) {
  if (!params.titulo) return { ok: false, error: 'titulo requerido' };
  var opciones = {
    excluirUsuario:  params.excluirUsuario || null,
    soloRolesAdmin:  params.soloRolesAdmin === true || String(params.soloRolesAdmin) === 'true',
    soloRolesMaster: params.soloRolesMaster === true || String(params.soloRolesMaster) === 'true',
    soloRolesWH:     params.soloRolesWH === true || String(params.soloRolesWH) === 'true',
    soloRolesME:     params.soloRolesME === true || String(params.soloRolesME) === 'true',
    soloAppOrigen:   params.soloAppOrigen || ''
  };
  _enviarPushTodos(params.titulo, params.cuerpo || '', opciones);
  return { ok: true };
}

// ── Enviar push DIRIGIDO a un usuario específico (solo al dispositivo más activo) ──
// Si el usuario tiene varios dispositivos (laptop+celular+tablet), envía
// solo al de Ultima_Vez más reciente — donde más probablemente está activo.
function enviarPushUsuario(params) {
  if (!params.usuario) return { ok: false, error: 'usuario requerido' };
  if (!params.titulo)  return { ok: false, error: 'titulo requerido' };
  var sheet = _getPushTokensSheet();
  var data  = sheet.getDataRange().getValues();
  // headers: idToken(0) token(1) usuario(2) dispositivo(3) appOrigen(4) fecha(5) ultimaVez(6) activo(7)
  var nombreNorm = String(params.usuario).trim().toLowerCase();
  var mejor = null; // { token, ultVez, dispositivo }
  for (var i = 1; i < data.length; i++) {
    var token  = String(data[i][1] || '');
    var u      = String(data[i][2] || '').trim().toLowerCase();
    var activo = data[i][7];
    if (!token) continue;
    if (activo === false || String(activo) === '0' || String(activo) === 'false') continue;
    if (u !== nombreNorm) continue;
    var ultVez = 0;
    try { ultVez = data[i][6] ? new Date(data[i][6]).getTime() : 0; } catch(_) {}
    if (!mejor || mejor.ultVez < ultVez) {
      mejor = { token: token, ultVez: ultVez, dispositivo: String(data[i][3] || '') };
    }
  }
  if (!mejor) {
    return { ok: false, error: 'Usuario "' + params.usuario + '" no tiene dispositivos suscritos a notificaciones' };
  }
  _enviarPushTokens(params.titulo, params.cuerpo || '', [mejor.token]);
  return { ok: true, data: { tokensAlcanzados: 1, usuario: params.usuario, dispositivo: mejor.dispositivo } };
}

// ── Resumen diario (llamado por el trigger de GAS) ─────────────
// El "neto cobrado" = efectivo + virtual + mixto. NO incluye crédito ni por-cobrar
// (que son promesas de venta, no caja real). Coincide con el TOTAL TURNO de turno.html
// menos los créditos/por-cobrar.
function enviarResumenDiario() {
  try {
    var fecha = _hoy();
    var ing   = _calcularIngresos(fecha);
    var cos   = _calcularCostoVentas(fecha, ing.detalleIds);
    var per   = _calcularPersonal(fecha);

    var titulo = '📊 Resumen ' + fecha;
    var lineas = [
      '💰 Cobrado: S/ ' + ing.cobrado.toFixed(2) + '  (' + ing.tickets + ' tickets)',
      '   💵 Efe: S/ ' + ing.cobradoEfectivo.toFixed(2) + ' · 📲 Vir: S/ ' + ing.cobradoVirtual.toFixed(2)
    ];
    if (ing.creditoOtorgado > 0) {
      lineas.push('💳 Crédito otorgado: S/ ' + ing.creditoOtorgado.toFixed(2) + ' (' + ing.creditos + ' tk · NO entró a caja)');
    }
    lineas.push('📦 ' + cos.unidades + ' uds · ' + cos.skusDistintos + ' SKUs');
    lineas.push('👥 Personal: ' + per.personas + ' persona' + (per.personas !== 1 ? 's' : ''));

    _enviarPushTodos(titulo, lineas.join('\n'));
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
    sheet.appendRow(['idToken','token','usuario','dispositivo','appOrigen','fecha','ultimaVez','activo','deviceId']);
    sheet.setFrozenRows(1);
  } else {
    // Agregar columna deviceId si falta (retrocompat con sheets viejos)
    var hdrs = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    if (hdrs.indexOf('deviceId') < 0) {
      sheet.getRange(1, sheet.getLastColumn() + 1).setValue('deviceId');
    }
  }
  return sheet;
}

// _hoy() y _sheetToObjects están definidos en otros archivos del proyecto
