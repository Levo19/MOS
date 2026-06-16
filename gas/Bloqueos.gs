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

  // ── Heartbeat de dispositivo (Round 2) ──────────────────────
  // Si la app envía deviceId, aprovechamos esta llamada (que ya corre
  // cada 30s) para actualizar Ultima_Conexion + Ultima_Zona/Estacion/Sesion
  // en la tabla DISPOSITIVOS. Cero round-trips extra.
  // Tolera errores: nunca bloquea la respuesta del bloqueo.
  if (params.deviceId) {
    try {
      // Auto-asignar estación de Almacén si viene de WH sin idEstacion explícito
      // (operadores WH no eligen estación — todos usan la única de Almacén).
      // Bug previo: buscaba e.app y e.activa, pero las columnas reales son
      // appOrigen y activo → siempre fallaba y la sesión quedaba sin estación.
      var idEstacionFinal = params.idEstacion || '';
      var idZonaFinal     = params.idZona || '';
      if (!idEstacionFinal && _normalizarApp(params.appOrigen) === 'warehousemos') {
        try {
          var estaciones = _sheetToObjects(getSheet('ESTACIONES'));
          var primeraWH = estaciones.find(function(e) {
            return String(e.appOrigen || '').toLowerCase() === 'warehousemos'
                && String(e.activo || '1') !== '0';
          });
          if (primeraWH) {
            idEstacionFinal = primeraWH.idEstacion || '';
            idZonaFinal     = idZonaFinal || primeraWH.idZona || '';
          }
        } catch(eEst) { Logger.log('Auto-estación WH falló: ' + eEst.message); }
      }
      registrarSesionDispositivo({
        ID_Dispositivo: params.deviceId,
        idZona:         idZonaFinal,
        idEstacion:     idEstacionFinal,
        vendedor:       params.nombre || '',
        app:            params.appOrigen || 'mosExpress',
        userAgent:      params.userAgent || ''
      });
    } catch(e) { /* tolerar */ }
  }

  // ── Heartbeat de PERSONAL ────────────────────────────────
  // Aprovecha el mismo poll cada 30s para actualizar Ultima_Conexion
  // del usuario (vendedor ME por nombre, operador WH por idPersonal).
  try {
    registrarConexionPersonal({
      idPersonal: params.idPersonal || '',
      nombre:     params.nombre || '',
      appOrigen:  params.appOrigen || ''
    });
  } catch(e) { /* tolerar */ }

  // 1) (Solo para usuarios "reales" tipo WH/MOS Admin) — buscar en PERSONAL_MASTER
  // Para vendedores ME esto NO aplica: ellos comparten el usuario plantilla
  // (ej: PER099 Cajero Genérico) y se identifican solo por nombre.
  var estaInactivoEnPM = false;
  var personaPM = null;
  if (appOrigen !== 'mosexpress') {
    var personas = _sheetToObjects(getSheet('PERSONAL_MASTER'));
    if (params.idPersonal) {
      personaPM = personas.find(function(p){ return String(p.idPersonal) === String(params.idPersonal); });
    }
    if (!personaPM && nombreNorm) {
      personaPM = personas.find(function(p) {
        if (!p.nombre) return false;
        if (appOrigen && _normalizarApp(p.appOrigen) !== appOrigen) return false;
        return _normalizarNombre(p.nombre) === nombreNorm;
      });
    }
    if (personaPM) estaInactivoEnPM = String(personaPM.estado) === '0';
  }

  // 2) Revisar BLOQUEOS_USUARIO — fila puede tener:
  //    - fechaBloqueo seteada → bloqueo manual del admin (vendedor ME, o cualquiera)
  //    - unlockHasta futuro → desbloqueo temporal vigente
  var unlockHasta = 0;
  var fechaBloqueo = '';
  var motivo = '';
  var idPersonalReg = personaPM ? personaPM.idPersonal : (params.idPersonal || '');
  var nombreReg = personaPM ? personaPM.nombre : (params.nombre || '');

  var sheet = _garantizarHojaBloqueos();
  var data = sheet.getDataRange().getValues();
  if (data.length > 1) {
    var hdrs = data[0];
    var iId  = hdrs.indexOf('idPersonal');
    var iNom = hdrs.indexOf('nombre');
    var iApp = hdrs.indexOf('appOrigen');
    var iUnl = hdrs.indexOf('unlockHasta');
    var iFB  = hdrs.indexOf('fechaBloqueo');
    var iMot = hdrs.indexOf('motivo');
    for (var r = data.length - 1; r >= 1; r--) {
      var row = data[r];
      var matchId  = idPersonalReg && String(row[iId]) === String(idPersonalReg);
      var matchNom = nombreReg && _normalizarNombre(row[iNom]) === _normalizarNombre(nombreReg);
      var matchApp = !appOrigen || _normalizarApp(row[iApp]) === appOrigen;
      if ((matchId || matchNom) && matchApp) {
        unlockHasta  = parseInt(row[iUnl], 10) || 0;
        fechaBloqueo = row[iFB] || '';
        motivo       = row[iMot] || '';
        break;
      }
    }
  }

  var ahora = new Date().getTime();
  var unlockVigente = unlockHasta > ahora;
  var bloqueoManualEnTabla = !!fechaBloqueo;

  // Bloqueado si:
  //  - PERSONAL_MASTER.estado=0 (WH/MOS Admin), o
  //  - BLOQUEOS_USUARIO.fechaBloqueo seteado (vendedor ME bloqueado por admin)
  // Y SIN unlock vigente.
  var bloqueado = (estaInactivoEnPM || bloqueoManualEnTabla) && !unlockVigente;

  return {
    ok: true,
    data: {
      bloqueado: bloqueado,
      inactivo: estaInactivoEnPM || bloqueoManualEnTabla,
      unlockHasta: unlockHasta,
      unlockVigente: unlockVigente,
      msRestantes: unlockVigente ? (unlockHasta - ahora) : 0,
      motivo: motivo,
      idPersonal: idPersonalReg,
      nombre: nombreReg
    }
  };
}

