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

// [CERO-GAS · 2026-07-13] ELIMINADOS por huérfanos tras centralizar la clave en Supabase:
//   ROTACION_DIAS, _generar4Digitos, _garantizarClaveGlobal (la rotación/seed vive en pg_cron + SQL 432).

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
  // [v2.43.172 R6] Cancelacion automatica de solicitudes PENDIENTE viejas
  'CANCELACION_AUTO_PENDIENTE':   { tier: 1, label: 'Auto-cancelar solicitud pendiente >20h' },
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
  // [v2.43.183] Extensión de horario in-situ por dispositivo (UUID).
  // Admin/master ingresa clave 8 dig + escoge tiempo (20m/1h/2h) → se guarda
  // en Desbloqueo_Temporal_Hasta del row del UUID en DISPOSITIVOS.
  'EXTENDER_HORARIO_DISPOSITIVO': { tier: 2, label: 'Extender horario in-situ por UUID' },
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

// [CERO-GAS · 2026-07-13] _buscarAdminPorPin + _diasDesde ELIMINADOS (huérfanos: la validación
// de PIN y el cálculo de días viven en Supabase — _validar_clave_admin_core + get_clave_admin_global).

// ────────────────────────────────────────────────────────────
// VERIFICAR CLAVE ADMIN — clave de 8 dígitos
// Retorna {ok, autorizado, validadoPor, idPersonal, nombre}
// ────────────────────────────────────────────────────────────
function verificarClaveAdmin(params) {
  if (!params || !params.clave) {
    return { ok: false, error: 'Requiere clave' };
  }
  var clave = String(params.clave).trim();
  if (clave.length !== 8 || !/^\d{8}$/.test(clave)) {
    return { ok: true, data: { autorizado: false, error: 'La clave debe ser de 8 dígitos numéricos' } };
  }

  // [CERO-GAS · CERO-CAÍDA · SQL 432/388] Fuente ÚNICA de verdad = Supabase bcrypt.
  // Antes comparaba el global contra el Sheet plano (ADMIN_GLOBAL_PIN) y el PIN personal
  // contra PERSONAL_MASTER (Sheet) → ambos quedaban STALE tras la rotación pg_cron y
  // desincronizaban (incidente 2026-07-13: Sheet 2715 vs hash verdadero). Ahora DELEGA a
  // mos.verificar_clave_admin_p: mismo hash sincronizado que MOS/ME/WH + cascada de rol +
  // lockout + auditoría server-side. FAIL-CLOSED: si Supabase no responde, NO autoriza
  // (jamás cae a validación local con datos viejos).
  var r;
  try {
    // mos.verificar_clave_admin_p(p jsonb) → los args van ENVUELTOS en {p:{...}} (no sueltos).
    r = _sbRpc('mos', 'verificar_clave_admin_p', { p: {
      clave: clave,
      accion: params.accion || 'GENERICA',
      ref: params.refDocumento || '',
      app: params.appOrigen || 'MOS',
      detalle: params.detalle || '',
      device: String(params.deviceId || ''),
      tier: (parseInt(params.tier, 10) || '')
    } });
  } catch(e) {
    return { ok: false, error: 'Verificación online no disponible (sin caída a GAS): ' + (e && e.message || e) };
  }
  if (!r || !r.ok || !r.data) {
    return { ok: false, error: (r && r.error) || 'Verificación online no disponible (sin caída a GAS)' };
  }
  var d = r.data;                       // { ok, autorizado, rol, nombre, id_personal, error? }
  if (d.ok === false) {
    return { ok: false, error: d.error || 'APP_NO_AUTORIZADA' };
  }
  if (!d.autorizado) {
    return { ok: true, data: { autorizado: false, error: d.error || 'Clave incorrecta' } };
  }

  var nombreCompleto = String(d.nombre || '').trim();
  var idPersonal     = d.id_personal || d.idPersonal || '';
  var rol            = String(d.rol || '').toUpperCase();

  // [v2.41.59] Push a admin/master cuando se autoriza (best-effort; la auditoría YA la
  // hizo Supabase en mos.auditoria_admin — no se duplica en el Sheet).
  try {
    if (typeof _enviarPushTodos === 'function') {
      var accionTxt = String(params.accion || 'ACCIÓN ADMIN').replace(/_/g, ' ');
      var partes = ['por ' + (nombreCompleto || 'admin')];
      if (params.refDocumento) partes.push(String(params.refDocumento));
      if (params.detalle)      partes.push(String(params.detalle));
      if (params.appOrigen)    partes.push('desde ' + params.appOrigen);
      _enviarPushTodos('🔐 ' + accionTxt, partes.join(' · '), {
        idNotif: 'MOS_ADMIN_AUTH',
        excluirUsuario: nombreCompleto
      });
    }
  } catch(eN) { /* push best-effort */ }

  return {
    ok: true,
    data: {
      autorizado: true,
      validadoPor: nombreCompleto ? ('admin:' + nombreCompleto) : 'admin',
      idPersonal: idPersonal,
      nombre: nombreCompleto,
      rol: rol   // expuesto para que callers validen admin vs master
    }
  };
}

