// ============================================================
// ProyectoMOS — Config.gs
// CRUD centralizado de configuración del ecosistema:
//   ESTACIONES · IMPRESORAS · SERIES_DOCUMENTALES · PERSONAL_MASTER
//
// Reglas:
//  - Los PINs NUNCA se devuelven en listados (solo en verificación)
//  - Las impresoras de WH: solo se guardan PrintNode IDs aquí,
//    la API key de PrintNode sigue en Script Properties de cada app
//  - VENDEDORES (tipo=VENDEDOR) son solo para registro histórico,
//    no requieren PIN ni credenciales
// ============================================================

// ────────────────────────────────────────────────────────────
// Helper: parsear user agent para nombre legible del dispositivo
// Ej: "Android · SM-G960F · Chrome" o "Windows · Chrome" o "iOS · iPhone · Safari"
// ────────────────────────────────────────────────────────────
function _parseUserAgent(ua) {
  if (!ua) return '';
  var s = String(ua);
  // Plataforma
  var plat = '';
  if (/android/i.test(s))      plat = 'Android';
  else if (/iphone/i.test(s))  plat = 'iOS · iPhone';
  else if (/ipad/i.test(s))    plat = 'iOS · iPad';
  else if (/ipod/i.test(s))    plat = 'iOS · iPod';
  else if (/windows nt/i.test(s)) plat = 'Windows';
  else if (/macintosh|mac os/i.test(s)) plat = 'Mac';
  else if (/linux/i.test(s))   plat = 'Linux';
  // Modelo Android: "Android X.Y.Z; ES; SM-G960F Build/..."
  var modelo = '';
  if (plat === 'Android') {
    var m = s.match(/Android[^)]*?;\s*[a-z]{2,3}[-\w]*;\s*([^);]+)/i)
         || s.match(/;\s*([^);]+)\s+Build\//);
    if (m) modelo = m[1].trim();
  }
  // Browser
  var nav = '';
  if (/edg\//i.test(s))         nav = 'Edge';
  else if (/opr\/|opera/i.test(s)) nav = 'Opera';
  else if (/chrome\//i.test(s)) nav = 'Chrome';
  else if (/firefox/i.test(s))  nav = 'Firefox';
  else if (/safari/i.test(s))   nav = 'Safari';
  var parts = [plat, modelo, nav].filter(function(x){ return !!x; });
  return parts.join(' · ');
}

// ════════════════════════════════════════════════
// CONSULTA CONVENIENCE PARA APPS CLIENTES
// (devuelve estaciones activas + su impresora TICKET unidas)
// ════════════════════════════════════════════════

function getEstacionesParaApp(params) {
  var appOrigen = (params && params.appOrigen) ? String(params.appOrigen).toLowerCase() : '';

  var estRows = _sheetToObjects(getSheet('ESTACIONES')).filter(function(r){
    var act = String(r.activo).toLowerCase();
    return act === '1' || act === 'true';
  });
  if (appOrigen) {
    estRows = estRows.filter(function(r){
      return String(r.appOrigen || '').toLowerCase() === appOrigen;
    });
  }

  var impRows = _sheetToObjects(getSheet('IMPRESORAS')).filter(function(r){
    var act = String(r.activo).toLowerCase();
    var tipo = String(r.tipo || '').toUpperCase();
    return (act === '1' || act === 'true') && tipo === 'TICKET';
  });
  if (appOrigen) {
    impRows = impRows.filter(function(r){
      return String(r.appOrigen || '').toLowerCase() === appOrigen;
    });
  }

  // Series documentales — case-insensitive y normaliza tipoDocumento
  var serRows = _sheetToObjects(getSheet('SERIES_DOCUMENTALES')).filter(function(r){
    var act = String(r.activo).toLowerCase();
    return act === '1' || act === 'true';
  });

  var impByEstacion = {};
  impRows.forEach(function(p) {
    var eid = String(p.idEstacion || '');
    if (eid && !impByEstacion[eid]) impByEstacion[eid] = String(p.printNodeId || '');
  });

  // Series por estación (preferencia) o por zona (fallback)
  var seriesByEstacion = {};
  var seriesByZona     = {};
  serRows.forEach(function(s) {
    var eid  = String(s.idEstacion || '');
    var zid  = String(s.idZona     || '');
    var tipo = String(s.tipoDocumento || '').toUpperCase().replace(/[\s_-]/g, '');
    var serie = String(s.serie || '');
    var key = '';
    if (tipo === 'NOTAVENTA' || tipo === 'NV' || tipo === 'NOTADEVENTA' || tipo === 'NOTA') key = 'Serie_Nota';
    else if (tipo === 'BOLETA' || tipo === 'BOL' || tipo === 'B')                              key = 'Serie_Boleta';
    else if (tipo === 'FACTURA' || tipo === 'FAC' || tipo === 'F')                             key = 'Serie_Factura';
    if (!key) return;
    if (eid) {
      if (!seriesByEstacion[eid]) seriesByEstacion[eid] = {};
      seriesByEstacion[eid][key] = serie;
    } else if (zid) {
      if (!seriesByZona[zid]) seriesByZona[zid] = {};
      seriesByZona[zid][key] = serie;
    }
  });

  var data = estRows.map(function(e) {
    var eid = String(e.idEstacion || '');
    var zid = String(e.idZona || '');
    var s = seriesByEstacion[eid] || seriesByZona[zid] || {};
    return {
      idEstacion:      eid,
      Estacion_Nombre: String(e.nombre || ''),
      Zona_ID:         zid,
      PrintNode_ID:    impByEstacion[eid] || '',
      Serie_Nota:      s.Serie_Nota    || '',
      Serie_Boleta:    s.Serie_Boleta  || '',
      Serie_Factura:   s.Serie_Factura || '',
      Admin_PIN:       String(e.adminPin || ''),
      tipo:            String(e.tipo || ''),
      appOrigen:       String(e.appOrigen || '')
    };
  });

  return { ok: true, data: data };
}

// ════════════════════════════════════════════════
// ESTACIONES
// ════════════════════════════════════════════════

function getEstaciones(params) {
  var rows = _sheetToObjects(getSheet('ESTACIONES'));
  if (params && params.idZona)    rows = rows.filter(function(r){ return r.idZona === params.idZona; });
  if (params && params.appOrigen) rows = rows.filter(function(r){ return r.appOrigen === params.appOrigen; });
  if (params && params.activo)    rows = rows.filter(function(r){ return String(r.activo) === String(params.activo); });
  // Nunca exponer adminPin en el listado general
  return {
    ok: true,
    data: rows.map(function(r){
      var c = Object.assign({}, r);
      if (!params || !params.incluirPin) delete c.adminPin;
      return c;
    })
  };
}

function crearEstacion(params) {
  if (!params.nombre) return { ok: false, error: 'Requiere nombre' };
  var sheet = getSheet('ESTACIONES');
  var id = _generateId('ES');
  sheet.appendRow([
    id,
    params.idZona       || '',
    params.nombre,
    params.tipo         || 'CAJA',
    params.appOrigen    || 'mosExpress',
    params.adminPin     || '',
    '1',
    params.descripcion  || ''
  ]);
  return { ok: true, data: { idEstacion: id } };
}

function actualizarEstacion(params) {
  if (!params.idEstacion) return { ok: false, error: 'Requiere idEstacion' };
  var sheet = getSheet('ESTACIONES');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  for (var i = 1; i < data.length; i++) {
    if (data[i][0] !== params.idEstacion) continue;
    var campos = ['idZona','nombre','tipo','appOrigen','adminPin','activo','descripcion'];
    campos.forEach(function(c) {
      if (params[c] !== undefined) {
        var col = hdrs.indexOf(c);
        if (col >= 0) sheet.getRange(i+1, col+1).setValue(params[c]);
      }
    });
    return { ok: true };
  }
  return { ok: false, error: 'Estación no encontrada: ' + params.idEstacion };
}

// Verificar PIN de una estación (para autorizar operaciones en ME/WH)
function verificarPinEstacion(params) {
  if (!params.idEstacion || !params.pin) return { ok: false, error: 'Requiere idEstacion y pin' };
  var rows = _sheetToObjects(getSheet('ESTACIONES'));
  var est  = rows.find(function(r){ return r.idEstacion === params.idEstacion; });
  if (!est) return { ok: false, error: 'Estación no encontrada' };
  return { ok: true, data: { autorizado: String(est.adminPin) === String(params.pin) } };
}

// ════════════════════════════════════════════════
// IMPRESORAS
// ════════════════════════════════════════════════

function getImpresoras(params) {
  var rows = _sheetToObjects(getSheet('IMPRESORAS'));
  if (params && params.appOrigen)  rows = rows.filter(function(r){ return r.appOrigen === params.appOrigen; });
  if (params && params.idEstacion) rows = rows.filter(function(r){ return r.idEstacion === params.idEstacion; });
  if (params && params.idZona)     rows = rows.filter(function(r){ return r.idZona === params.idZona; });
  if (params && params.tipo)       rows = rows.filter(function(r){ return r.tipo === params.tipo; });
  if (params && params.activo)     rows = rows.filter(function(r){ return String(r.activo) === String(params.activo); });
  return { ok: true, data: rows };
}

function crearImpresora(params) {
  if (!params.nombre) return { ok: false, error: 'Requiere nombre' };
  var sheet = getSheet('IMPRESORAS');
  var id = _generateId('IMP');
  sheet.appendRow([
    id,
    params.nombre,
    params.printNodeId  || '',
    params.tipo         || 'TICKET',
    params.idEstacion   || '',
    params.idZona       || '',
    params.appOrigen    || 'mosExpress',
    '1',
    params.descripcion  || ''
  ]);
  return { ok: true, data: { idImpresora: id } };
}

function actualizarImpresora(params) {
  if (!params.idImpresora) return { ok: false, error: 'Requiere idImpresora' };
  var sheet = getSheet('IMPRESORAS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  for (var i = 1; i < data.length; i++) {
    if (data[i][0] !== params.idImpresora) continue;
    var campos = ['nombre','printNodeId','tipo','idEstacion','idZona','appOrigen','activo','descripcion'];
    campos.forEach(function(c) {
      if (params[c] !== undefined) {
        var col = hdrs.indexOf(c);
        if (col >= 0) sheet.getRange(i+1, col+1).setValue(params[c]);
      }
    });
    return { ok: true };
  }
  return { ok: false, error: 'Impresora no encontrada: ' + params.idImpresora };
}

// ════════════════════════════════════════════════
// SERIES DOCUMENTALES
// ════════════════════════════════════════════════

function getSeries(params) {
  var rows = _sheetToObjects(getSheet('SERIES_DOCUMENTALES'));
  if (params && params.idEstacion)    rows = rows.filter(function(r){ return r.idEstacion === params.idEstacion; });
  if (params && params.idZona)        rows = rows.filter(function(r){ return r.idZona === params.idZona; });
  if (params && params.tipoDocumento) rows = rows.filter(function(r){ return r.tipoDocumento === params.tipoDocumento; });
  if (params && params.activo)        rows = rows.filter(function(r){ return String(r.activo) === String(params.activo); });
  return { ok: true, data: rows };
}

function crearSerie(params) {
  if (!params.idEstacion || !params.tipoDocumento || !params.serie) {
    return { ok: false, error: 'Requiere idEstacion, tipoDocumento y serie' };
  }
  var sheet = getSheet('SERIES_DOCUMENTALES');
  var id = _generateId('SER');
  sheet.appendRow([
    id,
    params.idEstacion,
    params.idZona       || '',
    params.tipoDocumento,
    params.serie,
    parseInt(params.correlativo) || 1,
    '1'
  ]);
  return { ok: true, data: { idSerie: id } };
}

function actualizarSerie(params) {
  if (!params.idSerie) return { ok: false, error: 'Requiere idSerie' };
  var sheet = getSheet('SERIES_DOCUMENTALES');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  for (var i = 1; i < data.length; i++) {
    if (data[i][0] !== params.idSerie) continue;
    var campos = ['idEstacion','idZona','tipoDocumento','serie','correlativo','activo'];
    campos.forEach(function(c) {
      if (params[c] !== undefined) {
        var col = hdrs.indexOf(c);
        if (col >= 0) sheet.getRange(i+1, col+1).setValue(params[c]);
      }
    });
    return { ok: true };
  }
  return { ok: false, error: 'Serie no encontrada: ' + params.idSerie };
}

// ════════════════════════════════════════════════
// PERSONAL MASTER
// OPERADORES: empleados fijos warehouseMos (PIN, rol, tarifa)
// VENDEDORES: cajeros MosExpress — solo registro de nombre, sin cuenta
// ════════════════════════════════════════════════

// Auto-añade columna Ultima_Conexion a PERSONAL_MASTER si no existe
function _garantizarColumnasPersonal() {
  var sheet = getSheet('PERSONAL_MASTER');
  var hdrs = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0]
    .map(function(h){ return String(h).trim(); });
  if (hdrs.indexOf('Ultima_Conexion') === -1) {
    var col = sheet.getLastColumn() + 1;
    sheet.getRange(1, col, 1, 1).setValues([['Ultima_Conexion']]);
    sheet.getRange(1, col, 1, 1).setFontWeight('bold').setBackground('#1f2937').setFontColor('#fff');
  }
  return sheet;
}