// ────────────────────────────────────────────────────────────
// BLOQUEAR/ACTIVAR VENDEDOR ME por NOMBRE (no toca PERSONAL_MASTER)
// Usado desde MOS panel: toggle de cajeros ME que comparten el usuario
// plantilla (ej: PER099). Escribe directamente en BLOQUEOS_USUARIO.
// ────────────────────────────────────────────────────────────
function bloquearVendedorME(params) {
  if (!params || !params.nombre) return { ok: false, error: 'Requiere nombre' };
  var nombre = String(params.nombre).trim();
  var appOrigen = _normalizarApp(params.appOrigen || 'mosExpress');
  var bloquear = !!params.bloquear;
  var bloqueadoPor = String(params.bloqueadoPor || 'admin').trim();

  var lock = LockService.getScriptLock();
  try { lock.tryLock(15000); } catch(e) {}
  try {
    var sheet = _garantizarHojaBloqueos();
    var data = sheet.getDataRange().getValues();
    var hdrs = data[0];
    var iId  = hdrs.indexOf('idPersonal');
    var iNom = hdrs.indexOf('nombre');
    var iApp = hdrs.indexOf('appOrigen');
    var iMot = hdrs.indexOf('motivo');
    var iBp  = hdrs.indexOf('bloqueadoPor');
    var iFB  = hdrs.indexOf('fechaBloqueo');
    var iUnl = hdrs.indexOf('unlockHasta');
    var iDes = hdrs.indexOf('desbloqueadoPor');

    var foundRow = -1;
    var nombreNorm = _normalizarNombre(nombre);
    for (var r = 1; r < data.length; r++) {
      var matchNom = _normalizarNombre(data[r][iNom]) === nombreNorm;
      var matchApp = _normalizarApp(data[r][iApp]) === appOrigen;
      if (matchNom && matchApp) { foundRow = r + 1; break; }
    }

    if (bloquear) {
      var ahora = new Date();
      var idPersonalParam = String(params.idPersonal || '').trim();
      if (foundRow > 0) {
        sheet.getRange(foundRow, iFB + 1).setValue(ahora);
        sheet.getRange(foundRow, iBp + 1).setValue(bloqueadoPor);
        sheet.getRange(foundRow, iMot + 1).setValue(params.motivo || 'bloqueo_admin');
        sheet.getRange(foundRow, iUnl + 1).setValue(0);
        sheet.getRange(foundRow, iDes + 1).setValue('');
        // Si nos pasan idPersonal y la fila existente no lo tenía, completarlo (para que WH polling matchee)
        if (idPersonalParam && !data[foundRow - 1][iId]) {
          sheet.getRange(foundRow, iId + 1).setValue(idPersonalParam);
        }
      } else {
        var fila = new Array(BLOQUEOS_HEADERS.length).fill('');
        fila[hdrs.indexOf('idBloqueo')] = _generateId('BLO');
        fila[iId]  = idPersonalParam;
        fila[iNom] = nombre;
        fila[iApp] = appOrigen;
        fila[iMot] = params.motivo || 'bloqueo_admin';
        fila[iBp]  = bloqueadoPor;
        fila[iFB]  = ahora;
        fila[iUnl] = 0;
        fila[iDes] = '';
        sheet.appendRow(fila);
      }
      // Auditoría
      try {
        var audSheet = _garantizarHojaAuditoria();
        audSheet.appendRow([
          _generateId('AUD'), ahora, 'BLOQUEAR_VENDEDOR_ME',
          nombre, '', bloqueadoPor, appOrigen, '', 'Toggle apagado desde panel MOS'
        ]);
      } catch(e) {}
      return { ok: true, data: { bloqueado: true, nombre: nombre } };
    } else {
      // Desbloquear — limpiar fechaBloqueo y unlockHasta
      if (foundRow > 0) {
        sheet.getRange(foundRow, iFB + 1).setValue('');
        sheet.getRange(foundRow, iUnl + 1).setValue(0);
        sheet.getRange(foundRow, iDes + 1).setValue(bloqueadoPor + ' (reactivado)');
      }
      try {
        var audSheet2 = _garantizarHojaAuditoria();
        audSheet2.appendRow([
          _generateId('AUD'), new Date(), 'ACTIVAR_VENDEDOR_ME',
          nombre, '', bloqueadoPor, appOrigen, '', 'Toggle encendido desde panel MOS'
        ]);
      } catch(e) {}
      return { ok: true, data: { bloqueado: false, nombre: nombre } };
    }
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

// Lista todos los vendedores ME con bloqueo manual (fechaBloqueo seteada)
function getVendedoresMEBloqueados(params) {
  var sheet = _garantizarHojaBloqueos();
  var rows = _sheetToObjects(sheet);
  var ahora = new Date().getTime();
  rows = rows
    .filter(function(r) {
      return _normalizarApp(r.appOrigen) === 'mosexpress' && r.fechaBloqueo;
    })
    .map(function(r) {
      var unl = parseInt(r.unlockHasta, 10) || 0;
      r.unlockVigente = unl > ahora;
      r.msRestantes = r.unlockVigente ? (unl - ahora) : 0;
      return r;
    });
  return { ok: true, data: rows };
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

  // Validación unificada — clave de 8 dígitos: ADMIN_GLOBAL_PIN + PIN admin
  var verif = verificarClaveAdmin({
    clave: clave,
    accion: 'DESBLOQUEO_USUARIO',
    refDocumento: (params.nombre || params.idPersonal || ''),
    appOrigen: params.appOrigen || '',
    detalle: 'Desbloqueo temporal 15 min'
  });
  if (!verif.ok || !verif.data || !verif.data.autorizado) {
    return { ok: true, data: { autorizado: false, error: (verif.data && verif.data.error) || 'Clave incorrecta' } };
  }
  var validadoPor = verif.data.validadoPor;

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

// ════════════════════════════════════════════════════════════════════════
// BLOQUEO POR DISPOSITIVO (UUID) — encarcela el aparato, no el usuario
// ════════════════════════════════════════════════════════════════════════
// Filosofía: el admin clickea 🔒 en card de "Orlando" → buscamos TODOS los
// dispositivos donde Orlando está logueado/asociado y los pasamos a Estado
// BLOQUEADO. La app hija (ME/WH) polea consultarEstadoDispositivo con su
// UUID y al recibir BLOQUEADO muestra pantalla de candado.
//
// Si Orlando borra cache → nuevo UUID → cae como PENDIENTE_APROBACION y
// admin+master tienen que aprobarlo in situ.

// Bloquea todos los dispositivos asociados al nombre del usuario.
// params: { nombre, appOrigen, bloqueadoPor, motivo }
function bloquearDispositivosDeUsuario(params) {
  if (!params || !params.nombre) return { ok: false, error: 'Requiere nombre' };
  var nombre = String(params.nombre).trim();
  var nombreNorm = nombre.toLowerCase();
  var appOrigen = _normalizarApp(params.appOrigen || '');
  var bloqueadoPor = String(params.bloqueadoPor || 'admin').trim();
  var motivo = String(params.motivo || 'bloqueo_desde_personal_dia');

  var sheet = getSheet('DISPOSITIVOS');
  var data = sheet.getDataRange().getValues();
  var hdrs = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iEst  = hdrs.indexOf('Estado');
  var iApp  = hdrs.indexOf('App');
  var iSes  = hdrs.indexOf('Ultima_Sesion');
  var iNomE = hdrs.indexOf('Nombre_Equipo');
  if (iId < 0 || iEst < 0 || iSes < 0) {
    return { ok: false, error: 'DISPOSITIVOS sin columnas requeridas' };
  }

  var bloqueados = [];
  var ahora = new Date();
  for (var r = 1; r < data.length; r++) {
    var sesion = String(data[r][iSes] || '').toLowerCase().trim();
    if (!sesion) continue;
    // Match flexible: igual o contiene (tolera "javier " vs "javier")
    if (sesion !== nombreNorm && sesion.indexOf(nombreNorm) < 0 && nombreNorm.indexOf(sesion) < 0) continue;
    if (appOrigen && iApp >= 0) {
      var appRow = _normalizarApp(data[r][iApp]);
      if (appRow !== appOrigen) continue;
    }
    var estadoActual = String(data[r][iEst] || '').toUpperCase();
    // No re-bloquear lo ya bloqueado/inactivo
    if (estadoActual === 'INACTIVO') continue;
    var deviceId = String(data[r][iId] || '');
    if (!deviceId) continue;

    // Reusa estado INACTIVO existente — ME/WH ya reaccionan a ese estado
    // mostrando pantalla candado. Diferenciamos "encarcelado por usuario"
    // de "revocado permanente" via fila en BLOQUEOS_USUARIO con motivo
    // 'DEVICE: ...' (sólo esos se pueden liberar via liberarDispositivoBloqueado).
    sheet.getRange(r + 1, iEst + 1).setValue('INACTIVO');
    // [FASE 4.1] espejo instantáneo a la sombra (bloqueo por usuario → INACTIVO). best-effort.
    if (typeof _dualWriteDispositivo === 'function') _dualWriteDispositivo(deviceId, { Estado: 'INACTIVO', Razon_Bloqueo: 'DEVICE: ' + motivo, Bloqueado_Desde: ahora });
    bloqueados.push({
      deviceId: deviceId,
      nombreEquipo: iNomE >= 0 ? String(data[r][iNomE] || '') : '',
      estadoAnterior: estadoActual
    });

    // Auditar en BLOQUEOS_USUARIO (una fila por device bloqueado)
    try {
      var bSheet = _garantizarHojaBloqueos();
      var bHdrs = bSheet.getRange(1, 1, 1, bSheet.getLastColumn()).getValues()[0];
      var fila = new Array(BLOQUEOS_HEADERS.length).fill('');
      fila[bHdrs.indexOf('idBloqueo')]    = _generateId('BLO');
      fila[bHdrs.indexOf('idPersonal')]   = deviceId; // usamos col para guardar deviceId
      fila[bHdrs.indexOf('nombre')]       = nombre;
      fila[bHdrs.indexOf('appOrigen')]    = appOrigen || (iApp >= 0 ? String(data[r][iApp] || '') : '');
      fila[bHdrs.indexOf('motivo')]       = 'DEVICE: ' + motivo;
      fila[bHdrs.indexOf('bloqueadoPor')] = bloqueadoPor;
      fila[bHdrs.indexOf('fechaBloqueo')] = ahora;
      fila[bHdrs.indexOf('unlockHasta')]  = 0;
      fila[bHdrs.indexOf('desbloqueadoPor')] = '';
      bSheet.appendRow(fila);
    } catch(eA) { Logger.log('Audit bloqueo device falló: ' + eA.message); }
  }

  // Auditoría general en hoja AUDITORIA
  try {
    var audSheet = _garantizarHojaAuditoria();
    audSheet.appendRow([
      _generateId('AUD'), ahora, 'BLOQUEAR_DISPOSITIVOS_USUARIO',
      nombre, '', bloqueadoPor, appOrigen, '',
      'Bloqueados ' + bloqueados.length + ' dispositivo(s): ' +
        bloqueados.map(function(b){ return b.deviceId; }).join(', ')
    ]);
  } catch(e) {}

  return {
    ok: true,
    data: {
      nombre: nombre,
      cantidad: bloqueados.length,
      bloqueados: bloqueados
    }
  };
}

// Libera un dispositivo bloqueado. Requiere clave admin/master de 8 dígitos.
// params: { deviceId, claveAdmin, motivo? }
function liberarDispositivoBloqueado(params) {
  if (!params || !params.deviceId) return { ok: false, error: 'Requiere deviceId' };
  if (!params.claveAdmin) return { ok: false, error: 'Requiere claveAdmin' };

  var auth = verificarClaveAdmin({
    clave: params.claveAdmin,
    accion: 'LIBERAR_DISPOSITIVO_BLOQUEADO',
    refDocumento: params.deviceId,
    appOrigen: params.app || '',
    detalle: params.motivo || 'Liberar dispositivo bloqueado'
  });
  if (!auth.ok) return auth;
  if (!auth.data || !auth.data.autorizado) {
    return { ok: true, data: { autorizado: false, error: auth.data?.error || 'Clave incorrecta' } };
  }

  var sheet = getSheet('DISPOSITIVOS');
  var data = sheet.getDataRange().getValues();
  var hdrs = data[0];
  var iId  = hdrs.indexOf('ID_Dispositivo');
  var iEst = hdrs.indexOf('Estado');
  var iNomE = hdrs.indexOf('Nombre_Equipo');
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iId]) !== String(params.deviceId)) continue;
    var estadoActual = String(data[i][iEst] || '').toUpperCase();
    if (estadoActual !== 'INACTIVO') {
      return { ok: true, data: { autorizado: true, ok: false, error: 'Estado actual: ' + estadoActual + ' (no estaba INACTIVO)' } };
    }
    // Solo liberable si fue encarcelado por flujo DEVICE (no si fue revocado
    // permanentemente por otro motivo). Verificar en BLOQUEOS_USUARIO.
    var esDeviceBloqueo = false;
    try {
      var bSheetChk = _garantizarHojaBloqueos();
      var bDataChk = bSheetChk.getDataRange().getValues();
      var bHdrsChk = bDataChk[0];
      var bIdPChk  = bHdrsChk.indexOf('idPersonal');
      var bMotChk  = bHdrsChk.indexOf('motivo');
      var bFBChk   = bHdrsChk.indexOf('fechaBloqueo');
      for (var brc = 1; brc < bDataChk.length; brc++) {
        if (String(bDataChk[brc][bIdPChk]) === String(params.deviceId)
            && bDataChk[brc][bFBChk]
            && String(bDataChk[brc][bMotChk] || '').indexOf('DEVICE:') === 0) {
          esDeviceBloqueo = true;
          break;
        }
      }
    } catch(_) {}
    if (!esDeviceBloqueo) {
      return { ok: true, data: { autorizado: true, ok: false, error: 'Este dispositivo fue revocado por otra vía. Usá el panel de dispositivos para reactivarlo.' } };
    }
    sheet.getRange(i + 1, iEst + 1).setValue('ACTIVO');
    // [FASE 4.1] espejo instantáneo a la sombra (liberación → ACTIVO). best-effort.
    if (typeof _dualWriteDispositivo === 'function') _dualWriteDispositivo(params.deviceId, { Estado: 'ACTIVO', Razon_Bloqueo: '', Bloqueado_Desde: '' });

    // Marcar fila(s) en BLOQUEOS_USUARIO como liberadas
    try {
      var bSheet = _garantizarHojaBloqueos();
      var bData = bSheet.getDataRange().getValues();
      var bHdrs = bData[0];
      var bIdP  = bHdrs.indexOf('idPersonal'); // contiene deviceId para bloqueos por device
      var bDes  = bHdrs.indexOf('desbloqueadoPor');
      var bFB   = bHdrs.indexOf('fechaBloqueo');
      for (var br = 1; br < bData.length; br++) {
        if (String(bData[br][bIdP]) === String(params.deviceId) && bData[br][bFB]) {
          bSheet.getRange(br + 1, bDes + 1).setValue(auth.data.validadoPor + ' @ ' + new Date().toISOString());
          bSheet.getRange(br + 1, bFB + 1).setValue('');
        }
      }
    } catch(eL) {}

    return {
      ok: true,
      data: {
        autorizado: true,
        deviceId: params.deviceId,
        nombreEquipo: iNomE >= 0 ? String(data[i][iNomE] || '') : '',
        liberadoPor: auth.data.validadoPor
      }
    };
  }
  return { ok: false, error: 'Dispositivo no encontrado: ' + params.deviceId };
}

