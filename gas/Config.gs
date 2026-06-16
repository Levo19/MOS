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
                        'Forzar_Logout', 'Logout_Auto_Ts',
                        // [v2.43.69] Forzar re-registro del FCM token. Admin lo
                        // setea desde la card del dispositivo cuando ve que el
                        // device no tiene token registrado en PUSH_TOKENS. La PWA
                        // lo lee en consultarEstadoDispositivo y dispara
                        // _pushInit forzado + limpia el flag.
                        'Forzar_Push',
                        // [v2.43.167] Forzar re-verificación inmediata del dispositivo.
                        // Master lo setea cuando revoca acceso de UN device específico
                        // sin esperar al cron diario. La PWA lo lee en heartbeat 1h,
                        // invalida cache local y re-verifica con backend. Si el
                        // dispositivo está INACTIVO/SUSPENDIDO, queda bloqueado en el
                        // acto. Cierra ventana de 24h de exposición post-revocación.
                        'Forzar_ReVerify',
                        // [v2.43.167] Flag para deduplicar alertas SEGURIDAD_ALERTAS
                        // del cron 2-7d. Cuando el cron crea una alerta para un
                        // dispositivo inactivo, marca este flag con ISO timestamp.
                        // Si el cron corre de nuevo al día siguiente y sigue inactivo,
                        // NO crea otra alerta (la PENDIENTE sigue ahí).
                        // Cuando el dispositivo se reconecta, este flag se limpia.
                        'Inactivo_Alerta_Ts',
                        // [v2.43.172 R6] Timestamp cuando el cron auto-cancelo una
                        // solicitud PENDIENTE_APROBACION por >20h sin aprobar.
                        // Si esta presente, el row queda con Estado=CANCELADO_AUTO.
                        // Al volver el operador, registrarSesionDispositivo lo
                        // reutiliza pasando a PENDIENTE_APROBACION nueva (limpia el flag).
                        'Cancelado_Auto_Ts'];

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

