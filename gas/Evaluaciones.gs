// ============================================================
// ProyectoMOS — Evaluaciones.gs
// Sistema de evaluación de personal con acumulativo diario (MAX/OR)
// y liquidación semanal con bonos por score (tramos) y por meta.
// ============================================================

// ── Hoja EVALUACIONES (auto-crear + agregar columnas faltantes) ──
function _getEvalSheet() {
  var ss = getSpreadsheet();
  var sheet = ss.getSheetByName('EVALUACIONES');
  if (!sheet) {
    sheet = ss.insertSheet('EVALUACIONES');
    sheet.appendRow([
      'idEval', 'fecha', 'idPersonal', 'rol', 'hora',
      'limpiezaPct', 'limpiezaProfPct',
      'controlChecks', 'comentario', 'evaluadoPor',
      'aplicaComision', 'aplicaBonoMeta', 'activo',
      'sancion', 'sancionMotivo',
      'bonificacion', 'bonificacionMotivo'  // [v2.41.51] extra discrecional
    ]);
    sheet.setFrozenRows(1);
  } else {
    // Migración: agregar columnas faltantes si la hoja ya existía sin ellas
    var lastCol = sheet.getLastColumn();
    var hdrs = sheet.getRange(1, 1, 1, lastCol).getValues()[0];
    if (hdrs.indexOf('sancion') === -1) {
      sheet.getRange(1, lastCol + 1).setValue('sancion');
      lastCol++;
    }
    if (hdrs.indexOf('sancionMotivo') === -1) {
      sheet.getRange(1, lastCol + 1).setValue('sancionMotivo');
      lastCol++;
    }
    if (hdrs.indexOf('bonificacion') === -1) {
      sheet.getRange(1, lastCol + 1).setValue('bonificacion');
      lastCol++;
    }
    if (hdrs.indexOf('bonificacionMotivo') === -1) {
      sheet.getRange(1, lastCol + 1).setValue('bonificacionMotivo');
    }
  }
  return sheet;
}

// ── Configuración: tramos + metas + pesos ──────────────────────
function _getEvalConfig() {
  var rows = _sheetToObjects(getSheet('CONFIG_MOS'));
  var cfg = {};
  rows.forEach(function(r){ cfg[r.clave] = r.valor; });
  return {
    bonoTramos: [
      { min: 95, pct: 18 },
      { min: 85, pct: 12 },
      { min: 70, pct:  7 },
      { min: 50, pct:  3 },
      { min:  0, pct:  0 }
    ],
    metaCajero:      parseFloat(cfg.evalMetaCajero      || 2000),
    metaEnvasador:   parseFloat(cfg.evalMetaEnvasador   || 500),
    metaAlmacenero:  parseFloat(cfg.evalMetaAlmacenero  || 15),
    metaAuditorias:  parseFloat(cfg.evalMetaAuditorias  || 30),
    bonoMetaBase:    parseFloat(cfg.evalBonoMetaBase    || 8),
    bonoMetaDoble:   parseFloat(cfg.evalBonoMetaDoble   || 15),
    // Tarifa por unidad envasada — aplica a ENVASADOR (único pago) y a
    // ALMACENERO (pago extra si decide envasar además de sus tareas).
    tarifaEnvasadoPorUnidad: parseFloat(cfg.evalTarifaEnvasadoPorUnidad || 0.10),
    pesoVentas:     parseFloat(cfg.evalPesoVentas     || 30) / 100,
    pesoAuditoria:  parseFloat(cfg.evalPesoAudit      || 20) / 100,
    pesoLimpieza:   parseFloat(cfg.evalPesoLimp       || 15) / 100,
    pesoControl:    parseFloat(cfg.evalPesoControl    || 35) / 100
  };
}

// ── Crear evaluación (registro único, varias por día permitidas) ──
function crearEvaluacion(params) {
  if (!params.idPersonal) return { ok: false, error: 'idPersonal requerido' };
  if (!params.rol)        return { ok: false, error: 'rol requerido' };
  var sheet = _getEvalSheet();
  var tz    = Session.getScriptTimeZone();
  var ahora = new Date();
  var fecha = params.fecha || Utilities.formatDate(ahora, tz, 'yyyy-MM-dd');
  var hora  = Utilities.formatDate(ahora, tz, 'HH:mm:ss');
  var id    = _generateId('EV');
  sheet.appendRow([
    id, fecha, params.idPersonal, params.rol, hora,
    parseFloat(params.limpiezaPct)     || 0,
    parseFloat(params.limpiezaProfPct) || 0,
    typeof params.controlChecks === 'string' ? params.controlChecks : JSON.stringify(params.controlChecks || {}),
    params.comentario  || '',
    params.evaluadoPor || '',
    params.aplicaComision === false || String(params.aplicaComision) === 'false' ? false : true,
    params.aplicaBonoMeta === false || String(params.aplicaBonoMeta) === 'false' ? false : true,
    true,
    Math.max(0, parseFloat(params.sancion) || 0),
    String(params.sancionMotivo || ''),
    Math.max(0, parseFloat(params.bonificacion) || 0),    // [v2.41.51] extra
    String(params.bonificacionMotivo || '')
  ]);
  // [dual-write] Espejo inmediato a mos.evaluaciones (best-effort; Sheets = verdad).
  // Re-leo la fila recién creada por header (la hoja tiene columnas migradas dinámicas)
  // → byte-idéntica al batch. id_eval = PK natural. NO altera los hooks _liqDia* de abajo
  // (esos materializan LIQUIDACIONES_DIA; esto solo espeja la fila de EVALUACIONES).
  try {
    if (typeof _dualWriteMOS === 'function') {
      var _evData = sheet.getDataRange().getValues();
      var _evHdrs = _evData[0].map(function(h){ return String(h).trim(); });
      for (var _er = 1; _er < _evData.length; _er++) {
        if (String(_evData[_er][0]) === String(id)) {
          var _evObj = {}; for (var _eh = 0; _eh < _evHdrs.length; _eh++) { _evObj[_evHdrs[_eh]] = _evData[_er][_eh]; }
          _dualWriteMOS('evaluaciones', _evObj);
          break;
        }
      }
    }
  } catch (eDW) { Logger.log('[dualWrite crearEvaluacion] ' + (eDW && eDW.message)); }
  // [v2.41.63] Hook materialización en 2 pasos:
  // 1. _liqDiaRecomputar: asegura que la fila existe + actualiza montoBase/
  //    pagoEnvasado/bonoMeta auto (recomputed de actividad real).
  //    PRESERVA bonificacion/sancion/estado de fila existente.
  // 2. _liqDiaSetBonSan: si admin TOCÓ la sección ajuste (params._ajusteTocado
  //    o pasó valor > 0), REEMPLAZA bon/san con los nuevos valores (incluido 0).
  //    Esto permite al admin BORRAR un bono previo poniendo 0/vacío.
  //    Si NO tocó la sección ajuste, preserva el valor actual.
  var bonNueva = Math.max(0, parseFloat(params.bonificacion) || 0);
  var sanNueva = Math.max(0, parseFloat(params.sancion) || 0);
  var ajusteTocado = (params._ajusteTocado === true || String(params._ajusteTocado) === 'true' ||
                      params._resetBonSan === true || String(params._resetBonSan) === 'true' ||
                      bonNueva > 0 || sanNueva > 0);
  try {
    if (typeof _liqDiaRecomputar === 'function' && params.fecha) {
      _liqDiaRecomputar(params.idPersonal, params.fecha);
      if (typeof _liqDiaSetBonSan === 'function' && ajusteTocado) {
        var ajusteTipoActivo = String(params.ajusteTipo || '').toLowerCase();
        var soloTipo = null;
        if (ajusteTipoActivo === 'sancion' || ajusteTipoActivo === 'bonificacion') {
          soloTipo = ajusteTipoActivo;
        } else if (bonNueva > 0 && sanNueva === 0) {
          soloTipo = 'bonificacion';
        } else if (sanNueva > 0 && bonNueva === 0) {
          soloTipo = 'sancion';
        }

        // [v2.41.69] FUSIÓN motivos: concatenar todos los motivos de
        // EVALUACIONES del día/persona como timeline (incluyendo el actual).
        // Así LIQUIDACIONES_DIA.bonificacionMotivo refleja TODAS las razones
        // que llevaron al monto actual. Si el último admin puso 0 (borrar),
        // el motivo también queda vacío.
        var bonMotivoFinal = String(params.bonificacionMotivo || '');
        var sanMotivoFinal = String(params.sancionMotivo || '');
        try {
          var evalsTodas = _sheetToObjects(_getEvalSheet()).filter(function(e){
            if (e.activo === false || String(e.activo) === '0' || String(e.activo) === 'false') return false;
            var ef = e.fecha instanceof Date
              ? Utilities.formatDate(e.fecha, Session.getScriptTimeZone(), 'yyyy-MM-dd')
              : String(e.fecha || '').substring(0, 10);
            return ef === params.fecha && String(e.idPersonal) === String(params.idPersonal);
          });
          // Solo concatenar si el tipo activo tiene valor > 0
          if (bonNueva > 0 && (soloTipo === 'bonificacion' || soloTipo === null)) {
            var bonMots = evalsTodas
              .filter(function(e){ return (parseFloat(e.bonificacion) || 0) > 0; })
              .map(function(e){ return String(e.bonificacionMotivo || '').trim(); })
              .filter(function(m){ return m.length > 0; });
            if (bonMots.length) bonMotivoFinal = bonMots.join(' · ');
          } else if (bonNueva === 0 && soloTipo === 'bonificacion') {
            bonMotivoFinal = ''; // user borró el bono → limpiar motivo
          }
          if (sanNueva > 0 && (soloTipo === 'sancion' || soloTipo === null)) {
            var sanMots = evalsTodas
              .filter(function(e){ return (parseFloat(e.sancion) || 0) > 0; })
              .map(function(e){ return String(e.sancionMotivo || '').trim(); })
              .filter(function(m){ return m.length > 0; });
            if (sanMots.length) sanMotivoFinal = sanMots.join(' · ');
          } else if (sanNueva === 0 && soloTipo === 'sancion') {
            sanMotivoFinal = '';
          }
        } catch(eM) { Logger.log('Fusión motivos fallo: ' + eM.message); }

        _liqDiaSetBonSan(
          params.idPersonal, params.fecha,
          bonNueva, sanNueva,
          bonMotivoFinal, sanMotivoFinal,
          { soloTipo: soloTipo }
        );
      }
    }
  } catch(eH) { Logger.log('Hook _liqDia* fallo: ' + eH.message); }

  return { ok: true, data: { idEval: id, bonificacion: bonNueva, sancion: sanNueva, ajusteTocado: ajusteTocado } };
}

// ── Lista de evaluaciones del día (todas o de una persona) ─────
function getEvaluacionesDia(params) {
  var fecha = params.fecha || _hoy();
  var rows  = _sheetToObjects(_getEvalSheet()).filter(function(r){
    if (r.activo === false || String(r.activo) === '0' || String(r.activo) === 'false') return false;
    var rf = r.fecha instanceof Date
      ? Utilities.formatDate(r.fecha, Session.getScriptTimeZone(), 'yyyy-MM-dd')
      : String(r.fecha).substring(0, 10);
    if (rf !== fecha) return false;
    if (params.idPersonal && r.idPersonal !== params.idPersonal) return false;
    return true;
  });
  return { ok: true, data: rows };
}

// Normaliza fechas que vienen de MosExpress (Date, "yyyy-MM-dd...", "dd/MM/yyyy...")
function _normalizarFechaME(raw, tz) {
  if (raw instanceof Date) return Utilities.formatDate(raw, tz, 'yyyy-MM-dd');
  var s = String(raw || '').trim();
  if (!s) return '';
  // Si comienza con yyyy- (ISO): tomar primeros 10
  if (/^\d{4}-\d{2}-\d{2}/.test(s)) return s.substring(0, 10);
  // Si es dd/MM/yyyy o d/M/yyyy: convertir (formato MosExpress)
  var m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/);
  if (m) {
    var dd = m[1].length === 1 ? '0' + m[1] : m[1];
    var mm = m[2].length === 1 ? '0' + m[2] : m[2];
    return m[3] + '-' + mm + '-' + dd;
  }
  return s.substring(0, 10);
}

