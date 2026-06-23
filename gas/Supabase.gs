/**
 * ============================================================
 * MIGRACIÓN SUPABASE — FASE 0 · Helper de conexión (MOS GAS)
 * ============================================================
 * Inerte hasta que existan las Script Properties:
 *   SUPABASE_URL          = https://<proyecto>.supabase.co
 *   SUPABASE_SERVICE_KEY  = <service_role key>  (solo backend, nunca al PWA)
 *
 * Notas técnicas honestas:
 *  - UrlFetchApp NO soporta timeout configurable; el "fallback en 4s" del
 *    runbook depende de que Supabase responda. La protección real es
 *    muteHttpExceptions + manejo de error + reintento.
 *  - Para esquemas != public (mos/me/wh) PostgREST exige los headers
 *    Accept-Profile (GET) / Content-Profile (escritura) y que el esquema
 *    esté en Settings → API → Exposed schemas.
 *  - 409 (conflict) se trata como ÉXITO (idempotencia con merge-duplicates).
 */

var _SB_MAX_RETRY = 3;          // reintentos para 5xx / 429
var _SB_BACKOFF_MS = [400, 1200, 3000];

function _sbCfg_() {
  var p = PropertiesService.getScriptProperties();
  var url = p.getProperty('SUPABASE_URL');
  var key = p.getProperty('SUPABASE_SERVICE_KEY');
  if (!url || !key) {
    throw new Error('Faltan SUPABASE_URL / SUPABASE_SERVICE_KEY en Script Properties');
  }
  return { url: String(url).replace(/\/+$/, ''), key: String(key) };
}

/** Separa 'mos.productos' -> {schema:'mos', table:'productos'} (default schema public). */
function _sbParse_(schemaTable) {
  var s = String(schemaTable || '');
  var i = s.indexOf('.');
  if (i < 0) return { schema: 'public', table: s };
  return { schema: s.slice(0, i), table: s.slice(i + 1) };
}

/** Construye querystring PostgREST desde un objeto de opciones de lectura. */
function _sbQuery_(opts) {
  opts = opts || {};
  var parts = [];
  if (opts.select) parts.push('select=' + encodeURIComponent(opts.select));
  if (opts.order)  parts.push('order=' + String(opts.order).split(',').map(function(c){ return encodeURIComponent(c.trim()); }).join(','));  // coma literal entre columnas (PostgREST no decodifica %2C en order)
  if (opts.limit != null)  parts.push('limit=' + encodeURIComponent(opts.limit));
  if (opts.offset != null) parts.push('offset=' + encodeURIComponent(opts.offset));
  if (opts.onConflict) parts.push('on_conflict=' + String(opts.onConflict).split(',').map(function(c){ return encodeURIComponent(c.trim()); }).join(','));  // coma literal entre columnas
  // filtros: { col: 'eq.valor', otra: 'gte.2026-01-01' }
  if (opts.filters) {
    Object.keys(opts.filters).forEach(function (k) {
      parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(opts.filters[k]));
    });
  }
  return parts.length ? ('?' + parts.join('&')) : '';
}

/**
 * Núcleo: una petición REST. Devuelve { ok, code, data, error }.
 * method: GET|POST|PATCH|DELETE
 * schemaTable: 'mos.productos'
 * opts: { data, filters, select, order, limit, offset, onConflict, prefer, returnRep }
 */
