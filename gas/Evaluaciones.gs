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

// ── Resolver persona (real o virtual MEX:nombre desde MosExpress) ──
// Para virtuales detecta si tuvo caja abierta hoy → CAJERO, si solo vendió → VENDEDOR
function _resolverPersona(idPersonal, fechaHint) {
  if (idPersonal && idPersonal.indexOf('MEX:') === 0) {
    var nombre = idPersonal.substring(4);
    var personal = _sheetToObjects(getSheet('PERSONAL_MASTER'));
    var genericos = personal.filter(function(r){
      var n = String(r.nombre || '').toLowerCase();
      return r.appOrigen === 'mosExpress' && (n.indexOf('gener') >= 0 || n.indexOf('génér') >= 0);
    });

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
      // Leer directo de VENTAS_CABECERA de MosExpress (columnas capitalizadas)
      try {
        var sh = _abrirMeSheet('VENTAS_CABECERA');
        if (sh) {
          var data = sh.getDataRange().getValues();
          var tz   = Session.getScriptTimeZone();
          var nombreLow = (p.nombre || '').toLowerCase();
          // Headers tipicos: 0=ID 1=Fecha 2=Vendedor 6=Total 8=FormaPago
          for (var r = 1; r < data.length; r++) {
            var row = data[r];
            var fRaw = row[1];
            var fStr = fRaw instanceof Date
              ? Utilities.formatDate(fRaw, tz, 'yyyy-MM-dd')
              : String(fRaw || '').substring(0, 10);
            if (fStr !== fecha) continue;
            var vendedor = String(row[2] || '').toLowerCase().trim();
            var formaPago = String(row[8] || '').toUpperCase();
            if (formaPago === 'ANULADO') continue;
            if (!vendedor) continue;
            // Match por contención (vendedor field puede tener nombre completo)
            if (vendedor === nombreLow || vendedor.indexOf(nombreLow) >= 0 || nombreLow.indexOf(vendedor) >= 0) {
              ventasReales += parseFloat(row[6]) || 0;
            }
          }
        }
      } catch(eV){ Logger.log('KPI ventas error: ' + eV.message); }
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
// Incluye warehouseMos del master + vendedores reales que abrieron caja hoy
// en MosExpress. Si un vendedor no está en master se vuelve virtual MEX:nombre.
function getResumenTodosDia(params) {
  var fecha    = params.fecha || _hoy();
  var personal = _sheetToObjects(getSheet('PERSONAL_MASTER')).filter(function(r){
    return String(r.estado) === '1';
  });

  // Detectar genéricos de mosExpress por rol (plantillas para virtuales)
  var genericos = personal.filter(function(r){
    var n = String(r.nombre || '').toLowerCase();
    return r.appOrigen === 'mosExpress' && (n.indexOf('gener') >= 0 || n.indexOf('génér') >= 0);
  });
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
        var fs = fr instanceof Date
          ? Utilities.formatDate(fr, tzWh, 'yyyy-MM-dd')
          : String(fr || '').substring(0, 10);
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
        var fStr = f instanceof Date ? Utilities.formatDate(f, tz, 'yyyy-MM-dd') : String(f || '').substring(0, 10);
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
        var fs = fr instanceof Date ? Utilities.formatDate(fr, tz, 'yyyy-MM-dd') : String(fr || '').substring(0, 10);
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