// Normaliza fechas de warehouseMos (formato M/D/yyyy — mes primero)
function _normalizarFechaWh(raw, tz) {
  if (raw instanceof Date) return Utilities.formatDate(raw, tz, 'yyyy-MM-dd');
  var s = String(raw || '').trim();
  if (!s) return '';
  if (/^\d{4}-\d{2}-\d{2}/.test(s)) return s.substring(0, 10);
  // M/D/yyyy (es el formato de WH según los datos)
  var m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/);
  if (m) {
    var mm = m[1].length === 1 ? '0' + m[1] : m[1];
    var dd = m[2].length === 1 ? '0' + m[2] : m[2];
    return m[3] + '-' + mm + '-' + dd;
  }
  return s.substring(0, 10);
}

// ── ¿La persona trabajó ese día? (sesión WH, caja abierta, ticket sellado) ──
function _estaPresente(p, fecha) {
  if (!p) return false;
  var idP = String(p.idPersonal || '');

  // Virtual MEX: existe solo si trabajó ese día
  if (idP.indexOf('MEX:') === 0) {
    return _verificarPresenciaME(p.nombre, fecha);
  }

  // WarehouseMos: chequear SESIONES
  if (p.appOrigen === 'warehouseMos') {
    try {
      var ses = _abrirWhSheet('SESIONES');
      if (!ses) return false;
      var d  = ses.getDataRange().getValues();
      var tz = Session.getScriptTimeZone();
      for (var i = 1; i < d.length; i++) {
        if (String(d[i][1] || '').trim() !== idP.trim()) continue;
        var f = _normalizarFechaWh(d[i][2], tz);
        if (f === fecha) return true;
      }
    } catch(_){}
    return false;
  }

  // mosExpress real: chequear CAJAS + VENTAS_CABECERA por nombre
  if (p.appOrigen === 'mosExpress') {
    return _verificarPresenciaME(p.nombre, fecha);
  }
  return false;
}

function _verificarPresenciaME(nombre, fecha) {
  var nLow = String(nombre || '').toLowerCase().trim();
  if (!nLow) return false;
  var tz = Session.getScriptTimeZone();

  // CAJAS (cajero abrió caja)
  try {
    var cs = _abrirMeSheet('CAJAS');
    if (cs) {
      var d  = cs.getDataRange().getValues();
      var headers = (d[0] || []).map(function(h){ return String(h || ''); });
      var idxV = headers.indexOf('Vendedor'); if (idxV < 0) idxV = 1;
      var idxF = -1;
      for (var hi = 0; hi < headers.length; hi++) {
        var hl = headers[hi].toLowerCase();
        if (hl.indexOf('fecha') >= 0 && hl.indexOf('apert') >= 0) { idxF = hi; break; }
      }
      if (idxF < 0) for (var hi2 = 0; hi2 < headers.length; hi2++) {
        if (headers[hi2].toLowerCase().indexOf('fecha') >= 0) { idxF = hi2; break; }
      }
      for (var i = 1; i < d.length; i++) {
        var v = String(d[i][idxV] || '').toLowerCase().trim();
        if (v !== nLow && v.indexOf(nLow) < 0 && nLow.indexOf(v) < 0) continue;
        var f = idxF >= 0 ? _normalizarFechaME(d[i][idxF], tz) : '';
        if (f === fecha) return true;
      }
    }
  } catch(_){}

  // VENTAS_CABECERA (vendedor selló ticket)
  try {
    var vs = _abrirMeSheet('VENTAS_CABECERA');
    if (vs) {
      var vd = vs.getDataRange().getValues();
      for (var rv = 1; rv < vd.length; rv++) {
        var v = String(vd[rv][2] || '').toLowerCase().trim();
        if (v !== nLow && v.indexOf(nLow) < 0 && nLow.indexOf(v) < 0) continue;
        var f = _normalizarFechaME(vd[rv][1], tz);
        if (f === fecha) return true;
      }
    }
  } catch(_){}

  // [v2.41.76] REMOVIDO criterio Ultima_Conexion como presencia.
  // Antes: "basta con loguearse para contar como presente" → causaba
  // que vendedores que solo abrían la PWA (sin vender, sin caja) figuren
  // como presentes hoy aunque hayan iniciado sesión AYER y nunca
  // cerraran. Ahora la presencia se basa SOLO en evidencia operativa:
  //   • CAJAS de ese día (cajero abrió caja)
  //   • VENTAS_CABECERA de ese día (vendedor selló ticket)
  //   • SESIONES WH de ese día (almacenero/envasador inició sesión)
  // Si alguien solo "estuvo logueado" pero no trabajó, NO presente.
  return false;
}

// ── Detecta los registros "Cajero/Vendedor Genérico" en PERSONAL_MASTER ──
// Busca en nombre + apellido (insensitive case + acentos), filtra por mosExpress.
function _detectarGenericosME(personal) {
  function _norm(s) {
    return String(s || '')
      .toLowerCase()
      .replace(/[áàä]/g, 'a').replace(/[éèë]/g, 'e').replace(/[íìï]/g, 'i')
      .replace(/[óòö]/g, 'o').replace(/[úùü]/g, 'u');
  }
  return (personal || []).filter(function(r){
    var app = _norm(r.appOrigen);
    if (app !== 'mosexpress') return false;
    var nombreCompleto = _norm(String(r.nombre || '') + ' ' + String(r.apellido || ''));
    return nombreCompleto.indexOf('generic') >= 0;
  });
}

// ── Resolver persona (real o virtual MEX:nombre desde MosExpress) ──
// Para virtuales detecta si tuvo caja abierta hoy → CAJERO, si solo vendió → VENDEDOR
function _resolverPersona(idPersonal, fechaHint) {
  if (idPersonal && idPersonal.indexOf('MEX:') === 0) {
    var nombre = idPersonal.substring(4);
    var personal = _sheetToObjects(getSheet('PERSONAL_MASTER'));
    var genericos = _detectarGenericosME(personal);

    // Detectar el rol real consultando CAJAS de hoy (o fechaHint)
    var rolDetectado = 'VENDEDOR';
    var fechaCheck = fechaHint || _hoy();
    try {
      var cs = _abrirMeSheet('CAJAS');
      if (cs) {
        var d = cs.getDataRange().getValues();
        var tz2 = Session.getScriptTimeZone();
        for (var i = 1; i < d.length; i++) {
          var v = String(d[i][1] || '').trim();
          if (v.toLowerCase() !== nombre.toLowerCase()) continue;
          // Encontrar cualquier columna fecha
          var fr = d[i][3] || d[i][2] || null; // intento de fecha
          // Mejor: revisar toda la fila para una fecha que coincida
          for (var c = 0; c < d[i].length; c++) {
            var cell = d[i][c];
            if (cell instanceof Date) {
              var fs = Utilities.formatDate(cell, tz2, 'yyyy-MM-dd');
              if (fs === fechaCheck) { rolDetectado = 'CAJERO'; break; }
            }
          }
          if (rolDetectado === 'CAJERO') break;
        }
      }
    } catch(_){}

    var g = genericos.find(function(x){ return String(x.rol || '').toUpperCase() === rolDetectado; }) || genericos[0];

    return {
      idPersonal: idPersonal,
      nombre:     nombre,
      apellido:   '',
      tipo:       'VENDEDOR',
      appOrigen:  'mosExpress',
      rol:        rolDetectado,
      montoBase:  g ? (parseFloat(g.montoBase) || 0) : 0,
      estado:     '1',
      __virtual:  true
    };
  }
  var personal = _sheetToObjects(getSheet('PERSONAL_MASTER'));
  return personal.find(function(x){ return x.idPersonal === idPersonal; });
}

// ── Resumen del día por persona — ACUMULATIVO (MAX/OR) ─────────
function getResumenDia(params) {
  var fecha      = params.fecha || _hoy();
  var idPersonal = params.idPersonal;
  if (!idPersonal) return { ok: false, error: 'idPersonal requerido' };

  var p = _resolverPersona(idPersonal, fecha);
  if (!p) return { ok: false, error: 'Personal no encontrado' };

  var evals = _sheetToObjects(_getEvalSheet()).filter(function(r){
    if (r.activo === false || String(r.activo) === '0' || String(r.activo) === 'false') return false;
    var rf = r.fecha instanceof Date
      ? Utilities.formatDate(r.fecha, Session.getScriptTimeZone(), 'yyyy-MM-dd')
      : String(r.fecha).substring(0, 10);
    return rf === fecha && r.idPersonal === idPersonal;
  });

  // Acumulativo: MAX para limpiezas, OR para checks. SUMA para sanciones
  // (cada evaluación del día puede tener su propia sanción independiente).
  var maxLimp = 0, maxLimpProf = 0;
  var checksAcum = {};
  var totalKeysVistos = {};   // todas las llaves del checklist enviadas
  var comentarios = [];
  var aplicaComision = true, aplicaBonoMeta = true;
  var sancionTotal = 0;
  var sancionesDetalle = [];  // [{ hora, monto, motivo }]
  var bonificacionTotal = 0;
  var bonificacionesDetalle = [];  // [{ hora, monto, motivo }]
  evals.forEach(function(e){
    var l  = parseFloat(e.limpiezaPct) || 0;
    if (l  > maxLimp)     maxLimp     = l;
    var lp = parseFloat(e.limpiezaProfPct) || 0;
    if (lp > maxLimpProf) maxLimpProf = lp;
    try {
      var c = typeof e.controlChecks === 'string'
        ? JSON.parse(e.controlChecks || '{}')
        : (e.controlChecks || {});
      Object.keys(c).forEach(function(k){
        totalKeysVistos[k] = true;
        if (c[k]) checksAcum[k] = true;
      });
    } catch(_){}
    if (e.comentario) comentarios.push('[' + e.hora + '] ' + e.comentario);
    if (e.aplicaComision === false || String(e.aplicaComision) === 'false') aplicaComision = false;
    if (e.aplicaBonoMeta === false || String(e.aplicaBonoMeta) === 'false') aplicaBonoMeta = false;
    // Sanción: las sanciones SE SUMAN entre evaluaciones del día (no MAX)
    var sancRow = parseFloat(e.sancion) || 0;
    if (sancRow > 0) {
      sancionTotal += sancRow;
      sancionesDetalle.push({
        hora: e.hora || '', monto: sancRow, motivo: String(e.sancionMotivo || '')
      });
    }
    // [v2.41.51] Bonificación: también se SUMA entre evaluaciones del día
    var bonRow = parseFloat(e.bonificacion) || 0;
    if (bonRow > 0) {
      bonificacionTotal += bonRow;
      bonificacionesDetalle.push({
        hora: e.hora || '', monto: bonRow, motivo: String(e.bonificacionMotivo || '')
      });
    }
  });
  sancionTotal = Math.round(sancionTotal * 100) / 100;
  bonificacionTotal = Math.round(bonificacionTotal * 100) / 100;

  var checkCount = Object.keys(checksAcum).length;
  var checkTotal = Object.keys(totalKeysVistos).length || 9;
  var controlPct = checkTotal > 0 ? (checkCount / checkTotal) * 100 : 0;

  // KPIs auto del día
  var kpis = _calcularKpisAutoDia(p, fecha);
  var cfg  = _getEvalConfig();

  // Score final ponderado
  var scoreFinal = (kpis.ventasPct      * cfg.pesoVentas)
                 + (kpis.auditPct       * cfg.pesoAuditoria)
                 + (((maxLimp + maxLimpProf) / 2) * cfg.pesoLimpieza)
                 + (controlPct          * cfg.pesoControl);
  scoreFinal = Math.round(scoreFinal * 10) / 10;

  // ── Bono por desempeño ELIMINADO ──
  // Antes existía un "bono score" calculado por tramos sobre montoBase.
  // El user pidió retirarlo: no está entre los 5 puntos de evaluación,
  // así que aquí lo dejamos en 0 (los lectores legacy ven 0, sin romper).
  var bonusPctScore = 0;
  var montoBase  = parseFloat(p.montoBase) || 0;
  var bonusScore = 0;

  // Bono por meta SOLO aplica a CAJERO/VENDEDOR (POS). Usa la meta
  // efectiva (kpis.metaVenta de la zona principal). Ni ALMACENERO ni
  // ENVASADOR tienen bono por meta:
  //   - ENVASADOR: pago = unidades × tarifa (puro)
  //   - ALMACENERO: pago = base diario + envasado opcional + bono score
  var bonoMeta = 0, metaPct = 0;
  if (aplicaBonoMeta) {
    var meta = 0, real = 0;
    if (p.rol === 'CAJERO' || p.rol === 'VENDEDOR') {
      meta = kpis.metaVenta || cfg.metaCajero;
      real = kpis.ventasReales;
    }
    if (meta > 0) {
      metaPct = Math.round((real / meta) * 1000) / 10;
      if (real >= meta * 2) bonoMeta = cfg.bonoMetaDoble;
      else if (real >= meta) bonoMeta = cfg.bonoMetaBase;
    }
  }

  // Pago por envasado (aplica a ENVASADOR siempre y ALMACENERO cuando
  // también envasa). Suma directo al total del día. Es independiente
  // del bono/auditoría (cobra aunque no haya sido auditado).
  var pagoEnvasado = 0;
  if (p.rol === 'ENVASADOR' || p.rol === 'ALMACENERO') {
    pagoEnvasado = Math.round((parseFloat(kpis.envasados) || 0) * cfg.tarifaEnvasadoPorUnidad * 100) / 100;
  }

  // Lógica de pago por rol:
  // - ENVASADOR: solo pago por envasado (sin base diaria)
  // - ALMACENERO: base diaria + envasado opcional
  // - CAJERO/VENDEDOR: base diaria + bono por meta (si la zona la logró)
  // Reglas:
  //   - Base diaria: solo si presente
  //   - Bono por meta: solo presente + auditado (no aplica a almacén)
  //   - Envasado: solo si presente (es por trabajo real, sin auditoría requerida)
  var presente = _estaPresente(p, fecha);
  var auditado = evals.length > 0;
  var esEnvasadorPuro = (p.rol === 'ENVASADOR');
  var baseEfectiva  = (presente && !esEnvasadorPuro) ? montoBase : 0;
  var bonusEfectivo = 0; // Bono por desempeño eliminado
  var metaEfectivo  = (presente && auditado && !esEnvasadorPuro) ? bonoMeta   : 0;
  var envasadoEfectivo = presente ? pagoEnvasado : 0;

  return {
    ok: true,
    data: {
      idPersonal:        p.idPersonal,
      nombre:            (p.nombre + ' ' + (p.apellido || '')).trim(),
      rol:               p.rol,
      appOrigen:         p.appOrigen,
      fecha:             fecha,
      evaluacionesCount: evals.length,
      presente:          presente,
      auditado:          auditado,
      kpis:              kpis,
      manual: {
        limpiezaPct:     maxLimp,
        limpiezaProfPct: maxLimpProf,
        checksAcum:      checksAcum,
        checkCount:      checkCount,
        checkTotal:      checkTotal,
        controlPct:      Math.round(controlPct * 10) / 10,
        comentarios:     comentarios.join('\n')
      },
      scoreFinal:    scoreFinal,
      bonusPctScore: bonusPctScore,
      bonusScore:    Math.round(bonusEfectivo * 100) / 100,
      bonoMeta:      metaEfectivo,
      metaPct:       metaPct,
      pagoEnvasado:  Math.round(envasadoEfectivo * 100) / 100,  // nuevo
      tarifaEnvasado: cfg.tarifaEnvasadoPorUnidad,                // info: cuánto S/uds
      unidadesEnvasadas: parseFloat(kpis.envasados) || 0,
      sancion:       sancionTotal,                                // monto descontado del día
      sancionesDetalle: sancionesDetalle,
      bonificacion:  bonificacionTotal,                            // [v2.41.51] extra del día
      bonificacionesDetalle: bonificacionesDetalle,
      montoBase:     baseEfectiva,
      tarifaDiaria:  montoBase, // tarifa configurada (info)
      // totalDia: base + bonus + meta + envasado + bonificación − sanción.
      // Si la sanción es mayor que lo que ganó, queda en 0 (no negativo).
      totalDia:      Math.max(0, Math.round((baseEfectiva + bonusEfectivo + metaEfectivo + envasadoEfectivo + bonificacionTotal - sancionTotal) * 100) / 100),
      aplicaComision: aplicaComision,
      aplicaBonoMeta: aplicaBonoMeta
    }
  };
}