function getPersonalMaster(params) {
  _garantizarColumnasPersonal();
  var rows = _sheetToObjects(getSheet('PERSONAL_MASTER'));
  if (params && params.tipo)      rows = rows.filter(function(r){ return r.tipo === params.tipo; });
  if (params && params.appOrigen) rows = rows.filter(function(r){ return r.appOrigen === params.appOrigen; });
  if (params && params.estado)    rows = rows.filter(function(r){ return String(r.estado) === String(params.estado); });
  // Normalizar Ultima_Conexion a ISO con Z explícito — mismo patrón que getDispositivos.
  // Sin esto, strings legacy "2026-05-09 14:35:29" sin Z los parseaba el browser
  // como hora local y mostraba "hace 9h" cuando eran segundos.
  var tz = Session.getScriptTimeZone();
  rows.forEach(function(r){
    if (!r.Ultima_Conexion) return;
    try {
      if (r.Ultima_Conexion instanceof Date) {
        r.Ultima_Conexion = r.Ultima_Conexion.toISOString();
        return;
      }
      if (typeof r.Ultima_Conexion === 'string') {
        var s = r.Ultima_Conexion.trim();
        // Si ya tiene T y Z → ISO válido
        if (s.indexOf('T') >= 0 && s.indexOf('Z') >= 0) return;
        // Intentar parsear formatos legacy en TZ del script (asumir local)
        var parsed = null;
        var formatos = ['yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd', 'M/d/yyyy H:m:s', 'd/M/yyyy H:m:s'];
        for (var fi = 0; fi < formatos.length; fi++) {
          try {
            parsed = Utilities.parseDate(s, tz, formatos[fi]);
            if (parsed && !isNaN(parsed.getTime())) break;
            parsed = null;
          } catch(_) {}
        }
        if (parsed) r.Ultima_Conexion = parsed.toISOString();
      }
    } catch(_) {}
  });
  // PIN solo se devuelve si se pide explícitamente (para verificación interna)
  return {
    ok: true,
    data: rows.map(function(r){
      var c = Object.assign({}, r);
      if (!params || !params.incluirPin) delete c.pin;
      return c;
    })
  };
}

