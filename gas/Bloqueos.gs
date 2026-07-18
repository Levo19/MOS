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
  // [CERO-HOJA shim 2026-07-17] Delega en la RPC Supabase mos.estado_bloqueo_usuario, que hace LO MISMO
  // (bloqueo + heartbeat dispositivo con auto-estacion WH + heartbeat personal) leyendo/escribiendo Supabase,
  // NO la hoja. Shape identico al viejo (verificado). Red para clientes ME/WH cacheados PRE-2026-07-03; los
  // clientes actuales ya llaman la RPC directo (cero-fallback). Borrable cuando la flota este en build nuevo.
  if (!params || (!params.nombre && !params.idPersonal)) {
    return { ok: false, error: 'Requiere nombre o idPersonal' };
  }
  try {
    var r = _sbRpc('mos', 'estado_bloqueo_usuario', { p: params });
    if (r && r.ok && r.data != null) return r.data;
  } catch (e) { Logger.log('[getEstadoBloqueoUsuario shim] ' + (e && e.message)); }
  // fail-SAFE: RPC no responde -> {ok:false} -> el cliente salta el tick y CONSERVA su ultimo estado.
  return { ok: false, error: 'estado_bloqueo temporalmente no disponible' };
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