// ── KPIs automáticos del día (consulta apps externas) ──────────
function _calcularKpisAutoDia(p, fecha) {
  var rol    = String(p.rol || '').toUpperCase();
  var nombre = (p.nombre + ' ' + (p.apellido || '')).trim();
  var cfg    = _getEvalConfig();

  var ventasReales = 0, ventasPct = 0, guias = 0, envasados = 0;
  var auditoriasHechas = 0, auditPct = 0;

  // Auditorías de productos según app del empleado (meta 30/día para todos)
  try {
    if (rol === 'CAJERO' || rol === 'VENDEDOR') {
      // MosExpress · AUDITORIAS: cols 0=ID 1=Fecha 2=Vendedor ...
      var au = _abrirMeSheet('AUDITORIAS');
      if (au) {
        var ad = au.getDataRange().getValues();
        var tzM = Session.getScriptTimeZone();
        for (var ar = 1; ar < ad.length; ar++) {
          var fA = _normalizarFechaME(ad[ar][1], tzM);
          if (fA !== fecha) continue;
          var vA = String(ad[ar][2] || '').toLowerCase().trim();
          if (!vA) continue;
          var nL = (p.nombre || '').toLowerCase().trim();
          if (vA === nL || vA.indexOf(nL) >= 0 || nL.indexOf(vA) >= 0) auditoriasHechas++;
        }
      }
    } else if (rol === 'ALMACENERO' || rol === 'ENVASADOR') {
      // warehouseMos · AUDITORIAS: 3=usuario 9=estado 10=fechaEjecucion
      var auW = _abrirWhSheet('AUDITORIAS');
      if (auW) {
        var adW = auW.getDataRange().getValues();
        var headers = (adW[0] || []).map(function(h){ return String(h || ''); });
        var idxUser    = headers.indexOf('usuario');
        var idxEstado  = headers.indexOf('estado');
        var idxFechaEj = headers.indexOf('fechaEjecucion');
        if (idxUser    < 0) idxUser    = 3;
        if (idxEstado  < 0) idxEstado  = 9;
        if (idxFechaEj < 0) idxFechaEj = 10;
        var tzW = Session.getScriptTimeZone();
        var nLow = (p.nombre + ' ' + (p.apellido || '')).toLowerCase().trim();
        for (var arW = 1; arW < adW.length; arW++) {
          var estA = String(adW[arW][idxEstado] || '').toUpperCase().trim();
          if (estA !== 'EJECUTADA') continue;
          var fW = _normalizarFechaWh(adW[arW][idxFechaEj], tzW);
          if (fW !== fecha) continue;
          var uW = String(adW[arW][idxUser] || '').toLowerCase().trim();
          if (!uW) continue;
          if (uW === nLow || uW.indexOf((p.nombre || '').toLowerCase()) >= 0 || nLow.indexOf(uW) >= 0) {
            auditoriasHechas++;
          }
        }
      }
    }
  } catch(eA){ Logger.log('KPI auditorias error: ' + eA.message); }
  auditPct = Math.min(100, (auditoriasHechas / cfg.metaAuditorias) * 100);

  try {
    if (rol === 'CAJERO' || rol === 'VENDEDOR') {
      // Leer directo de VENTAS_CABECERA de MosExpress
      // Además, contar ventas por zona (via ID_Caja → CAJAS.zona) para
      // determinar la "zona principal" del personal en este día.
      // Su política (meta diaria + meta auditorías) se resuelve desde ahí.
      var ventasPorZona = {};   // { 'ZONA-02': 1200, 'ZONA-03': 400 }
      var cajaZonaMap   = {};   // cache idCaja → zona (evita re-leer CAJAS)
      try {
        var shCajas = _abrirMeSheet('CAJAS');
        if (shCajas) {
          var dCajas = shCajas.getDataRange().getValues();
          for (var rc = 1; rc < dCajas.length; rc++) {
            cajaZonaMap[String(dCajas[rc][0])] = String(dCajas[rc][8] || '');
          }
        }
      } catch(_){}
      try {
        var sh = _abrirMeSheet('VENTAS_CABECERA');
        if (sh) {
          var data = sh.getDataRange().getValues();
          var tz   = Session.getScriptTimeZone();
          var nombreLow = (p.nombre || '').toLowerCase().trim();
          // Headers tipicos: 0=ID 1=Fecha 2=Vendedor 6=Total 8=FormaPago 10=ID_Caja
          for (var r = 1; r < data.length; r++) {
            var row = data[r];
            var fRaw = row[1];
            var fStr = _normalizarFechaME(fRaw, tz);
            if (fStr !== fecha) continue;
            var vendedor = String(row[2] || '').toLowerCase().trim();
            var formaPago = String(row[8] || '').toUpperCase().trim();
            if (!vendedor) continue;
            // Solo cuentan ventas COBRADAS (excluye ANULADO, POR_COBRAR, CREDITO)
            if (formaPago === 'ANULADO' || formaPago === 'POR_COBRAR' || formaPago === 'CREDITO') continue;
            // Match por contención (vendedor field puede tener nombre completo)
            if (vendedor === nombreLow || vendedor.indexOf(nombreLow) >= 0 || nombreLow.indexOf(vendedor) >= 0) {
              var totalRow = parseFloat(row[6]) || 0;
              ventasReales += totalRow;
              var idCaja = String(row[10] || '');
              var zonaVenta = cajaZonaMap[idCaja] || '';
              if (zonaVenta) ventasPorZona[zonaVenta] = (ventasPorZona[zonaVenta] || 0) + totalRow;
            }
          }
        }
      } catch(eV){ Logger.log('KPI ventas error: ' + eV.message); }
      // Zona principal = donde más vendió. Resolver su política
      var zonaPrincipal = '';
      Object.keys(ventasPorZona).forEach(function(z){
        if (!zonaPrincipal || ventasPorZona[z] > ventasPorZona[zonaPrincipal]) zonaPrincipal = z;
      });
      var politicaPersonal = (typeof _resolverPoliticaZona === 'function')
        ? _resolverPoliticaZona(zonaPrincipal) : null;
      var metaVtaUsar = (politicaPersonal && politicaPersonal.metaDiaria > 0)
        ? politicaPersonal.metaDiaria : cfg.metaCajero;
      var metaAudUsar = (politicaPersonal && politicaPersonal.metaAuditorias > 0)
        ? politicaPersonal.metaAuditorias : cfg.metaAuditorias;
      ventasPct = Math.min(100, (ventasReales / metaVtaUsar) * 100);
      // Recalcular auditPct con la meta de la zona del personal
      auditPct = Math.min(100, (auditoriasHechas / metaAudUsar) * 100);
      // Sobrescribir el valor que se retorna abajo
      cfg._metaAuditoriasEfectiva = metaAudUsar;
      cfg._metaVentaEfectiva      = metaVtaUsar;
      cfg._zonaPrincipal          = zonaPrincipal;
    } else if (rol === 'ENVASADOR') {
      // Leer ENVASADOS directo de warehouseMos (formato M/D/yyyy)
      try {
        var sh = _abrirWhSheet('ENVASADOS');
        if (sh) {
          var d = sh.getDataRange().getValues();
          var headers = (d[0] || []).map(function(h){ return String(h || ''); });
          var idxFecha = headers.indexOf('fecha');
          var idxUser  = headers.indexOf('usuario');
          var idxUds   = headers.indexOf('unidadesProducidas');
          var idxEstado= headers.indexOf('estado');
          if (idxFecha < 0 || idxUser < 0 || idxUds < 0) {
            // Fallback por posición típica
            idxFecha = idxFecha >= 0 ? idxFecha : 9;
            idxUser  = idxUser  >= 0 ? idxUser  : 10;
            idxUds   = idxUds   >= 0 ? idxUds   : 6;
          }
          var tzWh = Session.getScriptTimeZone();
          var nLow = (p.nombre + ' ' + (p.apellido || '')).toLowerCase().trim();
          for (var r = 1; r < d.length; r++) {
            var f = _normalizarFechaWh(d[r][idxFecha], tzWh);
            if (f !== fecha) continue;
            // [v2.41.31] Solo COMPLETADO cuenta para pago. Antes solo excluía
            // ANULADO, pero podía colar EN_PROCESO/PENDIENTE/etc. que no son pagos reales.
            if (idxEstado >= 0 && String(d[r][idxEstado]).toUpperCase() !== 'COMPLETADO') continue;
            var u = String(d[r][idxUser] || '').toLowerCase().trim();
            if (!u) continue;
            if (u === nLow || u.indexOf(p.nombre.toLowerCase()) >= 0 || nLow.indexOf(u) >= 0) {
              envasados += parseFloat(d[r][idxUds]) || 0;
            }
          }
        }
      } catch(eE){ Logger.log('KPI envasados error: ' + eE.message); }
      ventasPct = Math.min(100, (envasados / cfg.metaEnvasador) * 100);
    } else if (rol === 'ALMACENERO') {
      // Leer GUIAS directo de warehouseMos: solo cuentan guías CERRADAS
      // (las INGRESO_ENVASADO y SALIDA_ENVASADO son automáticas, no cuentan)
      try {
        var shG = _abrirWhSheet('GUIAS');
        if (shG) {
          var dG = shG.getDataRange().getValues();
          var hG = (dG[0] || []).map(function(h){ return String(h || ''); });
          var iFecha  = hG.indexOf('fecha');
          var iUser   = hG.indexOf('usuario');
          var iTipo   = hG.indexOf('tipo');
          var iEstado = hG.indexOf('estado');
          if (iFecha < 0)  iFecha  = 2;
          if (iUser < 0)   iUser   = 3;
          if (iTipo < 0)   iTipo   = 1;
          if (iEstado < 0) iEstado = 9;
          var tzWh2 = Session.getScriptTimeZone();
          var nLow2 = (p.nombre + ' ' + (p.apellido || '')).toLowerCase().trim();
          for (var rg = 1; rg < dG.length; rg++) {
            var fG = _normalizarFechaWh(dG[rg][iFecha], tzWh2);
            if (fG !== fecha) continue;
            var tipo = String(dG[rg][iTipo] || '').toUpperCase();
            // Excluir guías automáticas de envasado (las cuenta el envasador, no el almacenero)
            if (tipo === 'INGRESO_ENVASADO' || tipo === 'SALIDA_ENVASADO') continue;
            var uG = String(dG[rg][iUser] || '').toLowerCase().trim();
            if (!uG) continue;
            if (uG === nLow2 || uG.indexOf(p.nombre.toLowerCase()) >= 0 || nLow2.indexOf(uG) >= 0) {
              guias++;
            }
          }
        }
      } catch(eG){ Logger.log('KPI guias error: ' + eG.message); }
      // [v2.41.30] BUG FIX: el almacenero también envasa y debe cobrar por unidad.
      // Antes solo el bloque ENVASADOR leía la hoja ENVASADOS, así que kpis.envasados
      // quedaba en 0 para almaceneros aunque hubieran envasado, y luego el cálculo
      // de pagoEnvasado (que SÍ aplica al ALMACENERO en línea ~426) daba 0.
      try {
        var shE = _abrirWhSheet('ENVASADOS');
        if (shE) {
          var dE = shE.getDataRange().getValues();
          var hE = (dE[0] || []).map(function(h){ return String(h || ''); });
          var iFE   = hE.indexOf('fecha');
          var iUE   = hE.indexOf('usuario');
          var iUds  = hE.indexOf('unidadesProducidas');
          var iEstE = hE.indexOf('estado');
          if (iFE < 0) iFE = 9;
          if (iUE < 0) iUE = 10;
          if (iUds < 0) iUds = 6;
          var tzWhE = Session.getScriptTimeZone();
          var nLowE = (p.nombre + ' ' + (p.apellido || '')).toLowerCase().trim();
          for (var rE = 1; rE < dE.length; rE++) {
            var fE = _normalizarFechaWh(dE[rE][iFE], tzWhE);
            if (fE !== fecha) continue;
            // [v2.41.31] Solo COMPLETADO cuenta para pago
            if (iEstE >= 0 && String(dE[rE][iEstE]).toUpperCase() !== 'COMPLETADO') continue;
            var uE = String(dE[rE][iUE] || '').toLowerCase().trim();
            if (!uE) continue;
            if (uE === nLowE || uE.indexOf(p.nombre.toLowerCase()) >= 0 || nLowE.indexOf(uE) >= 0) {
              envasados += parseFloat(dE[rE][iUds]) || 0;
            }
          }
        }
      } catch(eE2){ Logger.log('KPI envasados (almacenero) error: ' + eE2.message); }
      ventasPct = Math.min(100, (guias / cfg.metaAlmacenero) * 100);
    }
  } catch(_){}

  // Meta de auditorías efectiva: si el personal es POS, viene de la zona
  // principal (politicaJSON.metaAuditorias). Si no, global cfg.metaAuditorias.
  var metaAudResp = cfg._metaAuditoriasEfectiva || cfg.metaAuditorias;
  var metaVtaResp = cfg._metaVentaEfectiva      || cfg.metaCajero;
  return {
    ventasReales:     Math.round(ventasReales * 100) / 100,
    ventasPct:        Math.round(ventasPct * 10) / 10,
    auditoriasHechas: auditoriasHechas,
    metaAuditorias:   metaAudResp,                  // meta usada (por zona o global)
    metaVenta:        metaVtaResp,                  // meta usada (por zona o global)
    zonaPrincipal:    cfg._zonaPrincipal || '',     // zona inferida (POS)
    auditPct:         Math.round(auditPct * 10) / 10,
    guias:            guias,
    envasados:        envasados
  };
}