// Heartbeat de personal — actualiza Ultima_Conexion del usuario.
// Soporta búsqueda por idPersonal o por (nombre + appOrigen).
// Si es vendedor ME nuevo (no existe en PM), no crea fila aquí — el bloqueo
// usa BLOQUEOS_USUARIO independiente.
function registrarConexionPersonal(params) {
  if (!params) return { ok: false, error: 'Sin params' };
  _garantizarColumnasPersonal();
  var sheet = getSheet('PERSONAL_MASTER');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId   = hdrs.indexOf('idPersonal');
  var iNom  = hdrs.indexOf('nombre');
  var iApp  = hdrs.indexOf('appOrigen');
  var iUC   = hdrs.indexOf('Ultima_Conexion');
  if (iUC < 0) return { ok: false, error: 'Columna Ultima_Conexion no creada' };

  var nombreNorm = String(params.nombre || '').trim().toLowerCase();
  var appNorm = String(params.appOrigen || '').toLowerCase();
  // ISO UTC explícito ('Z') — sin ambigüedad de timezone al leer del browser.
  // Antes guardábamos en TZ del script sin Z → JS lo parseaba como hora local
  // del browser y daba diferencias de horas.
  var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");

  for (var i = 1; i < data.length; i++) {
    var matchId  = params.idPersonal && String(data[i][iId]) === String(params.idPersonal);
    var matchNom = nombreNorm && String(data[i][iNom] || '').trim().toLowerCase() === nombreNorm;
    // Si appOrigen es 'mos' (master/admin abriendo el panel), no filtrar por app
    // — el master puede figurar como appOrigen='warehouseMos' u otro en PERSONAL_MASTER.
    var matchApp = !appNorm || appNorm === 'mos' || String(data[i][iApp] || '').toLowerCase() === appNorm;
    if ((matchId || matchNom) && matchApp) {
      sheet.getRange(i + 1, iUC + 1).setValue(nowStr);
      return { ok: true, data: { idPersonal: data[i][iId], nombre: data[i][iNom] } };
    }
  }
  return { ok: true, data: { idPersonal: null, nombre: params.nombre || null, encontrado: false } };
}

function crearPersonalMaster(params) {
  if (!params.nombre) return { ok: false, error: 'Requiere nombre' };
  var sheet = getSheet('PERSONAL_MASTER');
  var id = params.idPersonal || _generateId('PER');
  sheet.appendRow([
    id,
    params.nombre,
    params.apellido     || '',
    params.tipo         || 'OPERADOR',
    params.appOrigen    || 'warehouseMos',
    params.rol          || 'ALMACENERO',
    params.pin          || '',
    params.color        || '#6366f1',
    parseFloat(params.tarifaHora) || 0,
    parseFloat(params.montoBase)  || 0,
    '1',
    new Date(),
    params.foto         || ''
  ]);

  // Log de auditoría
  try {
    auditarLogMOS('PERSONAL_MASTER', id, {
      usuario: String(params.usuario || params._audit && params._audit.usuario || 'desconocido'),
      rol:     String(params._audit && params._audit.rol || ''),
      source:  String(params._source || 'MOS_PERSONAL'),
      accion:  'crear',
      ref: {
        nombre: params.nombre,
        apellido: params.apellido || '',
        tipo: params.tipo || 'OPERADOR',
        appOrigen: params.appOrigen || 'warehouseMos',
        rol: params.rol || 'ALMACENERO',
        montoBase: parseFloat(params.montoBase) || 0,
        tarifaHora: parseFloat(params.tarifaHora) || 0,
        tienePin: !!params.pin
      }
    });
  } catch(_){}

  return { ok: true, data: { idPersonal: id } };
}

function actualizarPersonalMaster(params) {
  if (!params.idPersonal) return { ok: false, error: 'Requiere idPersonal' };
  var sheet = getSheet('PERSONAL_MASTER');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  for (var i = 1; i < data.length; i++) {
    if (data[i][0] !== params.idPersonal) continue;
    var campos = ['nombre','apellido','tipo','appOrigen','rol','pin','color','tarifaHora','montoBase','estado'];
    var cambios = [];
    campos.forEach(function(c) {
      if (params[c] !== undefined) {
        var col = hdrs.indexOf(c);
        if (col >= 0) {
          var antes = data[i][col];
          var despues = params[c];
          // Comparación normalizada (números con tolerancia, strings con trim)
          if (String(antes).trim() !== String(despues).trim()) {
            // No exponer el PIN viejo en el log; solo decir que cambió
            if (c === 'pin') {
              cambios.push({ campo: c, antes: antes ? '••••' : '(vacío)', despues: despues ? '••••' : '(vacío)' });
            } else {
              cambios.push({ campo: c, antes: antes, despues: despues });
            }
          }
          sheet.getRange(i+1, col+1).setValue(despues);
        }
      }
    });

    // Log si hubo cambios reales
    if (cambios.length > 0) {
      try {
        auditarLogMOS('PERSONAL_MASTER', params.idPersonal, {
          usuario: String(params.usuario || (params._audit && params._audit.usuario) || 'desconocido'),
          rol:     String((params._audit && params._audit.rol) || ''),
          source:  String(params._source || 'MOS_PERSONAL'),
          accion:  'editar',
          cambios: cambios,
          motivo:  String(params.motivo || '')
        });
      } catch(_){}
    }

    return { ok: true, cambios: cambios.length };
  }
  return { ok: false, error: 'Personal no encontrado: ' + params.idPersonal };
}

function verificarPinPersonal(params) {
  if (!params.idPersonal || !params.pin) return { ok: false, error: 'Requiere idPersonal y pin' };
  var rows = _sheetToObjects(getSheet('PERSONAL_MASTER'));
  var persona = rows.find(function(r) {
    return r.idPersonal === params.idPersonal &&
           r.appOrigen  === 'MOS' &&
           String(r.estado) === '1';
  });
  if (!persona) return { ok: false, error: 'Usuario no encontrado' };
  if (String(persona.pin) !== String(params.pin)) return { ok: true, data: { autorizado: false } };
  return { ok: true, data: { autorizado: true, nombre: persona.nombre, rol: persona.rol } };
}

// ════════════════════════════════════════════════
// DISPOSITIVOS
// Gestión centralizada de equipos físicos autorizados por app.
// Columnas: ID_Dispositivo | Nombre_Equipo | App | Estado | Ultima_Conexion
//           + Ultima_Zona | Ultima_Estacion | Ultima_Sesion (auto-añadidas)
//
// Estados: ACTIVO | INACTIVO | PENDIENTE_APROBACION
// Si MosExpress conecta con un UUID desconocido se crea como
// PENDIENTE_APROBACION; el admin aprueba o rechaza desde el panel.
// ════════════════════════════════════════════════

