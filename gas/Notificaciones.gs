// ============================================================
// ProyectoMOS — Notificaciones.gs
// Catálogo configurable de notificaciones push del ecosistema
// (MOS + MosExpress + warehouseMos). Permite al master:
//   - Encender/apagar cada tipo de notificación
//   - Elegir audiencia por rol y/o usuarios específicos
//   - Silenciar temporalmente con preset (hasta hora, mañana, etc.)
//   - Ajustar prioridad (baja/normal/alta)
//   - Ver historial + reenviar
//
// Hojas:
//   - NOTIFICACIONES_CONFIG  (catálogo + reglas)
//   - NOTIFICACIONES_LOG     (historial)
// ============================================================

var _NTF_CFG_SHEET = 'NOTIFICACIONES_CONFIG';
var _NTF_LOG_SHEET = 'NOTIFICACIONES_LOG';

var _NTF_CFG_HDRS = [
  'idNotif', 'origen', 'titulo', 'descripcion', 'icono',
  'activa', 'audiencia_roles', 'audiencia_usuarios',
  'excluir_origen', 'prioridad', 'silenciada_hasta', 'sonido_custom',
  'ts_actualizado', 'actualizado_por'
];

var _NTF_LOG_HDRS = [
  'idLog', 'ts', 'idNotif', 'titulo', 'cuerpo',
  'audiencia_resuelta', 'destinatarios_count', 'entregadas', 'errores',
  'originadoPor', 'meta_json', 'estado'
];

