// ============================================================
// ProyectoMOS — Liquidaciones.gs
// Sistema de liquidación de jornales con cierre flexible:
//   - Cálculo dinámico hasta emitir (refleja cambios en bonos/jornadas)
//   - Snapshot inmutable al emitir (los datos quedan congelados)
//   - Soporta liquidación parcial (renuncias, adelantos)
//   - Días YA liquidados (en estado != ANULADA) no vuelven a aparecer
//   - Al marcar PAGADA → genera gasto automático en GASTOS / categoría JORNALES
// ============================================================

var _ESTADOS_LIQUIDACION = ['PENDIENTE', 'PAGADA', 'ANULADA'];

// ── Helpers ─────────────────────────────────────────────────

function _garantizarHojaLiquidaciones() {
  var ss = getSpreadsheet();
  var sheet = ss.getSheetByName('LIQUIDACIONES');
  if (sheet) return sheet;
  sheet = ss.insertSheet('LIQUIDACIONES');
  sheet.getRange(1, 1, 1, MOS_HEADERS.LIQUIDACIONES.length).setValues([MOS_HEADERS.LIQUIDACIONES]);
  sheet.getRange(1, 1, 1, MOS_HEADERS.LIQUIDACIONES.length)
       .setBackground('#0f3460').setFontColor('#e2e8f0').setFontWeight('bold').setFontSize(10);
  sheet.setFrozenRows(1);
  sheet.setColumnWidths(1, MOS_HEADERS.LIQUIDACIONES.length, 140);
  return sheet;
}

// Devuelve { lunes, domingo } como yyyy-MM-dd para una fecha dada (default hoy).
function _semanaLunDom(fechaRef) {
  var d = fechaRef ? new Date(fechaRef + 'T12:00:00') : new Date();
  var dia = d.getDay(); // 0=dom, 1=lun, ..., 6=sáb
  var diffLun = (dia === 0) ? -6 : (1 - dia); // si es domingo, retroceder 6
  var lun = new Date(d); lun.setDate(d.getDate() + diffLun);
  var dom = new Date(lun); dom.setDate(lun.getDate() + 6);
  var tz = Session.getScriptTimeZone();
  return {
    lunes:   Utilities.formatDate(lun, tz, 'yyyy-MM-dd'),
    domingo: Utilities.formatDate(dom, tz, 'yyyy-MM-dd')
  };
}

// Lista de fechas yyyy-MM-dd entre fechaIni y fechaFin (inclusivos).
function _rangoFechas(fechaIni, fechaFin) {
  var out = [];
  var d = new Date(fechaIni + 'T12:00:00');
  var fin = new Date(fechaFin + 'T12:00:00');
  var tz = Session.getScriptTimeZone();
  while (d <= fin) {
    out.push(Utilities.formatDate(d, tz, 'yyyy-MM-dd'));
    d.setDate(d.getDate() + 1);
  }
  return out;
}

// Devuelve mapa { 'idPersonal::fecha': true } de días YA liquidados (en estado ≠ ANULADA).
function _cargarDiasYaLiquidados() {
  _garantizarHojaLiquidaciones();
  var rows = _sheetToObjects(getSheet('LIQUIDACIONES'));
  var map = {};
  rows.forEach(function(r) {
    if (String(r.estado || '').toUpperCase() === 'ANULADA') return;
    var idP = String(r.idPersonal || '').trim();
    if (!idP) return;
    try {
      var dias = typeof r.diasJSON === 'string' ? JSON.parse(r.diasJSON || '[]') : (r.diasJSON || []);
      dias.forEach(function(d) {
        if (d && d.fecha) map[idP + '::' + d.fecha] = true;
      });
    } catch(_){}
  });
  return map;
}

