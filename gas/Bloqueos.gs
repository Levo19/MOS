// ============================================================
// ProyectoMOS — Bloqueos.gs
// Sistema de bloqueo remoto de usuarios para apps hijas (ME / WH).
//
// Cuando un MASTER/ADMIN desactiva (estado='0') a un usuario en
// PERSONAL_MASTER, las apps hijas detectan el bloqueo vía polling
// cada 30s y muestran una pantalla de candado.
//
// El admin puede otorgar un desbloqueo TEMPORAL (15 min) ingresando
// una clave válida (Admin_PIN de cualquier estación activa, o el
// PIN de cualquier MASTER/ADMIN activo en PERSONAL_MASTER).
//
// Hoja BLOQUEOS_USUARIO:
//   idBloqueo | idPersonal | nombre | appOrigen | motivo |
//   bloqueadoPor | fechaBloqueo | unlockHasta | desbloqueadoPor
// ============================================================

var BLOQUEOS_HEADERS = [
  'idBloqueo', 'idPersonal', 'nombre', 'appOrigen', 'motivo',
  'bloqueadoPor', 'fechaBloqueo', 'unlockHasta', 'desbloqueadoPor'
];

function _garantizarHojaBloqueos() {
  var ss = getSpreadsheet();
  var sheet = ss.getSheetByName('BLOQUEOS_USUARIO');
  if (!sheet) {
    sheet = ss.insertSheet('BLOQUEOS_USUARIO');
    sheet.getRange(1, 1, 1, BLOQUEOS_HEADERS.length).setValues([BLOQUEOS_HEADERS]);
    sheet.getRange(1, 1, 1, BLOQUEOS_HEADERS.length)
         .setFontWeight('bold').setBackground('#1f2937').setFontColor('#fff');
    sheet.setFrozenRows(1);
  }
  return sheet;
}

function _normalizarNombre(s) {
  return String(s || '').trim().toLowerCase();
}

function _normalizarApp(s) {
  s = String(s || '').toLowerCase();
  if (s.indexOf('express') >= 0 || s === 'me') return 'mosexpress';
  if (s.indexOf('warehouse') >= 0 || s === 'wh') return 'warehousemos';
  return s;
}

// ────────────────────────────────────────────────────────────
// ESTADO DE BLOQUEO
// Llamado por MosExpress y warehouseMos cada 30s.
// ────────────────────────────────────────────────────────────
function getEstadoBloqueoUsuario(params) {
  if (!params || (!params.nombre && !params.idPersonal)) {
    return { ok: false, error: 'Requiere nombre o idPersonal' };
  }
  var appOrigen = _normalizarApp(params.appOrigen || '');
  var nombreNorm = _normalizarNombre(params.nombre);

  // 1) Buscar persona en PERSONAL_MASTER
  var personas = _sheetToObjects(getSheet('PERSONAL_MASTER'));
  var persona = null;
  if (params.idPersonal) {
    persona = personas.find(function(p){ return String(p.idPersonal) === String(params.idPersonal); });
  }
  if (!persona && nombreNorm) {
    persona = personas.find(function(p) {
      if (!p.nombre) return false;
      if (appOrigen && _normalizarApp(p.appOrigen) !== appOrigen) return false;
      return _normalizarNombre(p.nombre) === nombreNorm;
    });
  }

  // Si no existe en PERSONAL_MASTER, no está bloqueado (no hay registro que revisar)
  if (!persona) {
    return { ok: true, data: { bloqueado: false, motivo: 'sin_registro' } };
  }

  var estaInactivo = String(persona.estado) === '0';

  // 2) Buscar fila de unlock temporal vigente en BLOQUEOS_USUARIO
  var unlockHasta = 0;
  var motivo = '';
  var sheet = _garantizarHojaBloqueos();
  var data = sheet.getDataRange().getValues();
  if (data.length > 1) {
    var hdrs = data[0];
    var iId  = hdrs.indexOf('idPersonal');
    var iNom = hdrs.indexOf('nombre');
    var iApp = hdrs.indexOf('appOrigen');
    var iUnl = hdrs.indexOf('unlockHasta');
    var iMot = hdrs.indexOf('motivo');
    for (var r = data.length - 1; r >= 1; r--) {
      var row = data[r];
      var matchId  = persona.idPersonal && String(row[iId]) === String(persona.idPersonal);
      var matchNom = nombreNorm && _normalizarNombre(row[iNom]) === _normalizarNombre(persona.nombre);
      var matchApp = !appOrigen || _normalizarApp(row[iApp]) === appOrigen;
      if ((matchId || matchNom) && matchApp) {
        unlockHasta = parseInt(row[iUnl], 10) || 0;
        motivo = row[iMot] || '';
        break;
      }
    }
  }

  var ahora = new Date().getTime();
  var unlockVigente = unlockHasta > ahora;

  return {
    ok: true,
    data: {
      bloqueado: estaInactivo && !unlockVigente,
      inactivo: estaInactivo,
      unlockHasta: unlockHasta,
      unlockVigente: unlockVigente,
      msRestantes: unlockVigente ? (unlockHasta - ahora) : 0,
      motivo: motivo,
      idPersonal: persona.idPersonal,
      nombre: persona.nombre
    }
  };
}

