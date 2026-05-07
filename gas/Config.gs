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
  var tz = Session.getScriptTimeZone();
  var nowStr = Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd HH:mm:ss');

  for (var i = 1; i < data.length; i++) {
    var matchId  = params.idPersonal && String(data[i][iId]) === String(params.idPersonal);
    var matchNom = nombreNorm && String(data[i][iNom] || '').trim().toLowerCase() === nombreNorm;
    var matchApp = !appNorm || String(data[i][iApp] || '').toLowerCase() === appNorm;
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
    campos.forEach(function(c) {
      if (params[c] !== undefined) {
        var col = hdrs.indexOf(c);
        if (col >= 0) sheet.getRange(i+1, col+1).setValue(params[c]);
      }
    });
    return { ok: true };
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

var _DISP_COLS_EXTRA = ['Ultima_Zona', 'Ultima_Estacion', 'Ultima_Sesion'];

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

function getDispositivos(params) {
  _garantizarColumnasDispositivos();
  var rows = _sheetToObjects(getSheet('DISPOSITIVOS'));
  if (params && params.app)    rows = rows.filter(function(r){ return r.App === params.app; });
  if (params && params.estado) rows = rows.filter(function(r){ return r.Estado === params.estado; });
  return { ok: true, data: rows };
}

function crearDispositivo(params) {
  _garantizarColumnasDispositivos();
  if (!params.ID_Dispositivo) return { ok: false, error: 'Requiere ID_Dispositivo' };
  if (!params.Nombre_Equipo)  return { ok: false, error: 'Requiere Nombre_Equipo' };
  var sheet = getSheet('DISPOSITIVOS');
  var dup = _sheetToObjects(sheet).find(function(d){ return d.ID_Dispositivo === params.ID_Dispositivo; });
  if (dup) return { ok: false, error: 'Dispositivo ya registrado: ' + params.ID_Dispositivo };
  var tz = Session.getScriptTimeZone();
  var hdrs = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  var fila = new Array(hdrs.length).fill('');
  fila[hdrs.indexOf('ID_Dispositivo')]   = params.ID_Dispositivo;
  fila[hdrs.indexOf('Nombre_Equipo')]    = params.Nombre_Equipo;
  fila[hdrs.indexOf('App')]              = params.App    || 'mosExpress';
  fila[hdrs.indexOf('Estado')]           = params.Estado || 'ACTIVO';
  fila[hdrs.indexOf('Ultima_Conexion')]  = Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd HH:mm:ss');
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
      var tz = Session.getScriptTimeZone();
      var nowStr = Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd HH:mm:ss');
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

  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iEst  = hdrs.indexOf('Estado');
  var iUC   = hdrs.indexOf('Ultima_Conexion');
  var iUZ   = hdrs.indexOf('Ultima_Zona');
  var iUEs  = hdrs.indexOf('Ultima_Estacion');
  var iUSe  = hdrs.indexOf('Ultima_Sesion');
  var tz = Session.getScriptTimeZone();
  var nowStr = Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd HH:mm:ss');

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
    return { ok: true, data: { autorizado: true, estado: 'ACTIVO', nombre: data[i][hdrs.indexOf('Nombre_Equipo')] } };
  }

  // No existe → crear como PENDIENTE_APROBACION
  var nombreNuevo = params.Nombre_Equipo || ('Nuevo dispositivo (' + deviceId.substring(0, 8) + ')');
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

  // Push notif a master/admin avisando del nuevo dispositivo
  try {
    var detalle = appNueva.toUpperCase() + ' · UUID ' + deviceId.substring(0, 8) + '...';
    if (params.idEstacion) detalle += ' · estación ' + params.idEstacion;
    if (params.vendedor)   detalle += ' · cajero ' + params.vendedor;
    // Solo MASTER recibe esta notificación: la aprobación de dispositivos es
    // exclusiva del master (no del admin), así que el push también.
    _enviarPushTodos('🔔 Nuevo dispositivo solicita acceso', detalle, { soloRolesMaster: true });
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
    return { ok: true };
  }
  return { ok: false, error: 'Dispositivo no encontrado' };
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