var _DISP_COLS_EXTRA = ['Ultima_Zona', 'Ultima_Estacion', 'Ultima_Sesion',
                        'Permisos_JSON', 'Permisos_LastUpdate',
                        'Forzar_Wizard', 'Suspendido_Desde',
                        // [v2.41.76] Cierre nocturno: cuando el cron 23h corre,
                        // marca Forzar_Logout='1' + Logout_Auto_Ts=ISO. La PWA
                        // ve el flag al próximo poll de consultarEstadoDispositivo
                        // y cierra sesión local + caja (si abierta) + va al login.
                        'Forzar_Logout', 'Logout_Auto_Ts'];

// Push helper · notifica a admin/master cuando se aprueba un dispositivo
function _notificarAprobacionDispositivo(deviceId, app, nombreEquipo, aprobadoPor, accion) {
  try {
    var titulo = '✅ Dispositivo aprobado';
    var appLabel = (app || '').toUpperCase() || '—';
    var nombre   = nombreEquipo || ('UUID ' + (deviceId || '').substring(0, 8) + '...');
    var quien    = aprobadoPor || 'admin';
    var via      = accion === 'creado' ? 'in-situ' : (accion === 'reactivado' ? 'in-situ (reactivado)' : 'desde panel');
    var cuerpo   = nombre + ' · ' + appLabel + ' · aprobado por ' + quien + ' (' + via + ')';
    _enviarPushTodos(titulo, cuerpo, { soloRolesAdmin: true, idNotif: 'MOS_DEVICE_APROBADO' });
  } catch (e) { Logger.log('Push aprobación falló: ' + e.message); }
}

function _garantizarColumnasDispositivos() {
  var sheet = getSheet('DISPOSITIVOS');
  var data = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues();
  var hdrs = (data[0] || []).map(function(h) { return String(h).trim(); });
  var faltan = _DISP_COLS_EXTRA.filter(function(c) { return hdrs.indexOf(c) === -1; });
  if (faltan.length > 0) {
    var startCol = sheet.getLastColumn() + 1;
    sheet.getRange(1, startCol, 1, faltan.length).setValues([faltan]);
    sheet.getRange(1, startCol, 1, faltan.length)
         .setFontWeight('bold').setBackground('#1f2937').setFontColor('#fff');
  }
  return sheet;
}

/**
 * [v2.43.28] Telemetría de quota de localStorage de dispositivos ME.
 * Cuando un cliente ME detecta QuotaExceeded persistente tras GC, envía
 * una vez al día este reporte. Se guarda en hoja QUOTA_DISPOSITIVOS_LOG
 * para que el admin sepa qué tablets están al límite y necesitan
 * intervención (reset master, más memoria, etc).
 *
 * No bloquea ni alerta — es solo telemetría. Sin push spammeoso porque
 * el cliente ya dedup diario localmente.
 */
function reportarQuotaDispositivo(params) {
  try {
    var ss = getSpreadsheet();
    var sh = ss.getSheetByName('QUOTA_DISPOSITIVOS_LOG');
    if (!sh) {
      sh = ss.insertSheet('QUOTA_DISPOSITIVOS_LOG');
      sh.appendRow(['ts','deviceId','vendedor','pendingSales','totalKeys','accion']);
      sh.getRange(1, 1, 1, 6).setFontWeight('bold')
        .setBackground('#7c2d12').setFontColor('#fff');
      sh.setFrozenRows(1);
    }
    sh.appendRow([
      new Date(),
      String(params.deviceId || ''),
      String(params.vendedor || ''),
      parseInt(params.pendingSales) || 0,
      parseInt(params.totalKeys) || 0,
      'QUOTA_FULL'
    ]);
    return ContentService.createTextOutput(JSON.stringify({ ok: true })).setMimeType(ContentService.MimeType.JSON);
  } catch(e) {
    return ContentService.createTextOutput(JSON.stringify({ ok: false, error: e.message })).setMimeType(ContentService.MimeType.JSON);
  }
}

function getDispositivos(params) {
  _garantizarColumnasDispositivos();
  var rows = _sheetToObjects(getSheet('DISPOSITIVOS'));
  if (params && params.app)    rows = rows.filter(function(r){ return r.App === params.app; });
  if (params && params.estado) rows = rows.filter(function(r){ return r.Estado === params.estado; });
  // Serializar Ultima_Conexion como ISO con Z (UTC explícito) para evitar
  // ambigüedad de timezone en el browser. Si el server timezone no coincide
  // con el del usuario, los strings sin Z se parseaban como hora local del
  // browser → mostraba "hace 19h" cuando realmente eran segundos.
  var tz = Session.getScriptTimeZone();
  rows.forEach(function(r){
    if (!r.Ultima_Conexion) return;
    try {
      if (r.Ultima_Conexion instanceof Date) {
        r.Ultima_Conexion = r.Ultima_Conexion.toISOString();
        return;
      }
      if (typeof r.Ultima_Conexion === 'string') {
        var s = r.Ultima_Conexion.trim();
        // Si ya tiene T o Z, asumir ISO válido — dejarlo como está
        if (s.indexOf('T') >= 0 || s.indexOf('Z') >= 0) return;
        // Intentar parsear con varios formatos legacy
        var parsed = null;
        var formatos = ['yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd', 'dd/MM/yyyy HH:mm:ss', 'dd/MM/yyyy'];
        for (var fi = 0; fi < formatos.length; fi++) {
          try {
            parsed = Utilities.parseDate(s, tz, formatos[fi]);
            if (parsed && !isNaN(parsed.getTime())) break;
            parsed = null;
          } catch(_) { /* intentar siguiente formato */ }
        }
        if (parsed) {
          r.Ultima_Conexion = parsed.toISOString();
        }
        // Si nada parsea, dejarlo como string crudo — el frontend hará best-effort
      }
    } catch(eRow) {
      Logger.log('Parse Ultima_Conexion failed for ' + r.ID_Dispositivo + ': ' + eRow.message);
      // No re-throw — un row mal no debe romper toda la lista
    }
  });
  return { ok: true, data: rows };
}

function crearDispositivo(params) {
  _garantizarColumnasDispositivos();
  if (!params.ID_Dispositivo) return { ok: false, error: 'Requiere ID_Dispositivo' };
  if (!params.Nombre_Equipo)  return { ok: false, error: 'Requiere Nombre_Equipo' };
  var sheet = getSheet('DISPOSITIVOS');
  var dup = _sheetToObjects(sheet).find(function(d){ return d.ID_Dispositivo === params.ID_Dispositivo; });
  if (dup) return { ok: false, error: 'Dispositivo ya registrado: ' + params.ID_Dispositivo };
  var hdrs = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  var fila = new Array(hdrs.length).fill('');
  fila[hdrs.indexOf('ID_Dispositivo')]   = params.ID_Dispositivo;
  fila[hdrs.indexOf('Nombre_Equipo')]    = params.Nombre_Equipo;
  fila[hdrs.indexOf('App')]              = params.App    || 'mosExpress';
  fila[hdrs.indexOf('Estado')]           = params.Estado || 'ACTIVO';
  // ISO UTC explícito (Z) — formato consistente con el resto de heartbeats
  fila[hdrs.indexOf('Ultima_Conexion')]  = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
  if (hdrs.indexOf('Ultima_Zona') >= 0)     fila[hdrs.indexOf('Ultima_Zona')]     = params.Ultima_Zona     || '';
  if (hdrs.indexOf('Ultima_Estacion') >= 0) fila[hdrs.indexOf('Ultima_Estacion')] = params.Ultima_Estacion || '';
  if (hdrs.indexOf('Ultima_Sesion') >= 0)   fila[hdrs.indexOf('Ultima_Sesion')]   = params.Ultima_Sesion   || '';
  sheet.appendRow(fila);
  return { ok: true, data: { ID_Dispositivo: params.ID_Dispositivo } };
}

