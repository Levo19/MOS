// ============================================================
// ProyectoMOS — Seguridad.gs
// Sistema unificado de clave admin global.
//
// Modelo: clave de 8 dígitos = ADMIN_GLOBAL_PIN (4) + PIN del
// usuario MASTER/ADMIN (4). Esto reemplaza los adminPin por
// estación (ESTACIONES.adminPin queda obsoleto).
//
// Rotación automática cada 30 días — el admin ve la nueva
// clave en el panel de MOS (Configuración → Seguridad).
//
// Cada validación queda registrada en AUDITORIA_ADMIN para
// trazabilidad de quién autorizó qué.
// ============================================================

var AUDITORIA_ADMIN_HEADERS = [
  'idAccion', 'fecha', 'accion', 'refDocumento',
  'idPersonalAutoriza', 'nombreAutoriza', 'appOrigen',
  'dispositivo', 'detalle'
];

var ROTACION_DIAS = 30;

// ────────────────────────────────────────────────────────────
// HELPERS
// ────────────────────────────────────────────────────────────
function _generar4Digitos() {
  // Random 4 dígitos, evita patrones obvios (0000, 1234, 1111, etc.)
  var malos = ['0000','1111','2222','3333','4444','5555','6666','7777','8888','9999','1234','4321','0123','9876'];
  for (var intento = 0; intento < 50; intento++) {
    var n = Math.floor(1000 + Math.random() * 9000); // 1000-9999
    var s = String(n);
    if (malos.indexOf(s) === -1) return s;
  }
  return String(Math.floor(1000 + Math.random() * 9000));
}

function _garantizarClaveGlobal() {
  var sheet = getSheet('CONFIG_MOS');
  var data = sheet.getDataRange().getValues();
  var pinExiste = false, fechaExiste = false;
  for (var i = 1; i < data.length; i++) {
    if (data[i][0] === 'ADMIN_GLOBAL_PIN')       pinExiste = true;
    if (data[i][0] === 'ADMIN_GLOBAL_PIN_FECHA') fechaExiste = true;
  }
  if (!pinExiste) {
    sheet.appendRow(['ADMIN_GLOBAL_PIN', _generar4Digitos(), 'Clave admin global (4 dig). Se concatena con PIN del admin (4 dig) para validar acciones protegidas en ME/WH.']);
  }
  if (!fechaExiste) {
    sheet.appendRow(['ADMIN_GLOBAL_PIN_FECHA', new Date().toISOString(), 'Fecha de la última rotación de la clave admin global.']);
  }
  // Forzar formato texto en col 2 para preservar ceros a la izquierda
  try {
    sheet.getRange(2, 2, sheet.getLastRow() - 1, 1).setNumberFormat('@');
  } catch(e) {}
}

function _garantizarHojaAuditoria() {
  var ss = getSpreadsheet();
  var sheet = ss.getSheetByName('AUDITORIA_ADMIN');
  if (!sheet) {
    sheet = ss.insertSheet('AUDITORIA_ADMIN');
    sheet.getRange(1, 1, 1, AUDITORIA_ADMIN_HEADERS.length).setValues([AUDITORIA_ADMIN_HEADERS]);
    sheet.getRange(1, 1, 1, AUDITORIA_ADMIN_HEADERS.length)
         .setFontWeight('bold').setBackground('#1f2937').setFontColor('#fff');
    sheet.setFrozenRows(1);
  }
  return sheet;
}

function _leerConfigMos(clave) {
  var data = getSheet('CONFIG_MOS').getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (data[i][0] === clave) return data[i][1];
  }
  return null;
}

function _escribirConfigMos(clave, valor) {
  var sheet = getSheet('CONFIG_MOS');
  var data = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (data[i][0] === clave) {
      sheet.getRange(i + 1, 2).setNumberFormat('@').setValue(valor);
      return;
    }
  }
  sheet.appendRow([clave, valor, '']);
}

function _esRolAdmin(rol) {
  var r = String(rol || '').toUpperCase();
  return r === 'MASTER' || r === 'ADMIN' || r === 'ADMINISTRADOR';
}

function _buscarAdminPorPin(pin4digitos) {
  var personas = _sheetToObjects(getSheet('PERSONAL_MASTER'));
  return personas.find(function(p) {
    return _esRolAdmin(p.rol) &&
           String(p.estado) === '1' &&
           String(p.pin || '').padStart(4, '0') === String(pin4digitos);
  });
}