// ── Catálogo predefinido (15 entries) ─────────────────────
// Audiencia default basada en cómo se llamaba antes:
//   soloRolesAdmin: true → 'MASTER,ADMIN,ADMINISTRADOR'
//   soloRolesMaster: true → 'MASTER'
//   (sin filtro) → todos
function _ntfCatalogoDefault() {
  return [
    // ── MOS ───────────────────────────────────────────────
    { idNotif: 'MOS_LIQUIDACION_LISTA',  origen: 'MOS', icono: '💰',
      titulo: 'Liquidación semanal lista',
      descripcion: 'Disparada los domingos 8pm (trigger automático). Recordatorio de pago del personal.',
      activa: true, audiencia_roles: 'MASTER,ADMIN,ADMINISTRADOR', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'normal' },
    { idNotif: 'MOS_DEVICE_PENDIENTE',   origen: 'MOS', icono: '🔔',
      titulo: 'Nuevo dispositivo solicita acceso',
      descripcion: 'Un device nuevo se conectó a MosExpress o warehouseMos y queda pendiente de aprobación.',
      activa: true, audiencia_roles: 'MASTER', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'alta' },
    { idNotif: 'MOS_DEVICE_APROBADO',    origen: 'MOS', icono: '✅',
      titulo: 'Dispositivo aprobado',
      descripcion: 'Confirmación cuando un admin/master aprueba un device (panel o in-situ).',
      activa: true, audiencia_roles: 'MASTER,ADMIN,ADMINISTRADOR', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'normal' },
    { idNotif: 'MOS_LOGIN_VENDEDOR',     origen: 'MOS', icono: '🛍',
      titulo: 'Vendedor / operador inició sesión',
      descripcion: 'Vendedor (ME sin abrir caja) u operador (WH) inicia sesión. Cuando es CAJERO y va a abrir caja, esta push NO se dispara — la cubre la de "Apertura de caja".',
      activa: true, audiencia_roles: 'MASTER,ADMIN', audiencia_usuarios: '',
      excluir_origen: true, prioridad: 'normal' },
    { idNotif: 'MOS_GPS_SIN_SENAL',      origen: 'MOS', icono: '📡',
      titulo: 'GPS sin señal',
      descripcion: 'Un dispositivo dejó de reportar GPS por mucho tiempo.',
      activa: true, audiencia_roles: 'MASTER', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'alta' },
    { idNotif: 'MOS_TEST',               origen: 'MOS', icono: '🔔',
      titulo: 'Test MOS',
      descripcion: 'Notificación de prueba manual desde el panel.',
      activa: true, audiencia_roles: '', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'normal' },
    { idNotif: 'MOS_GENERICO',           origen: 'MOS', icono: '📨',
      titulo: 'Notificación genérica',
      descripcion: 'Push enviada via enviarPushUsuario (custom desde el panel).',
      activa: true, audiencia_roles: '', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'normal' },

    // ── MosExpress ─────────────────────────────────────────
    { idNotif: 'ME_CAJA_APERTURA',       origen: 'ME',  icono: '🛒',
      titulo: 'Apertura de caja',
      descripcion: 'Cuando un cajero aperturar caja en MosExpress.',
      activa: true, audiencia_roles: 'MASTER,ADMIN,ADMINISTRADOR', audiencia_usuarios: '',
      excluir_origen: true, prioridad: 'baja' },
    { idNotif: 'ME_CAJA_CIERRE',         origen: 'ME',  icono: '🔐',
      titulo: 'Cierre de caja',
      descripcion: 'Cuando un cajero cierra caja.',
      activa: true, audiencia_roles: 'MASTER,ADMIN,ADMINISTRADOR', audiencia_usuarios: '',
      excluir_origen: true, prioridad: 'normal' },
    { idNotif: 'ME_RECOGER_EFECTIVO',    origen: 'ME',  icono: '💰',
      titulo: 'Recoger efectivo (umbral)',
      descripcion: 'Caja supera S/500 / S/750 / S/1000 → aviso para recoger.',
      activa: true, audiencia_roles: 'MASTER,ADMIN,ADMINISTRADOR', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'alta' },

    // ── warehouseMos ───────────────────────────────────────
    { idNotif: 'WH_OPERADOR_LOGIN',      origen: 'WH',  icono: '👤',
      titulo: 'Operador ingresó al almacén',
      descripcion: 'Operador inicia sesión en warehouseMos.',
      activa: true, audiencia_roles: 'MASTER,ADMIN,ADMINISTRADOR', audiencia_usuarios: '',
      excluir_origen: true, prioridad: 'baja' },
    { idNotif: 'WH_PRODUCTO_NUEVO',      origen: 'WH',  icono: '🆕',
      titulo: 'Producto nuevo pendiente',
      descripcion: 'Operador agrega Producto Nuevo (PN) que necesita aprobación/precio.',
      activa: true, audiencia_roles: 'MASTER,ADMIN,ADMINISTRADOR', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'normal' },
    { idNotif: 'WH_MERMA_REGISTRADA',    origen: 'WH',  icono: '⚠',
      titulo: 'Merma registrada',
      descripcion: 'Operador registra una merma EN_PROCESO.',
      activa: true, audiencia_roles: 'MASTER,ADMIN,ADMINISTRADOR', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'normal' },
    { idNotif: 'WH_MERMA_DESECHO',       origen: 'WH',  icono: '🗑',
      titulo: 'Desecho de mermas',
      descripcion: 'Admin/operador procesa desecho de mermas con guía.',
      activa: true, audiencia_roles: 'MASTER,ADMIN,ADMINISTRADOR', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'baja' },
    { idNotif: 'WH_PREINGRESO',          origen: 'WH',  icono: '📦',
      titulo: 'Nuevo preingreso',
      descripcion: 'Operador registra preingreso de mercadería.',
      activa: true, audiencia_roles: 'MASTER,ADMIN,ADMINISTRADOR', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'normal' },

    // ── Etiquetas (membretes de cambio de precio) ─────────
    { idNotif: 'MOS_ETIQUETA_NUEVA',     origen: 'MOS', icono: '🏷',
      titulo: 'Nueva etiqueta de precio',
      descripcion: 'Admin cambió un precio. Push a cajeros/vendedores activos para revisar el badge y pegar la etiqueta nueva.',
      activa: true, audiencia_roles: 'CAJERO,VENDEDOR', audiencia_usuarios: '',
      excluir_origen: true, prioridad: 'normal' },
    { idNotif: 'MOS_ETIQUETA_REVISAR',   origen: 'MOS', icono: '⚠',
      titulo: 'Etiquetas sin revisar (>2h)',
      descripcion: 'Cron horario: recuerda al cajero/vendedor que hay etiquetas sin marcar como vistas hace más de 2 horas.',
      activa: true, audiencia_roles: 'CAJERO,VENDEDOR', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'alta' },
    { idNotif: 'MOS_ETIQUETA_SIN_PEGAR_ADMIN', origen: 'MOS', icono: '🚨',
      titulo: 'Zona no actualiza etiquetas (>4h)',
      descripcion: 'Escalación al admin/master cuando una zona dejó etiquetas impresas sin pegar por más de 4 horas.',
      activa: true, audiencia_roles: 'MASTER,ADMIN', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'alta' },
    { idNotif: 'MOS_IMPRESORA_OFFLINE', origen: 'MOS', icono: '🖨',
      titulo: 'Impresora(s) offline',
      descripcion: 'Se detectó una o más impresoras del ecosistema apagadas o con la PC desconectada. Se dispara cuando alguien inicia sesión / abre caja y al heartbeat de zonas activas. Con anti-spam (no repite la misma caída antes de 30 min).',
      activa: true, audiencia_roles: 'MASTER,ADMIN,ADMINISTRADOR', audiencia_usuarios: '',
      excluir_origen: false, prioridad: 'alta' }
  ];
}

