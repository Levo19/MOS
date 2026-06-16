/**
 * Fase4Dispositivos.gs — [FASE 4.1 · Etapa B+C] Espejo (dual-write) + resembrar + comparador de la
 * sombra mos.dispositivos. Patrón idéntico a _dualWriteMOS: la escritura sigue por GAS→hoja (verdad) y
 * además espeja a Supabase al instante, para que la sombra esté SIEMPRE fresca (y se pueda quitar el
 * doble-check del auth directo en las 3 apps).
 *
 * ⚠️ INERTE: estas funciones EXISTEN pero nadie las invoca todavía. El cableo (llamar
 * _dualWriteDispositivo al final de cada función R/W de Config.gs/Bloqueos.gs/SeguridadAlerts.gs) se hará
 * en un paso posterior, con node -c + deploy disponibles. Mientras tanto, agregar este archivo NO cambia
 * ningún comportamiento (solo define funciones nuevas). resembrar/comparar son de uso manual (admin).
 *
 * Reusa los helpers Supabase existentes: _sbUpsert / _sbSelect / _sbCount / _sbCfg_ (Supabase.gs) y
 * _sheetToObjects (Code.gs). No reinventa el cliente HTTP.
 */

// Mapeo COLUMNA-DE-HOJA → [columna_snake_sombra, tipo]. tipo ∈ 'text' | 'ts' | 'bool' | 'json'.
var _DISP_MAP_F4 = {
  'ID_Dispositivo':            ['id_dispositivo',            'text'],
  'Nombre_Equipo':             ['nombre_equipo',             'text'],
  'App':                       ['app',                       'text'],
  'Estado':                    ['estado',                    'text'],
  'Ultima_Conexion':           ['ultima_conexion',           'ts'],
  'Ultima_Zona':               ['ultima_zona',               'text'],
  'Ultima_Estacion':           ['ultima_estacion',           'text'],
  'Ultima_Sesion':             ['ultima_sesion',             'text'],
  'Permisos_JSON':             ['permisos_json',             'json'],
  'Permisos_LastUpdate':       ['permisos_lastupdate',       'ts'],
  'Forzar_Wizard':             ['forzar_wizard',             'bool'],
  'Suspendido_Desde':          ['suspendido_desde',          'ts'],
  'Forzar_Logout':             ['forzar_logout',             'bool'],
  'Logout_Auto_Ts':            ['logout_auto_ts',            'ts'],
  'Forzar_Push':               ['forzar_push',               'bool'],
  'Forzar_ReVerify':           ['forzar_reverify',           'bool'],
  'Inactivo_Alerta_Ts':        ['inactivo_alerta_ts',        'ts'],
  'Cancelado_Auto_Ts':         ['cancelado_auto_ts',         'ts'],
  'User_Agent':                ['user_agent',                'text'],
  'FCM_Token':                 ['fcm_token',                 'text'],
  'Alerta_Seguridad':          ['alerta_seguridad',          'text'],
  'Alerta_Seguridad_Revisada': ['alerta_seguridad_revisada', 'bool'],
  'Forzar_Horario_Hasta':      ['forzar_horario_hasta',      'ts'],
  'Razon_Bloqueo':             ['razon_bloqueo',             'text'],
  'Bloqueado_Desde':           ['bloqueado_desde',           'ts'],
  'Fecha_Caducidad':           ['fecha_caducidad',           'ts'],
  'Desbloqueo_Temporal_Hasta': ['desbloqueo_temporal_hasta', 'ts']
};