function _diasDesde(fechaISO) {
  if (!fechaISO) return 999;
  var d = new Date(fechaISO);
  if (isNaN(d.getTime())) return 999;
  return Math.floor((Date.now() - d.getTime()) / (1000 * 60 * 60 * 24));
}

// ────────────────────────────────────────────────────────────
// VERIFICAR CLAVE ADMIN — clave de 8 dígitos
// Retorna {ok, autorizado, validadoPor, idPersonal, nombre}
// ────────────────────────────────────────────────────────────
function verificarClaveAdmin(params) {
  if (!params || !params.clave) {
    return { ok: false, error: 'Requiere clave' };
  }
  _garantizarClaveGlobal();
  var clave = String(params.clave).trim();
  if (clave.length !== 8 || !/^\d{8}$/.test(clave)) {
    return { ok: true, data: { autorizado: false, error: 'La clave debe ser de 8 dígitos numéricos' } };
  }

  var globalPart = clave.substring(0, 4);
  var userPart   = clave.substring(4, 8);

  var globalPin = String(_leerConfigMos('ADMIN_GLOBAL_PIN') || '').padStart(4, '0');
  if (!globalPin || globalPin.length !== 4) {
    return { ok: false, error: 'ADMIN_GLOBAL_PIN no configurado en MOS' };
  }
  if (globalPart !== globalPin) {
    return { ok: true, data: { autorizado: false, error: 'Clave incorrecta' } };
  }

  var admin = _buscarAdminPorPin(userPart);
  if (!admin) {
    return { ok: true, data: { autorizado: false, error: 'Clave incorrecta' } };
  }

  // Auditoría
  try {
    var sheet = _garantizarHojaAuditoria();
    sheet.appendRow([
      _generateId('AUD'),
      new Date(),
      params.accion || 'GENERICA',
      params.refDocumento || '',
      admin.idPersonal,
      admin.nombre + ' ' + (admin.apellido || ''),
      params.appOrigen || '',
      params.dispositivo || '',
      params.detalle || ''
    ]);
  } catch(e) { /* no bloquear validación si auditoría falla */ }

  return {
    ok: true,
    data: {
      autorizado: true,
      validadoPor: 'admin:' + (admin.nombre + ' ' + (admin.apellido || '')).trim(),
      idPersonal: admin.idPersonal,
      nombre: admin.nombre + ' ' + (admin.apellido || '')
    }
  };
}

// ────────────────────────────────────────────────────────────
// GET CLAVE ADMIN GLOBAL — para panel MOS
// Acceso: cualquier MASTER/ADMIN activo (autentica por su pin4)
// ────────────────────────────────────────────────────────────
function getClaveAdminGlobal(params) {
  _garantizarClaveGlobal();
  // Autenticación: requiere pinAdmin (4 dígitos del solicitante)
  var pinSol = String((params && params.pinAdmin) || '').trim();
  if (!pinSol) {
    return { ok: false, error: 'Requiere pinAdmin (PIN del solicitante)' };
  }
  var admin = _buscarAdminPorPin(pinSol);
  if (!admin) {
    return { ok: true, data: { autorizado: false, error: 'PIN no reconocido' } };
  }

  var pin = String(_leerConfigMos('ADMIN_GLOBAL_PIN') || '').padStart(4, '0');
  var fechaUlt = _leerConfigMos('ADMIN_GLOBAL_PIN_FECHA');
  var dias = _diasDesde(fechaUlt);
  var diasParaRotar = Math.max(0, ROTACION_DIAS - dias);
  var fechaProxima = new Date(Date.now() + diasParaRotar * 86400000).toISOString();

  return {
    ok: true,
    data: {
      autorizado: true,
      pin: pin,
      fechaUltimaRotacion: fechaUlt,
      fechaProximaRotacion: fechaProxima,
      diasDesdeRotacion: dias,
      diasParaProximaRotacion: diasParaRotar,
      vencida: dias > ROTACION_DIAS,
      consultadoPor: admin.nombre
    }
  };
}