// ── Setup de hojas ────────────────────────────────────────
function _ntfGetCfgSheet() {
  var ss = getSpreadsheet();
  var sh = ss.getSheetByName(_NTF_CFG_SHEET);
  if (!sh) {
    sh = ss.insertSheet(_NTF_CFG_SHEET);
    sh.getRange(1, 1, 1, _NTF_CFG_HDRS.length).setValues([_NTF_CFG_HDRS]);
    sh.getRange(1, 1, 1, _NTF_CFG_HDRS.length)
      .setBackground('#7c3aed').setFontColor('#fff').setFontWeight('bold').setFontSize(10);
    sh.setFrozenRows(1);
    _ntfSeedCatalogo(sh);
  } else {
    // Re-seed si faltan entradas (al añadir nuevas notificaciones al ecosistema)
    _ntfSeedCatalogo(sh);
  }
  return sh;
}

function _ntfGetLogSheet() {
  var ss = getSpreadsheet();
  var sh = ss.getSheetByName(_NTF_LOG_SHEET);
  if (!sh) {
    sh = ss.insertSheet(_NTF_LOG_SHEET);
    sh.getRange(1, 1, 1, _NTF_LOG_HDRS.length).setValues([_NTF_LOG_HDRS]);
    sh.getRange(1, 1, 1, _NTF_LOG_HDRS.length)
      .setBackground('#1e3a8a').setFontColor('#fff').setFontWeight('bold').setFontSize(10);
    sh.setFrozenRows(1);
  }
  return sh;
}

// Inserta cualquier entrada del catálogo que falte. Las existentes NO se sobrescriben.
function _ntfSeedCatalogo(sh) {
  var cat = _ntfCatalogoDefault();
  var data = sh.getDataRange().getValues();
  var existing = {};
  for (var i = 1; i < data.length; i++) existing[String(data[i][0])] = true;
  var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
  cat.forEach(function(c) {
    if (existing[c.idNotif]) return;
    sh.appendRow([
      c.idNotif, c.origen, c.titulo, c.descripcion, c.icono,
      !!c.activa, c.audiencia_roles || '', c.audiencia_usuarios || '',
      !!c.excluir_origen, c.prioridad || 'normal', '', '',
      nowStr, 'system'
    ]);
  });
}

// ── API: GET ──────────────────────────────────────────────
function getNotificacionesConfig() {
  var sh = _ntfGetCfgSheet();
  var rows = _sheetToObjects(sh);
  // Normalizar booleanos
  rows.forEach(function(r) {
    r.activa = String(r.activa).toLowerCase() === 'true' || r.activa === true;
    r.excluir_origen = String(r.excluir_origen).toLowerCase() === 'true' || r.excluir_origen === true;
  });
  return { ok: true, data: rows };
}