// Construye el detalle de un día específico para un personal usando getResumenDia.
// Retorna { fecha, presente, auditado, base, bonus, meta, totalDia, logros[], pendientes[] }
function _calcularDiaDetalle(idPersonal, fecha) {
  var r = getResumenDia({ idPersonal: idPersonal, fecha: fecha });
  if (!r || !r.ok) {
    return { fecha: fecha, presente: false, auditado: false, base: 0, bonus: 0, meta: 0, totalDia: 0, logros: [], pendientes: [] };
  }
  var rd = r.data;
  var logros = [];
  var pendientes = [];
  if (rd.presente) {
    if (rd.auditado) {
      var limpEst  = rd.manual && rd.manual.limpiezaPct;
      var limpProf = rd.manual && rd.manual.limpiezaProfPct;
      if (limpEst >= 70)      logros.push('Limpieza estación ' + Math.round(limpEst) + '%');
      else if (limpEst >= 0)  pendientes.push('Limpieza estación bajó a ' + Math.round(limpEst) + '%');
      if (limpProf >= 70)     logros.push('Limpieza profunda ' + Math.round(limpProf) + '%');
      else if (limpProf >= 0) pendientes.push('Limpieza profunda bajó a ' + Math.round(limpProf) + '%');
      if (rd.scoreFinal >= 80) logros.push('Score ' + rd.scoreFinal + '/100');
      else                     pendientes.push('Score ' + rd.scoreFinal + '/100 (objetivo 80)');
      if (rd.bonoMeta > 0)     logros.push('Meta del día alcanzada (S/ ' + rd.bonoMeta + ' bono)');
      else                     pendientes.push('Meta del día no alcanzada');
    } else {
      pendientes.push('Día sin auditoría — solo paga base');
    }
  } else {
    pendientes.push('Ausente — no se paga');
  }
  return {
    fecha:     fecha,
    presente:  !!rd.presente,
    auditado:  !!rd.auditado,
    base:      rd.montoBase  || 0,
    bonus:     rd.bonusScore || 0,
    meta:      rd.bonoMeta   || 0,
    totalDia:  rd.totalDia   || 0,
    score:     rd.scoreFinal || 0,
    logros:    logros,
    pendientes: pendientes
  };
}

// Para un personal y semana, calcula días pendientes (con jornada y NO ya liquidados).
function _calcularDiasPendientesPersonal(idPersonal, lunes, domingo, mapaYaLiq) {
  var fechas = _rangoFechas(lunes, domingo);
  var hoy = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
  var diasDetalle = [];
  fechas.forEach(function(f) {
    if (f > hoy) return; // no incluir días futuros
    if (mapaYaLiq[idPersonal + '::' + f]) return; // ya liquidado
    var det = _calcularDiaDetalle(idPersonal, f);
    if (det.presente || det.totalDia > 0) {
      diasDetalle.push(det);
    }
  });
  return diasDetalle;
}

// ── Endpoints públicos ──────────────────────────────────────