// ── Resumen del día para TODOS los empleados ───────────────────
// Incluye warehouseMos del master + vendedores reales que abrieron caja hoy
// en MosExpress. Si un vendedor no está en master se vuelve virtual MEX:nombre.
// ── Personal evaluable ──────────────────────────────────────
// Determina si un colaborador entra en evaluación / liquidación.
// EXCLUIDOS:
//   - appOrigen = 'MOS'         (admins del panel, no son operativos)
//   - rol = MASTER              (acceso total, audita pero no es auditado)
//   - rol = ADMINISTRADOR/ADMIN  (idem)
// INCLUIDOS:
//   - warehouseMos: ALMACENERO, ENVASADOR, OPERADOR (operativos)
//   - mosExpress:   CAJERO, VENDEDOR
function _esPersonalEvaluable(p) {
  if (!p) return false;
  if (String(p.appOrigen || '') === 'MOS') return false;
  var rol = String(p.rol || '').toUpperCase();
  if (rol === 'MASTER' || rol === 'ADMINISTRADOR' || rol === 'ADMIN') return false;
  return true;
}

function getResumenTodosDia(params) {
  var fecha    = params.fecha || _hoy();
  // [v2.41.57] Auto-instala el trigger nocturno de cierre 23h también aquí
  // (no solo en Liquidaciones). Personal del Día se abre TODOS los días desde
  // Finanzas → garantiza que el cron quede registrado aunque nadie abra
  // Liquidaciones por días.
  try { if (typeof _liqEnsureCierreNocturnoTrigger === 'function') _liqEnsureCierreNocturnoTrigger(); } catch(_){}
  // [v2.41.44] Cache 120s con CacheService — evita recalcular las 30-50 lecturas
  // de hoja en cada hit. Frontend lo llama varias veces (Personal del Día,
  // resumen, audit, etc.). params._refresh=true para forzar bypass.
  var ssCache, cacheKey;
  if (!params._refresh) {
    try {
      ssCache = CacheService.getScriptCache();
      cacheKey = 'rsmTd2_' + fecha;
      var hit = ssCache.get(cacheKey);
      if (hit) {
        try { return JSON.parse(hit); } catch(_){}
      }
    } catch(_){}
  }
  var todosPersonal = _sheetToObjects(getSheet('PERSONAL_MASTER')).filter(function(r){
    return String(r.estado) === '1';
  });
  var personal = todosPersonal.filter(_esPersonalEvaluable);

  // ── Set de nombres de admin/master/MOS para EXCLUIR ─────────
  // Cuando un admin o master abre WH (o ME), su nombre queda en
  // DISPOSITIVOS.Ultima_Sesion y los reports de actividad pueden
  // detectarlo. Sin esta exclusión se creaban virtuales tipo
  // "OPERADOR" en la lista de personal del día. Solo cuentan:
  //   - WH: ALMACENERO, ENVASADOR, OPERADOR
  //   - ME: CAJERO, VENDEDOR
  // REGLA: excluir SOLO por nombre+apellido (n2). El nombre solo (n1)
  // generaba falsos positivos cuando un vendedor real comparte primer
  // nombre con un admin (ej: "javier" vendedor vs "Javier Vasquez" ADMIN).
  var excluidosNorm = {};
  todosPersonal.forEach(function(p){
    if (_esPersonalEvaluable(p)) return;
    var n2 = (String(p.nombre || '') + ' ' + String(p.apellido || '')).toLowerCase().trim();
    if (n2 && n2.indexOf(' ') >= 0) excluidosNorm[n2] = true;
  });

  // Detectar genéricos de mosExpress por rol (plantillas para virtuales)
  var genericos = _detectarGenericosME(personal);
  function _genericoPorRol(rol) {
    var g = genericos.find(function(x){ return String(x.rol || '').toUpperCase() === rol; });
    return g || genericos[0] || null;
  }

  // 1. WarehouseMos: solo los que iniciaron sesión hoy (tienen fila en SESIONES)
  var idsWhDelDia = {};
  try {
    var sesSheet = _abrirWhSheet('SESIONES');
    if (sesSheet) {
      var sd = sesSheet.getDataRange().getValues();
      var tzWh = Session.getScriptTimeZone();
      // Cols esperadas: 0=idSesion 1=idPersonal 2=fechaInicio 3=horaInicio ...
      for (var rs = 1; rs < sd.length; rs++) {
        var fr = sd[rs][2];
        var fs = _normalizarFechaWh(fr, tzWh);
        if (fs !== fecha) continue;
        var idP = String(sd[rs][1] || '').trim();
        if (idP) idsWhDelDia[idP] = true;
      }
    }
  } catch(e){ Logger.log('No se pudo leer SESIONES: ' + e.message); }

  var lista = personal.filter(function(r){
    return r.appOrigen === 'warehouseMos' && idsWhDelDia[r.idPersonal];
  });

  // 2. MosExpress: 2a) cajeros (CAJAS) + 2b) vendedores puros (VENTAS_CABECERA)
  var rolesDelDia = {}; // nombre → 'CAJERO' | 'VENDEDOR'
  var tz = Session.getScriptTimeZone();

  // 2a. Cajeros — abren caja
  try {
    var cajasSheet = _abrirMeSheet('CAJAS');
    if (cajasSheet) {
      var data = cajasSheet.getDataRange().getValues();
      var headers = (data[0] || []).map(function(h){ return String(h || ''); });
      var idxVendedor = headers.indexOf('Vendedor');
      if (idxVendedor < 0) idxVendedor = 1;
      var idxFechaApertura = -1;
      for (var hi = 0; hi < headers.length; hi++) {
        var hLow = headers[hi].toLowerCase();
        if (hLow.indexOf('fecha') >= 0 && hLow.indexOf('apert') >= 0) { idxFechaApertura = hi; break; }
      }
      if (idxFechaApertura < 0) {
        for (var hi2 = 0; hi2 < headers.length; hi2++) {
          if (headers[hi2].toLowerCase().indexOf('fecha') >= 0) { idxFechaApertura = hi2; break; }
        }
      }
      for (var r = 1; r < data.length; r++) {
        var row = data[r];
        var f = idxFechaApertura >= 0 ? row[idxFechaApertura] : null;
        var fStr = _normalizarFechaME(f, tz);
        if (fStr !== fecha) continue;
        var nombre = String(row[idxVendedor] || '').trim();
        if (nombre) rolesDelDia[nombre] = 'CAJERO';
      }
    }
  } catch(e){ Logger.log('No se pudo leer CAJAS: ' + e.message); }

  // 2b. Vendedores puros — solo sellan tickets (no aparecen en CAJAS)
  try {
    var ventasSheet = _abrirMeSheet('VENTAS_CABECERA');
    if (ventasSheet) {
      var vd = ventasSheet.getDataRange().getValues();
      // Cols: 0=ID 1=Fecha 2=Vendedor 6=Total 8=FormaPago
      for (var rv = 1; rv < vd.length; rv++) {
        var fr = vd[rv][1];
        var fs = _normalizarFechaME(fr, tz);
        if (fs !== fecha) continue;
        var nv = String(vd[rv][2] || '').trim();
        if (!nv) continue;
        // Si ya está como CAJERO, mantener ese rol (más autoritativo)
        if (!rolesDelDia[nv]) rolesDelDia[nv] = 'VENDEDOR';
      }
    }
  } catch(e){ Logger.log('No se pudo leer VENTAS_CABECERA: ' + e.message); }

  // [v2.41.76] REMOVIDO bloque 2c (DISPOSITIVOS heartbeat).
  // Antes incluía como "presente" a quien solo abrió la PWA aunque no
  // hubiera vendido ni abierto caja. Eso causaba que vendedores de AYER
  // aparecieran HOY si abrían la app un instante. Ahora la lista del día
  // sale SOLO de evidencia operativa real:
  //   • CAJAS (2a) — cajero abrió caja
  //   • VENTAS_CABECERA (2b) — vendedor selló ticket
  // El admin que quiera ver "quién está logueado ahora" tiene el panel
  // Config → Dispositivos. Esto NO es lo mismo que "trabajó hoy".

  // 3. Para cada nombre detectado: matchear con master o crear virtual
  //
  // ── Regla de matching (PERSONAL_MASTER es source of truth) ──
  // Buscamos por nombre en cualquier appOrigen, no solo mosExpress.
  // Esto evita que un ENVASADOR/ALMACENERO (registrado en warehouseMos)
  // se duplique como VENDEDOR virtual cuando su nombre aparezca en
  // ventas/cajas de ME (p.ej. si abrió caja para cubrir un descanso).
  // El rol REAL del master gana al rol detectado por la actividad.
  Object.keys(rolesDelDia).forEach(function(nombre){
    var rol = rolesDelDia[nombre];
    var nLow = nombre.toLowerCase().trim();
    // FILTRO: si el nombre coincide con un admin/master de PERSONAL_MASTER,
    // descartarlo. No deben aparecer en el listado del día.
    if (excluidosNorm[nLow]) return;
    // Buscar primero en mosExpress (preferencia natural para POS), luego
    // en cualquier app (para detectar almaceneros/envasadores que aparecen
    // accidentalmente en ME logs).
    var match = personal.find(function(p){
      if (p.appOrigen !== 'mosExpress') return false;
      var full = (String(p.nombre || '') + ' ' + (p.apellido || '')).trim().toLowerCase();
      return full === nLow || String(p.nombre || '').toLowerCase() === nLow;
    });
    if (!match) {
      match = personal.find(function(p){
        var full = (String(p.nombre || '') + ' ' + (p.apellido || '')).trim().toLowerCase();
        return full === nLow || String(p.nombre || '').toLowerCase() === nLow;
      });
    }
    var esGenerico = match && genericos.indexOf(match) >= 0;
    if (match && !esGenerico) {
      // El rol del master MANDA: si Oswaldbit es ENVASADOR en master, su rol
      // queda como ENVASADOR aunque haya tocado ME ese día. No reasignar.
      if (lista.indexOf(match) < 0) lista.push(match);
    } else {
      var g = _genericoPorRol(rol);
      lista.push({
        idPersonal: 'MEX:' + nombre,
        nombre:     nombre,
        apellido:   '',
        tipo:       'VENDEDOR',
        appOrigen:  'mosExpress',
        rol:        rol,
        montoBase:  g ? (parseFloat(g.montoBase) || 0) : 0,
        estado:     '1',
        __virtual:  true
      });
    }
  });

  var resumenes = lista.map(function(p){
    var r = getResumenDia({ idPersonal: p.idPersonal, fecha: fecha });
    if (r.ok) {
      r.data.virtual = !!p.__virtual;
      return r.data;
    }
    return null;
  }).filter(Boolean);

  // [v2.41.43] Cruzar con LIQUIDACIONES_DIA para que Personal del Día
  // refleje el estado REAL de cada liquidación (VETADA/PAGADA/PENDIENTE).
  // Sin esto, vetar desde Liquidaciones (botón 🚫) no se reflejaba como
  // overlay vetada en la card de Personal del Día.
  try {
    var ldiaSh = _liqDiaGetSheet();
    var ldiaRows = _sheetToObjects(ldiaSh);
    var tz = Session.getScriptTimeZone();
    var estadoMap = {};
    ldiaRows.forEach(function(row) {
      var f = (typeof _liqNormFecha === 'function')
        ? _liqNormFecha(row.fecha, tz)
        : (row.fecha instanceof Date
            ? Utilities.formatDate(row.fecha, tz, 'yyyy-MM-dd')
            : String(row.fecha || '').substring(0, 10));
      if (f !== fecha) return;
      var idP = String(row.idPersonal || '').trim();
      if (!idP) return;
      estadoMap[idP] = String(row.estado || '').toUpperCase();
    });
    resumenes.forEach(function(r) {
      var est = estadoMap[String(r.idPersonal)] || 'PENDIENTE';
      r.liqEstado = est;
      // Si está VETADA, marcar el flag estandarizado que el frontend ya lee
      if (est === 'VETADA') {
        r.vetada = true;
      }
    });
  } catch(eL) { Logger.log('[getResumenTodosDia] liqEstado cross: ' + eL.message); }

  var resp = { ok: true, data: resumenes };
  // [v2.41.44] Persistir en cache 120s
  if (ssCache && cacheKey) {
    try {
      var ser = JSON.stringify(resp);
      // CacheService permite hasta 100KB por entrada. Si excede, no cachear (raro).
      if (ser.length < 95000) ssCache.put(cacheKey, ser, 120);
    } catch(_){}
  }
  return resp;
}