function _garantizarColumnasDispositivos(_lockHeld) {
  // [v2.43.136 FIX] Lock opt-in para evitar race entre callers concurrentes
  var _lock = null;
  if (!_lockHeld) {
    _lock = LockService.getScriptLock();
    try { _lock.waitLock(15000); } catch(e) { /* continúa sin lock; mejor algo que nada */ }
  }
  try {
    var sheet = getSheet('DISPOSITIVOS');
    var data = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues();
    var hdrs = (data[0] || []).map(function(h) { return String(h).trim(); });
    var faltan = _DISP_COLS_EXTRA.filter(function(c) { return hdrs.indexOf(c) === -1; });
    if (faltan.length > 0) {
      var startCol = sheet.getLastColumn() + 1;
      sheet.getRange(1, startCol, 1, faltan.length).setValues([faltan]);
      sheet.getRange(1, startCol, 1, faltan.length)
           .setFontWeight('bold').setBackground('#1f2937').setFontColor('#fff');
      SpreadsheetApp.flush();
    }
    return sheet;
  } finally {
    if (_lock) { try { _lock.releaseLock(); } catch(_){} }
  }
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

// [v2.43.167] Helpers compartidos para DeviceAuth
// Property que se bumpea para forzar re-verificación global de TODOS los devices.
// Cuando server cambia este número, los clientes detectan que su cache local
// tiene una versión menor → invalidan cache y re-verifican.
function _getDeviceVerifyVersion() {
  var v = parseInt(PropertiesService.getScriptProperties().getProperty('DEVICE_VERIFY_VERSION') || '1', 10);
  return isNaN(v) ? 1 : v;
}
// Fecha "hoy" en TZ Lima en formato YYYY-MM-DD. El cliente la compara con su
// `lastVerifyDate` para validar "cache válido este mismo día". Defensa contra
// manipulación del reloj del cliente — el cliente NO confía en su propio reloj
// para decidir el día, usa siempre el del server.
function _fechaHoyLima() {
  return Utilities.formatDate(new Date(), 'America/Lima', 'yyyy-MM-dd');
}
// Construir el payload "extra" que se anexa a TODAS las respuestas de
// registrarSesionDispositivo. Mantiene formato consistente cross-app.
function _payloadDeviceAuthExtras(rowData, hdrs) {
  var extras = {
    verifyVersion: _getDeviceVerifyVersion(),
    fechaHoyLima:  _fechaHoyLima()
  };
  if (rowData && hdrs) {
    var iFL  = hdrs.indexOf('Forzar_Logout');
    var iFLts= hdrs.indexOf('Logout_Auto_Ts');
    var iFRV = hdrs.indexOf('Forzar_ReVerify');
    var iFPu = hdrs.indexOf('Forzar_Push');
    var iFWiz= hdrs.indexOf('Forzar_Wizard');
    var iDTH = hdrs.indexOf('Desbloqueo_Temporal_Hasta');
    var fl  = iFL  >= 0 ? String(rowData[iFL]  || '') : '';
    var frv = iFRV >= 0 ? String(rowData[iFRV] || '') : '';
    var fpu = iFPu >= 0 ? String(rowData[iFPu] || '') : '';
    var fwz = iFWiz>= 0 ? String(rowData[iFWiz]|| '') : '';
    extras.forzar_logout   = fl  === '1' || fl.toLowerCase()  === 'true';
    extras.logout_auto_ts  = iFLts >= 0 ? String(rowData[iFLts] || '') : '';
    extras.forzar_reverify = frv === '1' || frv.toLowerCase() === 'true';
    extras.forzar_push     = fpu === '1' || fpu.toLowerCase() === 'true';
    extras.forzar_wizard   = fwz === '1' || fwz.toLowerCase() === 'true';
    // [v2.43.183] Extensión de horario por dispositivo — frontend respeta este TS.
    // Si <= ahora o vacío → no hay extensión vigente. Si > ahora → operador puede
    // seguir operando pasado el horario hasta ese TS exacto.
    if (iDTH >= 0) {
      var dthRaw = rowData[iDTH];
      var dthStr = '';
      if (dthRaw) {
        if (dthRaw instanceof Date && !isNaN(dthRaw.getTime())) {
          dthStr = dthRaw.toISOString();
        } else {
          dthStr = String(dthRaw);
          if (dthStr && !/[zZ]$/.test(dthStr) && !/[+-]\d{2}:?\d{2}$/.test(dthStr)) {
            var p = new Date(dthStr);
            if (!isNaN(p.getTime())) dthStr = p.toISOString();
          }
        }
      }
      extras.desbloqueo_temporal_hasta = dthStr;
    }
  }
  return extras;
}

// [v2.43.183] Extensión de horario in-situ por dispositivo (UUID).
// Admin/master ingresa clave 8 dig + escoge tiempo → se guarda en
// Desbloqueo_Temporal_Hasta del row del UUID. Frontend lo respeta.
// Auditoría automática vía verificarClaveAdmin (catálogo tier 2).
// [v2.43.185 senior fixes]:
//   - LockService previene race entre 2 admins simultáneos.
//   - Math.max preserva extensión vigente más alta (operador no pierde tiempo
//     si admin nuevo escoge menos minutos por error).
function extenderHorarioDispositivo(params) {
  if (!params.deviceId)   return { ok: false, error: 'Requiere deviceId' };
  if (!params.claveAdmin) return { ok: false, error: 'Requiere claveAdmin' };
  var minutos = parseInt(params.minutos) || 0;
  if (minutos <= 0 || minutos > 240) {
    return { ok: false, error: 'Minutos inválidos (1-240 max)' };
  }

  // [v2.43.185 FIX D] LockService — previene race entre 2 admins extendiendo
  // simultáneamente el mismo UUID (uno sobreescribiría al otro). 15s wait
  // alineado con otras funciones críticas de seguridad.
  var _lock = LockService.getScriptLock();
  try { _lock.waitLock(15000); } catch(eLock) {
    return { ok: false, error: 'Sistema ocupado, reintenta en unos segundos' };
  }
  try {
    // [Bug potencial #1 FIX] Validar device EXISTE antes de auditar clave.
    _garantizarColumnasDispositivos();
    var sheet = getSheet('DISPOSITIVOS');
    var data  = sheet.getDataRange().getValues();
    var hdrs  = data[0];
    var iId   = hdrs.indexOf('ID_Dispositivo');
    var iDTH  = hdrs.indexOf('Desbloqueo_Temporal_Hasta');
    if (iDTH < 0) {
      var col = hdrs.length + 1;
      sheet.getRange(1, col).setValue('Desbloqueo_Temporal_Hasta');
      iDTH = col - 1;
    }
    var rowFound = -1;
    for (var k = 1; k < data.length; k++) {
      if (String(data[k][iId]) === String(params.deviceId)) { rowFound = k; break; }
    }
    if (rowFound < 0) {
      return { ok: false, error: 'Dispositivo no encontrado — solicita primero alta del UUID' };
    }

    // Validar clave + audita
    var auth = verificarClaveAdmin({
      clave:        params.claveAdmin,
      accion:       'EXTENDER_HORARIO_DISPOSITIVO',
      refDocumento: params.deviceId,
      appOrigen:    params.app || '',
      detalle:      'Extensión in-situ de ' + minutos + ' min para el dispositivo',
      deviceId:     params.deviceId
    });
    if (!auth.ok) return auth;
    if (!auth.data || !auth.data.autorizado) {
      return { ok: true, data: { autorizado: false, error: (auth.data && auth.data.error) || 'Clave incorrecta' } };
    }

    // [v2.43.185 FIX B] Preservar extensión vigente más alta. Si admin escoge
    // 20 min cuando ya hay 50 min restantes, conservar los 50. Sino el operador
    // pierde tiempo por elección errónea del admin (UX bug + posible abuso).
    var nuevoMs = Date.now() + minutos * 60 * 1000;
    var actualRaw = data[rowFound][iDTH];
    var actualMs = 0;
    if (actualRaw) {
      var actualStr = (actualRaw instanceof Date) ? actualRaw.toISOString() : String(actualRaw);
      var parsed = Date.parse(actualStr);
      if (!isNaN(parsed)) actualMs = parsed;
    }
    var hastaMs = Math.max(nuevoMs, actualMs);
    var hastaIso = new Date(hastaMs).toISOString();
    var preservoExistente = (actualMs > nuevoMs);

    sheet.getRange(rowFound + 1, iDTH + 1).setValue(hastaIso);

    // Alerta para visibilidad en panel SEGURIDAD_ALERTAS
    try {
      if (typeof _crearAlertaSeg === 'function') {
        var nombreEq = data[rowFound][hdrs.indexOf('Nombre_Equipo')] || '';
        var appEq    = data[rowFound][hdrs.indexOf('App')] || '';
        _crearAlertaSeg('EXTENSION_HORARIO_DISPOSITIVO', {
          idDispositivo: params.deviceId,
          descripcion:   (appEq || '') + ' · ' + (nombreEq || 'Sin nombre') + ' · +' + minutos + ' min' + (preservoExistente ? ' (se mantuvo extensión mayor existente)' : ''),
          prioridad:     'MEDIA',
          datosExtra: {
            minutos: minutos,
            hastaTs: hastaIso,
            aprobadoPor: auth.data.validadoPor,
            preservoExistente: preservoExistente,
            app: appEq, nombre: nombreEq
          }
        });
      }
    } catch(_) {}

    return { ok: true, data: {
      autorizado: true,
      aprobadoPor: auth.data.validadoPor,
      hastaTs: hastaIso,
      minutos: minutos,
      preservoExistente: preservoExistente  // frontend puede mostrar mensaje
    }};
  } finally {
    try { _lock.releaseLock(); } catch(_){}
  }
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
        // [v2.43.167] Check Estado del row MOS — puede estar INACTIVO/SUSPENDIDO
        // aunque no se auto-cree pendiente. Master revocó MOS desde panel.
        var iEstM = hdrsMos.indexOf('Estado');
        var estadoM = iEstM >= 0 ? String(dataMos[rm][iEstM] || '').toUpperCase() : 'ACTIVO';
        if (estadoM === 'INACTIVO') {
          return { ok: true, data: Object.assign({
            autorizado: false, estado: 'INACTIVO',
            error: 'Acceso revocado por el master'
          }, _payloadDeviceAuthExtras(null, null)) };
        }
        if (estadoM === 'SUSPENDIDO') {
          return { ok: true, data: Object.assign({
            autorizado: false, estado: 'SUSPENDIDO',
            error: 'Acceso suspendido por inactividad. Pide reactivación al master.'
          }, _payloadDeviceAuthExtras(null, null)) };
        }
        // [v2.43.180 BUG CRÍTICO FIX R1] El path MOS NO chequeaba PENDIENTE_APROBACION
        // ni CANCELADO_AUTO antes de retornar ACTIVO. Si un operador limpiaba
        // localStorage y volvía a entrar antes de que el master aprobara el row
        // nuevo (que quedó en PENDIENTE_APROBACION en sheet), el backend retornaba
        // ACTIVO en el segundo boot porque solo chequeaba INACTIVO/SUSPENDIDO y caía
        // al return ACTIVO por fallthrough. Resultado: frontend creía autorizado y
        // dejaba entrar a la app aunque la fila siguiera PENDIENTE en sheet.
        // R1 violado de la peor forma — confirmado por reporte del usuario 2026-06-04.
        // Fix: replicar la misma lógica que el path no-MOS (líneas 943-951).
        if (estadoM === 'PENDIENTE_APROBACION') {
          // Ultima_Conexion ya fue actualizada en línea 795 (no duplicar setValue).
          // Extras genéricos (null,null) — consistente con path no-MOS (línea 946).
          // Los flags forzar_* del row solo aplican a ACTIVO; aquí no los enviamos.
          return { ok: true, data: Object.assign({
            autorizado: false, estado: 'PENDIENTE_APROBACION',
            error: 'Dispositivo MOS pendiente de aprobación del master'
          }, _payloadDeviceAuthExtras(null, null)) };
        }
        if (estadoM === 'CANCELADO_AUTO') {
          // [R6] El cron canceló esta solicitud por >20h. Reabrir como PENDIENTE
          // y notificar al master de nuevo (igual que path no-MOS líneas 897-929).
          // Ultima_Conexion ya actualizada en línea 795.
          sheetMos.getRange(rm + 1, iEstM + 1).setValue('PENDIENTE_APROBACION');
          var iCATMos = hdrsMos.indexOf('Cancelado_Auto_Ts');
          if (iCATMos >= 0) sheetMos.getRange(rm + 1, iCATMos + 1).setValue('');
          try {
            var nombreMosCA = dataMos[rm][hdrsMos.indexOf('Nombre_Equipo')] || '';
            _enviarPushTodos('🔒 MOS solicita acceso de nuevo (master)',
              'MOS · ' + (nombreMosCA || 'Sin nombre') + ' · re-solicitud tras auto-cancel',
              { soloRolesMaster: true, idNotif: 'MOS_DEVICE_RESOLICITUD_MOS' });
          } catch(eRMos){}
          try {
            if (typeof _crearAlertaSeg === 'function') {
              var nombreMosCA2 = dataMos[rm][hdrsMos.indexOf('Nombre_Equipo')] || '';
              _crearAlertaSeg('DISPOSITIVO_PENDIENTE_MOS', {
                idDispositivo: deviceId,
                descripcion:   'MOS · ' + (nombreMosCA2 || 'Sin nombre') + ' (re-solicitud)',
                prioridad:     'CRITICA',
                datosExtra:    { app: 'MOS', nombre: nombreMosCA2, reSolicitud: true, soloVisibleMaster: true }
              });
            }
          } catch(eAMos2){}
          return { ok: true, data: Object.assign({
            autorizado: false, estado: 'PENDIENTE_APROBACION',
            error: 'Re-solicitud MOS enviada — esperando aprobación del master'
          }, _payloadDeviceAuthExtras(null, null)) };
        }
        // [v2.43.181 DEFENSIVO] fail-CLOSED para estados desconocidos.
        // Si la sheet tiene un estado fuera del catálogo (ej. typo, valor manual
        // del admin, nuevo estado no manejado), NO autorizamos por defecto.
        // Antes: cualquier estado distinto de INACTIVO/SUSPENDIDO/PENDIENTE/CANCELADO
        // caía al return ACTIVO por fallthrough. Ahora exigimos 'ACTIVO' explícito.
        if (estadoM !== 'ACTIVO' && estadoM !== '') {
          return { ok: true, data: Object.assign({
            autorizado: false, estado: 'PENDIENTE_APROBACION',
            error: 'Estado de dispositivo desconocido: ' + estadoM + ' — re-solicita aprobación'
          }, _payloadDeviceAuthExtras(null, null)) };
        }
        // Solo ACTIVO (o vacío con default ACTIVO de línea 799) llega aquí
        var extMos = _payloadDeviceAuthExtras(dataMos[rm], hdrsMos);
        return { ok: true, data: Object.assign({
          autorizado: true, estado: 'ACTIVO', soloHeartbeat: true
        }, extMos) };
      }
    }
    // [v2.43.168] MOS dispositivo nuevo → ahora SÍ se crea PENDIENTE_APROBACION
    // (antes retornaba NO_REGISTRADO silencioso). El master ve la solicitud en
    // SEGURIDAD_ALERTAS y debe aprobar explícitamente.
    //
    // Push EXCLUSIVO al master (no al admin común). Razón: la app MOS solo la
    // puede activar el master en dispositivos nuevos (regla del usuario).
    var nombreNuevoMos = params.Nombre_Equipo;
    if (!nombreNuevoMos || nombreNuevoMos.indexOf('Nuevo dispositivo') === 0) {
      var labelUAMos = _parseUserAgent(params.userAgent || '');
      nombreNuevoMos = labelUAMos ? labelUAMos + ' (' + deviceId.substring(0, 6) + ')' : ('Nuevo MOS ' + deviceId.substring(0, 8));
    }
    var filaMos = new Array(hdrsMos.length).fill('');
    filaMos[iIdMos] = deviceId;
    var iNomMos = hdrsMos.indexOf('Nombre_Equipo');
    var iAppMos = hdrsMos.indexOf('App');
    var iEstMos = hdrsMos.indexOf('Estado');
    if (iNomMos >= 0) filaMos[iNomMos] = nombreNuevoMos;
    if (iAppMos >= 0) filaMos[iAppMos] = 'MOS';
    if (iEstMos >= 0) filaMos[iEstMos] = 'PENDIENTE_APROBACION';
    if (iUCMos >= 0)  filaMos[iUCMos]  = nowM;
    sheetMos.appendRow(filaMos);

    try {
      var detalleMos = (labelUAMos || 'MOS') + ' · UUID ' + deviceId.substring(0, 8) + '...';
      _enviarPushTodos('🔒 Nuevo MOS solicita acceso (master)', detalleMos, {
        soloRolesMaster: true,  // ← solo master, no admin
        idNotif: 'MOS_DEVICE_MOS_PENDIENTE'
      });
    } catch(ePuMos) { Logger.log('[MOS new] push master fallo: ' + ePuMos.message); }

    try {
      if (typeof _crearAlertaSeg === 'function') {
        _crearAlertaSeg('DISPOSITIVO_PENDIENTE_MOS', {
          idDispositivo: deviceId,
          descripcion:   'MOS · ' + (nombreNuevoMos || 'Sin nombre'),
          prioridad:     'CRITICA',  // ← más alta que admin común
          datosExtra:    {
            app: 'MOS', nombre: nombreNuevoMos,
            userAgent: params.userAgent || '',
            soloVisibleMaster: true  // ← flag para frontend: ocultar de admin común
          }
        });
      }
    } catch(eAMos) { Logger.log('[MOS new] crearAlerta fallo: ' + eAMos.message); }

    return { ok: true, data: Object.assign({
      autorizado: false, estado: 'PENDIENTE_APROBACION',
      error: 'Dispositivo MOS nuevo — esperando aprobación del master'
    }, _payloadDeviceAuthExtras(null, null)) };
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
      // [v2.43.167] Incluir extras (verifyVersion, fechaHoyLima) en todos los responses
      var extInact = _payloadDeviceAuthExtras(null, null);
      return { ok: true, data: Object.assign({
        autorizado: false, estado: 'INACTIVO',
        error: 'Dispositivo bloqueado por el admin'
      }, extInact) };
    }
    // [v2.43.172 R6] CANCELADO_AUTO = el cron auto-canceló esta solicitud por >20h.
    // El operador vuelve a abrir la app → reutilizar row como NUEVA PENDIENTE.
    // No bloquear, no tratar como INACTIVO (que es revocación legítima).
    if (estado === 'CANCELADO_AUTO') {
      sheet.getRange(i + 1, iEst + 1).setValue('PENDIENTE_APROBACION');
      var iCAT2 = hdrs.indexOf('Cancelado_Auto_Ts');
      if (iCAT2 >= 0) sheet.getRange(i + 1, iCAT2 + 1).setValue('');
      if (iUC >= 0) sheet.getRange(i + 1, iUC + 1).setValue(nowStr);
      // Push fresh al admin/master + alerta SEGURIDAD_ALERTAS nueva
      try {
        var nombreRow = data[i][hdrs.indexOf('Nombre_Equipo')] || '';
        var appRow    = data[i][hdrs.indexOf('App')] || '';
        var appUpper  = String(appRow || '').toUpperCase();
        var esMosRow  = appUpper === 'MOS' || appUpper === 'PROYECTOMOS';
        var detRow    = (appUpper || '') + ' · ' + (nombreRow || 'Sin nombre') + ' · re-solicitud tras auto-cancel';
        _enviarPushTodos(
          esMosRow ? '🔒 MOS solicita acceso de nuevo (master)' : '🔔 Re-solicitud de acceso',
          detRow,
          esMosRow ? { soloRolesMaster: true, idNotif: 'MOS_DEVICE_RESOLICITUD_MOS' }
                   : { soloRolesAdmin: true, idNotif: 'MOS_DEVICE_RESOLICITUD' }
        );
      } catch(eR){}
      try {
        if (typeof _crearAlertaSeg === 'function') {
          _crearAlertaSeg(esMosRow ? 'DISPOSITIVO_PENDIENTE_MOS' : 'DISPOSITIVO_PENDIENTE', {
            idDispositivo: deviceId,
            descripcion:   (appUpper || '') + ' · ' + (nombreRow || 'Sin nombre') + ' (re-solicitud)',
            prioridad:     esMosRow ? 'CRITICA' : 'MEDIA',
            datosExtra:    { app: appRow, nombre: nombreRow, reSolicitud: true }
          });
        }
      } catch(eA){}
      return { ok: true, data: Object.assign({
        autorizado: false, estado: 'PENDIENTE_APROBACION',
        error: 'Re-solicitud enviada — esperando aprobación'
      }, _payloadDeviceAuthExtras(null, null)) };
    }
    // [v2.43.167] SUSPENDIDO = auto-suspendido por cron 7d. El operador puede
    // pedir reactivación in-situ (admin/master con clave) o desde panel admin.
    if (estado === 'SUSPENDIDO') {
      // Refrescar Ultima_Conexion — el operador SÍ está intentando reconectarse,
      // útil para que admin vea actividad y considere reactivar.
      if (iUC >= 0) sheet.getRange(i + 1, iUC + 1).setValue(nowStr);
      var extSusp = _payloadDeviceAuthExtras(null, null);
      return { ok: true, data: Object.assign({
        autorizado: false, estado: 'SUSPENDIDO',
        error: 'Dispositivo suspendido por inactividad. Solicita reactivación al admin.'
      }, extSusp) };
    }
    if (estado === 'PENDIENTE_APROBACION') {
      // Solo refrescar Ultima_Conexion para que el admin sepa que sigue intentando
      if (iUC >= 0) sheet.getRange(i + 1, iUC + 1).setValue(nowStr);
      var extPend = _payloadDeviceAuthExtras(null, null);
      return { ok: true, data: Object.assign({
        autorizado: false, estado: 'PENDIENTE_APROBACION',
        error: 'Esperando aprobación del administrador'
      }, extPend) };
    }
    // ACTIVO → actualizar contexto
    if (iUC >= 0)  sheet.getRange(i + 1, iUC + 1).setValue(nowStr);
    if (iUZ >= 0   && params.idZona      !== undefined) sheet.getRange(i + 1, iUZ + 1).setValue(params.idZona || '');
    if (iUEs >= 0  && params.idEstacion  !== undefined) sheet.getRange(i + 1, iUEs + 1).setValue(params.idEstacion || '');
    if (iUSe >= 0  && params.vendedor    !== undefined) sheet.getRange(i + 1, iUSe + 1).setValue(params.vendedor || '');
    // [v2.43.167] Limpiar Inactivo_Alerta_Ts si el device se reconectó
    // (porque ya está ACTIVO, el cron no debe alertar de nuevo).
    var iIAT = hdrs.indexOf('Inactivo_Alerta_Ts');
    if (iIAT >= 0 && data[i][iIAT]) {
      sheet.getRange(i + 1, iIAT + 1).setValue('');
    }
    // [v2.43.167] Response con extras consistentes (verifyVersion, fechaHoyLima,
    // forzar_logout, forzar_reverify, forzar_push, forzar_wizard).
    var dataActivo = {
      autorizado: true, estado: 'ACTIVO',
      nombre: data[i][hdrs.indexOf('Nombre_Equipo')]
    };
    var extras = _payloadDeviceAuthExtras(data[i], hdrs);
    Object.keys(extras).forEach(function(k) { dataActivo[k] = extras[k]; });
    return { ok: true, data: dataActivo };
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

  // [SF3] Crear alerta de seguridad para que aparezca en el badge admin
  try {
    if (typeof _crearAlertaSeg === 'function') {
      _crearAlertaSeg('DISPOSITIVO_PENDIENTE', {
        idDispositivo: deviceId,
        descripcion: appNueva.toUpperCase() + ' · ' + (nombreNuevo || 'Sin nombre'),
        prioridad: appNueva.toUpperCase() === 'MOS' ? 'ALTA' : 'MEDIA',
        datosExtra: {
          app: appNueva, nombre: nombreNuevo,
          userAgent: params.userAgent || '',
          idZona: params.idZona || '',
          idEstacion: params.idEstacion || ''
        }
      });
    }
  } catch(eA) { Logger.log('[SF3] crearAlerta fallo: ' + eA.message); }

  // [v2.43.167] Incluir extras al response del dispositivo recién creado
  var extNuevo = _payloadDeviceAuthExtras(null, null);
  return { ok: true, data: Object.assign({
    autorizado: false, estado: 'PENDIENTE_APROBACION',
    error: 'Dispositivo nuevo — esperando aprobación del administrador'
  }, extNuevo) };
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
  var iFP   = hdrs.indexOf('Forzar_Push'); // [v2.43.69]
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
    // [v2.43.60] FIX TIMEZONE: si Sheets auto-parseó el ISO al guardar
    // → getValues devuelve Date object → String(Date) da el toString humano
    // (ej "Fri May 30 2026 12:26:00 GMT-0500") que el frontend interpretaba mal.
    // Convertimos explícitamente a ISO UTC con Z final para garantizar
    // que el frontend reciba siempre el mismo formato.
    var flTsRaw = iFLts >= 0 ? data[i][iFLts] : '';
    var flTs = '';
    if (flTsRaw) {
      if (flTsRaw instanceof Date && !isNaN(flTsRaw.getTime())) {
        flTs = flTsRaw.toISOString();   // Date object → "2026-05-30T17:26:00.000Z"
      } else {
        flTs = String(flTsRaw);  // string ya en formato adecuado
        // Si no tiene Z ni offset, asumir UTC (lo que escribimos) y agregar Z
        if (flTs && !/[zZ]$/.test(flTs) && !/[+-]\d{2}:?\d{2}$/.test(flTs)) {
          // Intentar convertir si parece "Fri May 30 ..." humano
          var parsed = new Date(flTs);
          if (!isNaN(parsed.getTime())) flTs = parsed.toISOString();
        }
      }
    }
    var fp = iFP >= 0 ? String(data[i][iFP] || '') : '';
    // [v2.43.167] forzar_reverify para el heartbeat del DeviceAuth module.
    var iFRV = hdrs.indexOf('Forzar_ReVerify');
    var frv = iFRV >= 0 ? String(data[i][iFRV] || '') : '';
    // [v2.43.183] Sincronizar extensión de horario via heartbeat. Sin esto el
    // sync con ExtensorHorario solo funcionaba en boot (registrarSesionDispositivo),
    // no en los heartbeats de 10 min. Misma normalización de formato que logout_auto_ts.
    var iDTH = hdrs.indexOf('Desbloqueo_Temporal_Hasta');
    var dthRaw = iDTH >= 0 ? data[i][iDTH] : '';
    var dthStr = '';
    if (dthRaw) {
      if (dthRaw instanceof Date && !isNaN(dthRaw.getTime())) {
        dthStr = dthRaw.toISOString();
      } else {
        dthStr = String(dthRaw);
        if (dthStr && !/[zZ]$/.test(dthStr) && !/[+-]\d{2}:?\d{2}$/.test(dthStr)) {
          var p = new Date(dthStr);
          if (!isNaN(p.getTime())) dthStr = p.toISOString();
        }
      }
    }
    return { ok: true, data: {
      registrado:    true,
      estado:        String(data[i][iEst] || ''),
      nombre:        data[i][iNom] || '',
      app:           data[i][iApp] || '',
      forzar_wizard: fw === '1' || fw.toLowerCase() === 'true',
      forzar_logout:    fl === '1' || fl.toLowerCase() === 'true',
      logout_auto_ts:   flTs,
      forzar_push:   fp === '1' || fp.toLowerCase() === 'true', // [v2.43.69]
      // [v2.43.167] Master setea esto para forzar re-verificación inmediata
      forzar_reverify: frv === '1' || frv.toLowerCase() === 'true',
      desbloqueo_temporal_hasta: dthStr,  // [v2.43.183] sync con ExtensorHorario
      verifyVersion:   _getDeviceVerifyVersion(),
      fechaHoyLima:    _fechaHoyLima()
    }};
  }
  return { ok: true, data: {
    registrado: false, estado: 'NO_REGISTRADO',
    verifyVersion: _getDeviceVerifyVersion(),
    fechaHoyLima:  _fechaHoyLima()
  }};
}

