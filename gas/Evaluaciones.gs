// ============================================================
// ProyectoMOS — Evaluaciones.gs
// Sistema de evaluación de personal con acumulativo diario (MAX/OR)
// y liquidación semanal con bonos por score (tramos) y por meta.
// ============================================================

// ── Hoja EVALUACIONES (auto-crear) ─────────────────────────────
function _getEvalSheet() {
  var ss = getSpreadsheet();
  var sheet = ss.getSheetByName('EVALUACIONES');
  if (!sheet) {
    sheet = ss.insertSheet('EVALUACIONES');
    sheet.appendRow([
      'idEval', 'fecha', 'idPersonal', 'rol', 'hora',
      'limpiezaPct', 'limpiezaProfPct',
      'controlChecks', 'comentario', 'evaluadoPor',
      'aplicaComision', 'aplicaBonoMeta', 'activo'
    ]);
    sheet.setFrozenRows(1);
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
    true
  ]);
  return { ok: true, data: { idEval: id } };
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

  // Acumulativo: MAX para limpiezas, OR para checks
  var maxLimp = 0, maxLimpProf = 0;
  var checksAcum = {};
  var totalKeysVistos = {};   // todas las llaves del checklist enviadas
  var comentarios = [];
  var aplicaComision = true, aplicaBonoMeta = true;
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
  });

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

  // Bonus por tramo de score
  var bonusPctScore = 0;
  for (var i = 0; i < cfg.bonoTramos.length; i++) {
    if (scoreFinal >= cfg.bonoTramos[i].min) { bonusPctScore = cfg.bonoTramos[i].pct; break; }
  }
  var montoBase  = parseFloat(p.montoBase) || 0;
  var bonusScore = aplicaComision ? (montoBase * bonusPctScore / 100) : 0;

  // Bono por meta
  var bonoMeta = 0, metaPct = 0;
  if (aplicaBonoMeta) {
    var meta = 0, real = 0;
    if (p.rol === 'CAJERO' || p.rol === 'VENDEDOR') { meta = cfg.metaCajero;     real = kpis.ventasReales; }
    else if (p.rol === 'ENVASADOR')                  { meta = cfg.metaEnvasador;  real = kpis.envasados; }
    else if (p.rol === 'ALMACENERO')                 { meta = cfg.metaAlmacenero; real = kpis.guias; }
    if (meta > 0) {
      metaPct = Math.round((real / meta) * 1000) / 10;
      if (real >= meta * 2) bonoMeta = cfg.bonoMetaDoble;
      else if (real >= meta) bonoMeta = cfg.bonoMetaBase;
    }
  }

  // Lógica de pago:
  // - Si trabajó ese día (presente) → cobra montoBase si o sí
  // - Si además fue auditado → suma bonus + meta
  // - Si no trabajó → 0 (no cobra nada)
  var presente = _estaPresente(p, fecha);
  var auditado = evals.length > 0;
  var baseEfectiva  = presente ? montoBase : 0;
  var bonusEfectivo = (presente && auditado) ? bonusScore : 0;
  var metaEfectivo  = (presente && auditado) ? bonoMeta   : 0;

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
      montoBase:     baseEfectiva,
      tarifaDiaria:  montoBase, // tarifa configurada (info)
      totalDia:      Math.round((baseEfectiva + bonusEfectivo + metaEfectivo) * 100) / 100,
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
      try {
        var sh = _abrirMeSheet('VENTAS_CABECERA');
        if (sh) {
          var data = sh.getDataRange().getValues();
          var tz   = Session.getScriptTimeZone();
          var nombreLow = (p.nombre || '').toLowerCase().trim();
          // Headers tipicos: 0=ID 1=Fecha 2=Vendedor 6=Total 8=FormaPago
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
              ventasReales += parseFloat(row[6]) || 0;
            }
          }
        }
      } catch(eV){ Logger.log('KPI ventas error: ' + eV.message); }
      ventasPct = Math.min(100, (ventasReales / cfg.metaCajero) * 100);
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
            if (idxEstado >= 0 && String(d[r][idxEstado]).toUpperCase() === 'ANULADO') continue;
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
      ventasPct = Math.min(100, (guias / cfg.metaAlmacenero) * 100);
    }
  } catch(_){}

  return {
    ventasReales:     Math.round(ventasReales * 100) / 100,
    ventasPct:        Math.round(ventasPct * 10) / 10,
    auditoriasHechas: auditoriasHechas,
    metaAuditorias:   cfg.metaAuditorias,
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
  var personal = _sheetToObjects(getSheet('PERSONAL_MASTER')).filter(function(r){
    return String(r.estado) === '1' && _esPersonalEvaluable(r);
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

  // 3. Para cada nombre detectado: matchear con master o crear virtual
  Object.keys(rolesDelDia).forEach(function(nombre){
    var rol = rolesDelDia[nombre];
    var nLow = nombre.toLowerCase();
    var match = personal.find(function(p){
      if (p.appOrigen !== 'mosExpress') return false;
      var full = (String(p.nombre || '') + ' ' + (p.apellido || '')).trim().toLowerCase();
      return full === nLow || String(p.nombre || '').toLowerCase() === nLow;
    });
    var esGenerico = match && genericos.indexOf(match) >= 0;
    if (match && !esGenerico) {
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

  return { ok: true, data: resumenes };
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
    if (typeof _enviarPushTodos === 'function') {
      _enviarPushTodos('💰 Liquidación semanal lista', 'Revisa MOS para imprimir y pagar al personal.');
    }
    Logger.log('Cierre semanal disparado: ' + new Date());
  } catch(e) {
    Logger.log('cerrarSemanaAutomatico error: ' + e.message);
  }
}