// ── Liquidación semanal ────────────────────────────────────────
// fechaInicio = lunes de la semana (yyyy-MM-dd)
function getLiquidacionSemana(params) {
  var idPersonal  = params.idPersonal;
  var fechaInicio = params.fechaInicio;
  if (!idPersonal)  return { ok: false, error: 'idPersonal requerido' };
  if (!fechaInicio) return { ok: false, error: 'fechaInicio requerido (lunes)' };

  var p = _resolverPersona(idPersonal);
  if (!p) return { ok: false, error: 'Personal no encontrado' };

  var dias = [];
  var totalBase = 0, totalBonus = 0, totalMeta = 0;
  var deficiencias = {};

  for (var i = 0; i < 7; i++) {
    var d = new Date(fechaInicio + 'T00:00:00');
    d.setDate(d.getDate() + i);
    var fStr = Utilities.formatDate(d, Session.getScriptTimeZone(), 'yyyy-MM-dd');
    var resumen = getResumenDia({ idPersonal: idPersonal, fecha: fStr });
    if (!resumen.ok) continue;
    var rd = resumen.data;
    var nombreDia = ['Dom','Lun','Mar','Mié','Jue','Vie','Sáb'][d.getDay()];
    dias.push({
      fecha:      fStr,
      diaSemana:  nombreDia,
      presente:   !!rd.presente,
      auditado:   !!rd.auditado,
      score:      rd.scoreFinal,
      montoBase:  rd.montoBase,    // ya viene en 0 si no presente
      bonusScore: rd.bonusScore,   // ya viene en 0 si no presente o no auditado
      bonoMeta:   rd.bonoMeta,
      totalDia:   rd.totalDia
    });
    // Sumar al total: base si presente; bonus/meta solo si presente + auditado
    if (rd.presente) {
      totalBase  += rd.montoBase;
      totalBonus += rd.bonusScore;
      totalMeta  += rd.bonoMeta;
      // Trackear deficiencias solo si fue auditado (sin auditoría no hay datos)
      if (rd.auditado) {
        if (rd.manual.limpiezaPct < 70) {
          deficiencias['limpieza_estacion'] = (deficiencias['limpieza_estacion'] || 0) + 1;
        }
        if (rd.manual.limpiezaProfPct < 70) {
          deficiencias['limpieza_profunda'] = (deficiencias['limpieza_profunda'] || 0) + 1;
        }
      }
    }
  }

  return {
    ok: true,
    data: {
      idPersonal:   idPersonal,
      nombre:       (p.nombre + ' ' + (p.apellido || '')).trim(),
      rol:          p.rol,
      appOrigen:    p.appOrigen,
      fechaInicio:  fechaInicio,
      dias:         dias,
      deficiencias: deficiencias,
      totales: {
        base:    Math.round(totalBase  * 100) / 100,
        bonus:   Math.round(totalBonus * 100) / 100,
        meta:    Math.round(totalMeta  * 100) / 100,
        aCobrar: Math.round((totalBase + totalBonus + totalMeta) * 100) / 100
      }
    }
  };
}

// ════════════════════════════════════════════════════════════════════
// [Lote4 · B6-MOS] SNAPSHOT CONGELADO de la liquidación semanal.
// Problema: getLiquidacionSemana RECALCULA on-the-fly desde jornadas/auditorías.
// Si entre el cierre (domingo 8pm) y el pago se editan jornadas/auditorías de esa
// semana, los montos cambian RETROACTIVAMENTE → no hay registro inmutable de lo
// que se debía al corte. Este snapshot CONGELA esos totales.
// Idempotente por (semana_inicio, idPersonal): re-correr ACTUALIZA la fila, NUNCA
// duplica, y NUNCA pisa una fila ya marcada 'PAGADO' (el pago es definitivo).
// ════════════════════════════════════════════════════════════════════
var _SNAP_HEADERS = ['ID_Snapshot','Semana_Inicio','Semana_Fin','idPersonal','Nombre','Rol','App',
  'Total_Base','Total_Bonus','Total_Meta','Total_aCobrar','Dias_Presente','Detalle_JSON','Fecha_Corte','Estado'];

function _getHojaSnapshotSemanal(){
  var ss = getSpreadsheet();   // openById(SS_ID) — getActiveSpreadsheet() es null en el Web App standalone
  var sh = ss.getSheetByName('LIQUIDACION_SEMANAL_SNAPSHOT');
  if(!sh){ sh = ss.insertSheet('LIQUIDACION_SEMANAL_SNAPSHOT'); sh.appendRow(_SNAP_HEADERS); sh.setFrozenRows(1); }
  return sh;
}

// Lunes (00:00) de la semana que contiene la fecha dada.
function _lunesDeSemana(d){
  var dia = d.getDay();                       // 0=Dom..6=Sab
  var resta = (dia === 0) ? 6 : (dia - 1);    // domingo pertenece a la semana que arranca 6 días antes
  var lun = new Date(d.getTime());
  lun.setDate(lun.getDate() - resta);
  lun.setHours(0,0,0,0);
  return lun;
}