// Obtener una sola config por id
function _ntfGetById(idNotif) {
  var sh = _ntfGetCfgSheet();
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === String(idNotif)) {
      var obj = {};
      hdrs.forEach(function(h, ix) { obj[h] = data[i][ix]; });
      obj._rowIdx = i + 1;
      obj.activa = String(obj.activa).toLowerCase() === 'true' || obj.activa === true;
      obj.excluir_origen = String(obj.excluir_origen).toLowerCase() === 'true' || obj.excluir_origen === true;
      return obj;
    }
  }
  return null;
}

// ── API: UPDATE ───────────────────────────────────────────
// Params: { idNotif, activa, audiencia_roles, audiencia_usuarios,
//           excluir_origen, prioridad, silenciada_hasta, sonido_custom,
//           actualizado_por }
function actualizarNotifConfig(params) {
  if (!params || !params.idNotif) return { ok: false, error: 'Requiere idNotif' };
  var sh = _ntfGetCfgSheet();
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) !== String(params.idNotif)) continue;
    var campos = ['activa','audiencia_roles','audiencia_usuarios','excluir_origen',
                  'prioridad','silenciada_hasta','sonido_custom'];
    campos.forEach(function(c) {
      if (params[c] !== undefined) {
        var col = hdrs.indexOf(c);
        if (col >= 0) sh.getRange(i + 1, col + 1).setValue(params[c]);
      }
    });
    // Stamp
    var iTs  = hdrs.indexOf('ts_actualizado');
    var iAct = hdrs.indexOf('actualizado_por');
    if (iTs >= 0)  sh.getRange(i + 1, iTs  + 1).setValue(Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'"));
    if (iAct >= 0) sh.getRange(i + 1, iAct + 1).setValue(String(params.actualizado_por || 'admin'));
    return { ok: true, data: { idNotif: params.idNotif } };
  }
  return { ok: false, error: 'idNotif no encontrado: ' + params.idNotif };
}

// Restaurar una sola entrada a sus defaults del catálogo
function restaurarNotifDefault(params) {
  if (!params || !params.idNotif) return { ok: false, error: 'Requiere idNotif' };
  var cat = _ntfCatalogoDefault();
  var def = cat.find(function(c) { return c.idNotif === params.idNotif; });
  if (!def) return { ok: false, error: 'idNotif no está en catálogo default' };
  return actualizarNotifConfig({
    idNotif: def.idNotif,
    activa: !!def.activa,
    audiencia_roles: def.audiencia_roles || '',
    audiencia_usuarios: def.audiencia_usuarios || '',
    excluir_origen: !!def.excluir_origen,
    prioridad: def.prioridad || 'normal',
    silenciada_hasta: '',
    sonido_custom: '',
    actualizado_por: params.actualizado_por || 'restore'
  });
}

// ── Test: enviar una notificación a mí mismo o a la audiencia configurada
function probarNotificacion(params) {
  if (!params || !params.idNotif) return { ok: false, error: 'Requiere idNotif' };
  var cfg = _ntfGetById(params.idNotif);
  if (!cfg) return { ok: false, error: 'idNotif no encontrado' };
  var titulo = cfg.icono + ' ' + cfg.titulo + ' (PRUEBA)';
  var cuerpo = 'Notificación de prueba · ' + (cfg.descripcion || '');
  var opciones = { idNotif: params.idNotif, _esTest: true };
  if (params.soloAMi && params.miUsuario) {
    opciones.soloUsuarios = [String(params.miUsuario)];
  }
  _enviarPushTodos(titulo, cuerpo, opciones);
  return { ok: true, data: { idNotif: params.idNotif, enviada: true } };
}