function actualizarDispositivo(params) {
  _garantizarColumnasDispositivos();
  if (!params.ID_Dispositivo) return { ok: false, error: 'Requiere ID_Dispositivo' };
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) !== String(params.ID_Dispositivo)) continue;
    var campos = ['Nombre_Equipo', 'App', 'Estado', 'Ultima_Zona', 'Ultima_Estacion', 'Ultima_Sesion'];
    var cambioZonaEstacion = false;
    var iZ  = hdrs.indexOf('Ultima_Zona');
    var iE  = hdrs.indexOf('Ultima_Estacion');
    campos.forEach(function(c) {
      if (params[c] !== undefined) {
        var col = hdrs.indexOf(c);
        if (col >= 0) {
          var actual = String(data[i][col] || '');
          if ((c === 'Ultima_Zona' || c === 'Ultima_Estacion') && actual !== String(params[c] || '')) {
            cambioZonaEstacion = true;
          }
          sheet.getRange(i + 1, col + 1).setValue(params[c]);
        }
      }
    });
    // Si el admin cambió manualmente la zona/estación, refrescar Ultima_Conexion
    // y marcar Ultima_Sesion='manual_admin' para que el panel muestre tiempo reciente.
    if (cambioZonaEstacion) {
      var iUC = hdrs.indexOf('Ultima_Conexion');
      var iUS = hdrs.indexOf('Ultima_Sesion');
      // ISO UTC explícito (mismo formato que el resto)
      var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
      if (iUC >= 0) sheet.getRange(i + 1, iUC + 1).setValue(nowStr);
      if (iUS >= 0 && params.Ultima_Sesion === undefined) {
        sheet.getRange(i + 1, iUS + 1).setValue('manual_admin');
      }
    }
    return { ok: true };
  }
  return { ok: false, error: 'Dispositivo no encontrado: ' + params.ID_Dispositivo };
}

// Registrar última conexión + zona/estación/vendedor de la sesión actual.
// Llamado por MosExpress al aperturar caja (o cualquier sesión válida).
// Si el UUID no existe → lo crea como PENDIENTE_APROBACION (admin debe aprobar).
function registrarSesionDispositivo(params) {
  _garantizarColumnasDispositivos();
  var deviceId = String(params.ID_Dispositivo || params.deviceId || '').trim();
  if (!deviceId) return { ok: false, error: 'Requiere ID_Dispositivo' };

  // ── App MOS = panel admin, NO se considera "dispositivo de operación" ──
  // No crear PENDIENTE_APROBACION ni mandar push spam. Cada admin/master abre
  // MOS desde múltiples browsers (laptop, celular, tablet) y cada UUID nuevo
  // generaba un push de "Nuevo dispositivo solicita acceso" — ruido innecesario.
  // Solo actualizar Ultima_Conexion si el row YA existe.
  var appNorm = String(params.app || params.App || '').toLowerCase();
  if (appNorm === 'mos') {
    var sheetMos = getSheet('DISPOSITIVOS');
    var dataMos  = sheetMos.getDataRange().getValues();
    var hdrsMos  = dataMos[0];
    var iIdMos   = hdrsMos.indexOf('ID_Dispositivo');
    var iUCMos   = hdrsMos.indexOf('Ultima_Conexion');
    // ISO UTC explícito (mismo formato que el resto)
    var nowM = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
    for (var rm = 1; rm < dataMos.length; rm++) {
      if (String(dataMos[rm][iIdMos]) === deviceId) {
        if (iUCMos >= 0) sheetMos.getRange(rm + 1, iUCMos + 1).setValue(nowM);
        return { ok: true, data: { autorizado: true, estado: 'ACTIVO', soloHeartbeat: true } };
      }
    }
    // No existe → no hacer nada (MOS no se auto-registra)
    return { ok: true, data: { autorizado: false, estado: 'NO_REGISTRADO', noEsDispositivoOperativo: true } };
  }

  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iEst  = hdrs.indexOf('Estado');
  var iUC   = hdrs.indexOf('Ultima_Conexion');
  var iUZ   = hdrs.indexOf('Ultima_Zona');
  var iUEs  = hdrs.indexOf('Ultima_Estacion');
  var iUSe  = hdrs.indexOf('Ultima_Sesion');
  // ISO UTC explícito como STRING — antes era Date object que Sheets formateaba
  // según locale del cell ("5/9/2026 9:35:29" en lugar de ISO), causando que el
  // browser lo interpretara como hora local y mostrara "hace 9h" cuando eran minutos.
  var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iId]) !== deviceId) continue;
    var estado = String(data[i][iEst] || '').toUpperCase();
    if (estado === 'INACTIVO') {
      return { ok: true, data: { autorizado: false, estado: 'INACTIVO', error: 'Dispositivo bloqueado por el admin' } };
    }
    if (estado === 'PENDIENTE_APROBACION') {
      // Solo refrescar Ultima_Conexion para que el admin sepa que sigue intentando
      if (iUC >= 0) sheet.getRange(i + 1, iUC + 1).setValue(nowStr);
      return { ok: true, data: { autorizado: false, estado: 'PENDIENTE_APROBACION', error: 'Esperando aprobación del administrador' } };
    }
    // ACTIVO → actualizar contexto
    if (iUC >= 0)  sheet.getRange(i + 1, iUC + 1).setValue(nowStr);
    if (iUZ >= 0   && params.idZona      !== undefined) sheet.getRange(i + 1, iUZ + 1).setValue(params.idZona || '');
    if (iUEs >= 0  && params.idEstacion  !== undefined) sheet.getRange(i + 1, iUEs + 1).setValue(params.idEstacion || '');
    if (iUSe >= 0  && params.vendedor    !== undefined) sheet.getRange(i + 1, iUSe + 1).setValue(params.vendedor || '');
    // [v2.41.76] Devolver flag forzar_logout para que ME/WH cierren sesión
    var iFL2   = hdrs.indexOf('Forzar_Logout');
    var iFLts2 = hdrs.indexOf('Logout_Auto_Ts');
    var fl2 = iFL2 >= 0 ? String(data[i][iFL2] || '') : '';
    return { ok: true, data: {
      autorizado: true, estado: 'ACTIVO',
      nombre: data[i][hdrs.indexOf('Nombre_Equipo')],
      forzar_logout: fl2 === '1' || fl2.toLowerCase() === 'true',
      logout_auto_ts: iFLts2 >= 0 ? String(data[i][iFLts2] || '') : ''
    }};
  }

  // No existe → crear como PENDIENTE_APROBACION con nombre legible
  var nombreNuevo = params.Nombre_Equipo;
  if (!nombreNuevo || nombreNuevo.indexOf('Nuevo dispositivo') === 0) {
    var labelUA = _parseUserAgent(params.userAgent || '');
    nombreNuevo = labelUA ? labelUA + ' (' + deviceId.substring(0, 6) + ')' : ('Nuevo dispositivo ' + deviceId.substring(0, 8));
  }
  var appNueva = params.app || params.App || 'mosExpress';
  var fila = new Array(hdrs.length).fill('');
  fila[iId] = deviceId;
  fila[hdrs.indexOf('Nombre_Equipo')] = nombreNuevo;
  fila[hdrs.indexOf('App')]           = appNueva;
  fila[iEst]                          = 'PENDIENTE_APROBACION';
  if (iUC >= 0)  fila[iUC]  = nowStr;
  if (iUZ >= 0)  fila[iUZ]  = params.idZona || '';
  if (iUEs >= 0) fila[iUEs] = params.idEstacion || '';
  if (iUSe >= 0) fila[iUSe] = params.vendedor || '';
  sheet.appendRow(fila);

  // Push notif a master avisando del nuevo dispositivo, con nombre legible.
  try {
    var deviceLabel = _parseUserAgent(params.userAgent || '');
    var detalle = (deviceLabel || appNueva.toUpperCase()) + ' · UUID ' + deviceId.substring(0, 8) + '...';
    if (params.idEstacion) detalle += ' · estación ' + params.idEstacion;
    if (params.vendedor)   detalle += ' · cajero ' + params.vendedor;
    _enviarPushTodos('🔔 Nuevo dispositivo solicita acceso', detalle, { soloRolesMaster: true, idNotif: 'MOS_DEVICE_PENDIENTE' });
  } catch(e) { Logger.log('Push pendiente fallo: ' + e.message); }

  return { ok: true, data: { autorizado: false, estado: 'PENDIENTE_APROBACION', error: 'Dispositivo nuevo — esperando aprobación del administrador' } };
}