// ════════════════════════════════════════════════════════════════════════
// [v2.43.69] FORZAR ACCIONES EN DISPOSITIVO REMOTO
// Mismo patrón que forzarWizardDispositivo: requiere claveAdmin para
// auditoría. La PWA cliente lee la flag en su próximo poll
// consultarEstadoDispositivo, ejecuta la acción y limpia el flag.
// ════════════════════════════════════════════════════════════════════════
function forzarPushDispositivo(params) {
  if (!params.deviceId)   return { ok: false, error: 'Requiere deviceId' };
  if (!params.claveAdmin) return { ok: false, error: 'Requiere claveAdmin' };
  var auth = verificarClaveAdmin({
    clave: params.claveAdmin, accion: 'FORZAR_PUSH',
    refDocumento: params.deviceId, appOrigen: params.app || '',
    detalle: 'Forzar re-registro del FCM token'
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
  var iFP   = hdrs.indexOf('Forzar_Push');
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iId]) !== params.deviceId) continue;
    if (iFP >= 0) sheet.getRange(i + 1, iFP + 1).setNumberFormat('@').setValue('1');
    try { SpreadsheetApp.flush(); } catch(_){}
    return { ok: true, data: { autorizado: true, forzadoPor: auth.data.validadoPor } };
  }
  return { ok: false, error: 'Dispositivo no encontrado' };
}