function _sbOnce_(method, schemaTable, opts) {
  opts = opts || {};
  var cfg = _sbCfg_();
  var st = _sbParse_(schemaTable);
  var isRead = (method === 'GET');

  // Guard de seguridad: DELETE sin filtros borraría la tabla entera.
  if (method === 'DELETE' && !(opts.filters && Object.keys(opts.filters).length)) {
    return { ok: false, code: 0, error: 'DELETE sin filtros BLOQUEADO (seguridad)' };
  }

  var headers = {
    'apikey': cfg.key,
    'Authorization': 'Bearer ' + cfg.key
  };
  // Profile header para apuntar al esquema correcto
  if (st.schema && st.schema !== 'public') {
    headers[isRead ? 'Accept-Profile' : 'Content-Profile'] = st.schema;
  }
  var prefer = [];
  if (opts.prefer) prefer.push(opts.prefer);
  if (!isRead && opts.upsert) prefer.push('resolution=merge-duplicates');
  prefer.push(opts.returnRep ? 'return=representation' : 'return=minimal');
  if (prefer.length && !isRead) headers['Prefer'] = prefer.join(',');

  var params = {
    method: method.toLowerCase(),
    headers: headers,
    muteHttpExceptions: true,
    followRedirects: true
  };
  if (!isRead) {
    params.contentType = 'application/json';
    params.payload = JSON.stringify(opts.data == null ? {} : opts.data);
  }

  var url = cfg.url + '/rest/v1/' + st.table + (isRead ? _sbQuery_(opts) : (opts.filters || opts.onConflict ? _sbQuery_(opts) : ''));

  var res = UrlFetchApp.fetch(url, params);
  var code = res.getResponseCode();
  var text = res.getContentText();

  if (code === 429 || code >= 500) {
    var h = res.getHeaders();
    var ra = h['Retry-After'] || h['retry-after'];   // UrlFetchApp puede normalizar a minúsculas
    var raN = ra ? parseInt(ra, 10) : 0;             // si viene fecha HTTP -> NaN -> 0 (usa backoff)
    if (isNaN(raN) || raN < 0) raN = 0;
    return { ok: false, code: code, retryable: true, retryAfter: raN,
             error: 'HTTP ' + code + ': ' + (text || '').slice(0, 300) };
  }
  if (code === 409) return { ok: true, code: 409, data: null }; // ya existía (idempotente)
  if (code >= 400) {
    var msg;
    try { msg = (JSON.parse(text).message) || text; } catch (e) { msg = text; }
    return { ok: false, code: code, retryable: false, error: 'HTTP ' + code + ': ' + String(msg).slice(0, 300) };
  }
  var data = null;
  if (text) { try { data = JSON.parse(text); } catch (e2) { data = null; } }
  return { ok: true, code: code, data: data };
}

/** Wrapper con reintento/backoff para 5xx y 429. */
function _sb(method, schemaTable, opts) {
  var last = null;
  for (var i = 0; i < _SB_MAX_RETRY; i++) {
    try {
      var r = _sbOnce_(method, schemaTable, opts);
      if (r.ok || !r.retryable) return r;
      last = r;
    } catch (e) {
      last = { ok: false, code: 0, retryable: true, error: String(e && e.message || e) };
    }
    if (i < _SB_MAX_RETRY - 1) {
      var wait = (last && last.retryAfter ? last.retryAfter * 1000 : 0) || _SB_BACKOFF_MS[i];
      Utilities.sleep(Math.min(wait, 30000));
    }
  }
  return last || { ok: false, code: 0, error: 'sin respuesta' };
}