// ────────────────────────────────────────────────────────────
// DESBLOQUEO TEMPORAL (15 min)
// Valida la clave contra:
//   - ESTACIONES.adminPin de cualquier estación activa
//   - PERSONAL_MASTER.pin de cualquier MASTER/ADMIN activo
// Si es válida, escribe/actualiza fila en BLOQUEOS_USUARIO con
// unlockHasta = ahora + 15 min.
// ────────────────────────────────────────────────────────────
function desbloquearUsuarioTemporal(params) {
  if (!params || !params.claveAdmin) {
    return { ok: false, error: 'Requiere claveAdmin' };
  }
  if (!params.nombre && !params.idPersonal) {
    return { ok: false, error: 'Requiere nombre o idPersonal del usuario a desbloquear' };
  }

  var clave = String(params.claveAdmin).trim();
  var validadoPor = '';

  // ── 1) Validar contra ESTACIONES.adminPin ──
  try {
    var estaciones = _sheetToObjects(getSheet('ESTACIONES'));
    var estMatch = estaciones.find(function(e) {
      return String(e.activo) !== '0' && String(e.adminPin || '') === clave && clave.length > 0;
    });
    if (estMatch) {
      validadoPor = 'estacion:' + (estMatch.nombre || estMatch.idEstacion);
    }
  } catch(e) { /* tolerar si no existe la hoja aún */ }

  // ── 2) Validar contra PIN de master/admin en PERSONAL_MASTER ──
  if (!validadoPor) {
    var personas = _sheetToObjects(getSheet('PERSONAL_MASTER'));
    var persMatch = personas.find(function(p) {
      var rol = String(p.rol || '').toUpperCase();
      var esAdmin = rol === 'MASTER' || rol === 'ADMIN' || rol === 'ADMINISTRADOR';
      return esAdmin && String(p.estado) === '1' &&
             String(p.pin || '') === clave && clave.length > 0;
    });
    if (persMatch) {
      validadoPor = 'admin:' + persMatch.nombre;
    }
  }

  if (!validadoPor) {
    return { ok: true, data: { autorizado: false, error: 'Clave incorrecta' } };
  }

  // ── 3) Resolver datos del usuario a desbloquear ──
  var personasAll = _sheetToObjects(getSheet('PERSONAL_MASTER'));
  var appOrigen = _normalizarApp(params.appOrigen || '');
  var nombreNorm = _normalizarNombre(params.nombre);
  var target = null;
  if (params.idPersonal) {
    target = personasAll.find(function(p){ return String(p.idPersonal) === String(params.idPersonal); });
  }
  if (!target && nombreNorm) {
    target = personasAll.find(function(p) {
      if (!p.nombre) return false;
      if (appOrigen && _normalizarApp(p.appOrigen) !== appOrigen) return false;
      return _normalizarNombre(p.nombre) === nombreNorm;
    });
  }
  // Permitir desbloqueo aunque no esté en PERSONAL_MASTER (registros legacy)
  var idPersonal = target ? target.idPersonal : (params.idPersonal || '');
  var nombre     = target ? target.nombre     : (params.nombre || '');
  var appReg     = target ? target.appOrigen  : (params.appOrigen || '');

  // ── 4) Upsert en BLOQUEOS_USUARIO ──
  var lock = LockService.getScriptLock();
  try { lock.tryLock(15000); } catch(e) {}
  try {
    var sheet = _garantizarHojaBloqueos();
    var data = sheet.getDataRange().getValues();
    var hdrs = data[0];
    var iId  = hdrs.indexOf('idPersonal');
    var iNom = hdrs.indexOf('nombre');
    var iApp = hdrs.indexOf('appOrigen');
    var iUnl = hdrs.indexOf('unlockHasta');
    var iDes = hdrs.indexOf('desbloqueadoPor');
    var iMot = hdrs.indexOf('motivo');

    var unlockHasta = new Date().getTime() + (15 * 60 * 1000);
    var motivo = params.motivo || 'desbloqueo_temporal_15min';

    var foundRow = -1;
    for (var r = 1; r < data.length; r++) {
      var matchId  = idPersonal && String(data[r][iId]) === String(idPersonal);
      var matchNom = nombre && _normalizarNombre(data[r][iNom]) === _normalizarNombre(nombre);
      var matchApp = !appOrigen || _normalizarApp(data[r][iApp]) === appOrigen;
      if ((matchId || matchNom) && matchApp) { foundRow = r + 1; break; }
    }

    if (foundRow > 0) {
      sheet.getRange(foundRow, iUnl + 1).setValue(unlockHasta);
      sheet.getRange(foundRow, iDes + 1).setValue(validadoPor);
      sheet.getRange(foundRow, iMot + 1).setValue(motivo);
    } else {
      var fila = new Array(BLOQUEOS_HEADERS.length).fill('');
      fila[hdrs.indexOf('idBloqueo')]       = _generateId('BLO');
      fila[iId]                             = idPersonal;
      fila[iNom]                            = nombre;
      fila[iApp]                            = appReg;
      fila[iMot]                            = motivo;
      fila[hdrs.indexOf('bloqueadoPor')]    = '';
      fila[hdrs.indexOf('fechaBloqueo')]    = '';
      fila[iUnl]                            = unlockHasta;
      fila[iDes]                            = validadoPor;
      sheet.appendRow(fila);
    }

    return {
      ok: true,
      data: {
        autorizado: true,
        unlockHasta: unlockHasta,
        msRestantes: 15 * 60 * 1000,
        validadoPor: validadoPor
      }
    };
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

// ────────────────────────────────────────────────────────────
// LISTAR BLOQUEOS ACTIVOS (para panel admin de MOS)
// ────────────────────────────────────────────────────────────
function getBloqueosActivos(params) {
  var sheet = _garantizarHojaBloqueos();
  var rows = _sheetToObjects(sheet);
  var ahora = new Date().getTime();
  rows = rows.map(function(r) {
    var unl = parseInt(r.unlockHasta, 10) || 0;
    r.unlockVigente = unl > ahora;
    r.msRestantes = r.unlockVigente ? (unl - ahora) : 0;
    return r;
  });
  if (params && params.appOrigen) {
    var app = _normalizarApp(params.appOrigen);
    rows = rows.filter(function(r){ return _normalizarApp(r.appOrigen) === app; });
  }
  return { ok: true, data: rows };
}