// [v2.43.69] Cliente limpia su propio flag después de ejecutar la acción.
// No requiere claveAdmin (es el propio dispositivo limpiando su tarea).
function limpiarFlagDevice(params) {
  var deviceId = String(params.deviceId || params.ID_Dispositivo || '').trim();
  var flag = String(params.flag || '').trim();
  if (!deviceId) return { ok: false, error: 'Requiere deviceId' };
  var permitidas = { 'Forzar_Push': 1, 'Forzar_Wizard': 1 };
  if (!permitidas[flag]) return { ok: false, error: 'Flag no permitida: ' + flag };
  _garantizarColumnasDispositivos();
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iCol  = hdrs.indexOf(flag);
  if (iCol < 0) return { ok: false, error: 'Columna no existe: ' + flag };
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iId]) !== deviceId) continue;
    sheet.getRange(i + 1, iCol + 1).setValue('');
    return { ok: true, data: { limpiado: flag } };
  }
  return { ok: false, error: 'Dispositivo no encontrado' };
}

// [v2.43.69] Endpoint para que el cliente verifique si su token está
// registrado activo en PUSH_TOKENS. Si false, debe re-ejecutar el registro.
function verificarMiTokenRegistrado(params) {
  var deviceId = String(params.deviceId || params.ID_Dispositivo || '').trim();
  if (!deviceId) return { ok: false, error: 'Requiere deviceId' };
  try {
    var sh = getSpreadsheet().getSheetByName('PUSH_TOKENS');
    if (!sh) return { ok: true, data: { registrado: false, motivo: 'hoja_no_existe' } };
    var data = sh.getDataRange().getValues();
    if (data.length < 2) return { ok: true, data: { registrado: false, motivo: 'hoja_vacia' } };
    var hdrs = data[0];
    var iTok = hdrs.indexOf('token');
    var iAct = hdrs.indexOf('activo');
    var iDev = hdrs.indexOf('deviceId');
    if (iDev < 0 || iTok < 0) return { ok: true, data: { registrado: false, motivo: 'sin_columna_deviceId' } };
    var encontrados = 0;
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][iDev] || '').trim() !== deviceId) continue;
      var act = data[i][iAct];
      if (act === false || String(act) === '0' || String(act).toLowerCase() === 'false') continue;
      if (String(data[i][iTok] || '').trim()) encontrados++;
    }
    return { ok: true, data: { registrado: encontrados > 0, tokens: encontrados } };
  } catch(e) { return { ok: false, error: e.message }; }
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
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iNom  = hdrs.indexOf('Nombre_Equipo');
  var iApp  = hdrs.indexOf('App');
  var nowMs = Date.now();
  var limMs = diasMax * 24 * 60 * 60 * 1000;
  var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
  var suspendidos = 0;
  var detallesSuspendidos = [];
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
      // [v2.43.167] Capturar detalles para crear alerta de seguridad y push
      var diasInactivo = Math.floor((nowMs - ucMs) / (24 * 60 * 60 * 1000));
      detallesSuspendidos.push({
        idDispositivo: String(data[i][iId] || ''),
        nombre:        String(data[i][iNom] || ''),
        app:           String(data[i][iApp] || ''),
        diasInactivo:  diasInactivo
      });
    }
  }
  // [v2.43.167] Crear alerta SEGURIDAD_ALERTAS + push master por cada suspendido.
  // Audit-trail: queda registro de QUÉ dispositivos suspendió el cron.
  detallesSuspendidos.forEach(function(d) {
    try {
      if (typeof _crearAlertaSeg === 'function') {
        _crearAlertaSeg('DISPOSITIVO_SUSPENDIDO_AUTO', {
          idDispositivo: d.idDispositivo,
          descripcion:   (d.app || '').toUpperCase() + ' · ' + (d.nombre || 'Sin nombre') + ' · ' + d.diasInactivo + 'd sin uso',
          prioridad:     'MEDIA',
          datosExtra:    d
        });
      }
    } catch(eA) { Logger.log('[purgar] crearAlerta fallo: ' + eA.message); }
  });
  if (detallesSuspendidos.length > 0) {
    try {
      var resumen = detallesSuspendidos.length + ' dispositivo(s) suspendido(s) por inactividad >' + diasMax + 'd';
      _enviarPushTodos('🚨 Auto-suspensión dispositivos', resumen, {
        soloRolesMaster: true, idNotif: 'MOS_DEVICE_SUSPENDIDO_AUTO'
      });
    } catch(ePu) { Logger.log('[purgar] push master fallo: ' + ePu.message); }
  }
  return { ok: true, data: {
    suspendidos: suspendidos, dias: diasMax,
    detalles: detallesSuspendidos
  }};
}

