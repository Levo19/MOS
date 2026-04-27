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
    metaCajero:     parseFloat(cfg.evalMetaCajero     || 2000),
    metaEnvasador:  parseFloat(cfg.evalMetaEnvasador  || 500),
    metaAlmacenero: parseFloat(cfg.evalMetaAlmacenero || 15),
    bonoMetaBase:   parseFloat(cfg.evalBonoMetaBase   || 8),
    bonoMetaDoble:  parseFloat(cfg.evalBonoMetaDoble  || 15),
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

// ── Resumen del día por persona — ACUMULATIVO (MAX/OR) ─────────
function getResumenDia(params) {
  var fecha      = params.fecha || _hoy();
  var idPersonal = params.idPersonal;
  if (!idPersonal) return { ok: false, error: 'idPersonal requerido' };

  var personal = _sheetToObjects(getSheet('PERSONAL_MASTER'));
  var p        = personal.find(function(x){ return x.idPersonal === idPersonal; });
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
      Object.keys(c).forEach(function(k){ if (c[k]) checksAcum[k] = true; });
    } catch(_){}
    if (e.comentario) comentarios.push('[' + e.hora + '] ' + e.comentario);
    if (e.aplicaComision === false || String(e.aplicaComision) === 'false') aplicaComision = false;
    if (e.aplicaBonoMeta === false || String(e.aplicaBonoMeta) === 'false') aplicaBonoMeta = false;
  });

  var checkCount = Object.keys(checksAcum).length;
  var checkTotal = 8;
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

  return {
    ok: true,
    data: {
      idPersonal:        p.idPersonal,
      nombre:            (p.nombre + ' ' + (p.apellido || '')).trim(),
      rol:               p.rol,
      appOrigen:         p.appOrigen,
      fecha:             fecha,
      evaluacionesCount: evals.length,
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
      bonusScore:    Math.round(bonusScore * 100) / 100,
      bonoMeta:      bonoMeta,
      metaPct:       metaPct,
      montoBase:     montoBase,
      totalDia:      Math.round((montoBase + bonusScore + bonoMeta) * 100) / 100,
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

  var ventasReales = 0, ventasPct = 0, auditPct = 0, guias = 0, envasados = 0;

  try {
    if (rol === 'CAJERO' || rol === 'VENDEDOR') {
      // Buscar ventas en MosExpress por nombre
      try {
        var ventas = getVentasMosExpress({ fecha: fecha });
        var lista  = (ventas && ventas.detalle) || (Array.isArray(ventas) ? ventas : []);
        lista.forEach(function(v){
          var vendedor = String(v.vendedor || '').toLowerCase();
          var estado   = String(v.estado   || '').toUpperCase();
          if (vendedor.indexOf(p.nombre.toLowerCase()) >= 0 && estado !== 'ANULADO') {
            ventasReales += parseFloat(v.total) || 0;
          }
        });
      } catch(_){}
      ventasPct = Math.min(100, (ventasReales / cfg.metaCajero) * 100);
    } else if (rol === 'ENVASADOR') {
      try {
        var enva = getEnvasadosWarehouse({ fecha: fecha, usuario: nombre });
        if (Array.isArray(enva)) {
          enva.forEach(function(e){ envasados += parseFloat(e.unidadesProducidas) || 0; });
        } else if (enva && enva.detalle) {
          enva.detalle.forEach(function(e){ envasados += parseFloat(e.unidadesProducidas) || 0; });
        }
      } catch(_){}
      ventasPct = Math.min(100, (envasados / cfg.metaEnvasador) * 100);
    } else if (rol === 'ALMACENERO') {
      try {
        var guiasResp = getGuiasWarehouse({ fecha: fecha, usuario: nombre });
        if (Array.isArray(guiasResp))      guias = guiasResp.length;
        else if (guiasResp && guiasResp.detalle) guias = guiasResp.detalle.length;
      } catch(_){}
      ventasPct = Math.min(100, (guias / cfg.metaAlmacenero) * 100);
    }
  } catch(_){}

  return {
    ventasReales: Math.round(ventasReales * 100) / 100,
    ventasPct:    Math.round(ventasPct * 10) / 10,
    auditPct:     auditPct,
    guias:        guias,
    envasados:    envasados
  };
}

// ── Resumen del día para TODOS los empleados ───────────────────
function getResumenTodosDia(params) {
  var fecha    = params.fecha || _hoy();
  var personal = _sheetToObjects(getSheet('PERSONAL_MASTER')).filter(function(r){
    return String(r.estado) === '1' && (r.appOrigen === 'warehouseMos' || r.appOrigen === 'mosExpress');
  });
  var resumenes = personal.map(function(p){
    var r = getResumenDia({ idPersonal: p.idPersonal, fecha: fecha });
    return r.ok ? r.data : null;
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

  var personal = _sheetToObjects(getSheet('PERSONAL_MASTER'));
  var p        = personal.find(function(x){ return x.idPersonal === idPersonal; });
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
      evaluado:   rd.evaluacionesCount > 0,
      score:      rd.scoreFinal,
      montoBase:  rd.montoBase,
      bonusScore: rd.bonusScore,
      bonoMeta:   rd.bonoMeta,
      totalDia:   rd.totalDia
    });
    if (rd.evaluacionesCount > 0) {
      totalBase  += rd.montoBase;
      totalBonus += rd.bonusScore;
      totalMeta  += rd.bonoMeta;
      // Trackear ítems no cumplidos para sección "qué mejorar"
      if (rd.manual.controlPct < 100) {
        var checks = rd.manual.checksAcum || {};
        // Solo nos interesan los faltantes — el frontend resuelve el listado
      }
      if (rd.manual.limpiezaPct < 70) {
        deficiencias['limpieza_estacion'] = (deficiencias['limpieza_estacion'] || 0) + 1;
      }
      if (rd.manual.limpiezaProfPct < 70) {
        deficiencias['limpieza_profunda'] = (deficiencias['limpieza_profunda'] || 0) + 1;
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