// Lista personal con días pendientes en la semana actual (o referencia).
// Retorna: { semanaInicio, semanaFin, hoy, personal: [{ idPersonal, nombre, ..., dias, totales }] }
function getLiquidacionesPendientesSemana(params) {
  try {
    _garantizarHojaLiquidaciones();
    var fechaRef = (params && params.fechaRef) || null;
    var sem = _semanaLunDom(fechaRef);
    var hoy = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
    var mapaYaLiq = _cargarDiasYaLiquidados();

    // Personal activo y EVALUABLE (excluye MASTER/ADMINISTRADOR/MOS — son auditores)
    var personal = _sheetToObjects(getSheet('PERSONAL_MASTER')).filter(function(p) {
      var ac = p.estado;
      var activo = (ac === undefined || ac === '' || ac === 1 || ac === '1' || ac === true);
      if (!activo) return false;
      if (typeof _esPersonalEvaluable === 'function') return _esPersonalEvaluable(p);
      return true;
    });

    var resultado = [];
    personal.forEach(function(p) {
      var dias = _calcularDiasPendientesPersonal(p.idPersonal, sem.lunes, sem.domingo, mapaYaLiq);
      if (!dias.length) return;
      var tBase = 0, tBonus = 0, tMeta = 0;
      var diasAuditados = 0;
      dias.forEach(function(d) {
        tBase  += d.base  || 0;
        tBonus += d.bonus || 0;
        tMeta  += d.meta  || 0;
        if (d.auditado) diasAuditados++;
      });
      resultado.push({
        idPersonal:     p.idPersonal,
        nombre:         (p.nombre + ' ' + (p.apellido || '')).trim(),
        rol:            p.rol     || '',
        appOrigen:      p.appOrigen || '',
        diasPendientes: dias.length,
        diasAuditados:  diasAuditados,
        fechas:         dias.map(function(d){ return d.fecha; }),
        montoBase:      Math.round(tBase  * 100) / 100,
        montoBonus:     Math.round(tBonus * 100) / 100,
        montoMeta:      Math.round(tMeta  * 100) / 100,
        montoTotal:     Math.round((tBase + tBonus + tMeta) * 100) / 100
      });
    });

    // Ordenar: más días pendientes primero
    resultado.sort(function(a, b){ return b.diasPendientes - a.diasPendientes; });

    var totalGeneral = resultado.reduce(function(s, r){ return s + r.montoTotal; }, 0);

    return { ok: true, data: {
      semanaInicio: sem.lunes,
      semanaFin:    sem.domingo,
      hoy:          hoy,
      personal:     resultado,
      totalGeneral: Math.round(totalGeneral * 100) / 100
    }};
  } catch(e) {
    return { ok: false, error: 'Error pendientes: ' + e.message };
  }
}

// Detalle día por día de un personal — para mostrar antes de emitir o en preview.
function getDetalleDiasPendientes(params) {
  try {
    if (!params || !params.idPersonal) return { ok: false, error: 'idPersonal requerido' };
    var fechaRef = params.fechaRef || null;
    var sem = _semanaLunDom(fechaRef);
    var mapaYaLiq = _cargarDiasYaLiquidados();
    var p = _resolverPersona(params.idPersonal);
    if (!p) return { ok: false, error: 'Personal no encontrado' };
    var dias = _calcularDiasPendientesPersonal(params.idPersonal, sem.lunes, sem.domingo, mapaYaLiq);
    var tBase = 0, tBonus = 0, tMeta = 0;
    dias.forEach(function(d) {
      tBase  += d.base  || 0;
      tBonus += d.bonus || 0;
      tMeta  += d.meta  || 0;
    });
    return { ok: true, data: {
      idPersonal:   p.idPersonal,
      nombre:       (p.nombre + ' ' + (p.apellido || '')).trim(),
      rol:          p.rol      || '',
      appOrigen:    p.appOrigen || '',
      semanaInicio: sem.lunes,
      semanaFin:    sem.domingo,
      dias:         dias,
      montoBase:    Math.round(tBase  * 100) / 100,
      montoBonus:   Math.round(tBonus * 100) / 100,
      montoMeta:    Math.round(tMeta  * 100) / 100,
      montoTotal:   Math.round((tBase + tBonus + tMeta) * 100) / 100
    }};
  } catch(e) {
    return { ok: false, error: 'Error detalle: ' + e.message };
  }
}

