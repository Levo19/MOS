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

// [CUTOVER auth] Columnas de ACTIVIDAD (heartbeat) que el reverse-sync Sombra→Hoja NO debe pisar en filas
// existentes: las escribe el latido del propio dispositivo DIRECTO a la hoja (consultarEstado/registrarSesion)
// y los crons de inactividad las LEEN de la hoja. Si el reverse-sync las sobrescribiera con el valor (más viejo)
// de la sombra, retrocedería ultima_conexion → un equipo activo podría marcarse inactivo/suspendido por error.
// El reverse-sync SÍ es dueño de las columnas de CONTROL (Estado/Forzar_*/Bloqueado/Suspendido/Desbloqueo/etc.),
// que ahora se espejan a la sombra en cada mutación vía _dualWriteDispositivo. (En filas NUEVAS/agregados sí se
// copian, no hay valor de hoja que preservar.)
var _DISP_ACTIVITY_COLS = {
  ultima_conexion: true, ultima_zona: true, ultima_estacion: true, ultima_sesion: true
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

// ── Conversor INVERSO: valor de la SOMBRA (snake) → valor para la HOJA, coherente con cómo GAS lee
//    (_f4ToBool: '1'/''; ts: Date; json: string). Espejo de _f4Conv. ──
function _f4HojaValFromSombra(tipo, v) {
  if (tipo === 'ts') {
    if (v == null || v === '') return '';
    var d = new Date(v);
    return isNaN(d.getTime()) ? String(v) : d;   // Date si parsea; si no, string crudo
  }
  if (tipo === 'bool') return _f4ToBool(v) ? '1' : '';
  if (tipo === 'json') {
    if (v == null || v === '') return '';
    return (typeof v === 'object') ? JSON.stringify(v) : String(v);
  }
  return (v == null) ? '' : String(v);   // text
}

// [CUTOVER auth] Forma canónica de un JSON plano (llaves ordenadas) para comparar contenido, no serialización.
// Postgres JSONB reordena llaves (cam,geo… vs notif,cam…) → sin esto, permisos_json "difiere" siempre aunque
// el contenido sea idéntico. permisos es plano {notif,cam,mic,geo,audio,install} → orden de llaves shallow basta.
function _f4JsonCanon(v) {
  if (v == null || v === '') return '';
  var o;
  if (typeof v === 'object') o = v;
  else { try { o = JSON.parse(String(v)); } catch (e) { return String(v); } }
  try { return JSON.stringify(o, Object.keys(o).sort()); } catch (e2) { return String(v); }
}

// [CUTOVER auth] Compara un valor de SOMBRA (ya convertido a forma-hoja) contra el valor VIEJO de la hoja, por
// SEMÁNTICA (no por formato): ts por instante, json por contenido canónico, resto por string. Devuelve true si
// realmente cambió. Evita el churn Date-vs-string e JSONB-key-order que inflaba 'actualizados' sin cambio real.
function _f4DiffHoja(tipo, nuevo, viejo) {
  if (tipo === 'ts') {
    var mN = (nuevo instanceof Date) ? nuevo.getTime() : (nuevo === '' || nuevo == null ? NaN : Date.parse(String(nuevo)));
    var mV = (viejo instanceof Date) ? viejo.getTime() : (viejo === '' || viejo == null ? NaN : Date.parse(String(viejo)));
    if (isNaN(mN) && isNaN(mV)) return false;          // ambos vacíos/no-fecha → igual
    return mN !== mV;
  }
  if (tipo === 'json') return _f4JsonCanon(nuevo) !== _f4JsonCanon(viejo);
  return String(nuevo) !== String(viejo == null ? '' : viejo);
}

/**
 * resembrarDispositivosDesdeSombra(opts) — REVERSE-SYNC Sombra→Hoja. Lee mos.dispositivos (verdad nueva
 * tras el cutover de escritura directa) y ACTUALIZA las filas de la hoja DISPOSITIVOS por ID_Dispositivo,
 * cubriendo TODAS las columnas que leen los ~13 lectores GAS (Estado, Forzar_*, Logout_Auto_Ts,
 * Suspendido_Desde, Desbloqueo_Temporal_Hasta, Ultima_*, FCM_Token, Permisos_JSON, etc.). Devices en la
 * sombra que no estén en la hoja se AGREGAN. NUNCA borra filas (un device solo-hoja se respeta).
 * Reemplaza a _resembrarDispositivosJob (que iba Hoja→Sombra y pisaría lo directo). Idempotente.
 *   opts.dryRun=true → no escribe, solo cuenta (para validar antes).
 * Devuelve {ok, sombra, actualizados, agregados, sinCambio, errores}.
 */
/** Wrapper SIN argumentos para correr desde el editor de Apps Script (el botón Run no pasa params).
 *  Hace el DRY-RUN: NO escribe la hoja, solo cuenta. Mirá el return / Logs: errores debe ser []. */
function dryRunDispositivosDesdeSombra() { return resembrarDispositivosDesdeSombra({ dryRun: true }); }

/** Wrapper REAL (escribe la hoja) para correr desde el editor el 1er reverse-sync tras el flip. Devuelve y
 *  loguea el resultado: esperado {ok:true, actualizados:0, agregados:3, errores:[]}. Es lo mismo que ejecuta
 *  el trigger _resembrarDispositivosJob ahora que MOS_DISPOSITIVOS_DIRECTO=1 (acá lo corrés a demanda). */
function correrReverseSyncDispositivos() { return resembrarDispositivosDesdeSombra(); }

function resembrarDispositivosDesdeSombra(opts) {
  opts = opts || {};
  var dry = !!opts.dryRun;
  try { _sbCfg_(); } catch (eCfg) {
    return { ok: false, error: 'Supabase no configurado: ' + (eCfg && eCfg.message || eCfg) };
  }
  var sheet = getSheet('DISPOSITIVOS');
  if (!sheet) return { ok: false, error: 'hoja DISPOSITIVOS no existe' };

  var sel = _sbSelect('mos.dispositivos', { select: '*', limit: 5000 });
  if (!sel.ok) return { ok: false, error: 'select sombra falló: HTTP ' + sel.code + ' ' + (sel.error || '') };
  var sombra = sel.data || [];

  var values  = sheet.getDataRange().getValues();
  var headers = values[0];
  var colIdx  = {};
  for (var h = 0; h < headers.length; h++) colIdx[String(headers[h]).trim()] = h;
  var idCol = colIdx['ID_Dispositivo'];
  if (idCol == null) return { ok: false, error: 'hoja sin columna ID_Dispositivo' };

  // índice id → fila (0-based dentro de values; fila real en la hoja = idx+1)
  var rowById = {};
  for (var r = 1; r < values.length; r++) {
    var idH = String(values[r][idCol] || '').trim();
    if (idH) rowById[idH] = r;
  }
  // inverso del mapa: snake → [colHoja, tipo]
  var inv = {};
  for (var colHoja in _DISP_MAP_F4) {
    if (!Object.prototype.hasOwnProperty.call(_DISP_MAP_F4, colHoja)) continue;
    var spec = _DISP_MAP_F4[colHoja];
    inv[spec[0]] = [colHoja, spec[1]];
  }

  var actualizados = 0, agregados = 0, sinCambio = 0, errores = [];
  var nuevasFilas = [];
  var diffCols = {}, diffSamples = [];   // [DIAG dryRun] qué columnas/valores impulsan los 'actualizados'

  for (var s = 0; s < sombra.length; s++) {
    var sr = sombra[s];
    var id = String(sr.id_dispositivo || '').trim();
    if (!id) continue;

    if (Object.prototype.hasOwnProperty.call(rowById, id)) {
      var rowVals = values[rowById[id]];
      var cambio = false;
      for (var snake in inv) {
        if (!Object.prototype.hasOwnProperty.call(inv, snake)) continue;
        if (snake === 'id_dispositivo') continue;             // no tocar la PK
        if (_DISP_ACTIVITY_COLS[snake]) continue;             // [CUTOVER] no pisar actividad/heartbeat de la hoja
        var ci = colIdx[inv[snake][0]];
        if (ci == null) continue;                              // la hoja no tiene esa columna
        if (!Object.prototype.hasOwnProperty.call(sr, snake)) continue;
        var nuevo = _f4HojaValFromSombra(inv[snake][1], sr[snake]);
        var viejo = rowVals[ci];
        var distinto = _f4DiffHoja(inv[snake][1], nuevo, viejo);   // [CUTOVER] semántico: instante/json-canon/string
        if (distinto) {
          rowVals[ci] = nuevo; cambio = true;
          if (dry) {
            diffCols[snake] = (diffCols[snake] || 0) + 1;
            if (diffSamples.length < 15) diffSamples.push({
              id: id.substring(0, 8), col: snake,
              sombra: String(nuevo).substring(0, 32),
              hoja: String(viejo == null ? '' : viejo).substring(0, 32),
              tipoNuevo: (nuevo instanceof Date) ? 'Date' : typeof nuevo,
              tipoViejo: (viejo instanceof Date) ? 'Date' : typeof viejo
            });
          }
        }
      }
      if (cambio) {
        if (!dry) {
          try {
            // [fix clobber] el write empuja la fila ENTERA, incl. las columnas de actividad del SNAPSHOT (viejas).
            // Un heartbeat pudo actualizar Ultima_Conexion entre el snapshot y este write → lo pisaría con el
            // valor viejo. Re-leer las 4 columnas de actividad frescas y superponerlas antes de escribir.
            for (var snakeA in _DISP_ACTIVITY_COLS) {
              if (!Object.prototype.hasOwnProperty.call(_DISP_ACTIVITY_COLS, snakeA)) continue;
              var specA = inv[snakeA]; if (!specA) continue;
              var ciA = colIdx[specA[0]]; if (ciA == null) continue;
              rowVals[ciA] = sheet.getRange(rowById[id] + 1, ciA + 1).getValue();
            }
            sheet.getRange(rowById[id] + 1, 1, 1, rowVals.length).setValues([rowVals]);
          }
          catch (eW) { errores.push('update ' + id + ': ' + (eW && eW.message || eW)); }
        }
        actualizados++;
      } else sinCambio++;
    } else {
      var fila = [];
      for (var k = 0; k < headers.length; k++) fila.push('');
      for (var snake2 in inv) {
        if (!Object.prototype.hasOwnProperty.call(inv, snake2)) continue;
        var ci2 = colIdx[inv[snake2][0]];
        if (ci2 == null) continue;
        if (!Object.prototype.hasOwnProperty.call(sr, snake2)) continue;
        fila[ci2] = _f4HojaValFromSombra(inv[snake2][1], sr[snake2]);
      }
      fila[idCol] = id;
      nuevasFilas.push(fila);
      agregados++;
    }
  }

  if (!dry && nuevasFilas.length) {
    try { sheet.getRange(sheet.getLastRow() + 1, 1, nuevasFilas.length, headers.length).setValues(nuevasFilas); }
    catch (eA) { errores.push('append: ' + (eA && eA.message || eA)); }
  }

  // [CUTOVER auth] FORWARD de ACTIVIDAD (Hoja→Sombra) en la MISMA pasada: arriba el reverse-sync NO pisa las
  // columnas de actividad en la hoja (las escribe el heartbeat del propio equipo); pero la sombra las necesita
  // frescas porque el panel de dispositivos del front la lee directo. Esto reemplaza al barrido forward que se
  // apaga al cutover. SOLO las 4 columnas de actividad (+ id) y SOLO para ids que YA existen en la sombra
  // (update-only: no crea filas control-less; un alta nueva ya trae su fila vía _dualWriteDispositivo con Estado).
  if (!dry) {
    try {
      var sombraIds = {};
      for (var si = 0; si < sombra.length; si++) {
        var sid = String(sombra[si].id_dispositivo || '').trim(); if (sid) sombraIds[sid] = true;
      }
      var actById = {};   // dedupe last-wins (la hoja puede traer ids repetidos)
      for (var ra = 1; ra < values.length; ra++) {
        var idA = String(values[ra][idCol] || '').trim();
        if (!idA || !sombraIds[idA]) continue;            // update-only: solo ids ya en la sombra
        var rowA = { id_dispositivo: idA };
        for (var snakeA in _DISP_ACTIVITY_COLS) {
          if (!Object.prototype.hasOwnProperty.call(_DISP_ACTIVITY_COLS, snakeA)) continue;
          var specA = inv[snakeA];                         // [colHoja, tipo]
          if (!specA) continue;
          var ciA = colIdx[specA[0]];
          if (ciA == null) continue;
          rowA[snakeA] = _f4Conv(specA[1], values[ra][ciA]);
        }
        actById[idA] = rowA;
      }
      var actRows = Object.keys(actById).map(function (k) { return actById[k]; });
      for (var ja = 0; ja < actRows.length; ja += 200) {
        var loteA = actRows.slice(ja, ja + 200);
        var rUpA = _sbUpsert('mos.dispositivos', loteA, 'id_dispositivo');
        if (!rUpA.ok) errores.push('forward-actividad lote ' + ja + ': HTTP ' + rUpA.code + ' ' + (rUpA.error || ''));
      }
    } catch (eFA) {
      Logger.log('[resembrarDispositivosDesdeSombra] forward-actividad WARN: ' + (eFA && eFA.message || eFA));
    }
  }

  var res = { ok: errores.length === 0, dryRun: dry, sombra: sombra.length,
              actualizados: actualizados, agregados: agregados, sinCambio: sinCambio, errores: errores };
  if (dry) { res.diffPorColumna = diffCols; res.diffMuestras = diffSamples; }   // [DIAG] desglose de los 'actualizados'
  Logger.log('[resembrarDispositivosDesdeSombra] ' + JSON.stringify(res));
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
// [CERO-GAS 2026-07-18] La reconciliación periódica AUTOMÁTICA (trigger 5min + fold en syncMOSReciente +
// _resembrarDispositivosJob + instalar/quitarTrigger + _mosDispositivosDirecto) fue ELIMINADA. La verdad es
// mos.dispositivos (escrituras vía RPCs mos.admin_* + _dualWriteDispositivo en mutaciones GAS); la hoja
// DISPOSITIVOS quedó ORFANADA (archivo histórico). Se conservan como utilidades MANUALES de reparación/
// diagnóstico (editor GAS, sin trigger): compararDispositivosMOS(), correrReverseSyncDispositivos(),
// dryRunDispositivosDesdeSombra(), resembrarDispositivosDesdeHoja/Sombra() — refrescan la hoja bajo demanda.
// aprobarDispositivoEnSitu/Pendiente espejan al instante (_propagarDispositivoSombra) el caso urgente.
// ════════════════════════════════════════════════════════════════════════════════════════════════════