// Cron-friendly wrapper: instalable como trigger diario sin params.
function purgarDispositivosInactivos7d() {
  return purgarDispositivosInactivos({ dias: 7 });
}

function aprobarDispositivoPendiente(params) {
  // [v2.43.134 FIX] Lock + idempotencia: si ya está ACTIVO, no duplicar push/alerta
  var _lock = LockService.getScriptLock();
  try { _lock.waitLock(15000); } catch(e) { return { ok: false, error: 'Sistema ocupado' }; }
  try {
    _garantizarColumnasDispositivos(true);  // ya estamos dentro del lock
    if (!params.ID_Dispositivo) return { ok: false, error: 'Requiere ID_Dispositivo' };
    var sheet = getSheet('DISPOSITIVOS');
    var data  = sheet.getDataRange().getValues();
    var hdrs  = data[0];
    var iEst  = hdrs.indexOf('Estado');
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][0]) !== String(params.ID_Dispositivo)) continue;
      var estadoActual = String(data[i][iEst] || '').toUpperCase();
      if (estadoActual === 'ACTIVO') {
        // Idempotente: ya estaba aprobado por otro admin/tab; no duplicar push
        return { ok: true, skipped: true, motivo: 'ya_activo' };
      }
      sheet.getRange(i + 1, iEst + 1).setValue('ACTIVO');
      // [v2.43.167] Limpiar Forzar_ReVerify y Inactivo_Alerta_Ts al aprobar
      var iFRV = hdrs.indexOf('Forzar_ReVerify');
      if (iFRV >= 0) sheet.getRange(i + 1, iFRV + 1).setValue('');
      var iIAT = hdrs.indexOf('Inactivo_Alerta_Ts');
      if (iIAT >= 0) sheet.getRange(i + 1, iIAT + 1).setValue('');
      // [v2.43.167] Si venía SUSPENDIDO, limpiar Suspendido_Desde
      var iSus = hdrs.indexOf('Suspendido_Desde');
      if (iSus >= 0 && estadoActual === 'SUSPENDIDO') sheet.getRange(i + 1, iSus + 1).setValue('');
      if (params.Nombre_Equipo) sheet.getRange(i + 1, hdrs.indexOf('Nombre_Equipo') + 1).setValue(params.Nombre_Equipo);
      if (params.App)           sheet.getRange(i + 1, hdrs.indexOf('App') + 1).setValue(params.App);

      var nombreFinal = params.Nombre_Equipo || data[i][hdrs.indexOf('Nombre_Equipo')] || '';
      var appFinal    = params.App || data[i][hdrs.indexOf('App')] || '';
      _notificarAprobacionDispositivo(params.ID_Dispositivo, appFinal, nombreFinal,
                                      (params.aprobadoPor || 'panel'), 'panel');
      try { _marcarAlertaSegRevisadaPorDispositivo(params.ID_Dispositivo, params.aprobadoPor || 'panel'); } catch(_){}

      // [v2.43.167] AUDITORIA — registrar en AUDITORIA_ADMIN con tier 2.
      // El admin que aprueba ya pasó por verificarClaveAdmin en el panel front
      // antes de llamar este endpoint, así que aquí solo registramos el efecto.
      try {
        var accionAudit = (estadoActual === 'SUSPENDIDO') ? 'REACTIVAR_DISPOSITIVO_SUSPENDIDO' : 'APROBAR_DISPOSITIVO_REMOTO';
        _registrarAuditoriaSeg({
          accion:        accionAudit,
          refDocumento:  params.ID_Dispositivo,
          appOrigen:     'MOS',
          detalle:       (appFinal || '').toUpperCase() + ' · ' + (nombreFinal || 'Sin nombre') + ' · estado previo ' + estadoActual,
          idPersonal:    params.idPersonalAutoriza || '',
          nombreAutoriza:params.aprobadoPor || 'panel'
        });
      } catch(eAud) { Logger.log('[aprobarDispositivoPendiente] auditoria fallo: ' + eAud.message); }

      return { ok: true };
    }
    return { ok: false, error: 'Dispositivo no encontrado' };
  } finally { try { _lock.releaseLock(); } catch(_){} }
}

// [v2.43.167] Helper para registrar auditoria sin pasar por verificarClaveAdmin
// (cuando el admin ya autenticó previamente en el panel y solo necesitamos
// trazar el efecto de la acción).
function _registrarAuditoriaSeg(params) {
  try {
    _garantizarHojaAuditoria();
    var sheet = getSheet('AUDITORIA_ADMIN');
    var idAccion = _generateId('AUD');
    var accion = String(params.accion || '').toUpperCase();
    var tier = _inferirTierAccion(accion);
    sheet.appendRow([
      idAccion,
      new Date(),
      accion,
      String(params.refDocumento || ''),
      String(params.idPersonal || ''),
      String(params.nombreAutoriza || ''),
      String(params.appOrigen || 'MOS'),
      String(params.dispositivo || ''),
      String(params.detalle || ''),
      tier,
      params.cache_hit === true ? 1 : 0,
      parseInt(params.tiempo_verify_ms) || 0,
      String(params.deviceId || ''),
      JSON.stringify(params.cliente_meta || {})
    ]);
    return { ok: true, idAccion: idAccion };
  } catch(e) {
    Logger.log('[_registrarAuditoriaSeg] fallo: ' + e.message);
    return { ok: false, error: e.message };
  }
}