// Emite liquidación para un personal con un set específico de fechas.
// params: { idPersonal, fechas?: ['yyyy-MM-dd', ...], comentario?, usuario? }
// Si no se pasan fechas, usa todos los días pendientes de la semana actual.
function emitirLiquidacion(params) {
  try {
    _garantizarHojaLiquidaciones();
    if (!params || !params.idPersonal) return { ok: false, error: 'idPersonal requerido' };

    var p = _resolverPersona(params.idPersonal);
    if (!p) return { ok: false, error: 'Personal no encontrado' };

    // Bloquear roles no evaluables (MASTER, ADMINISTRADOR, appOrigen=MOS)
    if (typeof _esPersonalEvaluable === 'function' && !_esPersonalEvaluable(p)) {
      return { ok: false, error: 'Este rol no es evaluable ni se le paga jornada (MASTER/ADMINISTRADOR/auditor)' };
    }

    var sem = _semanaLunDom(params.fechaRef || null);
    var mapaYaLiq = _cargarDiasYaLiquidados();

    // Determinar las fechas a liquidar
    var fechasObjetivo;
    if (params.fechas && Array.isArray(params.fechas) && params.fechas.length) {
      fechasObjetivo = params.fechas.slice();
    } else {
      // Default: días pendientes de la semana actual
      var pendientes = _calcularDiasPendientesPersonal(p.idPersonal, sem.lunes, sem.domingo, mapaYaLiq);
      fechasObjetivo = pendientes.map(function(d){ return d.fecha; });
    }

    if (!fechasObjetivo.length) {
      return { ok: false, error: 'No hay días pendientes para liquidar' };
    }

    // Validar que ninguna fecha esté ya liquidada (defensa contra carrera)
    var conflictos = [];
    fechasObjetivo.forEach(function(f) {
      if (mapaYaLiq[p.idPersonal + '::' + f]) conflictos.push(f);
    });
    if (conflictos.length) {
      return { ok: false, error: 'Algunas fechas ya están liquidadas: ' + conflictos.join(', ') };
    }

    // Calcular detalle para cada fecha
    var diasDetalle = fechasObjetivo.sort().map(function(f) {
      return _calcularDiaDetalle(p.idPersonal, f);
    });

    // Acumular totales
    var tBase = 0, tBonus = 0, tMeta = 0;
    diasDetalle.forEach(function(d) {
      tBase  += d.base  || 0;
      tBonus += d.bonus || 0;
      tMeta  += d.meta  || 0;
    });
    var tTotal = tBase + tBonus + tMeta;

    var fechaInicio = diasDetalle[0].fecha;
    var fechaFin    = diasDetalle[diasDetalle.length - 1].fecha;
    var rangoSemana = _rangoFechas(sem.lunes, sem.domingo);
    var esParcial   = (fechasObjetivo.length < rangoSemana.length) || (fechaInicio > sem.lunes) || (fechaFin < sem.domingo);

    var idLiq = 'LIQ' + new Date().getTime();
    var sheet = getSheet('LIQUIDACIONES');
    sheet.appendRow([
      idLiq,
      p.idPersonal,
      (p.nombre + ' ' + (p.apellido || '')).trim(),
      p.rol      || '',
      p.appOrigen || '',
      sem.lunes,                                                          // semanaReferencia
      fechaInicio,
      fechaFin,
      JSON.stringify(diasDetalle),                                        // diasJSON
      diasDetalle.length,
      Math.round(tBase  * 100) / 100,
      Math.round(tBonus * 100) / 100,
      Math.round(tMeta  * 100) / 100,
      Math.round(tTotal * 100) / 100,
      'PENDIENTE',
      esParcial ? 1 : 0,
      new Date(),
      params.usuario || '',
      '',                                                                 // fechaPago
      '',                                                                 // pagadoPor
      '',                                                                 // idGastoGenerado
      params.comentario || ''
    ]);

    return { ok: true, data: {
      idLiquidacion: idLiq,
      idPersonal:    p.idPersonal,
      nombre:        (p.nombre + ' ' + (p.apellido || '')).trim(),
      cantidadDias:  diasDetalle.length,
      montoTotal:    Math.round(tTotal * 100) / 100,
      esParcial:     esParcial
    }};
  } catch(e) {
    return { ok: false, error: 'Error emitiendo: ' + e.message };
  }
}