// Congela la liquidación de TODOS los evaluables activos para la semana indicada.
// params.fechaInicio (lunes 'yyyy-MM-dd') opcional → por defecto la semana de HOY (el domingo del trigger).
// [fix concurrencia] LockService: dos corridas simultáneas (trigger + manual, o reintentos) leían la hoja
// vacía y AMBAS appendaban → filas duplicadas. El lock serializa → la 2da ve las filas de la 1ra y actualiza.
function snapshotLiquidacionSemanal(params){
  var _lock = LockService.getScriptLock();
  try { _lock.waitLock(30000); } catch(e){ return { ok:false, error:'Sistema ocupado (otra liquidación en curso)' }; }
  try { return _snapshotLiquidacionSemanalImpl(params); }
  finally { try { _lock.releaseLock(); } catch(_){} }
}
function _snapshotLiquidacionSemanalImpl(params){
  params = params || {};
  var tz = Session.getScriptTimeZone();
  var lun = params.fechaInicio ? new Date(params.fechaInicio + 'T00:00:00') : _lunesDeSemana(new Date());
  var lunStr = Utilities.formatDate(lun, tz, 'yyyy-MM-dd');
  var dom = new Date(lun.getTime()); dom.setDate(dom.getDate()+6);
  var domStr = Utilities.formatDate(dom, tz, 'yyyy-MM-dd');
  var corte = new Date();

  var personal = _sheetToObjects(getSheet('PERSONAL_MASTER'))
    .filter(function(r){ return String(r.estado) === '1'; })
    .filter(_esPersonalEvaluable);

  var sh = _getHojaSnapshotSemanal();
  // [fix dedup] Limpiar duplicados pre-existentes por (semana|idPersonal): conservar la fila PAGADO si
  // alguna lo está, sino la primera; borrar el resto (de abajo hacia arriba para no correr índices).
  _dedupSnapshotSheet(sh);
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var iSem = hdrs.indexOf('Semana_Inicio'), iIdP = hdrs.indexOf('idPersonal'), iEst = hdrs.indexOf('Estado');
  var existente = {};   // (semana|idPersonal) → fila 1-based
  for(var r=1;r<data.length;r++){ existente[String(data[r][iSem])+'|'+String(data[r][iIdP])] = r+1; }

  var congelados = 0, yaPagados = 0, errores = [];
  personal.forEach(function(p){
    try {
      var liq = getLiquidacionSemana({ idPersonal: p.idPersonal, fechaInicio: lunStr });
      if(!liq.ok){ errores.push(String(p.idPersonal)+': '+liq.error); return; }
      var d = liq.data;
      var diasPresente = (d.dias||[]).filter(function(x){ return x.presente; }).length;
      var key = lunStr+'|'+String(p.idPersonal);
      var estadoFinal = 'PENDIENTE_PAGO';
      if(existente[key]){
        var estadoPrev = String(data[existente[key]-1][iEst] || '');
        if(estadoPrev === 'PAGADO'){ yaPagados++; return; }   // NUNCA pisar un pago confirmado
        if(estadoPrev) estadoFinal = estadoPrev;
      }
      var fila = [
        'SNP-'+lunStr+'-'+String(p.idPersonal),
        lunStr, domStr, String(p.idPersonal), d.nombre, d.rol||'', d.appOrigen||'',
        d.totales.base, d.totales.bonus, d.totales.meta, d.totales.aCobrar,
        diasPresente, JSON.stringify({ dias:d.dias, deficiencias:d.deficiencias }),
        corte, estadoFinal
      ];
      if(existente[key]) sh.getRange(existente[key], 1, 1, fila.length).setValues([fila]);
      else               sh.appendRow(fila);
      congelados++;
    } catch(e){ errores.push(String(p.idPersonal)+': '+(e&&e.message)); }
  });
  SpreadsheetApp.flush();
  Logger.log('[snapshotLiquidacionSemanal] semana '+lunStr+' · '+congelados+' congelados · '+yaPagados+' ya pagados · '+errores.length+' errores');
  return { ok:true, data:{ semana_inicio:lunStr, semana_fin:domStr, congelados:congelados, ya_pagados:yaPagados, errores:errores } };
}

// Quita filas duplicadas por (Semana_Inicio|idPersonal). Conserva la PAGADO si existe, sino la primera.
function _dedupSnapshotSheet(sh){
  var data = sh.getDataRange().getValues();
  if(data.length < 3) return 0;   // header + ≤1 fila → nada que dedupear
  var hdrs = data[0];
  var iSem = hdrs.indexOf('Semana_Inicio'), iIdP = hdrs.indexOf('idPersonal'), iEst = hdrs.indexOf('Estado');
  var keep = {};        // key → fila 1-based a conservar
  var borrar = [];      // filas 1-based a borrar
  for(var r=1;r<data.length;r++){
    var key = String(data[r][iSem])+'|'+String(data[r][iIdP]);
    var fila = r+1;
    if(!keep[key]){ keep[key] = fila; continue; }
    // ya hay una; decidir cuál conservar: PAGADO gana
    var estaPagada = String(data[r][iEst]) === 'PAGADO';
    var keepPagada = String(data[keep[key]-1][iEst]) === 'PAGADO';
    if(estaPagada && !keepPagada){ borrar.push(keep[key]); keep[key] = fila; }
    else { borrar.push(fila); }
  }
  borrar.sort(function(a,b){ return b-a; }).forEach(function(f){ sh.deleteRow(f); });
  if(borrar.length) Logger.log('[_dedupSnapshotSheet] '+borrar.length+' duplicados eliminados');
  return borrar.length;
}

// Lee los snapshots CONGELADOS de una semana (para que el admin pague el monto fijado, no el recalculado).
// GET ?accion=getSnapshotsSemanal&semanaInicio=yyyy-MM-dd  (default: semana de hoy)
function getSnapshotsSemanal(params){
  params = params || {};
  var tz = Session.getScriptTimeZone();
  var lunStr = params.semanaInicio || Utilities.formatDate(_lunesDeSemana(new Date()), tz, 'yyyy-MM-dd');
  var sh = _getHojaSnapshotSemanal();
  var rows = _sheetToObjects(sh).filter(function(r){ return String(r.Semana_Inicio) === lunStr; });
  return { ok:true, data:{ semana_inicio:lunStr, snapshots:rows } };
}

// ── Trigger automático: domingos 8pm ───────────────────────────
function configurarTriggerCierreSemanal() {
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === 'cerrarSemanaAutomatico') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('cerrarSemanaAutomatico')
    .timeBased()
    .onWeekDay(ScriptApp.WeekDay.SUNDAY)
    .atHour(20)
    .create();
  Logger.log('✅ Trigger creado: cerrarSemanaAutomatico domingos 8pm');
}

function cerrarSemanaAutomatico() {
  try {
    // [Lote4 · B6-MOS] CONGELAR la liquidación ANTES de avisar — así el admin paga el monto
    // fijado al corte, no uno que pudo cambiar si se editan jornadas/auditorías después.
    var snap = { data: { congelados: 0 } };
    try { snap = snapshotLiquidacionSemanal({}); } catch(eS) { Logger.log('[cierreSemanal] snapshot falló: ' + eS.message); }
    var n = (snap && snap.data && snap.data.congelados) || 0;
    if (typeof _enviarPushTodos === 'function') {
      _enviarPushTodos('💰 Liquidación semanal lista',
        n + ' empleado(s) liquidado(s) · revisa MOS para imprimir y pagar.',
        { soloRolesAdmin: true, idNotif: 'MOS_LIQUIDACION_LISTA' });
    }
    Logger.log('Cierre semanal disparado: ' + new Date() + ' · congelados: ' + n);
  } catch(e) {
    Logger.log('cerrarSemanaAutomatico error: ' + e.message);
  }
}

// ============================================================
// ── IMPRESIÓN DE LIQUIDACIÓN INDIVIDUAL (80mm · PrintNode) ───
// Llamado desde el modal Auditar de MOS, botón "🖨 Imprimir".
// Imprime un resumen profesional del día con todos los KPIs +
// checklist + sanciones + total liquidado. Útil para que el
// empleado se lleve su comprobante al cerrar turno.
// ============================================================

// Listar impresoras de PrintNode disponibles. Cruza con la hoja
// IMPRESORAS para anotar zona/estación/app a cada printer físico
// (cuando coincide el printNodeId), para que el frontend pueda
// agruparlas de forma intuitiva.
// [v2.41.81] Diagnóstico inteligente de estado de impresora.
// PrintNode tiene DOS estados independientes: computer (la PC) y printer.
// Antes solo mirábamos printer.state → falso positivo cuando la PC estaba
// disconnected. Ahora fusionamos ambos + detectamos errores específicos
// del driver (sin papel, sin tinta, atasco, tapa abierta, etc.) por
// palabras clave en state/description.
function _interpretarEstadoImpresora(printerState, computerState, descripcion) {
  var cs = String(computerState || '').toLowerCase().trim();
  var ps = String(printerState  || '').toLowerCase().trim();
  var ds = String(descripcion   || '').toLowerCase();
  var combined = ps + ' ' + ds;

  // 1. PC desconectada gana sobre cualquier otro estado del printer
  if (cs && cs !== 'connected') {
    return { state: 'PC_OFFLINE', reason: 'PC desconectada · revisa internet o cliente PrintNode',
             icon: '🔌', color: 'orange' };
  }
  // 2. Detalles específicos del driver (mayor utilidad operativa)
  if (/jam|atasco|atasc/.test(combined)) {
    return { state: 'ATASCO', reason: 'Papel atascado · revisa la bandeja',
             icon: '⚠', color: 'red' };
  }
  if (/paper.?out|out.?of.?paper|sin.?papel|no.?paper|paperout/.test(combined)) {
    return { state: 'SIN_PAPEL', reason: 'Sin papel · cargar bandeja',
             icon: '📄', color: 'yellow' };
  }
  if (/ink|toner|tinta|cartridge|low.?supplies/.test(combined)) {
    return { state: 'SIN_TINTA', reason: 'Tinta/toner bajo o ausente',
             icon: '🟡', color: 'yellow' };
  }
  if (/door.?open|tapa|cover.?open|cover\-?open/.test(combined)) {
    return { state: 'TAPA_ABIERTA', reason: 'Tapa abierta · cerrar para imprimir',
             icon: '🚪', color: 'yellow' };
  }
  // 3. Estados crudos de PrintNode
  if (ps === 'paused')   return { state: 'PAUSED',   reason: 'Pausada en la cola del OS',     icon: '⏸', color: 'gray' };
  if (ps === 'disabled') return { state: 'DISABLED', reason: 'Deshabilitada manualmente',     icon: '🚫', color: 'gray' };
  if (ps === 'error' || /error/.test(ps))
                          return { state: 'ERROR',    reason: descripcion || 'Error del driver', icon: '⚠', color: 'red' };
  if (ps === 'offline' || ps === 'disconnected')
                          return { state: 'PRINTER_OFFLINE', reason: 'Impresora apagada o cable desconectado', icon: '🔴', color: 'red' };
  if (ps === 'online')    return { state: 'ONLINE',   reason: 'Lista para imprimir',           icon: '🟢', color: 'green' };
  if (ps === 'unknown' || !ps)
                          return { state: 'UNKNOWN',  reason: 'Estado no reportado por driver', icon: '❔', color: 'gray' };
  // Caso fallback — estado raro que no reconocemos
  return { state: 'ERROR', reason: 'Estado: ' + printerState, icon: '⚠', color: 'red' };
}