// [SF3] Helper para marcar alertas DISPOSITIVO_PENDIENTE como REVISADA
function _marcarAlertaSegRevisadaPorDispositivo(idDispositivo, revisadaPor) {
  try {
    if (typeof _getSheetSegAlertas !== 'function') return;
    var sheet = _getSheetSegAlertas();
    if (sheet.getLastRow() < 2) return;
    var data = sheet.getDataRange().getValues();
    var hdrs = data[0];
    var iId = hdrs.indexOf('idDispositivo');
    var iEst = hdrs.indexOf('estado');
    var iRev = hdrs.indexOf('revisada_por');
    var iRevTs = hdrs.indexOf('revisada_en');
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][iId]) !== String(idDispositivo)) continue;
      if (String(data[i][iEst]).toUpperCase() !== 'PENDIENTE') continue;
      sheet.getRange(i + 1, iEst + 1).setValue('REVISADA');
      if (iRev >= 0) sheet.getRange(i + 1, iRev + 1).setValue(String(revisadaPor || ''));
      if (iRevTs >= 0) sheet.getRange(i + 1, iRevTs + 1).setValue(new Date().toISOString());
    }
  } catch(e) { Logger.log('[_marcarAlertaSegRevisadaPorDispositivo] ' + e.message); }
}

// ════════════════════════════════════════════════════════════════════════
// [v2.43.223 FIX RAÍZ] Propagación INMEDIATA del dispositivo a la sombra
// `mos.dispositivos` (la tabla que lee la Edge `mint-mos` para emitir el JWT
// directo). SIN esto, la aprobación in-situ solo escribía la HOJA y la sombra
// recién se actualizaba en el próximo `syncCatalogoSupabase` (trigger horario
// que ADEMÁS puede morir en silencio) → el device quedaba aprobado en la hoja
// pero `mint-mos` seguía devolviendo 401 hasta 1h (o indefinido si el trigger
// murió). Esto cierra esa ventana: el upsert va al instante con la service-role
// key del backend (la misma que ya usa el sync). Idempotente (onConflict por
// id_dispositivo, merge). NO lanza: si Supabase no está configurado o falla, se
// loguea y se devuelve false — el sync horario sigue siendo la red de respaldo.
//
// Devuelve true si la sombra quedó ACTIVA (confirmado por read-back), false si no.
// ════════════════════════════════════════════════════════════════════════
function _propagarDispositivoSombra(deviceId, app, nombreEquipo, userAgent) {
  try {
    if (!deviceId) return false;
    // ¿Supabase configurado? Si no, salir limpio (entorno sin sombra).
    try { _sbCfg_(); } catch (eCfg) {
      Logger.log('[_propagarDispositivoSombra] Supabase no configurado, omito: ' + (eCfg && eCfg.message || eCfg));
      return false;
    }
    var row = {
      id_dispositivo:  String(deviceId),
      estado:          'ACTIVO',
      ultima_conexion: Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'")
    };
    if (app)          row.app           = String(app);
    if (nombreEquipo) row.nombre_equipo = String(nombreEquipo);
    if (userAgent)    row.user_agent    = String(userAgent).substring(0, 500);

    var up = _sbUpsert('mos.dispositivos', [row], 'id_dispositivo');
    if (!up.ok) {
      Logger.log('[_propagarDispositivoSombra] upsert falló HTTP ' + up.code + ' ' + (up.error || ''));
      return false;
    }
    // Read-back de confirmación: la fila debe quedar ACTIVA con app que mint-mos acepta.
    var rb = _sbSelect('mos.dispositivos', {
      select: 'id_dispositivo,estado,app',
      filters: { id_dispositivo: 'eq.' + String(deviceId) },
      limit: 1
    });
    if (rb.ok && Array.isArray(rb.data) && rb.data.length) {
      var r0 = rb.data[0];
      var estadoOk = String(r0.estado || '').toUpperCase() === 'ACTIVO';
      var appVal   = String(r0.app == null ? '' : r0.app);
      // mint-mos acepta app ∈ {null,'','MOS'}. Si la sombra quedó con otra app
      // (ej. 'mosExpress'), mint-mos para MOS NO la aceptaría → no es ACTIVA-para-MOS.
      var appOkMos = (appVal === '' || appVal === 'MOS');
      return estadoOk && appOkMos;
    }
    Logger.log('[_propagarDispositivoSombra] read-back sin fila para ' + deviceId);
    return false;
  } catch (e) {
    Logger.log('[_propagarDispositivoSombra] EXCEPCIÓN: ' + (e && e.message || e));
    return false;
  }
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
// Retorna: { ok, data: { aprobadoPor, deviceId, shadowOk } } o autorizado:false
//   - deviceId: el id EXACTO que quedó ACTIVO (eco para que el front confirme
//     que aprobó el mismo que usa para mint-mos — imposible desfase).
//   - shadowOk: true si la sombra `mos.dispositivos` quedó ACTIVA al instante
//     (mint-mos ya emitirá token). false → el front debe esperar/avisar.
// ════════════════════════════════════════════════════════════════════════
function aprobarDispositivoEnSitu(params) {
  if (!params.deviceId)     return { ok: false, error: 'Requiere deviceId' };
  if (!params.claveAdmin)   return { ok: false, error: 'Requiere claveAdmin' };

  // [v2.43.167] Accion del catalogo según app:
  //   - WH/ME: APROBAR_DISPOSITIVO_INSITU (tier 2, admin o master)
  //   - MOS:   APROBAR_DISPOSITIVO_INSITU_MOS (tier 3, master only)
  // verificarClaveAdmin audita auto en AUDITORIA_ADMIN con esos tipos.
  var appTargetLower = String(params.app || '').toLowerCase();
  var accionCatalogo = (appTargetLower === 'mos' || appTargetLower === 'proyectomos')
    ? 'APROBAR_DISPOSITIVO_INSITU_MOS'
    : 'APROBAR_DISPOSITIVO_INSITU';

  // Validar la clave 8 dig — verificarClaveAdmin retorna ok:true incluso si
  // no autorizado (el flag está en data.autorizado). También deja auditoría.
  var auth = verificarClaveAdmin({
    clave:        params.claveAdmin,
    accion:       accionCatalogo,
    refDocumento: params.deviceId,
    appOrigen:    params.app || '',
    dispositivo:  params.nombreEquipo || params.userAgent || '',
    detalle:      'Aprobación in-situ desde el dispositivo nuevo',
    deviceId:     params.deviceId
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
      // [v2.43.223 FIX RAÍZ] Propagar al instante a la sombra mos.dispositivos
      // (lo que lee mint-mos) — antes esto solo llegaba en el sync horario.
      var shadowOkExist = _propagarDispositivoSombra(
        params.deviceId, params.app, params.nombreEquipo || data[i][iNom], params.userAgent);
      // [v2.43.182 BUG E FIX] Retornar verifyVersion y fechaHoyLima para que el
      // frontend pueda cachear correctamente sin esperar al próximo boot
      // (que antes invalidaba+re-guardaba con un fetch extra).
      return { ok: true, data: Object.assign(
        { autorizado: true, aprobadoPor: auth.data.validadoPor, accion: 'reactivado',
          deviceId: String(params.deviceId), shadowOk: shadowOkExist },
        _payloadDeviceAuthExtras(data[i], hdrs)
      ) };
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
  // [v2.43.223 FIX RAÍZ] Propagar al instante a la sombra mos.dispositivos.
  var shadowOkNew = _propagarDispositivoSombra(
    params.deviceId, params.app, params.nombreEquipo || params.userAgent, params.userAgent);
  // [v2.43.182 BUG E FIX] Retornar verifyVersion para que frontend cachee correctamente.
  // Como acabamos de appendRow, no podemos pasar el row a _payloadDeviceAuthExtras
  // (sería extra fetch). Pasamos (null,null) → solo verifyVersion + fechaHoyLima genéricos.
  return { ok: true, data: Object.assign(
    { autorizado: true, aprobadoPor: auth.data.validadoPor, accion: 'creado',
      deviceId: String(params.deviceId), shadowOk: shadowOkNew },
    _payloadDeviceAuthExtras(null, null)
  ) };
}

// Rechazar / bloquear dispositivo pendiente o activo
function rechazarDispositivoPendiente(params) {
  // [v2.43.138 FIX] Lock + idempotencia: previene sobreescribir un ACTIVO
  // recién aprobado por otro admin en paralelo (race entre 2 admins).
  var _lock = LockService.getScriptLock();
  try { _lock.waitLock(15000); } catch(e) { return { ok: false, error: 'Sistema ocupado' }; }
  try {
    _garantizarColumnasDispositivos(true);
    if (!params.ID_Dispositivo) return { ok: false, error: 'Requiere ID_Dispositivo' };
    var sheet = getSheet('DISPOSITIVOS');
    if (!sheet) return { ok: false, error: 'Sheet DISPOSITIVOS no creada' };
    var data  = sheet.getDataRange().getValues();
    var hdrs  = data[0];
    var iEst  = hdrs.indexOf('Estado');
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][0]) !== String(params.ID_Dispositivo)) continue;
      var estadoActual = String(data[i][iEst] || '').toUpperCase();
      // No rechazar lo que otro admin ya aprobó como ACTIVO (race protection)
      if (estadoActual === 'ACTIVO') {
        return { ok: true, skipped: true, motivo: 'ya_activo_no_se_rechaza' };
      }
      sheet.getRange(i + 1, iEst + 1).setValue('INACTIVO');
      return { ok: true };
    }
    return { ok: false, error: 'Dispositivo no encontrado' };
  } finally { try { _lock.releaseLock(); } catch(_){} }
}