// Emite TODAS las liquidaciones pendientes de la semana actual (bulk).
function emitirLiquidacionesTodas(params) {
  try {
    var pend = getLiquidacionesPendientesSemana(params || {});
    if (!pend.ok) return pend;
    var personas = pend.data.personal || [];
    var emitidas = [], errores = [];
    personas.forEach(function(per) {
      var r = emitirLiquidacion({
        idPersonal: per.idPersonal,
        fechas:     per.fechas,
        usuario:    (params && params.usuario) || '',
        comentario: (params && params.comentario) || 'Cierre semanal'
      });
      if (r.ok) emitidas.push(r.data);
      else errores.push({ idPersonal: per.idPersonal, error: r.error });
    });
    return { ok: true, data: {
      emitidas: emitidas,
      errores:  errores,
      total:    emitidas.reduce(function(s, e){ return s + (e.montoTotal || 0); }, 0)
    }};
  } catch(e) {
    return { ok: false, error: 'Error emisión bulk: ' + e.message };
  }
}

// Marca una liquidación como PAGADA y auto-genera gasto en GASTOS / categoría JORNALES.
function marcarLiquidacionPagada(params) {
  try {
    if (!params || !params.idLiquidacion) return { ok: false, error: 'idLiquidacion requerido' };
    var sheet = _garantizarHojaLiquidaciones();
    var data = sheet.getDataRange().getValues();
    var hdrs = data[0];
    var idxId = hdrs.indexOf('idLiquidacion');
    var idxEstado = hdrs.indexOf('estado');
    var idxFechaPago = hdrs.indexOf('fechaPago');
    var idxPagadoPor = hdrs.indexOf('pagadoPor');
    var idxIdGasto = hdrs.indexOf('idGastoGenerado');
    var idxNombre = hdrs.indexOf('nombrePersonal');
    var idxFI = hdrs.indexOf('fechaInicio');
    var idxFF = hdrs.indexOf('fechaFin');
    var idxMonto = hdrs.indexOf('montoTotal');

    for (var i = 1; i < data.length; i++) {
      if (String(data[i][idxId]) !== String(params.idLiquidacion)) continue;
      var estadoActual = String(data[i][idxEstado] || '').toUpperCase();
      if (estadoActual === 'PAGADA') return { ok: false, error: 'Ya estaba pagada' };
      if (estadoActual === 'ANULADA') return { ok: false, error: 'Está anulada — no se puede pagar' };

      var nombre = data[i][idxNombre];
      var fi     = data[i][idxFI];
      var ff     = data[i][idxFF];
      var monto  = parseFloat(data[i][idxMonto]) || 0;

      // Auto-generar gasto
      var idGasto = '';
      try {
        var gastoSheet = getSheet('GASTOS');
        idGasto = 'GA' + new Date().getTime();
        gastoSheet.appendRow([
          idGasto,
          new Date(),
          'JORNALES',
          'VARIABLE',
          'Liquidación ' + fi + ' a ' + ff + ' · ' + nombre,
          monto,
          params.idLiquidacion,         // comprobante = idLiquidacion (audit trail)
          params.usuario || ''
        ]);
      } catch(eG) { Logger.log('No se pudo crear gasto: ' + eG.message); }

      sheet.getRange(i + 1, idxEstado + 1).setValue('PAGADA');
      sheet.getRange(i + 1, idxFechaPago + 1).setValue(new Date());
      sheet.getRange(i + 1, idxPagadoPor + 1).setValue(params.usuario || '');
      sheet.getRange(i + 1, idxIdGasto + 1).setValue(idGasto);

      return { ok: true, data: { idLiquidacion: params.idLiquidacion, idGastoGenerado: idGasto } };
    }
    return { ok: false, error: 'Liquidación no encontrada' };
  } catch(e) {
    return { ok: false, error: 'Error pagando: ' + e.message };
  }
}