// Compat: viejo endpoint sigue funcionando (sólo refresca Ultima_Conexion)
function registrarConexionDispositivo(params) {
  return registrarSesionDispositivo(params);
}

// Listar dispositivos pendientes de aprobación (panel MOS los muestra arriba)
function getDispositivosPendientes() {
  _garantizarColumnasDispositivos();
  var rows = _sheetToObjects(getSheet('DISPOSITIVOS'))
    .filter(function(d) { return String(d.Estado || '').toUpperCase() === 'PENDIENTE_APROBACION'; });
  return { ok: true, data: rows };
}

// Aprobar dispositivo pendiente — admin asigna nombre y opcionalmente zona/estación
// ── Consultar estado del dispositivo (NO crea row, pero SÍ actualiza heartbeat) ──
// Lee el estado actual sin generar PENDIENTE_APROBACION accidentalmente.
// Si el row existe, actualiza Ultima_Conexion → master ve actividad en tiempo
// real aún cuando el operador esté en pantalla candado pre-login.
function consultarEstadoDispositivo(params) {
  _garantizarColumnasDispositivos();
  var deviceId = String(params.ID_Dispositivo || params.deviceId || '').trim();
  if (!deviceId) return { ok: false, error: 'Requiere ID_Dispositivo' };
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iEst  = hdrs.indexOf('Estado');
  var iApp  = hdrs.indexOf('App');
  var iNom  = hdrs.indexOf('Nombre_Equipo');
  var iUC   = hdrs.indexOf('Ultima_Conexion');
  var iFW   = hdrs.indexOf('Forzar_Wizard');
  var iSus  = hdrs.indexOf('Suspendido_Desde');
  var iFL   = hdrs.indexOf('Forzar_Logout');
  var iFLts = hdrs.indexOf('Logout_Auto_Ts');
  // ISO UTC explícito como string — formato consistente entre todos los heartbeats
  var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iId]) !== deviceId) continue;
    // Heartbeat: actualizar Ultima_Conexion aunque el dispositivo no haya logueado
    if (iUC >= 0) sheet.getRange(i + 1, iUC + 1).setValue(nowStr);
    // Si estaba suspendido por inactividad y reapareció, limpiar el flag
    if (iSus >= 0 && data[i][iSus]) sheet.getRange(i + 1, iSus + 1).setValue('');
    var fw = iFW >= 0 ? String(data[i][iFW] || '') : '';
    var fl = iFL >= 0 ? String(data[i][iFL] || '') : '';
    var flTs = iFLts >= 0 ? String(data[i][iFLts] || '') : '';
    return { ok: true, data: {
      registrado:    true,
      estado:        String(data[i][iEst] || ''),
      nombre:        data[i][iNom] || '',
      app:           data[i][iApp] || '',
      forzar_wizard: fw === '1' || fw.toLowerCase() === 'true',
      // [v2.41.76] Cuando el cron 23h corre, marca '1'. La PWA cierra
      // sesión + caja (si aplica) y va al login. Cliente debe llamar
      // 'marcarLogoutHonrado' para que el flag no quede en bucle.
      forzar_logout:    fl === '1' || fl.toLowerCase() === 'true',
      logout_auto_ts:   flTs
    }};
  }
  return { ok: true, data: { registrado: false, estado: 'NO_REGISTRADO' } };
}

// ════════════════════════════════════════════════════════════════════════
// PERMISOS DEL DISPOSITIVO — visibility para admin
// Cada app reporta los permisos que tiene granted/denied/unsupported.
// ════════════════════════════════════════════════════════════════════════
function registrarPermisosDispositivo(params) {
  _garantizarColumnasDispositivos();
  var deviceId = String(params.deviceId || params.ID_Dispositivo || '').trim();
  if (!deviceId) return { ok: false, error: 'Requiere deviceId' };
  if (!params.permisos || typeof params.permisos !== 'object') {
    return { ok: false, error: 'Requiere permisos:{notif,cam,mic,geo,audio,install}' };
  }
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iPJ   = hdrs.indexOf('Permisos_JSON');
  var iPLU  = hdrs.indexOf('Permisos_LastUpdate');
  var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iId]) !== deviceId) continue;
    if (iPJ  >= 0) sheet.getRange(i + 1, iPJ  + 1).setValue(JSON.stringify(params.permisos));
    if (iPLU >= 0) sheet.getRange(i + 1, iPLU + 1).setValue(nowStr);
    return { ok: true };
  }
  return { ok: false, error: 'Dispositivo no encontrado: ' + deviceId };
}

// El dispositivo confirma que ya mostró el wizard → limpiar la flag
function marcarWizardMostrado(params) {
  _garantizarColumnasDispositivos();
  var deviceId = String(params.deviceId || params.ID_Dispositivo || '').trim();
  if (!deviceId) return { ok: false, error: 'Requiere deviceId' };
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iFW   = hdrs.indexOf('Forzar_Wizard');
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iId]) !== deviceId) continue;
    if (iFW >= 0) sheet.getRange(i + 1, iFW + 1).setValue('');
    return { ok: true };
  }
  return { ok: false, error: 'Dispositivo no encontrado' };
}

// Admin fuerza re-wizard remoto. Requiere clave admin (8 dig).
function forzarWizardDispositivo(params) {
  if (!params.deviceId)   return { ok: false, error: 'Requiere deviceId' };
  if (!params.claveAdmin) return { ok: false, error: 'Requiere claveAdmin' };
  var auth = verificarClaveAdmin({
    clave: params.claveAdmin, accion: 'FORZAR_WIZARD',
    refDocumento: params.deviceId, appOrigen: params.app || '',
    detalle: 'Forzar re-wizard remoto'
  });
  if (!auth.ok) return auth;
  if (!auth.data || !auth.data.autorizado) {
    return { ok: true, data: { autorizado: false, error: auth.data?.error || 'Clave incorrecta' } };
  }
  _garantizarColumnasDispositivos();
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iFW   = hdrs.indexOf('Forzar_Wizard');
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iId]) !== params.deviceId) continue;
    if (iFW >= 0) sheet.getRange(i + 1, iFW + 1).setValue('1');
    return { ok: true, data: { autorizado: true, forzadoPor: auth.data.validadoPor } };
  }
  return { ok: false, error: 'Dispositivo no encontrado' };
}