// ════════════════════════════════════════════════════════════════════════
// [FASE 0 v2.43.225] reactivarDispositivoSuspendido_LEGACY_NO_USAR ELIMINADA.
// Era una def duplicada/muerta de reactivarDispositivoSuspendido (la ACTIVA vive
// en SeguridadAlerts.gs:338, gana por orden alfabético de clasp). No tenía
// callers — verificado por grep. La propagación a sombra ya vive en la activa.
// ════════════════════════════════════════════════════════════════════════

// ════════════════════════════════════════════════════════════════════════
// [v2.43.167] forzarReVerifyDispositivo — master setea Forzar_ReVerify=1 en
// un device. La PWA del device lo detecta en heartbeat 1h, invalida cache
// local y re-verifica. Si master ya revocó (INACTIVO/SUSPENDIDO), queda
// bloqueada en el acto. Cierra ventana de exposición post-revocación.
//
// Requiere clave admin/master. Audita auto con FORZAR_REVERIFY_DISPOSITIVO.
// ════════════════════════════════════════════════════════════════════════
function forzarReVerifyDispositivo(params) {
  if (!params.deviceId)   return { ok: false, error: 'Requiere deviceId' };
  if (!params.claveAdmin) return { ok: false, error: 'Requiere claveAdmin' };
  var auth = verificarClaveAdmin({
    clave:        params.claveAdmin,
    accion:       'FORZAR_REVERIFY_DISPOSITIVO',
    refDocumento: params.deviceId,
    appOrigen:    'MOS',
    detalle:      'Forzar re-verificación inmediata sin esperar cron diario',
    deviceId:     params.deviceId
  });
  if (!auth.ok) return auth;
  if (!auth.data || !auth.data.autorizado) {
    return { ok: true, data: { autorizado: false, error: auth.data && auth.data.error || 'Clave incorrecta' } };
  }
  _garantizarColumnasDispositivos();
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iFRV  = hdrs.indexOf('Forzar_ReVerify');
  if (iFRV < 0) return { ok: false, error: 'Columna Forzar_ReVerify no existe (corre _garantizarColumnasDispositivos)' };
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iId]) !== String(params.deviceId)) continue;
    sheet.getRange(i + 1, iFRV + 1).setValue('1');
    return { ok: true, data: { autorizado: true, deviceId: params.deviceId } };
  }
  return { ok: false, error: 'Dispositivo no encontrado' };
}

// ════════════════════════════════════════════════════════════════════════
// [v2.43.167] alertarDispositivosInactivos2a7d — cron diario 02:30 que
// crea alertas SEGURIDAD_ALERTAS + push master para dispositivos ACTIVOS
// con Ultima_Conexion entre 2 y 7 días atrás. Dedupe vía Inactivo_Alerta_Ts.
//
// Después de los 7 días el otro cron (purgarDispositivosInactivos7d) los
// marca SUSPENDIDO. Este avisa antes de la suspensión.
// ════════════════════════════════════════════════════════════════════════
function alertarDispositivosInactivos2a7d() {
  _garantizarColumnasDispositivos();
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iNom  = hdrs.indexOf('Nombre_Equipo');
  var iApp  = hdrs.indexOf('App');
  var iEst  = hdrs.indexOf('Estado');
  var iUC   = hdrs.indexOf('Ultima_Conexion');
  var iIAT  = hdrs.indexOf('Inactivo_Alerta_Ts');
  var nowMs = Date.now();
  var DOS_DIAS_MS = 2 * 24 * 60 * 60 * 1000;
  var SIETE_DIAS_MS = 7 * 24 * 60 * 60 * 1000;
  var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
  var alertados = 0;
  var detalles = [];
  for (var i = 1; i < data.length; i++) {
    var est = String(data[i][iEst] || '').toUpperCase();
    if (est !== 'ACTIVO') continue;
    // Dedupe: si ya hay alerta abierta (Ts presente), saltar
    if (iIAT >= 0 && data[i][iIAT]) continue;
    var uc = data[i][iUC];
    var ucMs = 0;
    if (uc instanceof Date) ucMs = uc.getTime();
    else if (typeof uc === 'string' && uc.trim()) {
      var d = new Date(uc);
      if (!isNaN(d.getTime())) ucMs = d.getTime();
    }
    if (!ucMs) continue;
    var lapse = nowMs - ucMs;
    if (lapse < DOS_DIAS_MS || lapse > SIETE_DIAS_MS) continue;
    var diasInactivo = Math.floor(lapse / (24 * 60 * 60 * 1000));
    var idDisp = String(data[i][iId] || '');
    var nombre = String(data[i][iNom] || '');
    var appEq  = String(data[i][iApp] || '');
    try {
      if (typeof _crearAlertaSeg === 'function') {
        _crearAlertaSeg('DISPOSITIVO_INACTIVO_AVISO', {
          idDispositivo: idDisp,
          descripcion:   (appEq || '').toUpperCase() + ' · ' + (nombre || 'Sin nombre') + ' · ' + diasInactivo + 'd sin uso',
          prioridad:     'BAJA',
          datosExtra:    { diasInactivo: diasInactivo, ultimaConexion: String(uc || '') }
        });
      }
    } catch(eA) { Logger.log('[alertarInactivos] crearAlerta fallo: ' + eA.message); }
    if (iIAT >= 0) sheet.getRange(i + 1, iIAT + 1).setValue(nowStr);
    alertados++;
    detalles.push({ idDispositivo: idDisp, nombre: nombre, app: appEq, diasInactivo: diasInactivo });
  }
  // Push master consolidado
  if (alertados > 0) {
    try {
      _enviarPushTodos('⚠ Dispositivos sin uso 2-7d', alertados + ' dispositivo(s) sin conectarse · revisar', {
        soloRolesMaster: true, idNotif: 'MOS_DEVICE_INACTIVO_AVISO'
      });
    } catch(ePu) { Logger.log('[alertarInactivos] push fallo: ' + ePu.message); }
  }
  return { ok: true, data: { alertados: alertados, detalles: detalles } };
}

// [v2.43.173] Setup-only: instala el trigger del cron 23:30. Llamar 1 vez
// desde el editor GAS o desde setupTodoSeguridad. Idempotente.
// Cambio v2.43.173: movido de 02:30 → 23:30. Razón: durante 23-24h es la
// ventana de mantenimiento (cron forzar_logout cierra sesiones, nadie usa
// las apps). Operaciones de seguridad concentradas en esa franja.
function instalarTriggerAlertaInactivos2a7d() {
  var TRG = 'alertarDispositivosInactivos2a7d';
  var existing = ScriptApp.getProjectTriggers().filter(function(t) {
    return t.getHandlerFunction() === TRG;
  });
  if (existing.length > 0) return { ok: true, ya: true, count: existing.length };
  ScriptApp.newTrigger(TRG).timeBased().atHour(23).nearMinute(30).everyDays(1).create();
  return { ok: true, instalado: true };
}