// ────────────────────────────────────────────────────────────
// GET CLAVE ADMIN GLOBAL — para panel MOS
// Acceso: cualquier MASTER/ADMIN activo (autentica por su pin4)
// ────────────────────────────────────────────────────────────
function getClaveAdminGlobal(params) {
  // [CERO-GAS · SQL 432] PROXY puro a Supabase mos.get_clave_admin_global. Antes leía el
  // PIN plano del Sheet (ADMIN_GLOBAL_PIN) → tras la rotación pg_cron quedaba STALE y servía
  // un PIN incorrecto. Ahora delega a la fuente única de verdad (misma que verifica el bcrypt).
  // FAIL-CLOSED: sin Supabase no devuelve PIN.
  var pinSol = String((params && params.pinAdmin) || '').trim();
  if (!pinSol) return { ok: false, error: 'Requiere pinAdmin (PIN del solicitante)' };
  try {
    var r = _sbRpc('mos', 'get_clave_admin_global', { p: { pinAdmin: pinSol } });
    if (!r || !r.ok || !r.data) return { ok: false, error: (r && r.error) || 'No disponible (sin caída a GAS)' };
    var d = r.data;                                  // { ok, data:{autorizado, pin, dias...} } ó jsonb directo
    var data = (d.data && typeof d.data === 'object') ? d.data : d;
    if (data.ok === false) return { ok: false, error: data.error || 'No autorizado' };
    return { ok: true, data: data };
  } catch (e) {
    return { ok: false, error: 'No disponible (sin caída a GAS): ' + (e && e.message || e) };
  }
}

// ────────────────────────────────────────────────────────────
// ROTAR CLAVE ADMIN GLOBAL — manual o auto (trigger)
// ────────────────────────────────────────────────────────────
function rotarClaveAdminGlobal(params) {
  // [CERO-GAS · SQL 432] DEPRECADO. Rotar la clave global ahora es EXCLUSIVO de
  // Supabase mos.rotar_clave_admin (escribe plano + bcrypt + fecha atómicamente y
  // setea el GUC que el guard mos._guard_global_pin exige). El frontend ya rutea
  // 'rotarClaveAdminGlobal' → RPC Supabase (api.js _MOS_ADMIN_RPC). Esta versión GAS
  // escribía el plano SIN el hash → causaba el desync del incidente 2026-07-13.
  // No escribe ni notifica; solo devuelve deprecación para no romper llamadores viejos.
  return { ok: false, error: 'DEPRECADO_USAR_SUPABASE', data: { autorizado: false,
    motivo: 'rotar_clave_admin (Supabase) es el único escritor autorizado — SQL 432' } };
}

// ────────────────────────────────────────────────────────────
// CACHE OFFLINE — ME/WH descargan globalPin + lista admins
// ────────────────────────────────────────────────────────────
function getAdminPinsCache(params) {
  // [G4 online-only · 2026-06-27] DEPRECADO. Este endpoint exponía PINs admin en TEXTO PLANO al navegador
  // (cache offline). Decisión: la verificación de clave admin es SIEMPRE online (verificarClaveAdmin →
  // bcrypt + lockout + auditoría server-side). WH 2.13.365 y ME 2.8.96 ya NO lo llaman (validan online o
  // bloquean sin conexión). Se neutraliza para cerrar la exposición del endpoint abierto. NO reintroducir
  // sin hashear/rediseñar (un PIN de 4 díg no se puede proteger offline).
  return { ok: false, error: 'DEPRECADO_ONLINE_ONLY', data: null };
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
  // [CERO-GAS · SQL 432] DEPRECADO. La rotación automática de la clave admin global
  // ahora vive 100% en Supabase (pg_cron job 'mos-rotacion-clave-global' →
  // mos.rotar_clave_admin_si_vence, que re-hashea las 3 llaves atómicamente).
  // Esta función GAS escribía SOLO el texto plano + fecha (NUNCA el hash) → desincronizaba
  // el verificador y dejaba el PIN viejo válido para siempre (incidente 2026-07-13).
  // Se neutraliza. Un guard a nivel tabla (mos._guard_global_pin) ya ignora en silencio
  // cualquier escritura GAS a ADMIN_GLOBAL_PIN*, pero mejor no dispararla.
  // ACCIÓN PENDIENTE: borrar el time-trigger de Apps Script que apunta a esta función.
  Logger.log('verificarRotacionAuto DEPRECADO — rotación en pg_cron (SQL 432). No-op.');
  return { ok: true, data: { deprecado: true, motivo: 'rotacion en pg_cron SQL 432' } };
}