function listarImpresorasPN() {
  var pnKey;
  try {
    pnKey = PropertiesService.getScriptProperties().getProperty('PRINTNODE_API_KEY');
  } catch(_){}
  if (!pnKey) return { ok: false, error: 'PRINTNODE_API_KEY no configurado en Script Properties de ProyectoMOS' };

  // [v2.41.81] Fetch en PARALELO de /printers y /computers — 1 sola
  // latencia para ambos endpoints. Antes solo se traía /printers y se
  // ignoraba el estado de la PC host → falso positivo "online" cuando
  // DESKTOP-Q872N86 estaba disconnected.
  var pnList, pnComps;
  var authHeader = 'Basic ' + Utilities.base64Encode(pnKey + ':');
  try {
    var responses = UrlFetchApp.fetchAll([
      { url: 'https://api.printnode.com/printers',  method: 'get', headers: { 'Authorization': authHeader }, muteHttpExceptions: true },
      { url: 'https://api.printnode.com/computers', method: 'get', headers: { 'Authorization': authHeader }, muteHttpExceptions: true }
    ]);
    if (responses[0].getResponseCode() !== 200) {
      return { ok: false, error: 'PrintNode printers HTTP ' + responses[0].getResponseCode() + ': ' + responses[0].getContentText().substring(0, 200) };
    }
    pnList  = JSON.parse(responses[0].getContentText() || '[]');
    pnComps = responses[1].getResponseCode() === 200
            ? JSON.parse(responses[1].getContentText() || '[]')
            : [];
  } catch(e) {
    return { ok: false, error: 'PrintNode fetch fallo: ' + e.message };
  }

  // Mapa idComputer → {name, state}
  var compMap = {};
  pnComps.forEach(function(c){
    compMap[String(c.id)] = {
      name:  String(c.name || ''),
      state: String(c.state || '').toLowerCase()
    };
  });
  // Mapa idPrinter → printer crudo
  var printerMap = {};
  pnList.forEach(function(p){ printerMap[String(p.id)] = p; });

  // Lookups de nombres (zona + estación) para etiquetas friendly
  var zonaNom = {};
  try {
    _sheetToObjects(getSheet('ZONAS')).forEach(function(z){
      zonaNom[String(z.idZona)] = String(z.nombre || z.idZona);
    });
  } catch(_){}
  var estNom = {};
  try {
    _sheetToObjects(getSheet('ESTACIONES')).forEach(function(e){
      estNom[String(e.idEstacion)] = String(e.nombre || e.idEstacion);
    });
  } catch(_){}

  // [v2.41.81] Iteramos sobre IMPRESORAS (catálogo MOS) — no sobre la
  // respuesta de PrintNode — para PODER REPORTAR los 2 casos críticos
  // que antes desaparecían:
  //   • SIN_ID:       fila en catálogo SIN printNodeId asignado
  //   • ID_INVALIDO:  printNodeId asignado pero NO existe en PrintNode
  var data = [];
  try {
    var rowsCat = _sheetToObjects(getSheet('IMPRESORAS'));
    rowsCat.forEach(function(r) {
      var act = String(r.activo) === '1' || String(r.activo).toLowerCase() === 'true';
      if (!act) return;
      var pid       = String(r.printNodeId || '').trim();
      var nombreCat = String(r.nombre || '');
      var idEst     = String(r.idEstacion || '');
      var idZona    = String(r.idZona || '');
      var tipo      = String(r.tipo || 'TICKET');

      var diag, compName = '', compState = '', printerName = '', printerStateRaw = '';

      if (!pid) {
        diag = { state: 'SIN_ID', reason: 'Falta asignar ID de PrintNode',
                 icon: '⚙', color: 'gray' };
      } else if (!printerMap[pid]) {
        diag = { state: 'ID_INVALIDO', reason: 'ID ' + pid + ' no existe en PrintNode (verifica que esté registrada)',
                 icon: '❓', color: 'red' };
      } else {
        var p = printerMap[pid];
        var cid = (p.computer && p.computer.id) ? String(p.computer.id) : '';
        var comp = compMap[cid] || { name: '', state: '' };
        compName = comp.name || (p.computer && p.computer.name ? String(p.computer.name) : '');
        compState = comp.state || '';
        printerName = String(p.name || '');
        printerStateRaw = String(p.state || '');
        var desc = String(p.description || (p.default && 'default') || '');
        diag = _interpretarEstadoImpresora(printerStateRaw, compState, desc);
      }

      data.push({
        id:               pid ? parseInt(pid, 10) : null,
        printNodeId:      pid,
        nombrePN:         printerName,
        nombre:           nombreCat || printerName,
        nombreCatalogo:   nombreCat,
        computer:         compName,
        computerState:    compState,      // 'connected' | 'disconnected' | ''
        printerStateRaw:  printerStateRaw, // crudo de PrintNode
        // ── Diagnóstico semántico unificado ──
        state:            diag.state,     // 'ONLINE' | 'PC_OFFLINE' | 'SIN_PAPEL' | etc
        reason:           diag.reason,    // texto humano accionable
        icon:             diag.icon,
        color:            diag.color,
        online:           diag.state === 'ONLINE', // retro-compat para código viejo
        registrada:       true,
        idEstacion:       idEst,
        estacionNombre:   estNom[idEst] || idEst || '',
        idZona:           idZona,
        zonaNombre:       zonaNom[idZona] || idZona || '',
        appOrigen:        String(r.appOrigen || ''),
        tipo:             tipo
      });
    });
  } catch(eC) {
    return { ok: false, error: 'No se pudo leer catálogo IMPRESORAS: ' + eC.message };
  }

  return { ok: true, data: data };
}

// Compat: alias para frontend que use camelCase legacy
function getPrintNodePrinters() { return listarImpresorasPN(); }

// [v2.41.82] Verifica el estado FRESH de UNA impresora puntual.
// Se llama justo antes de mandar un job de impresión para evitar enviar
// trabajos a impresoras que cambiaron de estado desde el último listado.
// Solo hace 2 requests (printer + computer) y devuelve diagnóstico
// completo. Sin cache.
function verificarImpresoraAhora(params) {
  var pid = String(params.printerId || params.id || '').trim();
  if (!pid) return { ok: false, error: 'Requiere printerId' };
  var pnKey;
  try { pnKey = PropertiesService.getScriptProperties().getProperty('PRINTNODE_API_KEY'); } catch(_){}
  if (!pnKey) return { ok: false, error: 'PRINTNODE_API_KEY no configurado' };
  var authHeader = 'Basic ' + Utilities.base64Encode(pnKey + ':');
  try {
    var resp = UrlFetchApp.fetch('https://api.printnode.com/printers/' + encodeURIComponent(pid), {
      method: 'get',
      headers: { 'Authorization': authHeader },
      muteHttpExceptions: true
    });
    if (resp.getResponseCode() === 404) {
      return { ok: true, data: { state: 'ID_INVALIDO', reason: 'ID ' + pid + ' no existe en PrintNode',
                                  icon: '❓', color: 'red', online: false, printerId: pid } };
    }
    if (resp.getResponseCode() !== 200) {
      return { ok: false, error: 'PrintNode HTTP ' + resp.getResponseCode() };
    }
    var json = JSON.parse(resp.getContentText() || '[]');
    var p = Array.isArray(json) ? json[0] : json;
    if (!p) return { ok: true, data: { state: 'ID_INVALIDO', reason: 'No reportada', icon: '❓', color: 'red', online: false } };

    // Estado de la PC
    var compState = '';
    var compName = '';
    if (p.computer) {
      compName = String(p.computer.name || '');
      compState = String(p.computer.state || '').toLowerCase();
    }
    var diag = _interpretarEstadoImpresora(String(p.state || ''), compState, String(p.description || ''));
    return { ok: true, data: {
      printerId:        pid,
      nombrePN:         String(p.name || ''),
      computer:         compName,
      computerState:    compState,
      printerStateRaw:  String(p.state || ''),
      state:            diag.state,
      reason:           diag.reason,
      icon:             diag.icon,
      color:            diag.color,
      online:           diag.state === 'ONLINE'
    }};
  } catch(e) {
    return { ok: false, error: 'PrintNode fetch fallo: ' + e.message };
  }
}