// Admin revoca acceso de un dispositivo (UUID → INACTIVO). Clave admin requerida.
function revocarDispositivo(params) {
  if (!params.deviceId)   return { ok: false, error: 'Requiere deviceId' };
  if (!params.claveAdmin) return { ok: false, error: 'Requiere claveAdmin' };
  var auth = verificarClaveAdmin({
    clave: params.claveAdmin, accion: 'REVOCAR_DISPOSITIVO',
    refDocumento: params.deviceId, appOrigen: params.app || '',
    detalle: 'Revocar acceso de dispositivo'
  });
  if (!auth.ok) return auth;
  if (!auth.data || !auth.data.autorizado) {
    return { ok: true, data: { autorizado: false, error: auth.data?.error || 'Clave incorrecta' } };
  }
  _garantizarColumnasDispositivos();
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iEst  = hdrs.indexOf('Estado');
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iId]) !== params.deviceId) continue;
    if (iEst >= 0) sheet.getRange(i + 1, iEst + 1).setValue('INACTIVO');
    return { ok: true, data: { autorizado: true, revocadoPor: auth.data.validadoPor } };
  }
  return { ok: false, error: 'Dispositivo no encontrado' };
}

// Auto-purge: dispositivos ACTIVOS sin Ultima_Conexion en >7 días → SUSPENDIDO.
// Diseñado para correr desde un trigger diario (o manual).
// SUSPENDIDO ≠ INACTIVO: re-activable solo con que el dispositivo vuelva a conectar.
function purgarDispositivosInactivos(params) {
  _garantizarColumnasDispositivos();
  var diasMax = (params && Number(params.dias)) > 0 ? Number(params.dias) : 7;
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iEst  = hdrs.indexOf('Estado');
  var iUC   = hdrs.indexOf('Ultima_Conexion');
  var iSus  = hdrs.indexOf('Suspendido_Desde');
  var nowMs = Date.now();
  var limMs = diasMax * 24 * 60 * 60 * 1000;
  var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
  var suspendidos = 0;
  for (var i = 1; i < data.length; i++) {
    var est = String(data[i][iEst] || '').toUpperCase();
    if (est !== 'ACTIVO') continue;
    var uc = data[i][iUC];
    var ucMs = 0;
    if (uc instanceof Date) ucMs = uc.getTime();
    else if (typeof uc === 'string' && uc.trim()) {
      var d = new Date(uc);
      if (!isNaN(d.getTime())) ucMs = d.getTime();
    }
    if (!ucMs) continue;
    if ((nowMs - ucMs) > limMs) {
      sheet.getRange(i + 1, iEst + 1).setValue('SUSPENDIDO');
      if (iSus >= 0) sheet.getRange(i + 1, iSus + 1).setValue(nowStr);
      suspendidos++;
    }
  }
  return { ok: true, data: { suspendidos: suspendidos, dias: diasMax } };
}

// Cron-friendly wrapper: instalable como trigger diario sin params.
function purgarDispositivosInactivos7d() {
  return purgarDispositivosInactivos({ dias: 7 });
}

function aprobarDispositivoPendiente(params) {
  _garantizarColumnasDispositivos();
  if (!params.ID_Dispositivo) return { ok: false, error: 'Requiere ID_Dispositivo' };
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) !== String(params.ID_Dispositivo)) continue;
    sheet.getRange(i + 1, hdrs.indexOf('Estado') + 1).setValue('ACTIVO');
    if (params.Nombre_Equipo) sheet.getRange(i + 1, hdrs.indexOf('Nombre_Equipo') + 1).setValue(params.Nombre_Equipo);
    if (params.App)           sheet.getRange(i + 1, hdrs.indexOf('App') + 1).setValue(params.App);

    var nombreFinal = params.Nombre_Equipo || data[i][hdrs.indexOf('Nombre_Equipo')] || '';
    var appFinal    = params.App || data[i][hdrs.indexOf('App')] || '';
    _notificarAprobacionDispositivo(params.ID_Dispositivo, appFinal, nombreFinal,
                                    (params.aprobadoPor || 'panel'), 'panel');
    return { ok: true };
  }
  return { ok: false, error: 'Dispositivo no encontrado' };
}

// ════════════════════════════════════════════════════════════════════════
// APROBAR DISPOSITIVO EN SITU — admin presente con clave 8 dígitos
//
// El admin escribe su clave de 8 dig (4 globales + 4 PIN personal) en el
// dispositivo nuevo y este queda activo al instante. No requiere ir al
// panel MOS a aprobar manualmente. Igual que el flujo de
// anulaciones/conversiones que ya usa verificarClaveAdmin.
//
// Params: { deviceId, nombreEquipo, app, userAgent, claveAdmin (8 dig) }
// Retorna: { ok, data: { aprobadoPor: 'admin:Juan Perez' } } o autorizado:false
// ════════════════════════════════════════════════════════════════════════
function aprobarDispositivoEnSitu(params) {
  if (!params.deviceId)     return { ok: false, error: 'Requiere deviceId' };
  if (!params.claveAdmin)   return { ok: false, error: 'Requiere claveAdmin' };

  // Validar la clave 8 dig — verificarClaveAdmin retorna ok:true incluso si
  // no autorizado (el flag está en data.autorizado). También deja auditoría.
  var auth = verificarClaveAdmin({
    clave:        params.claveAdmin,
    accion:       'APROBAR_DISPOSITIVO',
    refDocumento: params.deviceId,
    appOrigen:    params.app || '',
    dispositivo:  params.nombreEquipo || params.userAgent || '',
    detalle:      'Aprobación in-situ desde el dispositivo nuevo'
  });
  if (!auth.ok) return auth;
  if (!auth.data || !auth.data.autorizado) {
    return { ok: true, data: { autorizado: false, error: auth.data?.error || 'Clave incorrecta' } };
  }

  // ── REGLA: activar MOS en un dispositivo nuevo SOLO puede hacerlo MASTER ──
  // Los admins comunes no pueden propagar MOS a equipos arbitrarios. Esto
  // limita el acceso a la app de administración a quien explícitamente
  // designe el master. WH y ME no tienen esta restricción.
  var appTarget = String(params.app || '').trim().toUpperCase();
  var esAppMOS  = (appTarget === 'MOS' || appTarget === 'PROYECTOMOS');
  var rolAprob  = String(auth.data.rol || '').toUpperCase();
  if (esAppMOS && rolAprob !== 'MASTER') {
    return {
      ok: true,
      data: {
        autorizado: false,
        error: 'Solo el MASTER puede activar la app MOS en un nuevo dispositivo. Pídelo al master.'
      }
    };
  }

  _garantizarColumnasDispositivos();
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iEst  = hdrs.indexOf('Estado');
  var iNom  = hdrs.indexOf('Nombre_Equipo');
  var iApp  = hdrs.indexOf('App');
  var iUC   = hdrs.indexOf('Ultima_Conexion');

  // Buscar si ya existe (puede estar como PENDIENTE de un solicitarAcceso previo)
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iId]) === String(params.deviceId)) {
      sheet.getRange(i + 1, iEst + 1).setValue('ACTIVO');
      if (params.nombreEquipo && iNom >= 0) sheet.getRange(i + 1, iNom + 1).setValue(params.nombreEquipo);
      if (params.app && iApp >= 0)          sheet.getRange(i + 1, iApp + 1).setValue(params.app);
      if (iUC >= 0) sheet.getRange(i + 1, iUC + 1).setValue(
        Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'")
      );
      _notificarAprobacionDispositivo(params.deviceId, params.app, params.nombreEquipo || data[i][iNom],
                                      auth.data.validadoPor, 'reactivado');
      return { ok: true, data: { autorizado: true, aprobadoPor: auth.data.validadoPor, accion: 'reactivado' } };
    }
  }

  // No existe: crearlo ya como ACTIVO directamente
  var fila = new Array(hdrs.length).fill('');
  if (iId  >= 0) fila[iId]  = String(params.deviceId);
  if (iEst >= 0) fila[iEst] = 'ACTIVO';
  if (iNom >= 0) fila[iNom] = String(params.nombreEquipo || params.userAgent || 'Sin nombre');
  if (iApp >= 0) fila[iApp] = String(params.app || '');
  if (iUC  >= 0) fila[iUC]  = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
  sheet.appendRow(fila);

  _notificarAprobacionDispositivo(params.deviceId, params.app,
                                  params.nombreEquipo || params.userAgent,
                                  auth.data.validadoPor, 'creado');
  return { ok: true, data: { autorizado: true, aprobadoPor: auth.data.validadoPor, accion: 'creado' } };
}

