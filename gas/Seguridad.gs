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
  'dispositivo', 'detalle',
  // [v2.41.83] Columnas para AdminAuthModal universal — métricas y trazabilidad
  'tier',            // 1=rutina · 2=sensible · 3=critica
  'cache_hit',       // 1 si reutilizó caché, 0 si pidió clave
  'tiempo_verify_ms',// ms desde abrir modal a confirmación OK
  'deviceId',        // huella del dispositivo solicitante
  'cliente_meta'     // JSON con ip/userAgent/etc opcional
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
    return sheet;
  }
  // [v2.41.83] Migrar headers — agregar columnas nuevas si faltan
  var firstRow = sheet.getRange(1, 1, 1, Math.max(sheet.getLastColumn(), AUDITORIA_ADMIN_HEADERS.length)).getValues()[0];
  var current = firstRow.map(function(h){ return String(h || '').trim(); });
  var faltan = AUDITORIA_ADMIN_HEADERS.filter(function(h) { return current.indexOf(h) === -1; });
  if (faltan.length > 0) {
    var startCol = sheet.getLastColumn() + 1;
    sheet.getRange(1, startCol, 1, faltan.length).setValues([faltan]);
    sheet.getRange(1, startCol, 1, faltan.length)
         .setFontWeight('bold').setBackground('#1f2937').setFontColor('#fff');
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

// [v2.41.83] Catálogo de acciones admin con su TIER de sensibilidad.
//   Tier 1 = rutinaria (cache 10 min)
//   Tier 2 = sensible  (cache 5 min)
//   Tier 3 = crítica   (NUNCA cachea — clave fresca siempre)
// Si una acción no está aquí, default = tier 2 (conservador).
var _AUTH_CATALOGO = {
  // === MOS ===
  'ANULAR_PAGO':                  { tier: 2, label: 'Anular pago liquidación' },
  'VETAR_LIQUIDACION':            { tier: 2, label: 'Vetar liquidación día' },
  'DESVETAR_LIQUIDACION':         { tier: 1, label: 'Desvetar liquidación' },
  'BLOQUEAR_DISPOSITIVO':         { tier: 2, label: 'Bloquear dispositivo(s)' },
  'LIBERAR_DISPOSITIVO_BLOQUEADO':{ tier: 2, label: 'Liberar dispositivo' },
  'REVOCAR_DISPOSITIVO':          { tier: 3, label: 'Revocar dispositivo' },
  // [v2.43.167] Eventos faltantes para auditoria completa de seguridad de dispositivos
  'APROBAR_DISPOSITIVO_REMOTO':   { tier: 2, label: 'Aprobar dispositivo (panel)' },
  'APROBAR_DISPOSITIVO_INSITU_MOS':{ tier: 3, label: 'Aprobar MOS in-situ (master)' },
  'REACTIVAR_DISPOSITIVO_SUSPENDIDO':{ tier: 2, label: 'Reactivar dispositivo suspendido' },
  'FORZAR_REVERIFY_DISPOSITIVO':  { tier: 2, label: 'Forzar re-verificación dispositivo' },
  'FORZAR_WIZARD':                { tier: 2, label: 'Forzar wizard remoto' },
  'CIERRE_CAJA_FORZADO':          { tier: 3, label: 'Cierre forzado de caja' },
  'PURGAR_CATALOGO':              { tier: 3, label: 'Eliminar items del catálogo' },
  // === MosExpress ===
  'ANULACION':                    { tier: 1, label: 'Anular venta' },
  'CREDITO_DIRECTO':              { tier: 1, label: 'Crédito directo' },
  'CREDITAR_VENTA':               { tier: 1, label: 'Marcar como crédito' },
  'COBRAR_VENTA':                 { tier: 1, label: 'Cambiar método de pago' },
  'COBRAR_CREDITO_CON_EXTRA':     { tier: 1, label: 'Cobrar crédito (caja receptora)' },
  'CONVERTIR_NV_A_CPE':           { tier: 2, label: 'Convertir NV → CPE' },
  'BAJA_CPE':                     { tier: 3, label: 'Baja CPE a SUNAT' },
  'EDITAR_CLIENTE_VENTA':         { tier: 2, label: 'Editar cliente venta' },
  'ACTIVAR_POS_60':               { tier: 2, label: 'Activar POS 60 min' },
  'DESBLOQUEO_TEMPORAL':          { tier: 2, label: 'Desbloqueo temporal' },
  // === Warehouse ===
  'REABRIR_GUIA':                 { tier: 1, label: 'Reabrir guía cerrada' },
  'ANULAR_ENVASADO':              { tier: 2, label: 'Anular envasado' },
  'EDITAR_ENVASADO':              { tier: 1, label: 'Editar envasado' },
  'APROBAR_DISPOSITIVO_INSITU':   { tier: 2, label: 'Aprobar dispositivo' },
  'PROCESAR_MERMAS':              { tier: 2, label: 'Procesar mermas' },
  // === Centro Tributario (admin/master) ===
  'TRIBUTARIO_LIMPIAR_HUERFANAS': { tier: 2, label: 'Limpiar ventas huérfanas' },
  'TRIBUTARIO_RECONCILIAR_TODOS': { tier: 2, label: 'Reconciliar CPE con SUNAT' },
  'TRIBUTARIO_REINTENTAR_CPE':    { tier: 2, label: 'Reintentar CPE individual' },
  'TRIBUTARIO_REPROCESAR_OCR':    { tier: 1, label: 'Reprocesar OCR factura' },
  'TRIBUTARIO_OCR_MASIVO':        { tier: 2, label: 'OCR masivo del mes' }
};
function _inferirTierAccion(accion) {
  var x = _AUTH_CATALOGO[String(accion || '').toUpperCase()];
  return x ? x.tier : 2; // default conservador
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

  // Auditoría — registro en hoja AUDITORIA_ADMIN
  var nombreCompleto = (admin.nombre + ' ' + (admin.apellido || '')).trim();
  try {
    var sheet = _garantizarHojaAuditoria();
    // [v2.41.83] Determinar tier por defecto si no viene del cliente
    var tier = parseInt(params.tier, 10);
    if (!tier || tier < 1 || tier > 3) {
      tier = _inferirTierAccion(String(params.accion || ''));
    }
    var clienteMeta = '';
    try {
      if (params.cliente_meta) {
        clienteMeta = typeof params.cliente_meta === 'string'
          ? params.cliente_meta
          : JSON.stringify(params.cliente_meta);
      }
    } catch(_){}
    sheet.appendRow([
      _generateId('AUD'),
      new Date(),
      params.accion || 'GENERICA',
      params.refDocumento || '',
      admin.idPersonal,
      nombreCompleto,
      params.appOrigen || '',
      params.dispositivo || '',
      params.detalle || '',
      tier,
      params.cache_hit ? 1 : 0,
      parseInt(params.tiempo_verify_ms, 10) || 0,
      String(params.deviceId || ''),
      clienteMeta
    ]);
  } catch(e) { /* no bloquear validación si auditoría falla */ }

  // [v2.41.59] Push a admin/master cuando se autoriza acción con clave.
  // Usa idNotif='MOS_ADMIN_AUTH' del catálogo → respeta config (silencio,
  // audiencia, prioridad) + queda en NOTIFICACIONES_LOG con su idLog único.
  // Cubre TODO lo que pasa por verificarClaveAdmin: anular pago/venta,
  // desbloquear dispositivo, cierre forzado, etc.
  try {
    if (typeof _enviarPushTodos === 'function') {
      var accionTxt = String(params.accion || 'ACCIÓN ADMIN').replace(/_/g, ' ');
      var titulo = '🔐 ' + accionTxt;
      var partes = [];
      partes.push('por ' + nombreCompleto);
      if (params.refDocumento) partes.push(String(params.refDocumento));
      if (params.detalle)      partes.push(String(params.detalle));
      if (params.appOrigen)    partes.push('desde ' + params.appOrigen);
      var cuerpo = partes.join(' · ');
      _enviarPushTodos(titulo, cuerpo, {
        idNotif: 'MOS_ADMIN_AUTH',
        excluirUsuario: nombreCompleto  // el mismo admin que ejecutó no se auto-notifica
      });
    }
  } catch(eN) { /* push best-effort */ }

  return {
    ok: true,
    data: {
      autorizado: true,
      validadoPor: 'admin:' + nombreCompleto,
      idPersonal: admin.idPersonal,
      nombre: nombreCompleto,
      rol: String(admin.rol || '').toUpperCase()  // expuesto para que callers
                                                   // puedan validar admin vs master
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
// [v2.41.83] Catálogo de acciones admin para AdminAuthModal universal.
// El frontend lo lee para mostrar el label correcto + saber el tier
// (y decidir si cachear la autorización).
// ────────────────────────────────────────────────────────────
function getAuthCatalogo() {
  var out = {};
  Object.keys(_AUTH_CATALOGO).forEach(function(k) {
    out[k] = { tier: _AUTH_CATALOGO[k].tier, label: _AUTH_CATALOGO[k].label };
  });
  return { ok: true, data: out };
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