// Lista dispositivos bloqueados, opcionalmente agrupados por nombre de usuario.
// Frontend de Finanzas lo usa para pintar el overlay de rejas en cards.
// params: { agruparPorNombre?: bool }
function getDispositivosBloqueados(params) {
  // 1. Set de deviceIds que fueron encarcelados por flujo DEVICE (sospecha
  //    de usuario). Excluye revocaciones permanentes hechas desde panel.
  var deviceBloqueadosSet = {};
  try {
    var bSheet = _garantizarHojaBloqueos();
    var bData = bSheet.getDataRange().getValues();
    if (bData.length > 1) {
      var bHdrs = bData[0];
      var bIdP  = bHdrs.indexOf('idPersonal');
      var bMot  = bHdrs.indexOf('motivo');
      var bFB   = bHdrs.indexOf('fechaBloqueo');
      var bNom  = bHdrs.indexOf('nombre');
      var bBp   = bHdrs.indexOf('bloqueadoPor');
      for (var br = 1; br < bData.length; br++) {
        if (!bData[br][bFB]) continue; // ya liberado
        if (String(bData[br][bMot] || '').indexOf('DEVICE:') !== 0) continue;
        var did = String(bData[br][bIdP] || '');
        if (did) {
          deviceBloqueadosSet[did] = {
            nombre:       String(bData[br][bNom] || ''),
            bloqueadoPor: String(bData[br][bBp] || ''),
            fechaBloqueo: bData[br][bFB]
          };
        }
      }
    }
  } catch(_) {}

  // 2. Cruzar con DISPOSITIVOS para enriquecer con nombre de equipo / app
  var sheet = getSheet('DISPOSITIVOS');
  var data = sheet.getDataRange().getValues();
  var hdrs = data[0];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iEst  = hdrs.indexOf('Estado');
  var iApp  = hdrs.indexOf('App');
  var iSes  = hdrs.indexOf('Ultima_Sesion');
  var iNomE = hdrs.indexOf('Nombre_Equipo');

  var bloqueados = [];
  for (var r = 1; r < data.length; r++) {
    var did2 = String(data[r][iId] || '');
    if (!deviceBloqueadosSet[did2]) continue;
    var est = String(data[r][iEst] || '').toUpperCase();
    if (est !== 'INACTIVO') continue; // si ya no está INACTIVO ignorar (out of sync)
    var meta = deviceBloqueadosSet[did2];
    bloqueados.push({
      deviceId:     did2,
      nombreEquipo: iNomE >= 0 ? String(data[r][iNomE] || '') : '',
      app:          iApp  >= 0 ? String(data[r][iApp]  || '') : '',
      ultimaSesion: iSes  >= 0 ? String(data[r][iSes]  || '') : '',
      nombreUsuario: meta.nombre,
      bloqueadoPor: meta.bloqueadoPor,
      fechaBloqueo: meta.fechaBloqueo
    });
  }

  if (params && params.agruparPorNombre) {
    var byNombre = {};
    bloqueados.forEach(function(b){
      var k = String(b.nombreUsuario || b.ultimaSesion || '').toLowerCase().trim();
      if (!k) return;
      if (!byNombre[k]) byNombre[k] = { nombre: b.nombreUsuario || b.ultimaSesion, dispositivos: [] };
      byNombre[k].dispositivos.push(b);
    });
    return { ok: true, data: { lista: bloqueados, porNombre: byNombre } };
  }
  return { ok: true, data: bloqueados };
}