// -------- Helpers de conveniencia --------
function _sbSelect(schemaTable, opts) { return _sb('GET', schemaTable, opts || {}); }
function _sbInsert(schemaTable, rows, returnRep) {
  return _sb('POST', schemaTable, { data: rows, returnRep: !!returnRep });
}
function _sbUpsert(schemaTable, rows, onConflict, returnRep) {
  return _sb('POST', schemaTable, { data: rows, upsert: true, onConflict: onConflict, returnRep: !!returnRep });
}
function _sbUpdate(schemaTable, patch, filters) {
  return _sb('PATCH', schemaTable, { data: patch, filters: filters });
}
/** DELETE con guard: rechaza si no hay filtros (evita borrar la tabla entera). */
function _sbDelete(schemaTable, filters) {
  if (!filters || !Object.keys(filters).length) {
    return { ok: false, code: 0, error: 'DELETE sin filtros BLOQUEADO (seguridad)' };
  }
  return _sb('DELETE', schemaTable, { filters: filters });
}
/** RPC: schema='mos', fn='hoy_lima', args={} */
function _sbRpc(schema, fn, args) {
  var cfg = _sbCfg_();
  var headers = { 'apikey': cfg.key, 'Authorization': 'Bearer ' + cfg.key, 'Content-Type': 'application/json' };
  if (schema && schema !== 'public') headers['Content-Profile'] = schema;
  var res = UrlFetchApp.fetch(cfg.url + '/rest/v1/rpc/' + fn, {
    method: 'post', headers: headers, muteHttpExceptions: true,
    payload: JSON.stringify(args || {})
  });
  var code = res.getResponseCode(), text = res.getContentText();
  if (code >= 400) return { ok: false, code: code, error: text };
  var data = null; if (text) { try { data = JSON.parse(text); } catch (e) {} }
  return { ok: true, code: code, data: data };
}

// ════════════════════════════════════════════════════════════════════════════
// [CUTOVER DELETE-SAFE · LECTURA GAS DESDE SUPABASE]  — agregado 2026-06-18
// Para que MOS funcione "aunque borre el Sheet", los READ-BACKS operativos de GAS
// (getProveedoresMaster, getJornadas, getEvaluacionesDia, ...) deben poder leer la
// sombra mos.* en vez de la HOJA. Espejan EXACTAMENTE el patrón del frontend
// (js/api.js): RPC *_lista → gate de FRESCURA (_fresh) → si stale/!ok ⇒ null ⇒ el
// caller cae a la HOJA (fallback). Money-safe: nunca sirve sombra STALE (idéntico
// criterio que finanzas_rango/76 y *_lista/94).
//
//  · Gate de lectura: se controla por flag mos.config 'MOS_<MODULO>_LECTURA' (mismo
//    flag que prende la lectura directa del FRONTEND) — leído por _mosFlagOn_().
//    Default OFF ⇒ _sbLeerListaMOS NO entra ⇒ GAS lee la HOJA = IDÉNTICO a hoy.
//  · _claim_ok(): GAS usa service_role (jwt_app vacío) ⇒ pasa el gate de las RPCs.
//  · NUNCA lanza: ante CUALQUIER error/flag-off/stale devuelve null → fallback HOJA.
// ════════════════════════════════════════════════════════════════════════════

// Memo por-ejecución de flags (las ejecuciones GAS son cortas; evita N round-trips a mos.config
// cuando un orquestador llama varios getters en loop, p.ej. _calcularPersonal).
var _MOS_FLAG_MEMO = {};
/** Lee un flag booleano de mos.config (valor '1'/'true' ⇒ true). Best-effort: error ⇒ false (OFF = seguro). */
function _mosFlagRawOn_(clave) {
  if (Object.prototype.hasOwnProperty.call(_MOS_FLAG_MEMO, clave)) return _MOS_FLAG_MEMO[clave];
  var res = false;
  try {
    var r = _sbSelect('mos.config', { select: 'valor', filters: { clave: 'eq.' + clave }, limit: 1 });
    if (r && r.ok && r.data && r.data.length) {
      var v = String(r.data[0].valor == null ? '' : r.data[0].valor).trim().toLowerCase();
      res = (v === '1' || v === 'true' || v === 't');
    }
  } catch (e) { res = false; }
  _MOS_FLAG_MEMO[clave] = res;
  return res;
}

/**
 * Gate de LECTURA de un módulo, espejando el frontend (js/api.js _mos<Modulo>Lectura):
 *   MAESTRO 'MOS_LECTURA_NAVEGADOR' OR el flag específico del módulo.
 * Así, prender el maestro (ya ON en prod) habilita TODAS las lecturas GAS de golpe, igual que el front.
 * flagClave null ⇒ solo mira el maestro. Best-effort: error ⇒ false (OFF = seguro = HOJA).
 */