// Anula una liquidación. Si tenía gasto vinculado, lo anula también.
// Después de anular, los días vuelven a estar disponibles para una nueva liquidación.
function anularLiquidacion(params) {
  try {
    if (!params || !params.idLiquidacion) return { ok: false, error: 'idLiquidacion requerido' };
    var sheet = _garantizarHojaLiquidaciones();
    var data = sheet.getDataRange().getValues();
    var hdrs = data[0];
    var idxId = hdrs.indexOf('idLiquidacion');
    var idxEstado = hdrs.indexOf('estado');
    var idxIdGasto = hdrs.indexOf('idGastoGenerado');
    var idxComent = hdrs.indexOf('comentario');

    for (var i = 1; i < data.length; i++) {
      if (String(data[i][idxId]) !== String(params.idLiquidacion)) continue;
      var estadoActual = String(data[i][idxEstado] || '').toUpperCase();
      if (estadoActual === 'ANULADA') return { ok: true, yaAnulada: true };

      // Si tenía gasto, removerlo (eliminar fila de GASTOS)
      var idGasto = String(data[i][idxIdGasto] || '').trim();
      if (idGasto) {
        try {
          var gastoSheet = getSheet('GASTOS');
          var dG = gastoSheet.getDataRange().getValues();
          for (var j = 1; j < dG.length; j++) {
            if (String(dG[j][0]) === idGasto) { gastoSheet.deleteRow(j + 1); break; }
          }
        } catch(_){}
      }

      sheet.getRange(i + 1, idxEstado + 1).setValue('ANULADA');
      var motivoTxt = (params.motivo ? '[Anulada: ' + params.motivo + '] ' : '[Anulada] ');
      sheet.getRange(i + 1, idxComent + 1).setValue(motivoTxt + (data[i][idxComent] || ''));
      return { ok: true, data: { idLiquidacion: params.idLiquidacion } };
    }
    return { ok: false, error: 'Liquidación no encontrada' };
  } catch(e) {
    return { ok: false, error: 'Error anulando: ' + e.message };
  }
}

// Lista liquidaciones emitidas con filtros.
// params: { estado?: PENDIENTE|PAGADA|ANULADA, mes?: 'yyyy-MM', idPersonal?: string }
function getLiquidacionesEmitidas(params) {
  try {
    _garantizarHojaLiquidaciones();
    var rows = _sheetToObjects(getSheet('LIQUIDACIONES'));
    var p = params || {};
    if (p.estado)     rows = rows.filter(function(r){ return String(r.estado).toUpperCase() === String(p.estado).toUpperCase(); });
    if (p.idPersonal) rows = rows.filter(function(r){ return r.idPersonal === p.idPersonal; });
    if (p.mes) {
      var mes = String(p.mes); // 'yyyy-MM'
      rows = rows.filter(function(r){
        var ref = String(r.semanaReferencia || r.fechaInicio || '').substring(0, 7);
        return ref === mes;
      });
    }
    // Ordenar: fecha generación desc
    rows.sort(function(a, b){
      var fa = new Date(a.fechaGeneracion).getTime() || 0;
      var fb = new Date(b.fechaGeneracion).getTime() || 0;
      return fb - fa;
    });
    return { ok: true, data: rows };
  } catch(e) {
    return { ok: false, error: 'Error listando: ' + e.message };
  }
}

// Devuelve detalle completo de una liquidación (para impresión / vista).
function getLiquidacionDetalle(params) {
  try {
    if (!params || !params.idLiquidacion) return { ok: false, error: 'idLiquidacion requerido' };
    _garantizarHojaLiquidaciones();
    var rows = _sheetToObjects(getSheet('LIQUIDACIONES'));
    var liq = rows.find(function(r){ return String(r.idLiquidacion) === String(params.idLiquidacion); });
    if (!liq) return { ok: false, error: 'Liquidación no encontrada' };
    try {
      liq.dias = typeof liq.diasJSON === 'string' ? JSON.parse(liq.diasJSON || '[]') : (liq.diasJSON || []);
    } catch(_){ liq.dias = []; }
    return { ok: true, data: liq };
  } catch(e) {
    return { ok: false, error: 'Error detalle: ' + e.message };
  }
}