// Rechazar / bloquear dispositivo pendiente o activo
function rechazarDispositivoPendiente(params) {
  _garantizarColumnasDispositivos();
  if (!params.ID_Dispositivo) return { ok: false, error: 'Requiere ID_Dispositivo' };
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) !== String(params.ID_Dispositivo)) continue;
    sheet.getRange(i + 1, hdrs.indexOf('Estado') + 1).setValue('INACTIVO');
    return { ok: true };
  }
  return { ok: false, error: 'Dispositivo no encontrado' };
}

// Notifica a master+admin que un vendedor/operador inició sesión en ME o WH.
// Llamado desde ME al completar configuración inicial (nombre + estación) y
// también desde WH al login. Idempotente: si el mismo nombre ya tiene sesión
// activa ese día (Ultima_Sesion + Ultima_Conexion en DISPOSITIVOS hoy y <30 min),
// NO envía push (evita spam por reloads).
function notificarInicioSesionVendedor(params) {
  var nombre = String(params.nombre || '').trim();
  var appOrigen = String(params.appOrigen || 'mosExpress');
  var deviceId = String(params.deviceId || '').trim();
  if (!nombre) return { ok: false, error: 'Requiere nombre' };

  // ── Gancho: verificación de impresoras por evento de presencia ──
  // Alguien (cajero, vendedor u operador WH) está iniciando sesión →
  // verificamos el estado de todas las impresoras. Anti-spam interno
  // evita repetir la misma caída. Tolerante a errores.
  try {
    if (typeof _verificarImpresorasYAlertar === 'function') {
      _verificarImpresorasYAlertar('login:' + appOrigen);
    }
  } catch(eImp) { Logger.log('Verificación impresoras (login): ' + eImp.message); }

  // Si ME indica que es cajero Y va a abrir caja de inmediato → no dispar
  // la push aquí, deja que la push de apertura de caja la cubra (evita doble).
  // Si esCajero=false (vendedor puro sin caja), siempre disparamos.
  var esCajero = params.esCajero === true || String(params.esCajero) === 'true';
  if (esCajero) {
    return { ok: true, data: { sinPush: true, motivo: 'cajero (cubierto por apertura caja)', nombre: nombre } };
  }

  // Anti-spam: solo notificar si esta sesión es nueva (no había heartbeat reciente)
  try {
    var sheetD = getSheet('DISPOSITIVOS');
    var dataD = sheetD.getDataRange().getValues();
    var hdrsD = dataD[0];
    var iSesD = hdrsD.indexOf('Ultima_Sesion');
    var iUcD  = hdrsD.indexOf('Ultima_Conexion');
    var ahora = new Date().getTime();
    var nLow = nombre.toLowerCase();
    for (var rd = 1; rd < dataD.length; rd++) {
      var sesion = String(dataD[rd][iSesD] || '').toLowerCase();
      if (sesion !== nLow) continue;
      var uc = dataD[rd][iUcD];
      var ts = uc instanceof Date ? uc.getTime() : (uc ? new Date(uc).getTime() : 0);
      if (!ts) continue;
      if (ahora - ts < 30 * 60 * 1000) {
        return { ok: true, data: { yaEstabaActivo: true, sinPush: true } };
      }
    }
  } catch(e) {}

  // Push diferenciado: vendedor (ME), operador (WH)
  var esWH = appOrigen.toLowerCase().indexOf('warehouse') >= 0;
  var appLbl = esWH ? 'warehouseMos' : 'MosExpress';
  var icono  = esWH ? '🏭' : '🛍';   // 🛍 para vendedor (sin caja), distinto del 🛒 cajero
  var verbo  = esWH ? 'ingresó al almacén' : 'inició sesión como vendedor';
  try {
    if (typeof _enviarPushTodos === 'function') {
      _enviarPushTodos(
        icono + ' ' + nombre + ' ' + verbo,
        appLbl + (params.estacion ? ' · ' + params.estacion : '') + (params.zona ? ' · ' + params.zona : ''),
        { soloRolesAdmin: true, excluirUsuario: nombre, idNotif: 'MOS_LOGIN_VENDEDOR' }
      );
    }
  } catch(eP) { Logger.log('Push inicio sesión fallo: ' + eP.message); }

  return { ok: true, data: { notificado: true, nombre: nombre, icono: icono, verbo: verbo } };
}

// Limpia los rows PENDIENTE_APROBACION huérfanos creados por browsers MOS antes
// de que registrarSesionDispositivo dejara de auto-crearlos. Útil para purga
// puntual del spam acumulado.
function limpiarPendientesMOS() {
  _garantizarColumnasDispositivos();
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iEst  = hdrs.indexOf('Estado');
  var iApp  = hdrs.indexOf('App');
  var borradas = 0;
  // Iterar de atrás hacia adelante para no perder índices al borrar
  for (var i = data.length - 1; i >= 1; i--) {
    var est = String(data[i][iEst] || '').toUpperCase();
    var app = String(data[i][iApp] || '').toUpperCase();
    if (est === 'PENDIENTE_APROBACION' && (app === 'MOS' || app === '')) {
      sheet.deleteRow(i + 1);
      borradas++;
    }
  }
  return { ok: true, data: { borradas: borradas } };
}

// Vincula un browser (mos_deviceId UUID) a un row existente en DISPOSITIVOS.
// Reemplaza el ID_Dispositivo del row con el UUID del browser, así futuros
// heartbeats actualizan ese row específico. Si había un row PENDIENTE con el
// browserDeviceId, lo elimina (para no duplicar).
function vincularBrowserDispositivo(params) {
  _garantizarColumnasDispositivos();
  var idTarget = String(params.idDispositivoTarget || '').trim();
  var browserId = String(params.browserDeviceId || '').trim();
  if (!idTarget || !browserId) return { ok: false, error: 'Requiere idDispositivoTarget y browserDeviceId' };

  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId = hdrs.indexOf('ID_Dispositivo');

  var targetRow = -1;
  var pendienteRow = -1;
  for (var i = 1; i < data.length; i++) {
    var rowId = String(data[i][iId] || '');
    if (rowId === idTarget) targetRow = i + 1;
    if (rowId === browserId) pendienteRow = i + 1;
  }
  if (targetRow === -1) return { ok: false, error: 'Dispositivo target no encontrado' };

  // Reemplazar el ID del target con el browserId
  sheet.getRange(targetRow, iId + 1).setValue(browserId);

  // Borrar el row "huérfano" del browser (si MOS lo había creado como PENDIENTE_APROBACION)
  if (pendienteRow > 0 && pendienteRow !== targetRow) {
    sheet.deleteRow(pendienteRow);
  }
  return { ok: true, data: { vinculado: true, targetRow: targetRow, deviceId: browserId } };
}