function _mosFlagOn_(clave) {
  if (_mosFlagRawOn_('MOS_LECTURA_NAVEGADOR')) return true;   // maestro: prende todas (paridad con _mosLecturaDirecta)
  if (!clave) return false;
  return _mosFlagRawOn_(clave);
}

/**
 * Lee una RPC mos.<fn>_lista (o cualquier RPC que devuelva {ok,data:[...],_fresh}) con gate de frescura.
 *   fn        : nombre de la RPC (ej. 'proveedores_lista')
 *   args      : objeto de argumentos (se envuelve como { p: args }, convención de las RPCs *_lista)
 *   flagClave : flag mos.config que habilita esta lectura (ej. 'MOS_PROVEEDORES_LECTURA'). null ⇒ exige el MAESTRO.
 * Devuelve el ARRAY `data` si {ok && _fresh===true}; null en cualquier otro caso (⇒ el caller cae a la HOJA).
 * NUNCA lanza. (Gate: MAESTRO 'MOS_LECTURA_NAVEGADOR' OR flagClave → master OFF revierte TODO a HOJA.)
 */
function _sbLeerListaMOS(fn, args, flagClave) {
  try {
    if (!_mosFlagOn_(flagClave)) return null;                       // gate (maestro OR módulo) OFF → HOJA
    var r = _sbRpc('mos', fn, { p: args || {} });
    if (!r || !r.ok || !r.data) return null;
    var d = r.data;
    if (d.ok !== true) return null;                                  // negocio rechazó (APP_NO_AUTORIZADA, etc.) → HOJA
    if (d._fresh !== true) {                                         // sombra STALE → NO servir datos viejos → HOJA
      Logger.log('[_sbLeerListaMOS ' + fn + '] sombra STALE (_fresh=' + d._fresh + ', hb=' + d._heartbeat + ') → fallback HOJA');
      return null;
    }
    return Array.isArray(d.data) ? d.data : null;
  } catch (e) {
    Logger.log('[_sbLeerListaMOS ' + fn + '] WARN ' + (e && e.message || e) + ' → fallback HOJA');
    return null;
  }
}

/**
 * Variante para RPCs cuyo `data` es un OBJETO (no array): horarios_apps devuelve {<app>:{...}}.
 * Devuelve el objeto `data` si {ok && _fresh===true}; null en otro caso. NUNCA lanza.
 */
function _sbLeerObjetoMOS(fn, args, flagClave) {
  try {
    if (!_mosFlagOn_(flagClave)) return null;                       // gate (maestro OR módulo) OFF → HOJA
    var r = _sbRpc('mos', fn, { p: args || {} });
    if (!r || !r.ok || !r.data) return null;
    var d = r.data;
    if (d.ok !== true) return null;
    if (d._fresh !== true) {
      Logger.log('[_sbLeerObjetoMOS ' + fn + '] sombra STALE → fallback HOJA');
      return null;
    }
    return (d.data && typeof d.data === 'object') ? d.data : null;
  } catch (e) {
    Logger.log('[_sbLeerObjetoMOS ' + fn + '] WARN ' + (e && e.message || e) + ' → fallback HOJA');
    return null;
  }
}

/**
 * Variante para RPCs que ya devuelven el OBJETO-RESPUESTA COMPLETO con el shape del endpoint GAS
 * (ej. liquidaciones_pendientes → {ok,data:[...],rango,fast,_fresh}). Devuelve ese objeto TAL CUAL
 * (con sus llaves _fresh/_heartbeat extra, inocuas) si {ok && _fresh===true}; null en otro caso.
 * El caller hace: var resp=_sbLeerRpcFreshMOS(...); if(resp) return resp;  ⇒ shape idéntico al endpoint.
 * NUNCA lanza.
 */