// ── Resolver audiencia a partir de config + opciones legacy ──
// Devuelve un objeto de filtros que _seleccionarTokensActivos entiende.
// Si idNotif está en config + activa + no silenciada → usa la config.
// Si no hay config → respeta las opciones legacy (compat).
function _ntfResolverFiltros(opcionesLegacy) {
  opcionesLegacy = opcionesLegacy || {};
  if (!opcionesLegacy.idNotif) return { permitir: true, filtros: opcionesLegacy };
  var cfg = _ntfGetById(opcionesLegacy.idNotif);
  if (!cfg) return { permitir: true, filtros: opcionesLegacy };

  // Silenciada globalmente
  if (!cfg.activa) return { permitir: false, motivo: 'desactivada', cfg: cfg };

  // Silenciada temporal
  if (cfg.silenciada_hasta) {
    try {
      var hastaTs = new Date(cfg.silenciada_hasta).getTime();
      if (!isNaN(hastaTs) && hastaTs > Date.now()) {
        return { permitir: false, motivo: 'silenciada_temporal', cfg: cfg };
      }
    } catch(_){}
  }

  // Construir filtros nuevos basados en config
  var filtros = {
    excluirUsuario: cfg.excluir_origen ? (opcionesLegacy.excluirUsuario || '') : '',
    _idNotif: opcionesLegacy.idNotif,
    _prioridad: cfg.prioridad || 'normal'
  };

  // Si solo se pidió enviar a 1 usuario (test "solo a mí"), no aplicar audiencia
  if (opcionesLegacy.soloUsuarios && opcionesLegacy.soloUsuarios.length > 0) {
    filtros.soloUsuarios = opcionesLegacy.soloUsuarios;
    return { permitir: true, filtros: filtros, cfg: cfg };
  }

  // Roles desde config
  var roles = String(cfg.audiencia_roles || '').split(',').map(function(s){ return s.trim().toUpperCase(); }).filter(Boolean);
  if (roles.length > 0) filtros.rolesPermitidos = roles;

  // Usuarios específicos extra
  var usuariosExtra = String(cfg.audiencia_usuarios || '').split(',').map(function(s){ return s.trim(); }).filter(Boolean);
  if (usuariosExtra.length > 0) filtros.usuariosExtra = usuariosExtra;

  return { permitir: true, filtros: filtros, cfg: cfg };
}

// ── Log de envío ──────────────────────────────────────────
function _ntfLogEnvio(idNotif, titulo, cuerpo, audienciaRes, count, ok, err, origen, estado, meta) {
  try {
    var sh = _ntfGetLogSheet();
    sh.appendRow([
      'NLOG-' + new Date().getTime(),
      Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'"),
      String(idNotif || ''), String(titulo || ''), String(cuerpo || ''),
      String(audienciaRes || ''),
      count || 0, ok || 0, err || 0,
      String(origen || ''),
      meta ? JSON.stringify(meta).substring(0, 500) : '',
      String(estado || 'OK')
    ]);
  } catch(e) {
    Logger.log('[Ntf] Log fallo: ' + e.message);
  }
}

// ── API: historial ────────────────────────────────────────
function getNotifLog(params) {
  params = params || {};
  var sh = _ntfGetLogSheet();
  var rows = _sheetToObjects(sh);
  // Filtros opcionales
  if (params.idNotif) rows = rows.filter(function(r){ return String(r.idNotif) === String(params.idNotif); });
  if (params.desde) {
    rows = rows.filter(function(r){
      var ts = String(r.ts || '').substring(0, 10);
      return ts >= params.desde;
    });
  }
  if (params.hasta) {
    rows = rows.filter(function(r){
      var ts = String(r.ts || '').substring(0, 10);
      return ts <= params.hasta;
    });
  }
  // Orden descendente por ts
  rows.sort(function(a,b){ return String(b.ts).localeCompare(String(a.ts)); });
  // Limit
  var limit = parseInt(params.limit) || 100;
  if (rows.length > limit) rows = rows.slice(0, limit);
  return { ok: true, data: rows };
}

// Reenviar una entrada del log (busca por idLog, recupera titulo + cuerpo + idNotif)
function reenviarNotificacion(params) {
  if (!params || !params.idLog) return { ok: false, error: 'Requiere idLog' };
  var sh = _ntfGetLogSheet();
  var rows = _sheetToObjects(sh);
  var entry = rows.find(function(r){ return String(r.idLog) === String(params.idLog); });
  if (!entry) return { ok: false, error: 'idLog no encontrado' };
  _enviarPushTodos(entry.titulo, entry.cuerpo, {
    idNotif: entry.idNotif,
    _reenvio: true,
    _origenLog: entry.idLog
  });
  return { ok: true, data: { reenviado: entry.idLog } };
}
