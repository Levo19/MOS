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

function getPersonalMaster(params) {
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
