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
  // [DELETE-SAFE · espejo inmediato] Mirror best-effort a mos.estaciones (las otras 6 tablas del catálogo
  // ya lo hacen). Sin esto, una estación nueva SOLO llegaba a la sombra por el sync batch time-based — que
  // Google desactiva sin avisar → no bumpea catalogo_version → WH/RPCs no la ven (mismo bug del proveedor).
  try {
    if (typeof _dualWriteCAT === 'function') _dualWriteCAT('estaciones', {
      idEstacion: id, idZona: params.idZona || '', nombre: params.nombre,
      tipo: params.tipo || 'CAJA', appOrigen: params.appOrigen || 'mosExpress',
      adminPin: params.adminPin || '', activo: '1', descripcion: params.descripcion || ''
    });
  } catch (eDW) { Logger.log('[dualWrite crearEstacion] ' + (eDW && eDW.message)); }
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
    // [DELETE-SAFE · espejo inmediato] Mirror de la fila ACTUALIZADA a mos.estaciones (patrón actualizarZona).
    try {
      if (typeof _dualWriteCAT === 'function') {
        var fila = sheet.getRange(i + 1, 1, 1, hdrs.length).getValues()[0];
        var obj = {};
        hdrs.forEach(function(h, k){ obj[h] = fila[k]; });
        _dualWriteCAT('estaciones', obj);
      }
    } catch (eDW) { Logger.log('[dualWrite actualizarEstacion] ' + (eDW && eDW.message)); }
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
// [FASE 0 v2.43.225] reactivarDispositivoSuspendido_LEGACY_NO_USAR ELIMINADA.
// Era una def duplicada/muerta de reactivarDispositivoSuspendido (la ACTIVA vive
// en SeguridadAlerts.gs:338, gana por orden alfabético de clasp). No tenía
// callers — verificado por grep. La propagación a sombra ya vive en la activa.
// ════════════════════════════════════════════════════════════════════════




// ════════════════════════════════════════════════════════════════════════
// [v2.43.172 R6] cancelarPendientesAntiguos — auto-cancela solicitudes
// PENDIENTE_APROBACION viejas para evitar spam de alertas al admin.
//
// Lógica: dispositivo PENDIENTE sin aprobar por +2 DÍAS (48h) = solicitud
// abandonada. Marca como CANCELADO_AUTO. Al volver el operador,
// registrarSesionDispositivo lo reutiliza pasando a PENDIENTE_APROBACION nueva.
//
// [dueño 2026-07-14] Antes el default era 20h → cancelaba las solicitudes
// "de un día para otro" antes de que el master alcanzara a aprobarlas
// (por eso la solicitud remota "desaparecía"). Subido a 48h = misma regla que
// la suspensión de dispositivos activos (+2 días). Property PENDIENTE_AUTO_CANCEL_HORAS.
// ⚠️ CERO-GAS: esta función debe MIGRAR al pg_cron de Supabase
// (mos.cron_dispositivos_inactivos) y desactivarse su trigger GAS.
// ════════════════════════════════════════════════════════════════════════
// [dueño 2026-07-14 · CERO-GAS] MIGRADO a Supabase. La cancelación de solicitudes
// PENDIENTE_APROBACION >2 días ahora la hace el pg_cron `mos.cron_dispositivos_inactivos`
// (que además marca las alertas REVISADA). Esta función quedó como NO-OP para no
// duplicar/adelantar la lógica desde GAS. El trigger `cancelarPendientesAntiguos20h`
// debe ELIMINARSE (ver desinstalarTriggerCancelarPendientes()).
function cancelarPendientesAntiguos() {
  return { ok: true, noop: true, migrado: 'mos.cron_dispositivos_inactivos (Supabase, 48h)' };
}

// Wrapper del trigger (no-op tras la migración a Supabase).
function cancelarPendientesAntiguos20h() {
  return cancelarPendientesAntiguos();
}

// [dueño 2026-07-14 · CERO-GAS] Ejecuta esto UNA vez desde el editor GAS para
// ELIMINAR el trigger diario de auto-cancelación (ya lo hace el pg_cron de Supabase).
// Idempotente: si no existe, devuelve {ya:true}.
function desinstalarTriggerCancelarPendientes() {
  var TRG = 'cancelarPendientesAntiguos20h';
  var quitados = 0;
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === TRG) { ScriptApp.deleteTrigger(t); quitados++; }
  });
  return { ok: true, quitados: quitados, ya: quitados === 0 };
}

// [CERO-GAS 2026-07-14] NO-OP tras la migración a Supabase. Ya NO se instala el
// trigger de auto-cancelación (lo hace mos.cron_dispositivos_inactivos). Se conserva
// el nombre para no romper llamadas existentes.
function instalarTriggerCancelarPendientes() {
  return { ok: true, noop: true, migrado: 'mos.cron_dispositivos_inactivos (Supabase)' };
}

// [v2.43.173] Función ÚNICA que limpia los triggers de seguridad antiguos
// (que pueden tener horarios viejos) y los reinstala con horario nocturno
// 23:15 / 23:30 / 23:45. Idempotente — se puede ejecutar varias veces.
//
// Ejecutar desde el editor GAS cuando se quiera refrescar la configuración
// de triggers. Útil tras cambios de horario como v2.43.173.
function reinstalarTriggersSeguridadNocturno() {
  var TRGS_SEG = {
    // [CERO-GAS 2026-07-14] 'cancelarPendientesAntiguos20h' RETIRADO — migrado a Supabase (mos.cron_dispositivos_inactivos).
    // [CERO-GAS 2026-07-17] 'purgarDispositivosInactivos7d' + 'alertarDispositivosInactivos2a7d' RETIRADOS — la
    // suspensión (>2d) y su aviso los hace el pg_cron mos.cron_dispositivos_inactivos (cada hora). Mapa vacío = no
    // (re)instala ningún trigger GAS de inactividad. Los 2 crons GAS quedaron obsoletos y se borraron.
  };
  // [CERO-GAS 2026-07-17] Handlers RETIRADOS (funciones borradas/migradas a pg_cron): si quedó algún trigger
  // huérfano apuntándolos, dispararía "Script function not found" cada noche → correo de fallo al dueño. Los
  // limpiamos acá también. Correr esta función 1 vez basta para evacuar cualquier trigger huérfano.
  var RETIRED = { purgarDispositivosInactivos7d: 1, alertarDispositivosInactivos2a7d: 1, cancelarPendientesAntiguos20h: 1 };
  var triggers = ScriptApp.getProjectTriggers();
  var borrados = [];
  var creados  = [];
  // 1. Borrar triggers existentes para esas funciones (con cualquier horario) + los retirados huérfanos
  triggers.forEach(function(t) {
    var fn = t.getHandlerFunction();
    if (TRGS_SEG.hasOwnProperty(fn) || RETIRED[fn]) {
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
  // [CERO-GAS 2026-07-17] Los 3 triggers de seguridad (R5a purgar >7d, R5b alerta 2-7d, R6 cancelar PEND >20h)
  // fueron RETIRADOS — la inactividad/expiración la maneja el pg_cron mos.cron_dispositivos_inactivos. Mapa vacío.
  var esperados = {};
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