// ── Conversores de valor hoja → valor sombra (coherentes con consultarEstadoDispositivo/getDispositivos) ──
function _f4ToIso(v) {
  if (v == null || v === '') return null;
  if (Object.prototype.toString.call(v) === '[object Date]') {
    if (isNaN(v.getTime())) return null;
    return Utilities.formatDate(v, 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
  }
  var s = String(v).trim();
  if (!s) return null;
  // Ya parece ISO (tiene T o Z u offset) → dejar como está.
  if (s.indexOf('T') >= 0 || /[zZ]$/.test(s) || /[+-]\d{2}:?\d{2}$/.test(s)) return s;
  // Intentar parsear formatos humanos/legacy → ISO UTC.
  var d = new Date(s);
  if (!isNaN(d.getTime())) return d.toISOString();
  return s; // último recurso: string crudo (Postgres intentará castear; si falla, el batch lo corrige)
}
function _f4ToBool(v) {
  if (v === true) return true;
  if (v === false || v == null) return false;
  var s = String(v).trim().toLowerCase();
  return s === '1' || s === 'true' || s === 'si' || s === 'sí';
}
function _f4ToJson(v) {
  if (v == null || v === '') return null;
  if (typeof v === 'object') return v;
  try { return JSON.parse(String(v)); } catch (e) { return null; }
}
function _f4ToText(v) {
  if (v == null) return null;
  var s = String(v);
  return s; // '' permitido (campo vaciado intencionalmente)
}
function _f4Conv(tipo, v) {
  if (tipo === 'ts')   return _f4ToIso(v);
  if (tipo === 'bool') return _f4ToBool(v);
  if (tipo === 'json') return _f4ToJson(v);
  return _f4ToText(v);
}

// Convierte un objeto-fila de la HOJA (claves = headers) a un row de la SOMBRA (claves snake). soloPresentes:
// si true, solo incluye las columnas presentes en `obj` (para patches parciales del dual-write).
function _f4RowFromHoja(obj, soloPresentes) {
  var row = {};
  for (var colHoja in _DISP_MAP_F4) {
    if (!Object.prototype.hasOwnProperty.call(_DISP_MAP_F4, colHoja)) continue;
    var hasKey = Object.prototype.hasOwnProperty.call(obj, colHoja);
    if (soloPresentes && !hasKey) continue;
    var spec = _DISP_MAP_F4[colHoja];
    row[spec[0]] = _f4Conv(spec[1], hasKey ? obj[colHoja] : null);
  }
  return row;
}

/**
 * _dualWriteDispositivo(deviceId, patch) — espeja a mos.dispositivos un cambio de la hoja.
 * patch: objeto con claves en NOMBRE DE COLUMNA DE HOJA (ej {Estado:'INACTIVO', Razon_Bloqueo:'...'}).
 *   - id_dispositivo SIEMPRE se setea desde deviceId (no hace falta incluirlo en el patch).
 *   - Solo se espejan las columnas presentes en el patch (upsert parcial) + id_dispositivo.
 * Best-effort: si Supabase no está configurado o el upsert falla, loguea y devuelve false; NUNCA lanza.
 * Idempotente (upsert por id_dispositivo). Devuelve true/false.
 */
function _dualWriteDispositivo(deviceId, patch) {
  try {
    if (!deviceId) return false;
    try { _sbCfg_(); } catch (eCfg) {
      Logger.log('[_dualWriteDispositivo] Supabase no configurado, omito: ' + (eCfg && eCfg.message || eCfg));
      return false;
    }
    var row = _f4RowFromHoja(patch || {}, true);
    row.id_dispositivo = String(deviceId);
    var up = _sbUpsert('mos.dispositivos', [row], 'id_dispositivo');
    if (!up.ok) {
      Logger.log('[_dualWriteDispositivo] upsert falló HTTP ' + up.code + ' ' + (up.error || ''));
      return false;
    }
    return true;
  } catch (e) {
    Logger.log('[_dualWriteDispositivo] EXCEPCIÓN: ' + (e && e.message || e));
    return false;
  }
}

/**
 * resembrarDispositivosDesdeHoja() — backfill/reconciliación: lee TODA la hoja DISPOSITIVOS y la upserta a
 * la sombra (fila completa). Uso manual (admin), una vez antes de migrar lectores y como reparación.
 * Devuelve {ok, filas, upserted, errores}.
 */
function resembrarDispositivosDesdeHoja() {
  try {
    _sbCfg_();
  } catch (eCfg) {
    return { ok: false, error: 'Supabase no configurado: ' + (eCfg && eCfg.message || eCfg) };
  }
  var sheet = getSheet('DISPOSITIVOS');
  if (!sheet) return { ok: false, error: 'hoja DISPOSITIVOS no existe' };
  var objs = _sheetToObjects(sheet);
  // Deduplicar por id_dispositivo ANTES del upsert: PostgREST rechaza un lote con IDs repetidos
  // (ON CONFLICT no puede tocar la misma fila 2 veces en un comando). last-wins (la última fila de la
  // hoja para ese id gana). Reportar los duplicados para que el admin limpie el dato sucio en la hoja.
  var byId = {}, dupSet = {};
  for (var i = 0; i < objs.length; i++) {
    var id = String(objs[i].ID_Dispositivo || '').trim();
    if (!id) continue;
    if (Object.prototype.hasOwnProperty.call(byId, id)) dupSet[id] = true;  // visto antes → duplicado
    byId[id] = objs[i];  // last-wins
  }
  var rows = [];
  for (var idK in byId) {
    if (!Object.prototype.hasOwnProperty.call(byId, idK)) continue;
    var row = _f4RowFromHoja(byId[idK], false);
    row.id_dispositivo = idK;
    rows.push(row);
  }
  var duplicados = Object.keys(dupSet);
  var upserted = 0, errores = [];
  var LOTE = 200;
  for (var j = 0; j < rows.length; j += LOTE) {
    var lote = rows.slice(j, j + LOTE);
    var r = _sbUpsert('mos.dispositivos', lote, 'id_dispositivo');
    if (r.ok) { upserted += lote.length; }
    else { errores.push('lote ' + j + ': HTTP ' + r.code + ' ' + (r.error || '')); }
  }
  var res = { ok: errores.length === 0, filasHoja: objs.length, filasUnicas: rows.length,
              upserted: upserted, duplicadosEnHoja: duplicados, errores: errores };
  Logger.log('[resembrarDispositivosDesdeHoja] ' + JSON.stringify(res));
  return res;
}

/**
 * compararDispositivosMOS() — comparador sombra vs hoja (mismo espíritu que semaforoLecturasMOS). Cuenta
 * filas, detecta faltantes por id en cada lado, y diferencias de estado. NO escribe nada. Para validar
 * paridad antes de migrar lectores / quitar doble-check.
 */
function compararDispositivosMOS() {
  try { _sbCfg_(); } catch (eCfg) {
    return { ok: false, error: 'Supabase no configurado: ' + (eCfg && eCfg.message || eCfg) };
  }
  var sheet = getSheet('DISPOSITIVOS');
  if (!sheet) return { ok: false, error: 'hoja DISPOSITIVOS no existe' };
  var objs = _sheetToObjects(sheet);
  var hojaById = {};
  for (var i = 0; i < objs.length; i++) {
    var id = String(objs[i].ID_Dispositivo || '').trim();
    if (id) hojaById[id] = String(objs[i].Estado || '').toUpperCase();
  }
  // Traer la sombra (id + estado) — paginado simple: hasta 2000 (la flota es chica).
  var sel = _sbSelect('mos.dispositivos', { select: 'id_dispositivo,estado', limit: 2000 });
  if (!sel.ok) return { ok: false, error: 'select sombra falló: HTTP ' + sel.code + ' ' + (sel.error || '') };
  var sombraById = {};
  (sel.data || []).forEach(function (r) {
    sombraById[String(r.id_dispositivo)] = String(r.estado || '').toUpperCase();
  });

  var faltanEnSombra = [], faltanEnHoja = [], conDiff = [];
  for (var idH in hojaById) {
    if (!Object.prototype.hasOwnProperty.call(hojaById, idH)) continue;
    if (!(idH in sombraById)) { faltanEnSombra.push(idH); }
    else if (hojaById[idH] !== sombraById[idH]) {
      conDiff.push({ id: idH, hoja: hojaById[idH], sombra: sombraById[idH] });
    }
  }
  for (var idS in sombraById) {
    if (!Object.prototype.hasOwnProperty.call(sombraById, idS)) continue;
    if (!(idS in hojaById)) faltanEnHoja.push(idS);
  }

  var nHoja = Object.keys(hojaById).length, nSombra = Object.keys(sombraById).length;
  var ok = faltanEnSombra.length === 0 && faltanEnHoja.length === 0 && conDiff.length === 0;
  var res = {
    ok: ok,
    filas: { hoja: nHoja, sombra: nSombra },
    faltanEnSombra: faltanEnSombra.length,
    faltanEnHoja: faltanEnHoja.length,
    filasConDiff: conDiff.length,
    veredicto: ok ? '✓ PARIDAD (id + estado) — sombra fresca' : '⚠ descuadre — revisar (resembrar o cablear dual-write)',
    ejemplos: {
      faltanEnSombra: faltanEnSombra.slice(0, 10),
      faltanEnHoja: faltanEnHoja.slice(0, 10),
      conDiff: conDiff.slice(0, 10)
    }
  };
  Logger.log('[compararDispositivosMOS] ' + JSON.stringify(res, null, 2));
  return res;
}

// ════════════════════════════════════════════════════════════════════════════════════════════════════
// [FASE 4.1 · Etapa B — versión segura para el outage] RECONCILIACIÓN PERIÓDICA en vez de cablear 20
// dual-writes a ciegas. Un trigger time-based reespeja la hoja completa a la sombra cada 5 min. Cubre TODAS
// las columnas/operaciones, NO toca ninguna función existente (cero riesgo de romper MOS), idempotente.
// Mantiene la sombra fresca (lag ≤5 min, aceptable: el doble-check actual ya tolera el round-trip GAS).
// El dual-write instantáneo granular (latencia de segundos) se cablea DESPUÉS, cuando se pueda probar.
// OJO triggers GAS: pueden morir en silencio (ver memoria). El comparador compararDispositivosMOS() es el
// detector; aprobarDispositivoEnSitu/Pendiente YA espejan al instante (_propagarDispositivoSombra) el caso
// más urgente (device nuevo → entra ya). INERTE hasta que se corra instalarTriggerResembrarDispositivos().
// ════════════════════════════════════════════════════════════════════════════════════════════════════
function _resembrarDispositivosJob() {
  try {
    var r = resembrarDispositivosDesdeHoja();
    Logger.log('[_resembrarDispositivosJob] ' + JSON.stringify(r));
  } catch (e) {
    Logger.log('[_resembrarDispositivosJob] EXCEPCIÓN: ' + (e && e.message || e));
  }
}

function instalarTriggerResembrarDispositivos() {
  // Elimina cualquier trigger previo de este job (idempotente — evita duplicar al re-correr).
  var triggers = ScriptApp.getProjectTriggers();
  for (var i = 0; i < triggers.length; i++) {
    if (triggers[i].getHandlerFunction() === '_resembrarDispositivosJob') {
      ScriptApp.deleteTrigger(triggers[i]);
    }
  }
  ScriptApp.newTrigger('_resembrarDispositivosJob').timeBased().everyMinutes(5).create();
  Logger.log('[instalarTriggerResembrarDispositivos] trigger cada 5 min instalado');
  return { ok: true, intervalo: '5min', job: '_resembrarDispositivosJob' };
}

function quitarTriggerResembrarDispositivos() {
  // KILL-SWITCH: apaga la reconciliación periódica (vuelve al estado previo, solo aprobar espeja).
  var triggers = ScriptApp.getProjectTriggers();
  var n = 0;
  for (var i = 0; i < triggers.length; i++) {
    if (triggers[i].getHandlerFunction() === '_resembrarDispositivosJob') {
      ScriptApp.deleteTrigger(triggers[i]); n++;
    }
  }
  Logger.log('[quitarTriggerResembrarDispositivos] ' + n + ' trigger(s) eliminado(s)');
  return { ok: true, eliminados: n };
}