// ────────────────────────────────────────────────────────────
// ROTAR CLAVE ADMIN GLOBAL — manual o auto (trigger)
// ────────────────────────────────────────────────────────────
function rotarClaveAdminGlobal(params) {
  _garantizarClaveGlobal();
  var manual = params && params.manual;
  var consultadoPor = '';

  if (manual) {
    var pinSol = String((params && params.pinAdmin) || '').trim();
    var admin = _buscarAdminPorPin(pinSol);
    if (!admin) {
      return { ok: true, data: { autorizado: false, error: 'PIN no reconocido' } };
    }
    consultadoPor = admin.nombre;
  } else {
    consultadoPor = 'AUTO_TRIGGER';
  }

  var lock = LockService.getScriptLock();
  try { lock.tryLock(15000); } catch(e) {}
  try {
    var nuevoPin = _generar4Digitos();
    // Asegurar que el nuevo es distinto al actual
    var actual = String(_leerConfigMos('ADMIN_GLOBAL_PIN') || '');
    var seguridad = 0;
    while (nuevoPin === actual && seguridad < 10) {
      nuevoPin = _generar4Digitos();
      seguridad++;
    }
    _escribirConfigMos('ADMIN_GLOBAL_PIN', nuevoPin);
    _escribirConfigMos('ADMIN_GLOBAL_PIN_FECHA', new Date().toISOString());

    // Auditar la rotación
    try {
      var sheet = _garantizarHojaAuditoria();
      sheet.appendRow([
        _generateId('AUD'),
        new Date(),
        'ROTACION_PIN_GLOBAL',
        '',
        '',
        consultadoPor,
        'MOS',
        '',
        manual ? 'Rotación manual' : 'Rotación automática (>30 días)'
      ]);
    } catch(e) {}

    return {
      ok: true,
      data: {
        autorizado: true,
        pin: nuevoPin,
        fechaUltimaRotacion: new Date().toISOString(),
        fechaProximaRotacion: new Date(Date.now() + ROTACION_DIAS * 86400000).toISOString()
      }
    };
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

// ────────────────────────────────────────────────────────────
// CACHE OFFLINE — ME/WH descargan globalPin + lista admins
// ────────────────────────────────────────────────────────────
function getAdminPinsCache(params) {
  _garantizarClaveGlobal();
  var pin = String(_leerConfigMos('ADMIN_GLOBAL_PIN') || '').padStart(4, '0');
  var personas = _sheetToObjects(getSheet('PERSONAL_MASTER'));
  var admins = personas
    .filter(function(p) {
      return _esRolAdmin(p.rol) && String(p.estado) === '1' && p.pin;
    })
    .map(function(p) {
      return {
        idPersonal: p.idPersonal,
        nombre: (p.nombre + ' ' + (p.apellido || '')).trim(),
        pin: String(p.pin || '').padStart(4, '0')
      };
    });
  return {
    ok: true,
    data: {
      globalPin: pin,
      adminPins: admins,
      generadoEn: new Date().toISOString()
    }
  };
}

// ────────────────────────────────────────────────────────────
// AUDITORÍA — listar acciones recientes (panel MOS)
// ────────────────────────────────────────────────────────────
function getAuditoriaAdmin(params) {
  var sheet = _garantizarHojaAuditoria();
  var rows = _sheetToObjects(sheet);
  // Más recientes primero
  rows.sort(function(a, b) {
    var fa = new Date(a.fecha).getTime() || 0;
    var fb = new Date(b.fecha).getTime() || 0;
    return fb - fa;
  });
  if (params && params.accion) {
    rows = rows.filter(function(r){ return String(r.accion).toUpperCase() === String(params.accion).toUpperCase(); });
  }
  if (params && params.appOrigen) {
    rows = rows.filter(function(r){ return String(r.appOrigen).toLowerCase() === String(params.appOrigen).toLowerCase(); });
  }
  var limit = parseInt((params && params.limit), 10) || 100;
  rows = rows.slice(0, limit);
  return { ok: true, data: rows };
}

// ────────────────────────────────────────────────────────────
// TRIGGER AUTOMÁTICO — verificar rotación cada día
// Configurar en Apps Script: triggers > nuevo > verificarRotacionAuto > diario
// ────────────────────────────────────────────────────────────
function verificarRotacionAuto() {
  _garantizarClaveGlobal();
  var fechaUlt = _leerConfigMos('ADMIN_GLOBAL_PIN_FECHA');
  var dias = _diasDesde(fechaUlt);
  if (dias >= ROTACION_DIAS) {
    rotarClaveAdminGlobal({ manual: false });
    Logger.log('Clave admin global rotada automáticamente (días desde rotación: ' + dias + ')');
  } else {
    Logger.log('Rotación auto: aún no toca (' + dias + '/' + ROTACION_DIAS + ' días)');
  }
}