// ════════════════════════════════════════════════════════════════════════
// [v2.43.172 R6] cancelarPendientesAntiguos — auto-cancela solicitudes
// PENDIENTE_APROBACION viejas para evitar spam de alertas al admin.
//
// Lógica: dispositivo PENDIENTE >20h sin aprobar = el admin claramente lo
// está ignorando o no le interesa. Marca como CANCELADO_AUTO. Al volver el
// operador (próximo día), registrarSesionDispositivo lo reutiliza pasando
// a PENDIENTE_APROBACION nueva (con nueva fecha y push fresh).
//
// Límite configurable vía Property PENDIENTE_AUTO_CANCEL_HORAS (default 20).
// Trigger sugerido: cada 1h.
// ════════════════════════════════════════════════════════════════════════
function cancelarPendientesAntiguos() {
  _garantizarColumnasDispositivos();
  var horasMax = parseInt(PropertiesService.getScriptProperties().getProperty('PENDIENTE_AUTO_CANCEL_HORAS') || '20', 10);
  if (isNaN(horasMax) || horasMax < 1) horasMax = 20;
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iNom  = hdrs.indexOf('Nombre_Equipo');
  var iApp  = hdrs.indexOf('App');
  var iEst  = hdrs.indexOf('Estado');
  var iUC   = hdrs.indexOf('Ultima_Conexion');
  var iCAT  = hdrs.indexOf('Cancelado_Auto_Ts');
  var nowMs = Date.now();
  var limMs = horasMax * 60 * 60 * 1000;
  var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
  var canceladas = 0;
  var detalles = [];
  for (var i = 1; i < data.length; i++) {
    var est = String(data[i][iEst] || '').toUpperCase();
    if (est !== 'PENDIENTE_APROBACION') continue;
    var uc = data[i][iUC];
    var ucMs = 0;
    if (uc instanceof Date) ucMs = uc.getTime();
    else if (typeof uc === 'string' && uc.trim()) {
      var d = new Date(uc);
      if (!isNaN(d.getTime())) ucMs = d.getTime();
    }
    if (!ucMs) continue;
    if ((nowMs - ucMs) > limMs) {
      sheet.getRange(i + 1, iEst + 1).setValue('CANCELADO_AUTO');
      if (iCAT >= 0) sheet.getRange(i + 1, iCAT + 1).setValue(nowStr);
      canceladas++;
      var idDisp = String(data[i][iId] || '');
      detalles.push({
        idDispositivo: idDisp,
        nombre:        String(data[i][iNom] || ''),
        app:           String(data[i][iApp] || ''),
        horasInactivo: Math.floor((nowMs - ucMs) / (60 * 60 * 1000))
      });
      // Marcar alerta SEGURIDAD_ALERTAS asociada como REVISADA con motivo
      try {
        _marcarAlertaSegRevisadaPorDispositivo(idDisp, 'AUTO_CANCEL_20H');
      } catch(_){}
    }
  }
  return { ok: true, data: { canceladas: canceladas, horas: horasMax, detalles: detalles } };
}

// Wrapper para trigger horario (sin params)
function cancelarPendientesAntiguos20h() {
  return cancelarPendientesAntiguos();
}

// [v2.43.173] Setup-only: instala trigger 23:45. Idempotente.
// Cambio v2.43.173: antes corría cada 1h. Ahora 1 vez al día a las 23:45
// (ventana de mantenimiento). Razón: los admins tienen toda la jornada para
// aprobar; si pasan 20h sin acción, esa noche se limpian de una vez.
function instalarTriggerCancelarPendientes() {
  var TRG = 'cancelarPendientesAntiguos20h';
  var existing = ScriptApp.getProjectTriggers().filter(function(t) {
    return t.getHandlerFunction() === TRG;
  });
  if (existing.length > 0) return { ok: true, ya: true, count: existing.length };
  ScriptApp.newTrigger(TRG).timeBased().atHour(23).nearMinute(45).everyDays(1).create();
  return { ok: true, instalado: true };
}

// [v2.43.173] Función ÚNICA que limpia los triggers de seguridad antiguos
// (que pueden tener horarios viejos) y los reinstala con horario nocturno
// 23:15 / 23:30 / 23:45. Idempotente — se puede ejecutar varias veces.
//
// Ejecutar desde el editor GAS cuando se quiera refrescar la configuración
// de triggers. Útil tras cambios de horario como v2.43.173.
function reinstalarTriggersSeguridadNocturno() {
  var TRGS_SEG = {
    'purgarDispositivosInactivos7d':    { hora: 23, min: 15 },  // antes 02:00
    'alertarDispositivosInactivos2a7d': { hora: 23, min: 30 },  // antes 02:30
    'cancelarPendientesAntiguos20h':    { hora: 23, min: 45 }   // antes cada 1h
  };
  var triggers = ScriptApp.getProjectTriggers();
  var borrados = [];
  var creados  = [];
  // 1. Borrar triggers existentes para esas funciones (con cualquier horario)
  triggers.forEach(function(t) {
    var fn = t.getHandlerFunction();
    if (TRGS_SEG.hasOwnProperty(fn)) {
      ScriptApp.deleteTrigger(t);
      borrados.push(fn);
    }
  });
  // 2. Crear de nuevo con horarios nocturnos
  Object.keys(TRGS_SEG).forEach(function(fn) {
    var cfg = TRGS_SEG[fn];
    ScriptApp.newTrigger(fn).timeBased().atHour(cfg.hora).nearMinute(cfg.min).everyDays(1).create();
    creados.push(fn + ' @ ' + cfg.hora + ':' + (cfg.min < 10 ? '0' : '') + cfg.min);
  });
  return { ok: true, data: { borrados: borrados, creados: creados } };
}

// [v2.43.175] Listado de triggers actualmente instalados con info detallada.
// Ejecutar desde el editor GAS para verificar que los 3 triggers de seguridad
// están activos con los horarios correctos. Output va al Logger.
function verificarTriggersSeguridad() {
  Logger.log('═════════════════════════════════════════════════');
  Logger.log('TRIGGERS DE SEGURIDAD INSTALADOS');
  Logger.log('═════════════════════════════════════════════════');
  var esperados = {
    'purgarDispositivosInactivos7d':    { regla: 'R5a · auto-suspende >7d', horaEsperada: '23:15' },
    'alertarDispositivosInactivos2a7d': { regla: 'R5b · alerta master 2-7d', horaEsperada: '23:30' },
    'cancelarPendientesAntiguos20h':    { regla: 'R6  · auto-cancela PEND >20h', horaEsperada: '23:45' }
  };
  var triggers = ScriptApp.getProjectTriggers();
  var encontrados = {};
  triggers.forEach(function(t) {
    var fn = t.getHandlerFunction();
    if (esperados.hasOwnProperty(fn)) {
      var src = t.getTriggerSource();
      var info = 'TimeDriven';
      try {
        // No hay API directa para leer hora del trigger; el id es suficiente para confirmar.
        info = 'TimeDriven (UID ' + t.getUniqueId().substring(0, 8) + '...)';
      } catch(_){}
      encontrados[fn] = info;
    }
  });
  var todos = true;
  Object.keys(esperados).forEach(function(fn) {
    var meta = esperados[fn];
    if (encontrados[fn]) {
      Logger.log('✅ ' + fn + ' @ ' + meta.horaEsperada + ' diario · ' + meta.regla);
    } else {
      Logger.log('❌ FALTA · ' + fn + ' @ ' + meta.horaEsperada + ' · ' + meta.regla);
      todos = false;
    }
  });
  Logger.log('');
  if (todos) {
    Logger.log('🎉 TODOS los triggers están instalados correctamente.');
  } else {
    Logger.log('⚠ Algunos faltan. Ejecuta reinstalarTriggersSeguridadNocturnoConLog');
  }
  Logger.log('');
  // Listar OTROS triggers no de seguridad (informativo)
  var otros = triggers.filter(function(t) {
    return !esperados.hasOwnProperty(t.getHandlerFunction());
  });
  if (otros.length > 0) {
    Logger.log('────────────────────────────────────────────────');
    Logger.log('OTROS triggers del proyecto (' + otros.length + '):');
    otros.forEach(function(t) {
      Logger.log('   · ' + t.getHandlerFunction());
    });
  }
  Logger.log('═════════════════════════════════════════════════');
  return { ok: true, todos_instalados: todos };
}

// [v2.43.173] Mismo wrapper pero con log claro para el editor (que no
// muestra el return automáticamente).
function reinstalarTriggersSeguridadNocturnoConLog() {
  Logger.log('═════════════════════════════════════════════════');
  Logger.log('REINSTALANDO TRIGGERS DE SEGURIDAD (horario 23h-24h)');
  Logger.log('═════════════════════════════════════════════════');
  var r = reinstalarTriggersSeguridadNocturno();
  if (!r.ok) { Logger.log('❌ ERROR: ' + r.error); return r; }
  Logger.log('🗑  Triggers borrados:');
  (r.data.borrados || []).forEach(function(f) { Logger.log('   - ' + f); });
  if (!(r.data.borrados || []).length) Logger.log('   (ninguno — primera instalación)');
  Logger.log('');
  Logger.log('✅ Triggers creados:');
  (r.data.creados || []).forEach(function(f) { Logger.log('   + ' + f); });
  Logger.log('═════════════════════════════════════════════════');
  Logger.log('TODOS los crons de seguridad corren ahora entre 23:15 y 23:45,');
  Logger.log('durante la ventana de mantenimiento. Las apps están cerradas');
  Logger.log('en ese horario (cron forzar_logout a las 23h).');
  return r;
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