// ════════════════════════════════════════════════════════════════════
// MONITOREO DE IMPRESORAS — verificación + alerta inteligente
// ════════════════════════════════════════════════════════════════════
// _verificarImpresorasYAlertar: consulta el estado real de TODAS las
// impresoras del catálogo (vía PrintNode) y, si hay alguna offline,
// emite UNA notificación MOS_IMPRESORA_OFFLINE con el resumen.
//
// Anti-spam: guarda en CacheService los printNodeId ya reportados (TTL
// 30 min). Solo vuelve a emitir si aparece una caída NUEVA. Cuando todo
// vuelve a estar online, limpia el cache para que la próxima caída sí
// alerte de inmediato.
function _verificarImpresorasYAlertar(origenTrigger) {
  try {
    var res = listarImpresorasPN();
    if (!res || !res.ok || !Array.isArray(res.data)) {
      return { ok: false, error: (res && res.error) || 'No se pudo consultar PrintNode' };
    }
    var offline = res.data.filter(function(p) { return !p.online; });
    var cache = CacheService.getScriptCache();

    if (!offline.length) {
      // Todo OK → limpiar el registro de reportadas para que la próxima
      // caída alerte sin esperar el TTL.
      try { cache.remove('imp_offline_reportadas'); } catch(_){}
      return { ok: true, data: { offline: 0, origen: origenTrigger || '' } };
    }

    // ── Anti-spam ────────────────────────────────────────────
    var yaReportadas = {};
    try {
      var raw = cache.get('imp_offline_reportadas');
      if (raw) JSON.parse(raw).forEach(function(id) { yaReportadas[String(id)] = true; });
    } catch(_){}
    var hayNueva = offline.some(function(p) { return !yaReportadas[String(p.id)]; });
    if (!hayNueva) {
      return { ok: true, data: { offline: offline.length, sinPush: true,
                                 motivo: 'ya reportadas (anti-spam 30min)' } };
    }

    // ── Emitir UNA notificación con TODAS las offline ────────
    var lineas = offline.map(function(p) {
      var ub = p.zonaNombre || p.estacionNombre || p.appOrigen || '';
      return '• ' + p.nombre + (ub ? ' · ' + ub : '') +
             (p.computer ? ' (PC: ' + p.computer + ')' : '');
    });
    var titulo = offline.length === 1
      ? '🖨 Impresora offline: ' + offline[0].nombre
      : '🖨 ' + offline.length + ' impresoras offline';
    var cuerpo = lineas.join('\n') + '\n\nRevisar: encendido · cable · PC conectada a internet.';

    if (typeof _enviarPushTodos === 'function') {
      _enviarPushTodos(titulo, cuerpo, { soloRolesAdmin: true, idNotif: 'MOS_IMPRESORA_OFFLINE' });
    }

    // Registrar las offline actuales (anti-spam por 30 min)
    try {
      cache.put('imp_offline_reportadas',
                JSON.stringify(offline.map(function(p) { return p.id; })), 1800);
    } catch(_){}

    return { ok: true, data: { offline: offline.length, notificado: true,
                               origen: origenTrigger || '' } };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

// Heartbeat: verificación periódica PERO solo si hay gente operando ahora.
// Si no hay ningún dispositivo ME/WH con conexión reciente (<20 min) →
// la tienda está cerrada/inactiva → NO verifica → cero alertas falsas
// de madrugada. Lo dispara un trigger time-based cada ~15 min.
function _heartbeatImpresoras() {
  var hayActividad = false;
  try {
    var sheetD = getSheet('DISPOSITIVOS');
    var dataD  = sheetD.getDataRange().getValues();
    var hdrs   = dataD[0];
    var iUc    = hdrs.indexOf('Ultima_Conexion');
    var iApp   = hdrs.indexOf('App');
    var iEst   = hdrs.indexOf('Estado');
    var ahora  = Date.now();
    for (var i = 1; i < dataD.length && !hayActividad; i++) {
      var app = String(dataD[i][iApp] || '').toLowerCase();
      if (app === 'mos') continue; // dispositivos del panel admin no son "operación"
      var est = String(dataD[i][iEst] || '').toUpperCase();
      if (est === 'INACTIVO') continue;
      var uc = dataD[i][iUc];
      var ts = uc instanceof Date ? uc.getTime() : (uc ? new Date(uc).getTime() : 0);
      if (ts && (ahora - ts) < 20 * 60 * 1000) hayActividad = true;
    }
  } catch(e) { Logger.log('_heartbeatImpresoras DISPOSITIVOS: ' + e.message); }

  if (!hayActividad) {
    return { ok: true, data: { skip: true, motivo: 'sin actividad operativa' } };
  }
  return _verificarImpresorasYAlertar('heartbeat');
}

// Endpoint público — el frontend (panel Infraestructura) puede forzar una
// verificación manual además de leer getPrintNodePrinters.
function verificarImpresorasAhora() {
  return _verificarImpresorasYAlertar('manual');
}

// Instala el trigger del heartbeat de impresoras (cada 15 min).
// Ejecutar UNA vez desde el editor de Apps Script. Idempotente: borra
// el trigger previo antes de crear el nuevo.
function configurarTriggerImpresoras() {
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === '_heartbeatImpresoras') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('_heartbeatImpresoras').timeBased().everyMinutes(15).create();
  return { ok: true, msg: 'Trigger creado: _heartbeatImpresoras cada 15 min' };
}

// Construye el ticket 80mm (~48 chars) y lo manda a PrintNode.
// Reusa getResumenDia para hidratar todos los KPIs + bonos + sanción del día.
//
// params: { idPersonal, fecha, printerId, comentarioExtra? }
function imprimirLiquidacionDia(params) {
  if (!params || !params.idPersonal) return { ok: false, error: 'Requiere idPersonal' };
  if (!params.printerId)             return { ok: false, error: 'Requiere printerId' };

  var fecha = params.fecha || _hoy();
  var resR = getResumenDia({ idPersonal: params.idPersonal, fecha: fecha });
  if (!resR || !resR.ok) return { ok: false, error: (resR && resR.error) || 'No se pudo obtener resumen' };
  var r = resR.data;

  // ── Helpers de formato (mismos que tickets de cierre Z) ──
  var W = 48;
  function _rep(ch, n)  { var s=''; for (var i=0;i<n;i++) s+=ch; return s; }
  function _pEnd(s, w)  { s=String(s||'').substring(0,w); while(s.length<w) s+=' '; return s; }
  function _pSt(s, w)   { s=String(s||''); while(s.length<w) s=' '+s; return s; }
  function _amtP(n, w)  { return _pSt('S/'+(parseFloat(n)||0).toFixed(2), w); }
  function _amtN(n, w)  { var v=parseFloat(n)||0; return _pSt((v<0?'-':' ')+'S/'+Math.abs(v).toFixed(2), w); }
  function _norm(s)     { return String(s||'').normalize('NFD').replace(/[̀-ͯ]/g,'').replace(/[^\x20-\x7E]/g,'?'); }
  function _center(s)   { var n=_norm(s); var l=Math.floor((W-n.length)/2); return _rep(' ',Math.max(0,l))+n+'\n'; }
  function _sHdr(t)     { var s=' '+t+' '; var l=Math.floor((W-s.length)/2); return _rep('=',Math.max(0,l))+s+_rep('=',Math.max(0,W-s.length-l))+'\n'; }
  function _bar(pct)    { var f=Math.round((parseFloat(pct)||0)*26/100); if(f<0)f=0; if(f>26)f=26; return '  ['+_rep('#',f)+_rep('-',26-f)+'] '+_pSt(String(Math.round(parseFloat(pct)||0)),3)+'%\n'; }

  var SEP  = _rep('=', W) + '\n';
  var SEPd = _rep('-', W) + '\n';
  var rolU = String(r.rol || '').toUpperCase();
  var esPos = (rolU === 'CAJERO' || rolU === 'VENDEDOR');
  var esAlm = (rolU === 'ALMACENERO' || rolU === 'ENVASADOR');

  var txt = '';
  // ── HEADER ─────────────────────────────────────────────────
  txt += '\x1b\x40';                       // init
  txt += '\x1b\x61\x01';                   // center
  txt += '\x1b\x21\x30';                   // double height+width
  txt += _norm('LIQUIDACION DEL DIA') + '\n';
  txt += '\x1b\x21\x00';                   // reset
  txt += _norm('ProyectoMOS · Personal') + '\n';
  txt += '\x1b\x61\x00';                   // left
  txt += SEP;

  txt += _pEnd('FECHA', 12)     + ': ' + fecha + '\n';
  txt += _pEnd('HORA',  12)     + ': ' + Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'HH:mm:ss') + '\n';
  txt += _pEnd('PERSONAL', 12)  + ': ' + _norm(r.nombre) + '\n';
  txt += _pEnd('ROL', 12)       + ': ' + _norm(r.rol || '') + '\n';
  txt += _pEnd('ID', 12)        + ': ' + _norm(r.idPersonal) + '\n';
  if (r.kpis && r.kpis.zonaPrincipal) {
    txt += _pEnd('ZONA', 12)    + ': ' + _norm(r.kpis.zonaPrincipal) + '\n';
  }
  txt += _pEnd('PRESENTE', 12)  + ': ' + (r.presente ? 'SI' : 'NO') + '\n';
  txt += _pEnd('AUDITADO', 12)  + ': ' + (r.auditado ? (r.evaluacionesCount + 'x hoy') : 'NO') + '\n';
  txt += SEP;

  // ── PUNTO 1+2: KPIs por rol ───────────────────────────────
  txt += _sHdr('LOGROS DEL DIA');
  if (esPos) {
    var metaV  = parseFloat(r.kpis.metaVenta) || 0;
    var realV  = parseFloat(r.kpis.ventasReales) || 0;
    var pctV   = metaV > 0 ? Math.min(100, realV/metaV*100) : 0;
    txt += 'META DE VENTA (zona)\n';
    if (metaV > 0) {
      txt += '  ' + _pEnd('Real: S/'+realV.toFixed(2), 24)
                  + _pSt('Meta: S/'+metaV.toFixed(0), 18) + '\n';
      txt += _bar(pctV);
    } else {
      txt += '  Sin meta configurada · ver Infra\n';
    }
    var aud = parseFloat(r.kpis.auditoriasHechas) || 0;
    var mAud = parseFloat(r.kpis.metaAuditorias) || 30;
    txt += 'AUDITORIAS DE PRODUCTOS\n';
    txt += '  ' + _pSt(aud + ' / ' + mAud, W-2) + '\n';
    txt += _bar(r.kpis.auditPct || 0);
  } else if (esAlm) {
    var aud2 = parseFloat(r.kpis.auditoriasHechas) || 0;
    var mAud2 = parseFloat(r.kpis.metaAuditorias) || 30;
    txt += 'AUDITORIAS\n';
    txt += '  ' + _pSt(aud2 + ' / ' + mAud2, W-2) + '\n';
    txt += _bar(r.kpis.auditPct || 0);
    var uds = parseFloat(r.kpis.envasados) || 0;
    var tar = parseFloat(r.tarifaEnvasado) || 0;
    txt += 'ENVASADO DEL DIA\n';
    if (uds > 0) {
      txt += '  ' + _norm(uds + ' uds x S/'+tar.toFixed(2)+' = S/'+(uds*tar).toFixed(2)) + '\n';
    } else {
      txt += '  Sin envasar\n';
    }
  }
  txt += SEPd;

  // ── PUNTO 3+4: limpieza ────────────────────────────────────
  var l1 = parseFloat(r.manual && r.manual.limpiezaPct) || 0;
  var l2 = parseFloat(r.manual && r.manual.limpiezaProfPct) || 0;
  txt += _pEnd('Limpieza estacion', 22) + _pSt(l1.toFixed(0)+'%', 6) + '\n';
  txt += _bar(l1);
  txt += _pEnd('Limpieza profunda', 22) + _pSt(l2.toFixed(0)+'%', 6) + '\n';
  txt += _bar(l2);
  txt += SEPd;

  // ── PUNTO 5: Checklist (control diario) ────────────────────
  txt += _sHdr('CONTROL DIARIO');
  try {
    var cfgAll = getConfigMos();
    var cfg = (cfgAll && cfgAll.data) || {};
    var clKey = 'evalChecklist' + rolU;
    var items = null;
    try {
      var raw = cfg[clKey];
      if (raw) items = (typeof raw === 'string' ? JSON.parse(raw) : raw);
    } catch(_){}
    if (!items || !items.length) {
      // Fallback: defaults básicos
      items = (rolU === 'CAJERO' || rolU === 'VENDEDOR')
        ? ['Amabilidad','Cobra correcto','Guias ingreso','Reposicion','Conoce precios','Maneja efectivo','Reporta incidencias','Puntualidad']
        : ['Buen uso del sistema','Acomoda productos','Rotula correcto','FIFO','Recibe mercaderia','EPP','Reporta mermas','Puntualidad'];
    }
    var checks = (r.manual && r.manual.checksAcum) || {};
    items.forEach(function(it, i){
      var marca = checks['c'+i] ? '[X]' : '[ ]';
      // Cortar item a W-5 para que entre con marca
      var maxLen = W - 5;
      var t = _norm(it);
      if (t.length > maxLen) t = t.substring(0, maxLen-1) + '~';
      txt += marca + ' ' + t + '\n';
    });
    var cnt = (r.manual && r.manual.checkCount) || 0;
    var tot = items.length;
    txt += _pEnd('Cumplidos: ' + cnt + ' / ' + tot, W) + '\n';
  } catch(eCl) {
    txt += _norm('(checklist no disponible)') + '\n';
  }
  txt += SEPd;

  // ── SCORE FINAL ────────────────────────────────────────────
  txt += _pEnd('SCORE FINAL DEL DIA', 28) + _pSt((r.scoreFinal || 0).toFixed(1)+'%', 10) + '\n';
  txt += _bar(r.scoreFinal || 0);
  if (esPos && r.metaPct) {
    txt += _pEnd('Avance meta venta', 28) + _pSt((r.metaPct).toFixed(1)+'%', 10) + '\n';
  }
  txt += SEPd;

  // ── SANCIONES (si las hay) ─────────────────────────────────
  if (r.sancion && parseFloat(r.sancion) > 0) {
    txt += _sHdr('SANCIONES DEL DIA');
    (r.sancionesDetalle || []).forEach(function(s){
      var motivo = _norm(s.motivo || '(sin motivo)');
      if (motivo.length > W-10) motivo = motivo.substring(0, W-11) + '~';
      txt += _pEnd('[' + (s.hora || '--:--') + '] ' + motivo, W-12) + _amtN(-Math.abs(s.monto), 12) + '\n';
    });
    txt += _pEnd('TOTAL SANCIONES', W-12) + _amtN(-Math.abs(r.sancion), 12) + '\n';
    txt += SEPd;
  }

  // ── LIQUIDACION FINAL ──────────────────────────────────────
  txt += '\x1b\x21\x10'; // alto doble
  txt += _sHdr('LIQUIDACION');
  txt += '\x1b\x21\x00';
  txt += _pEnd('Base diaria', W-12)         + _amtP(r.montoBase, 12) + '\n';
  if (esPos) {
    txt += _pEnd('Bono por meta', W-12)     + _amtP(r.bonoMeta, 12) + '\n';
  } else if (esAlm) {
    txt += _pEnd('Pago envasado', W-12)     + _amtP(r.pagoEnvasado, 12) + '\n';
  }
  if (r.sancion && parseFloat(r.sancion) > 0) {
    txt += _pEnd('Sancion del dia', W-12)   + _amtN(-Math.abs(r.sancion), 12) + '\n';
  }
  txt += SEPd;
  txt += '\x1b\x21\x30'; // doble alto+ancho
  txt += _pEnd('TOTAL A PAGAR', W/2-6)      + _amtP(r.totalDia, W/2-4) + '\n';
  txt += '\x1b\x21\x00';
  txt += SEPd;

  // ── COMENTARIOS DEL AUDITOR ────────────────────────────────
  if (r.manual && r.manual.comentarios) {
    txt += _sHdr('COMENTARIOS');
    var coms = String(r.manual.comentarios).split('\n');
    coms.forEach(function(c){
      var t = _norm(c);
      while (t.length > W) {
        txt += t.substring(0, W) + '\n';
        t = t.substring(W);
      }
      if (t) txt += t + '\n';
    });
    txt += SEPd;
  }

  // ── FIRMA + PIE ────────────────────────────────────────────
  txt += '\n';
  txt += _pEnd('Firma personal', 20) + ' ' + _rep('_', W-22) + '\n\n';
  txt += _pEnd('V.B. admin/master', 20) + ' ' + _rep('_', W-22) + '\n\n';
  txt += '\x1b\x61\x01';
  txt += '\x1b\x45\x01*** FIN ***\x1b\x45\x00\n';
  txt += _norm('Impreso desde ProyectoMOS') + '\n';
  txt += Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'dd/MM/yyyy HH:mm:ss') + '\n';
  // Feed + corte
  txt += '\n\n\n\n\n\x1d\x56\x00';

  // ── ENVIO A PRINTNODE ──────────────────────────────────────
  var pnKey;
  try { pnKey = PropertiesService.getScriptProperties().getProperty('PRINTNODE_API_KEY'); } catch(_){}
  if (!pnKey) return { ok: false, error: 'PRINTNODE_API_KEY no configurado' };

  var bytes = [];
  for (var ci = 0; ci < txt.length; ci++) bytes.push(txt.charCodeAt(ci) & 0xFF);
  var content = Utilities.base64Encode(bytes);

  try {
    var pj = UrlFetchApp.fetch('https://api.printnode.com/printjobs', {
      method:      'post',
      headers:     { 'Authorization': 'Basic ' + Utilities.base64Encode(pnKey + ':') },
      contentType: 'application/json',
      payload:     JSON.stringify({
        printerId:   parseInt(String(params.printerId), 10),
        title:       'Liquidacion ' + r.nombre + ' ' + fecha,
        contentType: 'raw_base64',
        content:     content,
        source:      'ProyectoMOS · Liquidacion'
      }),
      muteHttpExceptions: true
    });
    var code2 = pj.getResponseCode();
    if (code2 !== 201) {
      return { ok: false, error: 'PrintNode HTTP ' + code2 + ': ' + pj.getContentText().substring(0, 200) };
    }
    return { ok: true, data: { printJobId: pj.getContentText(), totalDia: r.totalDia } };
  } catch(e) {
    return { ok: false, error: 'PrintNode fetch fallo: ' + e.message };
  }
}