function _sbLeerRpcFreshMOS(fn, args, flagClave) {
  try {
    if (!_mosFlagOn_(flagClave)) return null;            // gate (maestro OR módulo) OFF → HOJA
    var r = _sbRpc('mos', fn, { p: args || {} });
    if (!r || !r.ok || !r.data) return null;
    var d = r.data;
    if (d.ok !== true) return null;
    if (d._fresh !== true) {
      Logger.log('[_sbLeerRpcFreshMOS ' + fn + '] sombra STALE → fallback HOJA');
      return null;
    }
    return d;
  } catch (e) {
    Logger.log('[_sbLeerRpcFreshMOS ' + fn + '] WARN ' + (e && e.message || e) + ' → fallback HOJA');
    return null;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// [CUTOVER DELETE-SAFE · ESCRITURA GAS DIRECTO-PURO]  — agregado 2026-06-18
// Para que MOS funcione "aunque borre el Sheet", las funciones de ESCRITURA de
// GAS (registrarGasto, registrarPago, crearProveedorMaster, setHorarioApp, ...)
// deben poder persistir SOLO en Supabase vía la RPC mos.<fn> (idempotente),
// SALTANDO la hoja, cuando el flag mos.config 'MOS_<TABLA>_DIRECTO' está en '1'.
//
// CONTRATO money-safe del helper:
//  · Gate por flag MOS_<TABLA>_DIRECTO (NO mira el maestro de lectura): default
//    OFF ⇒ devuelve null ⇒ el caller hace su dual-write a la HOJA = IDÉNTICO a hoy.
//  · GAS usa service_role (jwt_app vacío) ⇒ pasa mos._claim_ok() de la RPC.
//  · La RPC es idempotente (local_id / PK). El caller manda su id de negocio ya
//    generado (_generateId) como idPP/idGasto/... Y como localId (clave de gesto
//    estable: una invocación GAS = un id ⇒ reintento del MISMO id no duplica).
//  · NUNCA lanza. Ante CUALQUIER error/flag-off/RPC-no-ok devuelve null → el caller
//    cae a su dual-write de SIEMPRE (la hoja sigue siendo la red de seguridad).
//    => activar el flag no puede PERDER una escritura: o la mete a Supabase, o
//       (si falla) la mete a la hoja como hoy. JAMÁS la pierde silenciosamente.
//  · Devuelve el OBJETO-RESPUESTA de la RPC ({ok,dedup,data,...}) si ok===true,
//    así el caller arma su shape de retorno idéntico al de la hoja.
// ════════════════════════════════════════════════════════════════════════════

/**
 * Escritura directa-pura vía RPC mos.<fn>, gated por MOS_<flagClave>_DIRECTO.
 *   fn       : nombre de la RPC de escritura (ej. 'crear_gasto', 'registrar_pago_proveedor')
 *   args     : objeto {p} de la RPC (las RPCs de escritura reciben (p jsonb))
 *   flagClave: flag mos.config que habilita el directo-puro (ej. 'MOS_GASTOS_DIRECTO')
 * Devuelve el objeto-respuesta de la RPC si {ok:true}; null en cualquier otro caso
 * (flag OFF, RPC !ok / *_OFF / APP_NO_AUTORIZADA, error de red, excepción) ⇒ el
 * caller hace su dual-write a la HOJA. NUNCA lanza.
 */
function _sbEscribirDirectoMOS(fn, args, flagClave) {
  try {
    if (!flagClave || !_mosFlagRawOn_(flagClave)) return null;   // gate del módulo OFF → HOJA (dual-write de siempre)
    var r = _sbRpc('mos', fn, { p: args || {} });
    if (!r || !r.ok || !r.data) {
      Logger.log('[_sbEscribirDirectoMOS ' + fn + '] RPC transporte falló (HTTP ' + (r && r.code) + ') → fallback HOJA');
      return null;
    }
    var d = r.data;
    if (d && d.ok === true) return d;                            // éxito directo-puro (incluye dedup:true)
    // d.ok=false: *_OFF (flag se apagó entre el check y la llamada), APP_NO_AUTORIZADA, validación, etc.
    Logger.log('[_sbEscribirDirectoMOS ' + fn + '] RPC ok=false (' + (d && d.error) + ') → fallback HOJA');
    return null;
  } catch (e) {
    Logger.log('[_sbEscribirDirectoMOS ' + fn + '] WARN ' + (e && e.message || e) + ' → fallback HOJA');
    return null;
  }
}

/** Cuenta filas de una tabla (HEAD con Prefer count). */
function _sbCount(schemaTable, filters) {
  var cfg = _sbCfg_(); var st = _sbParse_(schemaTable);
  var headers = { 'apikey': cfg.key, 'Authorization': 'Bearer ' + cfg.key, 'Prefer': 'count=exact' };
  if (st.schema !== 'public') headers['Accept-Profile'] = st.schema;
  var url = cfg.url + '/rest/v1/' + st.table + _sbQuery_({ filters: filters, limit: 1 });
  var res = UrlFetchApp.fetch(url, { method: 'get', headers: headers, muteHttpExceptions: true }); // GET + count=exact + limit 1 (UrlFetchApp no soporta HEAD)
  var hh = res.getHeaders();
  var cr = hh['Content-Range'] || hh['content-range'] || '';
  var m = String(cr).match(/\/(\d+)$/);
  return m ? parseInt(m[1], 10) : -1;
}

/**
 * DIAGNÓSTICO — ejecutar manualmente desde el editor de Apps Script.
 * Verifica credenciales + conectividad + latencia + acceso a esquema mos.
 */
function _sbPing() {
  var out = { ok: false, pasos: [] };
  try {
    var cfg = _sbCfg_();
    out.pasos.push('✓ Credenciales presentes (' + cfg.url + ')');
  } catch (e) {
    out.error = String(e.message); out.pasos.push('✗ ' + out.error);
    Logger.log(JSON.stringify(out, null, 2)); return out;
  }
  var t0 = new Date().getTime();
  var r = _sbSelect('mos.config', { select: 'clave', limit: 1 });
  var ms = new Date().getTime() - t0;
  out.latencia_ms = ms;
  if (!r.ok) {
    out.pasos.push('✗ GET mos.config falló: HTTP ' + r.code + ' — ' + (r.error || ''));
    out.pasos.push('  Revisa: (1) esquema "mos" en Settings→API→Exposed schemas; (2) corriste 01_schema.sql; (3) service_role key correcta.');
    Logger.log(JSON.stringify(out, null, 2)); return out;
  }
  out.pasos.push('✓ GET mos.config OK (' + ms + ' ms, HTTP ' + r.code + ') — tabla vacía [] es normal antes del backfill');

  // Prueba de ESCRITURA contra backfill_audit (tabla de descarte; NO contamina el cuadre del catálogo).
  var w = _sbInsert('mos.backfill_audit', [{ app: '__sbping__', tipo_issue: 'selftest', nota: 'ping' }], true);
  if (w.ok) {
    out.pasos.push('✓ WRITE mos.backfill_audit OK (HTTP ' + w.code + ')');
    var d = _sbDelete('mos.backfill_audit', { app: 'eq.__sbping__' });
    if (!d.ok) { Utilities.sleep(400); d = _sbDelete('mos.backfill_audit', { app: 'eq.__sbping__' }); }
    out.pasos.push((d.ok ? '✓' : '⚠ no se pudo limpiar') + ' cleanup self-test (HTTP ' + d.code + ')');
    out.ok = true;
  } else {
    out.pasos.push('✗ WRITE mos.backfill_audit falló: HTTP ' + w.code + ' — ' + (w.error || ''));
  }
  Logger.log(JSON.stringify(out, null, 2));
  return out;
}
