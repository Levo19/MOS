// ============================================================
// ProyectoMOS — Liquidaciones.gs (v2: pagos acumulados por día)
//
// Modelo:
//   - 1 fila = 1 persona × 1 día pagado (en LIQUIDACIONES_PAGOS).
//   - "Pendientes" = días con presencia que NO están en esa hoja.
//   - Cada batch "Pagar" = 1 idPago (LIQ-XXXX) por persona × N días.
//   - Editable: mientras el día NO esté pagado, se puede re-auditar y
//     el monto se recalcula al instante.
//   - Anular pago: estado=ANULADA → los días vuelven a Pendientes.
//
// Compatibilidad:
//   - Se conserva la hoja vieja como LIQUIDACIONES_LEGACY (migración
//     one-shot mueve filas PAGADA → LIQUIDACIONES_PAGOS).
//   - Endpoints legacy quedan como stubs que delegan al modelo nuevo.
// ============================================================

var _LIQ_SHEET = 'LIQUIDACIONES_PAGOS';
var _LIQ_HDRS  = [
  'idPago', 'fecha', 'idPersonal', 'nombre', 'rol', 'appOrigen',
  'montoBase', 'pagoEnvasado', 'bonoMeta', 'sancion', 'totalDia',
  'ticketJobId', 'pagadoPor', 'pagadoTs', 'estado',
  'comentario', 'idGastoGenerado'
];

// ── Helpers ─────────────────────────────────────────────────
function _liqGetSheet() {
  var ss = getSpreadsheet();
  var sh = ss.getSheetByName(_LIQ_SHEET);
  if (sh) return sh;
  sh = ss.insertSheet(_LIQ_SHEET);
  sh.getRange(1, 1, 1, _LIQ_HDRS.length).setValues([_LIQ_HDRS]);
  sh.getRange(1, 1, 1, _LIQ_HDRS.length)
    .setBackground('#1e3a8a').setFontColor('#e2e8f0').setFontWeight('bold').setFontSize(10);
  sh.setFrozenRows(1);
  // Forzar columnas idPago e idPersonal como texto
  try {
    sh.getRange(2, 1, 5000, 1).setNumberFormat('@');
    sh.getRange(2, 3, 5000, 1).setNumberFormat('@');
  } catch(_){}
  return sh;
}

function _liqHoy() {
  return Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
}

function _liqGenId() {
  // LIQ-<timestamp> — suficiente unicidad en práctica
  return 'LIQ-' + new Date().getTime();
}

// Mapa { 'idPersonal::fecha': {idPago, totalDia, estado, ...} } de días YA pagados
// (estado=PAGADA). Excluye ANULADA porque al anular el día vuelve a Pendientes.
function _liqMapaPagados() {
  var sh = _liqGetSheet();
  var rows = _sheetToObjects(sh);
  var map = {};
  rows.forEach(function(r) {
    if (String(r.estado || '').toUpperCase() !== 'PAGADA') return;
    var idP = String(r.idPersonal || '').trim();
    var fecha = r.fecha instanceof Date
      ? Utilities.formatDate(r.fecha, Session.getScriptTimeZone(), 'yyyy-MM-dd')
      : String(r.fecha || '').substring(0, 10);
    if (!idP || !fecha) return;
    map[idP + '::' + fecha] = r;
  });
  return map;
}

// ============================================================
// API NUEVA — el módulo que usa el modal "💼 Liquidaciones"
// ============================================================

// Devuelve TODAS las personas con días no pagados en el rango.
// INCLUYE virtuales (MEX:...) detectados automáticamente de cajas/ventas
// que no están en PERSONAL_MASTER pero tienen presencia y monto.
//
// Lógica de agrupado de identidad:
//   - idPersonal real (PERSONAL_MASTER) → 1 entrada por persona
//   - idPersonal virtual (MEX:nombre)  → 1 entrada por nombre detectado
// Ningún día se duplica: si Carlos aparece como virtual hoy y mañana como
// real (se agregó a master), se trata como personas distintas porque su
// idPersonal cambió. Aceptable porque el master debe agregarlo en su
// momento.
//
// Params: { desde:'yyyy-MM-dd', hasta:'yyyy-MM-dd' }
// Retorna: [{ idPersonal, nombre, rol, appOrigen, virtual, dias:[{fecha, ...}], total }]
// ⚡ MATERIALIZADO — ahora delega a getLiquidacionesPendientesDia que lee
// directamente de LIQUIDACIONES_DIA (instantáneo). El nombre se mantiene
// para no romper el frontend ni los caches localStorage.
function getLiquidacionesPendientes(params) {
  return getLiquidacionesPendientesDia(params);
}

// Versión LEGACY (cálculo virtual). Se conserva por si se quiere comparar
// o usar como fallback. No se llama por defecto.
function getLiquidacionesPendientesLegacy(params) {
  params = params || {};
  var hasta = params.hasta || _liqHoy();
  var desde = params.desde || _fechaOffset(hasta, -2);
  var mapaPag = _liqMapaPagados();

  var fechas = _rangoFechas(desde, hasta);
  var hoy = _liqHoy();

  // ── Cache script-side (TTL 90s) ──
  // getResumenTodosDia es costoso (~3s/día). Si en la última 1.5min se
  // pidió el resumen del mismo día (típico al navegar entre Pendientes y
  // Editar día), reusamos el JSON cacheado en CacheService.
  var ssCache;
  try { ssCache = CacheService.getScriptCache(); } catch(_){}
  function _rsmDelDiaCached(f) {
    var ck = 'rsm_d_' + f;
    if (ssCache) {
      try {
        var hit = ssCache.get(ck);
        if (hit) return JSON.parse(hit);
      } catch(_){}
    }
    var r;
    try { r = getResumenTodosDia({ fecha: f }); } catch(_){ return null; }
    if (r && r.ok && Array.isArray(r.data) && ssCache) {
      try { ssCache.put(ck, JSON.stringify(r), 90); } catch(_){}
    }
    return r;
  }

  // Acumulador: { idPersonal: { metadata, dias[] } }
  var acum = {};

  // Pre-fetch resumen por cada fecha del rango (incluye reales + virtuales).
  fechas.forEach(function(f) {
    if (f > hoy) return;
    var rsm = _rsmDelDiaCached(f);
    if (!rsm || !rsm.ok || !Array.isArray(rsm.data)) return;

    rsm.data.forEach(function(r) {
      if (!r || !r.presente) return;
      var idP = String(r.idPersonal || '').trim();
      if (!idP) return;
      var key = idP + '::' + f;
      if (mapaPag[key]) return; // ya pagado, no incluir

      // Filtro: si el rol es admin/master → no liquidable
      var rol = String(r.rol || '').toUpperCase();
      if (rol === 'MASTER' || rol === 'ADMIN' || rol === 'ADMINISTRADOR') return;

      // Crear entrada si no existe (primer día de esta persona en el rango)
      if (!acum[idP]) {
        acum[idP] = {
          idPersonal: idP,
          nombre:     String(r.nombre || ''),
          rol:        rol,
          appOrigen:  String(r.appOrigen || ''),
          virtual:    !!r.__virtual || idP.indexOf('MEX:') === 0,
          dias:       []
        };
      }
      // Agregar día
      acum[idP].dias.push({
        fecha:        f,
        presente:     true,
        auditado:     !!r.auditado,
        montoBase:    parseFloat(r.montoBase)    || 0,
        pagoEnvasado: parseFloat(r.pagoEnvasado) || 0,
        bonoMeta:     parseFloat(r.bonoMeta)     || 0,
        sancion:      parseFloat(r.sancion)      || 0,
        totalDia:     parseFloat(r.totalDia)     || 0,
        scoreFinal:   parseFloat(r.scoreFinal)   || 0,
        evaluacionesCount: parseInt(r.evaluacionesCount) || 0,
        tarifaEnvasado: parseFloat(r.tarifaEnvasado) || 0
      });
    });
  });

  // Materializar y ordenar días por fecha
  var out = Object.keys(acum).map(function(k) {
    var p = acum[k];
    p.dias.sort(function(a,b){ return String(a.fecha).localeCompare(String(b.fecha)); });
    var total = p.dias.reduce(function(s,d){ return s + d.totalDia; }, 0);
    p.total = Math.round(total * 100) / 100;
    p.cantidadDias = p.dias.length;
    return p;
  }).filter(function(p){ return p.cantidadDias > 0; });

  // Ordenar: más adeudado primero, luego alfabético
  out.sort(function(a,b){
    if (b.total !== a.total) return b.total - a.total;
    return String(a.nombre).localeCompare(String(b.nombre));
  });

  return { ok: true, data: out, rango: { desde: desde, hasta: hasta } };
}

// Marcar como pagados N días para 1 persona → genera 1 idPago + filas.
// Params: { idPersonal, fechas:['yyyy-MM-dd', ...], pagadoPor, comentario, imprimir, printerId }
// Retorna: { ok, data: { idPago, total, jobId? } }
function marcarPagos(params) {
  params = params || {};
  if (!params.idPersonal) return { ok: false, error: 'Requiere idPersonal' };
  if (!Array.isArray(params.fechas) || !params.fechas.length) {
    return { ok: false, error: 'Requiere fechas[]' };
  }

  // Resolver persona (acepta reales y virtuales MEX:nombre)
  var personalAll = _sheetToObjects(getSheet('PERSONAL_MASTER'));
  var p = personalAll.find(function(r){ return String(r.idPersonal) === String(params.idPersonal); });
  var esVirtual = String(params.idPersonal).indexOf('MEX:') === 0;
  if (!p && !esVirtual) {
    // Tampoco está en master ni es virtual conocido → intentar resolverlo
    // por getResumenDia de la primera fecha (puede que el resumen lo tenga
    // como virtual detectado).
    try {
      var rs = getResumenDia({ idPersonal: params.idPersonal, fecha: params.fechas[0] });
      if (rs && rs.ok && rs.data) {
        p = { idPersonal: rs.data.idPersonal, nombre: rs.data.nombre, apellido: '',
              rol: rs.data.rol, appOrigen: rs.data.appOrigen };
      }
    } catch(_){}
  }
  if (!p && esVirtual) {
    // Virtual: usar nombre/rol/appOrigen del params o del resumen
    p = {
      idPersonal: params.idPersonal,
      nombre:     params.nombre || String(params.idPersonal).substring(4),
      apellido:   '',
      rol:        String(params.rol || '').toUpperCase(),
      appOrigen:  params.appOrigen || 'mosExpress'
    };
  }
  if (!p) return { ok: false, error: 'Personal no encontrado' };
  var nombreFull = (String(p.nombre || '') + ' ' + String(p.apellido || '')).trim();

  // Validar que ningún día ya esté pagado (idempotencia básica)
  var mapaPag = _liqMapaPagados();
  var yaPagadas = params.fechas.filter(function(f){ return mapaPag[params.idPersonal + '::' + f]; });
  if (yaPagadas.length > 0) {
    return { ok: false, error: 'Días ya pagados: ' + yaPagadas.join(', ') };
  }

  var sh = _liqGetSheet();
  var idPago = _liqGenId();
  var pagadoTs = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
  var pagadoPor = String(params.pagadoPor || 'admin');
  var comentario = String(params.comentario || '');
  var rol = String(p.rol || '').toUpperCase();
  var appO = p.appOrigen || '';

  // Recolectar resúmenes por fecha (para snapshot inmutable de los montos)
  var filas = [];
  var totalPago = 0;
  for (var i = 0; i < params.fechas.length; i++) {
    var f = String(params.fechas[i]);
    var rsm;
    try { rsm = getResumenDia({ idPersonal: params.idPersonal, fecha: f }); } catch(_){}
    var rd = (rsm && rsm.ok) ? rsm.data : null;
    var montoBase    = rd ? (parseFloat(rd.montoBase)    || 0) : 0;
    var pagoEnvasado = rd ? (parseFloat(rd.pagoEnvasado) || 0) : 0;
    var bonoMeta     = rd ? (parseFloat(rd.bonoMeta)     || 0) : 0;
    var sancion      = rd ? (parseFloat(rd.sancion)      || 0) : 0;
    var totalDia     = rd ? (parseFloat(rd.totalDia)     || 0) : 0;
    totalPago += totalDia;
    filas.push([
      idPago, f, String(params.idPersonal), nombreFull, rol, appO,
      montoBase, pagoEnvasado, bonoMeta, sancion, totalDia,
      '',                  // ticketJobId (se llena después si imprime)
      pagadoPor, pagadoTs, 'PAGADA',
      comentario, ''       // idGastoGenerado (se llena después)
    ]);
  }

  // Insertar todas las filas de golpe
  if (filas.length > 0) {
    sh.getRange(sh.getLastRow() + 1, 1, filas.length, _LIQ_HDRS.length).setValues(filas);
  }
  totalPago = Math.round(totalPago * 100) / 100;

  // Registrar como GASTO categoría JORNALES (1 gasto por idPago)
  var idGasto = '';
  try {
    if (typeof crearGasto === 'function') {
      var gastoRes = crearGasto({
        fecha:       params.fechas[0] || _liqHoy(),
        descripcion: 'Liquidación ' + idPago + ' · ' + nombreFull + ' · ' + filas.length + ' día(s)',
        monto:       totalPago,
        categoria:   'JORNALES',
        tipo:        'FIJO',
        proveedor:   nombreFull,
        observacion: 'Pago de jornales ' + idPago,
        creadoPor:   pagadoPor
      });
      if (gastoRes && gastoRes.ok && gastoRes.data) idGasto = gastoRes.data.idGasto || '';
    }
  } catch(_){}

  // Backfill idGastoGenerado en todas las filas del batch
  if (idGasto) {
    try {
      var data = sh.getDataRange().getValues();
      var hdrs = data[0];
      var iIdPago = hdrs.indexOf('idPago');
      var iIdGas  = hdrs.indexOf('idGastoGenerado');
      for (var r = data.length - 1; r >= 1; r--) {
        if (String(data[r][iIdPago]) === idPago) {
          sh.getRange(r + 1, iIdGas + 1).setValue(idGasto);
        }
      }
    } catch(_){}
  }

  // Imprimir ticket si se pidió
  var jobId = null;
  if (params.imprimir && params.printerId) {
    try {
      var imp = imprimirTicketPago({ idPago: idPago, printerId: params.printerId });
      if (imp && imp.ok && imp.data) jobId = imp.data.printJobId;
    } catch(eP) { Logger.log('Print fallo: ' + eP.message); }
  }

  // ⚡ Materialización: marcar los días como PAGADA en LIQUIDACIONES_DIA
  try { _liqDiaMarcarPagadas(String(params.idPersonal), params.fechas, idPago); } catch(_){}

  return { ok: true, data: { idPago: idPago, total: totalPago, jobId: jobId, dias: filas.length } };
}

// Anular pago: estado=ANULADA → los días vuelven a Pendientes.
// Requiere clave admin de 8 dig.
function anularPago(params) {
  params = params || {};
  if (!params.idPago) return { ok: false, error: 'Requiere idPago' };
  if (!params.claveAdmin) return { ok: false, error: 'Requiere claveAdmin' };

  var auth = verificarClaveAdmin({
    clave: params.claveAdmin,
    accion: 'ANULAR_PAGO',
    refDocumento: params.idPago,
    detalle: 'Anular pago de liquidación'
  });
  if (!auth.ok) return auth;
  if (!auth.data || !auth.data.autorizado) {
    return { ok: true, data: { autorizado: false, error: auth.data?.error || 'Clave incorrecta' } };
  }

  var sh = _liqGetSheet();
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var iIdPago = hdrs.indexOf('idPago');
  var iEstado = hdrs.indexOf('estado');
  var iComent = hdrs.indexOf('comentario');
  var anuladas = 0;
  var nombrePago = '';
  var idGastoLiq = '';
  for (var r = 1; r < data.length; r++) {
    if (String(data[r][iIdPago]) !== String(params.idPago)) continue;
    if (String(data[r][iEstado]).toUpperCase() === 'ANULADA') continue;
    sh.getRange(r + 1, iEstado + 1).setValue('ANULADA');
    var prevC = String(data[r][iComent] || '');
    sh.getRange(r + 1, iComent + 1).setValue(
      prevC + (prevC ? ' · ' : '') + '↺ ANULADO por ' + (auth.data.validadoPor || 'admin') + ' (' + _liqHoy() + ')'
    );
    if (!nombrePago) nombrePago = data[r][hdrs.indexOf('nombre')] || '';
    var idG = data[r][hdrs.indexOf('idGastoGenerado')];
    if (idG && !idGastoLiq) idGastoLiq = String(idG);
    anuladas++;
  }
  if (!anuladas) return { ok: false, error: 'idPago no encontrado o ya anulado' };

  // Anular gasto vinculado si existe
  if (idGastoLiq) {
    try {
      if (typeof anularGasto === 'function') {
        anularGasto({ idGasto: idGastoLiq, motivo: 'Pago ' + params.idPago + ' anulado' });
      } else {
        // Fallback: setear estado=ANULADO en GASTOS
        var shG = getSheet('GASTOS');
        var dG = shG.getDataRange().getValues();
        var hG = dG[0];
        var iIdG = hG.indexOf('idGasto');
        var iEstG = hG.indexOf('estado');
        for (var rg = 1; rg < dG.length; rg++) {
          if (String(dG[rg][iIdG]) === idGastoLiq && iEstG >= 0) {
            shG.getRange(rg + 1, iEstG + 1).setValue('ANULADO');
            break;
          }
        }
      }
    } catch(_){}
  }

  // ⚡ Materialización: revertir los días a PENDIENTE en LIQUIDACIONES_DIA
  try { _liqDiaRevertirPagadas(params.idPago); } catch(_){}

  return { ok: true, data: { autorizado: true, anuladas: anuladas, nombre: nombrePago, anuladoPor: auth.data.validadoPor } };
}

// Pagos del rango (los que el user ve en pestaña "Pagadas")
// Agrupa por idPago para mostrarlos como batches.
function getLiquidacionesPagadas(params) {
  params = params || {};
  var hasta = params.hasta || _liqHoy();
  var desde = params.desde || _fechaOffset(hasta, -29);
  var tz = Session.getScriptTimeZone();
  var sh = _liqGetSheet();
  var rows = _sheetToObjects(sh);
  var batches = {};
  rows.forEach(function(r) {
    if (String(r.estado || '').toUpperCase() === 'ANULADA') return; // ocultar anuladas por default (param.incluirAnuladas)
    var fechaPago = r.pagadoTs instanceof Date
      ? Utilities.formatDate(r.pagadoTs, tz, 'yyyy-MM-dd')
      : String(r.pagadoTs || '').substring(0, 10);
    if (fechaPago < desde || fechaPago > hasta) return;
    var idPago = String(r.idPago || '');
    if (!idPago) return;
    if (!batches[idPago]) {
      batches[idPago] = {
        idPago:    idPago,
        pagadoTs:  String(r.pagadoTs || ''),
        pagadoPor: String(r.pagadoPor || ''),
        idPersonal: String(r.idPersonal || ''),
        nombre:    String(r.nombre || ''),
        rol:       String(r.rol || ''),
        dias:      [],
        total:     0,
        ticketJobId: String(r.ticketJobId || ''),
        idGastoGenerado: String(r.idGastoGenerado || ''),
        comentario: String(r.comentario || '')
      };
    }
    var f = r.fecha instanceof Date
      ? Utilities.formatDate(r.fecha, tz, 'yyyy-MM-dd')
      : String(r.fecha || '').substring(0,10);
    batches[idPago].dias.push({
      fecha: f,
      montoBase:    parseFloat(r.montoBase)    || 0,
      pagoEnvasado: parseFloat(r.pagoEnvasado) || 0,
      bonoMeta:     parseFloat(r.bonoMeta)     || 0,
      sancion:      parseFloat(r.sancion)      || 0,
      totalDia:     parseFloat(r.totalDia)     || 0
    });
    batches[idPago].total += parseFloat(r.totalDia) || 0;
  });
  var arr = Object.keys(batches).map(function(k){
    batches[k].total = Math.round(batches[k].total * 100) / 100;
    batches[k].cantidadDias = batches[k].dias.length;
    return batches[k];
  });
  arr.sort(function(a,b){ return String(b.pagadoTs).localeCompare(String(a.pagadoTs)); });
  return { ok: true, data: arr, rango: { desde: desde, hasta: hasta } };
}

// Detalle de un batch (todos los días + montos)
function getPagoDetalle(params) {
  if (!params || !params.idPago) return { ok: false, error: 'Requiere idPago' };
  var sh = _liqGetSheet();
  var rows = _sheetToObjects(sh).filter(function(r){ return String(r.idPago) === String(params.idPago); });
  if (!rows.length) return { ok: false, error: 'idPago no encontrado' };
  var tz = Session.getScriptTimeZone();
  var dias = rows.map(function(r){
    var f = r.fecha instanceof Date
      ? Utilities.formatDate(r.fecha, tz, 'yyyy-MM-dd')
      : String(r.fecha || '').substring(0,10);
    return {
      fecha: f,
      montoBase:    parseFloat(r.montoBase)    || 0,
      pagoEnvasado: parseFloat(r.pagoEnvasado) || 0,
      bonoMeta:     parseFloat(r.bonoMeta)     || 0,
      sancion:      parseFloat(r.sancion)      || 0,
      totalDia:     parseFloat(r.totalDia)     || 0
    };
  });
  var total = dias.reduce(function(s,d){ return s + d.totalDia; }, 0);
  return {
    ok: true,
    data: {
      idPago:    String(rows[0].idPago),
      idPersonal: String(rows[0].idPersonal),
      nombre:    String(rows[0].nombre),
      rol:       String(rows[0].rol),
      pagadoPor: String(rows[0].pagadoPor),
      pagadoTs:  String(rows[0].pagadoTs),
      estado:    String(rows[0].estado),
      ticketJobId: String(rows[0].ticketJobId || ''),
      idGastoGenerado: String(rows[0].idGastoGenerado || ''),
      comentario: String(rows[0].comentario || ''),
      dias: dias,
      total: Math.round(total * 100) / 100,
      cantidadDias: dias.length
    }
  };
}

// ============================================================
// IMPRESIÓN — Ticket 80mm del batch (mismo motor que liquidación)
// ============================================================
function imprimirTicketPago(params) {
  if (!params || !params.idPago) return { ok: false, error: 'Requiere idPago' };
  if (!params.printerId)         return { ok: false, error: 'Requiere printerId' };

  var det = getPagoDetalle({ idPago: params.idPago });
  if (!det || !det.ok) return det;
  var d = det.data;

  // Helpers ESC/POS 80mm (W=48)
  var W = 48;
  function _rep(ch, n)  { var s=''; for (var i=0;i<n;i++) s+=ch; return s; }
  function _pEnd(s, w)  { s=String(s||'').substring(0,w); while(s.length<w) s+=' '; return s; }
  function _pSt(s, w)   { s=String(s||''); while(s.length<w) s=' '+s; return s; }
  function _amtP(n, w)  { return _pSt('S/'+(parseFloat(n)||0).toFixed(2), w); }
  function _amtN(n, w)  { var v=parseFloat(n)||0; return _pSt((v<0?'-':' ')+'S/'+Math.abs(v).toFixed(2), w); }
  function _norm(s)     { return String(s||'').normalize('NFD').replace(/[̀-ͯ]/g,'').replace(/[^\x20-\x7E]/g,'?'); }
  function _sHdr(t)     { var s=' '+t+' '; var l=Math.floor((W-s.length)/2); return _rep('=',Math.max(0,l))+s+_rep('=',Math.max(0,W-s.length-l))+'\n'; }

  var SEP  = _rep('=', W) + '\n';
  var SEPd = _rep('-', W) + '\n';

  var txt = '';
  txt += '\x1b\x40\x1b\x61\x01\x1b\x21\x30';
  txt += _norm('LIQUIDACION DE PAGO') + '\n';
  txt += '\x1b\x21\x00' + _norm('ProyectoMOS') + '\n';
  txt += '\x1b\x61\x00' + SEP;
  txt += _pEnd('ID PAGO',  12) + ': ' + d.idPago + '\n';
  txt += _pEnd('FECHA',    12) + ': ' + Utilities.formatDate(new Date(d.pagadoTs || new Date()), Session.getScriptTimeZone(), 'dd/MM/yyyy HH:mm') + '\n';
  txt += _pEnd('PAGO',     12) + ': ' + _norm(d.pagadoPor) + '\n';
  txt += SEPd;
  txt += _pEnd('PERSONAL', 12) + ': ' + _norm(d.nombre) + '\n';
  txt += _pEnd('ROL',      12) + ': ' + _norm(d.rol) + '\n';
  txt += SEP;

  // Detalle por día
  txt += _sHdr('DIAS LIQUIDADOS');
  d.dias.forEach(function(dia) {
    var f = dia.fecha;
    var d1 = new Date(f + 'T12:00:00');
    var dStr = Utilities.formatDate(d1, Session.getScriptTimeZone(), 'EEE dd MMM');
    txt += _pEnd(_norm(dStr), W-12) + _amtP(dia.totalDia, 12) + '\n';
    var sub = [];
    if (dia.montoBase    > 0) sub.push('base '   + dia.montoBase.toFixed(2));
    if (dia.pagoEnvasado > 0) sub.push('env '    + dia.pagoEnvasado.toFixed(2));
    if (dia.bonoMeta     > 0) sub.push('+meta '  + dia.bonoMeta.toFixed(2));
    if (dia.sancion      > 0) sub.push('-san '   + dia.sancion.toFixed(2));
    if (sub.length) txt += '  ' + _norm(sub.join('  ')) + '\n';
  });
  txt += SEPd;

  // Total
  txt += '\x1b\x21\x30';
  txt += _pEnd('TOTAL', W/2-6) + _amtP(d.total, W/2-4) + '\n';
  txt += '\x1b\x21\x00';
  txt += SEPd;

  if (d.comentario) {
    txt += _sHdr('COMENTARIO');
    var c = _norm(d.comentario);
    while (c.length > W) { txt += c.substring(0, W) + '\n'; c = c.substring(W); }
    if (c) txt += c + '\n';
    txt += SEPd;
  }

  // Firmas
  txt += '\n' + _pEnd('Firma personal', 20) + ' ' + _rep('_', W-22) + '\n\n';
  txt += _pEnd('V.B. admin/master', 20) + ' ' + _rep('_', W-22) + '\n\n';
  txt += '\x1b\x61\x01\x1b\x45\x01*** FIN ***\x1b\x45\x00\n';
  txt += _norm('Impreso desde ProyectoMOS') + '\n';
  txt += Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'dd/MM/yyyy HH:mm:ss') + '\n';
  txt += '\n\n\n\n\n\x1d\x56\x00';

  // PrintNode
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
        title:       'Liquidacion ' + d.idPago + ' ' + d.nombre,
        contentType: 'raw_base64',
        content:     content,
        source:      'ProyectoMOS · Pago'
      }),
      muteHttpExceptions: true
    });
    var code = pj.getResponseCode();
    if (code !== 201) return { ok: false, error: 'PrintNode HTTP ' + code + ': ' + pj.getContentText().substring(0, 200) };

    // Backfill ticketJobId en todas las filas del batch
    try {
      var jobId = String(pj.getContentText());
      var sh = _liqGetSheet();
      var data = sh.getDataRange().getValues();
      var hdrs = data[0];
      var iIdPago = hdrs.indexOf('idPago');
      var iJob   = hdrs.indexOf('ticketJobId');
      for (var rr = 1; rr < data.length; rr++) {
        if (String(data[rr][iIdPago]) === d.idPago) {
          sh.getRange(rr + 1, iJob + 1).setValue(jobId);
        }
      }
    } catch(_){}
    return { ok: true, data: { printJobId: pj.getContentText() } };
  } catch(e) {
    return { ok: false, error: 'PrintNode fetch fallo: ' + e.message };
  }
}

// ============================================================
// MIGRACIÓN ONE-SHOT — corre 1 vez para mover legacy → nuevo
// ============================================================
//
// 1. Renombra hoja LIQUIDACIONES → LIQUIDACIONES_LEGACY
// 2. Crea LIQUIDACIONES_PAGOS
// 3. Por cada fila legacy con estado=PAGADA:
//    - parsea diasJSON
//    - inserta 1 fila por día con monto proporcional al totalDia
//
// Idempotente: si ya migrado, sale rápido.
function migrarLiquidacionesV2() {
  var ss = getSpreadsheet();
  var nueva = ss.getSheetByName(_LIQ_SHEET);
  if (nueva && nueva.getLastRow() > 1) {
    return { ok: true, data: { msg: 'Ya migrado (hoja ' + _LIQ_SHEET + ' tiene ' + (nueva.getLastRow()-1) + ' filas)' } };
  }
  // Asegurar hoja nueva
  _liqGetSheet();

  var vieja = ss.getSheetByName('LIQUIDACIONES');
  if (!vieja) {
    return { ok: true, data: { msg: 'No hay LIQUIDACIONES legacy. Migración omitida.', migradas: 0 } };
  }

  // Leer legacy ANTES de renombrar
  var rows = _sheetToObjects(vieja);
  var insertadas = 0;
  var batchByLegacyId = {};

  rows.forEach(function(r) {
    if (String(r.estado || '').toUpperCase() !== 'PAGADA') return;
    var idPersonal = String(r.idPersonal || '');
    var nombre     = String(r.nombrePersonal || '');
    var rol        = String(r.rol || '').toUpperCase();
    var app        = String(r.appOrigen || '');
    var pagadoPor  = String(r.pagadoPor || 'migrado');
    var pagadoTs   = r.fechaPago instanceof Date
      ? Utilities.formatDate(r.fechaPago, 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'")
      : String(r.fechaPago || '');
    var idGasto    = String(r.idGastoGenerado || '');
    var idPagoNew  = 'LIQ-LEGACY-' + (r.idLiquidacion || ('' + new Date().getTime()));
    var dias = [];
    try {
      dias = typeof r.diasJSON === 'string' ? JSON.parse(r.diasJSON || '[]') : (r.diasJSON || []);
    } catch(_){}
    if (!Array.isArray(dias)) dias = [];

    var sh = _liqGetSheet();
    dias.forEach(function(d) {
      if (!d || !d.fecha) return;
      var totalDia = parseFloat(d.totalDia) || 0;
      sh.appendRow([
        idPagoNew, d.fecha, idPersonal, nombre, rol, app,
        parseFloat(d.base)  || 0,
        0,                          // pagoEnvasado: no existía
        parseFloat(d.meta)  || 0,
        0,                          // sanción: no existía
        totalDia,
        '',
        pagadoPor, pagadoTs, 'PAGADA',
        'Migrado desde LIQUIDACIONES legacy',
        idGasto
      ]);
      insertadas++;
    });
  });

  // Renombrar la vieja a _LEGACY
  try {
    vieja.setName('LIQUIDACIONES_LEGACY');
  } catch(_) { /* puede que ya exista */ }

  return { ok: true, data: { migradas: insertadas, msg: 'Migrados ' + insertadas + ' días desde legacy.' } };
}

// ============================================================
// ── MATERIALIZED VIEW: LIQUIDACIONES_DIA ─────────────────────
// 1 fila por (idPersonal × fecha) con su totalDia ya calculado y
// su estado (PENDIENTE/PAGADA/ANULADA). Leer Pendientes = SELECT
// directo, sin recomputar.
// ============================================================

var _LDIA_SHEET = 'LIQUIDACIONES_DIA';
var _LDIA_HDRS  = [
  'idDia', 'fecha', 'idPersonal', 'nombre', 'rol', 'appOrigen', 'virtual',
  'montoBase', 'pagoEnvasado', 'bonoMeta', 'sancion', 'totalDia',
  'auditado', 'evaluacionesCount', 'scoreFinal', 'tarifaEnvasado', 'presente',
  'estado', 'idPago', 'ts_creado', 'ts_actualizado'
];

function _liqDiaGetSheet() {
  var ss = getSpreadsheet();
  var sh = ss.getSheetByName(_LDIA_SHEET);
  if (sh) return sh;
  sh = ss.insertSheet(_LDIA_SHEET);
  sh.getRange(1, 1, 1, _LDIA_HDRS.length).setValues([_LDIA_HDRS]);
  sh.getRange(1, 1, 1, _LDIA_HDRS.length)
    .setBackground('#7c3aed').setFontColor('#fff').setFontWeight('bold').setFontSize(10);
  sh.setFrozenRows(1);
  // Texto en columnas críticas
  try {
    sh.getRange(2, 1, 5000, 1).setNumberFormat('@'); // idDia
    sh.getRange(2, 3, 5000, 1).setNumberFormat('@'); // idPersonal
  } catch(_){}
  return sh;
}

function _liqDiaKey(idPersonal, fecha) {
  var fechaCompacta = String(fecha).replace(/-/g, '');
  var idClean = String(idPersonal).replace(/[^a-zA-Z0-9:]/g, '_');
  return 'LDIA-' + fechaCompacta + '-' + idClean;
}

function _liqDiaIsBlocked(rol) {
  var r = String(rol || '').toUpperCase();
  return r === 'MASTER' || r === 'ADMIN' || r === 'ADMINISTRADOR';
}

// Upsert una fila desde un resumen ya computado (de getResumenDia.data)
function _liqDiaUpsertRow(rd, fecha) {
  if (!rd) return null;
  if (!rd.presente) return null;
  if (_liqDiaIsBlocked(rd.rol)) return null;

  var sh = _liqDiaGetSheet();
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var iIdDia = hdrs.indexOf('idDia');
  var iEstado = hdrs.indexOf('estado');
  var iIdPago = hdrs.indexOf('idPago');
  var iTsCreado = hdrs.indexOf('ts_creado');

  var idDia = _liqDiaKey(rd.idPersonal, fecha);
  var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
  var idPersonalStr = String(rd.idPersonal);
  var isVirtual = idPersonalStr.indexOf('MEX:') === 0;

  // Buscar existing row
  var existingIdx = -1;
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iIdDia]) === idDia) { existingIdx = i; break; }
  }

  // Preserve estado/idPago si la fila ya está PAGADA o ANULADA
  var estadoExist = 'PENDIENTE', idPagoExist = '', tsCreadoExist = nowStr;
  if (existingIdx >= 0) {
    estadoExist = String(data[existingIdx][iEstado] || 'PENDIENTE').toUpperCase();
    idPagoExist = String(data[existingIdx][iIdPago] || '');
    tsCreadoExist = data[existingIdx][iTsCreado] || nowStr;
  }
  // Si está PAGADA conservamos esos valores; si está PENDIENTE/ANULADA tampoco
  // recalculamos estado, solo actualizamos los montos.
  var newRow = {
    idDia:             idDia,
    fecha:             fecha,
    idPersonal:        idPersonalStr,
    nombre:            String(rd.nombre || ''),
    rol:               String(rd.rol || '').toUpperCase(),
    appOrigen:         String(rd.appOrigen || ''),
    virtual:           isVirtual,
    montoBase:         parseFloat(rd.montoBase) || 0,
    pagoEnvasado:      parseFloat(rd.pagoEnvasado) || 0,
    bonoMeta:          parseFloat(rd.bonoMeta) || 0,
    sancion:           parseFloat(rd.sancion) || 0,
    totalDia:          parseFloat(rd.totalDia) || 0,
    auditado:          !!rd.auditado,
    evaluacionesCount: parseInt(rd.evaluacionesCount) || 0,
    scoreFinal:        parseFloat(rd.scoreFinal) || 0,
    tarifaEnvasado:    parseFloat(rd.tarifaEnvasado) || 0,
    presente:          !!rd.presente,
    estado:            estadoExist,
    idPago:            idPagoExist,
    ts_creado:         tsCreadoExist,
    ts_actualizado:    nowStr
  };
  var rowArr = hdrs.map(function(h){ return newRow[h] !== undefined ? newRow[h] : ''; });
  if (existingIdx >= 0) {
    sh.getRange(existingIdx + 1, 1, 1, hdrs.length).setValues([rowArr]);
  } else {
    sh.appendRow(rowArr);
  }
  return idDia;
}

// Recompute UNA fila (idPersonal × fecha) — llamado tras crear audit
function _liqDiaRecomputar(idPersonal, fecha) {
  try {
    var rs = getResumenDia({ idPersonal: idPersonal, fecha: fecha });
    if (!rs || !rs.ok) return false;
    _liqDiaUpsertRow(rs.data, fecha);
    return true;
  } catch(e) { Logger.log('_liqDiaRecomputar fallo: ' + e.message); return false; }
}

// Sync TODOS los presentes de una fecha (heavy — llama getResumenTodosDia)
function _liqDiaSync(fecha) {
  try {
    var rsm = getResumenTodosDia({ fecha: fecha });
    if (!rsm || !rsm.ok || !Array.isArray(rsm.data)) return { sincronizadas: 0 };
    var n = 0;
    rsm.data.forEach(function(r) {
      if (!r || !r.presente) return;
      if (_liqDiaIsBlocked(r.rol)) return;
      _liqDiaUpsertRow(r, fecha);
      n++;
    });
    return { sincronizadas: n };
  } catch(e) { Logger.log('_liqDiaSync(' + fecha + '): ' + e.message); return { sincronizadas: 0, error: e.message }; }
}

// ── Endpoint: leer Pendientes desde la sheet (instantáneo) ──
function getLiquidacionesPendientesDia(params) {
  params = params || {};
  var hasta = params.hasta || _liqHoy();
  var desde = params.desde || _fechaOffset(hasta, -29);

  // Auto-refresh de HOY (1 día) — captura eventos del día actual.
  // [v2.41.31] TTL subido 60s → 300s para evitar timeouts en la UI cuando
  // el sync se ejecuta justo durante el primer load (resync de getResumenTodosDia
  // tarda ~3-8s y bloqueaba el endpoint).
  try {
    var ssCache = CacheService.getScriptCache();
    var last = ssCache.get('ldia_hoy_sync');
    if (!last) {
      // Marcar cache ANTES de syncear para que requests paralelos no
      // dispararan otro sync. Best-effort: si el sync falla, igual cacheamos
      // (la próxima request rehidrata).
      ssCache.put('ldia_hoy_sync', '' + Date.now(), 300);
      try { _liqDiaSync(_liqHoy()); } catch(__){}
    }
    // [v2.41.33] AUTO-RESYNC últimos 3 días cada hora — cubre cambios en WH
    // (envasados nuevos/anulados, ajustes) sin requerir bridge ni acción manual.
    var last3d = ssCache.get('ldia_3d_sync');
    if (!last3d) {
      ssCache.put('ldia_3d_sync', '' + Date.now(), 3600);
      try {
        var hoyStr = _liqHoy();
        for (var dk = 1; dk <= 3; dk++) {
          var fDk = _fechaOffset(hoyStr, -dk);
          try { _liqDiaSync(fDk); } catch(__){}
        }
      } catch(__){}
    }
  } catch(_) {}

  var sh = _liqDiaGetSheet();
  var rows = _sheetToObjects(sh);
  var tz = Session.getScriptTimeZone();

  // Filtrar por rango + estado=PENDIENTE
  var pendientes = rows.filter(function(r) {
    if (String(r.estado || '').toUpperCase() !== 'PENDIENTE') return false;
    var f = r.fecha instanceof Date
      ? Utilities.formatDate(r.fecha, tz, 'yyyy-MM-dd')
      : String(r.fecha || '').substring(0, 10);
    return f >= desde && f <= hasta;
  });

  // Agrupar por idPersonal
  var acum = {};
  pendientes.forEach(function(r) {
    var idP = String(r.idPersonal);
    if (!acum[idP]) {
      var virtBool = (typeof r.virtual === 'boolean') ? r.virtual
                   : (String(r.virtual).toLowerCase() === 'true')
                   || (idP.indexOf('MEX:') === 0);
      acum[idP] = {
        idPersonal: idP,
        nombre:     String(r.nombre || ''),
        rol:        String(r.rol || '').toUpperCase(),
        appOrigen:  String(r.appOrigen || ''),
        virtual:    virtBool,
        dias:       []
      };
    }
    var f = r.fecha instanceof Date
      ? Utilities.formatDate(r.fecha, tz, 'yyyy-MM-dd')
      : String(r.fecha || '').substring(0, 10);
    acum[idP].dias.push({
      fecha:             f,
      presente:          true,
      auditado:          (r.auditado === true) || (String(r.auditado).toLowerCase() === 'true'),
      montoBase:         parseFloat(r.montoBase) || 0,
      pagoEnvasado:      parseFloat(r.pagoEnvasado) || 0,
      bonoMeta:          parseFloat(r.bonoMeta) || 0,
      sancion:           parseFloat(r.sancion) || 0,
      totalDia:          parseFloat(r.totalDia) || 0,
      scoreFinal:        parseFloat(r.scoreFinal) || 0,
      evaluacionesCount: parseInt(r.evaluacionesCount) || 0,
      tarifaEnvasado:    parseFloat(r.tarifaEnvasado) || 0
    });
  });

  var out = Object.keys(acum).map(function(k) {
    var p = acum[k];
    p.dias.sort(function(a,b){ return String(a.fecha).localeCompare(String(b.fecha)); });
    var total = p.dias.reduce(function(s,d){ return s + d.totalDia; }, 0);
    p.total = Math.round(total * 100) / 100;
    p.cantidadDias = p.dias.length;
    return p;
  }).filter(function(p){ return p.cantidadDias > 0; });

  out.sort(function(a,b){
    if (b.total !== a.total) return b.total - a.total;
    return String(a.nombre).localeCompare(String(b.nombre));
  });

  return { ok: true, data: out, rango: { desde: desde, hasta: hasta }, fast: true };
}

// [v2.41.31] VETAR / DESVETAR — alternativa rápida a marcar como pagado.
// El operador toca el botón 🚫 inline y la liquidación del día queda VETADA
// (no aparece más en Pendientes). Puede desvetar después si fue por error.
// VETADA NO se cobra ni computa para liquidaciones; es como un "skip".
function vetarLiquidacionDia(params) {
  var idPersonal = String(params.idPersonal || '').trim();
  var fecha      = String(params.fecha || '').trim();
  if (!idPersonal || !fecha) return { ok: false, error: 'idPersonal y fecha requeridos' };
  var sh = _liqDiaGetSheet();
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var iIdPersonal = hdrs.indexOf('idPersonal');
  var iFecha      = hdrs.indexOf('fecha');
  var iEstado     = hdrs.indexOf('estado');
  var iTsAct      = hdrs.indexOf('ts_actualizado');
  if (iIdPersonal < 0 || iFecha < 0 || iEstado < 0) {
    return { ok: false, error: 'Hoja sin columnas requeridas' };
  }
  var tz = Session.getScriptTimeZone();
  for (var i = 1; i < data.length; i++) {
    var idP = String(data[i][iIdPersonal] || '');
    var f   = data[i][iFecha] instanceof Date
              ? Utilities.formatDate(data[i][iFecha], tz, 'yyyy-MM-dd')
              : String(data[i][iFecha] || '').substring(0, 10);
    if (idP === idPersonal && f === fecha) {
      var est = String(data[i][iEstado] || '').toUpperCase();
      if (est === 'PAGADA') return { ok: false, error: 'YA_PAGADA' };
      sh.getRange(i + 1, iEstado + 1).setValue('VETADA');
      if (iTsAct >= 0) {
        sh.getRange(i + 1, iTsAct + 1).setValue(
          Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'")
        );
      }
      return { ok: true };
    }
  }
  return { ok: false, error: 'NO_ENCONTRADA' };
}

function desvetarLiquidacionDia(params) {
  var idPersonal = String(params.idPersonal || '').trim();
  var fecha      = String(params.fecha || '').trim();
  if (!idPersonal || !fecha) return { ok: false, error: 'idPersonal y fecha requeridos' };
  var sh = _liqDiaGetSheet();
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var iIdPersonal = hdrs.indexOf('idPersonal');
  var iFecha      = hdrs.indexOf('fecha');
  var iEstado     = hdrs.indexOf('estado');
  var iTsAct      = hdrs.indexOf('ts_actualizado');
  if (iIdPersonal < 0 || iFecha < 0 || iEstado < 0) {
    return { ok: false, error: 'Hoja sin columnas requeridas' };
  }
  var tz = Session.getScriptTimeZone();
  for (var i = 1; i < data.length; i++) {
    var idP = String(data[i][iIdPersonal] || '');
    var f   = data[i][iFecha] instanceof Date
              ? Utilities.formatDate(data[i][iFecha], tz, 'yyyy-MM-dd')
              : String(data[i][iFecha] || '').substring(0, 10);
    if (idP === idPersonal && f === fecha) {
      var est = String(data[i][iEstado] || '').toUpperCase();
      if (est !== 'VETADA') return { ok: false, error: 'NO_VETADA', mensaje: 'Estado actual: ' + est };
      sh.getRange(i + 1, iEstado + 1).setValue('PENDIENTE');
      if (iTsAct >= 0) {
        sh.getRange(i + 1, iTsAct + 1).setValue(
          Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'")
        );
      }
      return { ok: true };
    }
  }
  return { ok: false, error: 'NO_ENCONTRADA' };
}

// [v2.41.32] Endpoint público: recomputa UNA fila (idPersonal × fecha)
// y devuelve los valores actualizados. Usado por el botón "lápiz" de
// liquidaciones para garantizar que pendientes esté en sync con el
// resumen vivo (getResumenTodosDia).
function recomputarLiquidacionDia(params) {
  var idPersonal = String(params.idPersonal || '').trim();
  var fecha      = String(params.fecha || '').trim();
  if (!idPersonal || !fecha) return { ok: false, error: 'idPersonal y fecha requeridos' };
  try {
    var rs = getResumenDia({ idPersonal: idPersonal, fecha: fecha });
    if (!rs || !rs.ok) return { ok: false, error: 'getResumenDia falló' };
    _liqDiaUpsertRow(rs.data, fecha);
    // Devolver la fila actualizada
    var sh = _liqDiaGetSheet();
    var data = sh.getDataRange().getValues();
    var hdrs = data[0];
    var idDia = _liqDiaKey(idPersonal, fecha);
    var iIdDia = hdrs.indexOf('idDia');
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][iIdDia]) === idDia) {
        var fila = {};
        hdrs.forEach(function(h, k) { fila[h] = data[i][k]; });
        return { ok: true, data: fila };
      }
    }
    return { ok: true, data: rs.data };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

function getLiquidacionesVetadas(params) {
  params = params || {};
  var hasta = params.hasta || _liqHoy();
  var desde = params.desde || _fechaOffset(hasta, -29);
  var sh = _liqDiaGetSheet();
  var rows = _sheetToObjects(sh);
  var tz = Session.getScriptTimeZone();
  var vetadas = rows.filter(function(r) {
    if (String(r.estado || '').toUpperCase() !== 'VETADA') return false;
    var f = r.fecha instanceof Date
            ? Utilities.formatDate(r.fecha, tz, 'yyyy-MM-dd')
            : String(r.fecha || '').substring(0, 10);
    return f >= desde && f <= hasta;
  }).map(function(r) {
    var f = r.fecha instanceof Date
            ? Utilities.formatDate(r.fecha, tz, 'yyyy-MM-dd')
            : String(r.fecha || '').substring(0, 10);
    return {
      idPersonal: String(r.idPersonal || ''),
      nombre:     String(r.nombre || ''),
      rol:        String(r.rol || '').toUpperCase(),
      appOrigen:  String(r.appOrigen || ''),
      fecha:      f,
      montoBase:  parseFloat(r.montoBase) || 0,
      pagoEnvasado: parseFloat(r.pagoEnvasado) || 0,
      totalDia:   parseFloat(r.totalDia) || 0,
      ts_actualizado: String(r.ts_actualizado || '')
    };
  });
  // Más recientes (por fecha desc, luego nombre)
  vetadas.sort(function(a, b) {
    if (a.fecha !== b.fecha) return b.fecha.localeCompare(a.fecha);
    return a.nombre.localeCompare(b.nombre);
  });
  return { ok: true, data: vetadas, rango: { desde: desde, hasta: hasta } };
}

// ── Migración / backfill: poblar últimos N días desde resúmenes ──
function backfillLiquidacionesDia(params) {
  params = params || {};
  var dias = parseInt(params.dias) || 30;
  var hoy = _liqHoy();
  _liqDiaGetSheet(); // crear hoja si no existe

  // Backfill
  var total = 0;
  for (var i = 0; i < dias; i++) {
    var f = _fechaOffset(hoy, -i);
    var r = _liqDiaSync(f);
    total += r.sincronizadas || 0;
  }

  // Cross-check con LIQUIDACIONES_PAGOS para marcar PAGADAS
  var marcadasPagadas = 0;
  try {
    var pagosSh = _liqGetSheet();
    var pagosData = _sheetToObjects(pagosSh);
    var pagosMap = {};  // 'idPersonal::fecha' → idPago
    var tzPag = Session.getScriptTimeZone();
    pagosData.forEach(function(p) {
      if (String(p.estado || '').toUpperCase() === 'ANULADA') return;
      var fp = p.fecha instanceof Date
        ? Utilities.formatDate(p.fecha, tzPag, 'yyyy-MM-dd')
        : String(p.fecha || '').substring(0, 10);
      pagosMap[String(p.idPersonal) + '::' + fp] = String(p.idPago);
    });

    var sh = _liqDiaGetSheet();
    var data = sh.getDataRange().getValues();
    var hdrs = data[0];
    var iIdP = hdrs.indexOf('idPersonal');
    var iF   = hdrs.indexOf('fecha');
    var iEst = hdrs.indexOf('estado');
    var iIdPago = hdrs.indexOf('idPago');
    var iTsAct = hdrs.indexOf('ts_actualizado');
    var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
    for (var rIdx = 1; rIdx < data.length; rIdx++) {
      var idP = String(data[rIdx][iIdP]);
      var ff  = data[rIdx][iF];
      var fStr = ff instanceof Date
        ? Utilities.formatDate(ff, tzPag, 'yyyy-MM-dd')
        : String(ff || '').substring(0, 10);
      var k = idP + '::' + fStr;
      if (pagosMap[k] && String(data[rIdx][iEst]).toUpperCase() !== 'PAGADA') {
        sh.getRange(rIdx + 1, iEst    + 1).setValue('PAGADA');
        sh.getRange(rIdx + 1, iIdPago + 1).setValue(pagosMap[k]);
        sh.getRange(rIdx + 1, iTsAct  + 1).setValue(nowStr);
        marcadasPagadas++;
      }
    }
  } catch(eP) { Logger.log('Cross-check pagos: ' + eP.message); }

  return { ok: true, data: { dias: dias, sincronizadas: total, marcadasPagadas: marcadasPagadas, msg: 'Backfill OK: ' + total + ' filas, ' + marcadasPagadas + ' marcadas PAGADAS' } };
}

// Update LIQUIDACIONES_DIA al pagar/anular (llamados desde marcarPagos/anularPago)
function _liqDiaMarcarPagadas(idPersonal, fechas, idPago) {
  try {
    var sh = _liqDiaGetSheet();
    var data = sh.getDataRange().getValues();
    var hdrs = data[0];
    var iIdDia  = hdrs.indexOf('idDia');
    var iEst    = hdrs.indexOf('estado');
    var iIdPago = hdrs.indexOf('idPago');
    var iTsAct  = hdrs.indexOf('ts_actualizado');
    var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
    fechas.forEach(function(f) {
      var idDia = _liqDiaKey(idPersonal, f);
      var found = false;
      for (var i = 1; i < data.length; i++) {
        if (String(data[i][iIdDia]) === idDia) {
          sh.getRange(i + 1, iEst    + 1).setValue('PAGADA');
          sh.getRange(i + 1, iIdPago + 1).setValue(idPago);
          sh.getRange(i + 1, iTsAct  + 1).setValue(nowStr);
          found = true;
          break;
        }
      }
      // Si la fila no existe, intentamos crearla con un sync rápido
      if (!found) {
        _liqDiaRecomputar(idPersonal, f);
        // Reintentamos marcar (el upsert puede no haber agregado si no había presencia)
        try {
          var sh2 = _liqDiaGetSheet();
          var data2 = sh2.getDataRange().getValues();
          for (var j = 1; j < data2.length; j++) {
            if (String(data2[j][iIdDia]) === idDia) {
              sh2.getRange(j + 1, iEst    + 1).setValue('PAGADA');
              sh2.getRange(j + 1, iIdPago + 1).setValue(idPago);
              sh2.getRange(j + 1, iTsAct  + 1).setValue(nowStr);
              break;
            }
          }
        } catch(_){}
      }
    });
  } catch(e) { Logger.log('_liqDiaMarcarPagadas fallo: ' + e.message); }
}

function _liqDiaRevertirPagadas(idPago) {
  try {
    var sh = _liqDiaGetSheet();
    var data = sh.getDataRange().getValues();
    var hdrs = data[0];
    var iEst    = hdrs.indexOf('estado');
    var iIdPago = hdrs.indexOf('idPago');
    var iTsAct  = hdrs.indexOf('ts_actualizado');
    var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
    var revertidas = 0;
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][iIdPago]) === String(idPago)) {
        sh.getRange(i + 1, iEst    + 1).setValue('PENDIENTE');
        sh.getRange(i + 1, iIdPago + 1).setValue('');
        sh.getRange(i + 1, iTsAct  + 1).setValue(nowStr);
        revertidas++;
      }
    }
    return revertidas;
  } catch(e) { Logger.log('_liqDiaRevertirPagadas fallo: ' + e.message); return 0; }
}

// Trigger diario 23:30 — sweep del día completo (catch-all)
function _liqDiaCronDiario() {
  try { _liqDiaSync(_liqHoy()); }
  catch(e) { Logger.log('Cron LDIA fallo: ' + e.message); }
}
function configurarTriggerLiquidacionDia() {
  ScriptApp.getProjectTriggers().forEach(function(t){
    if (t.getHandlerFunction() === '_liqDiaCronDiario') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('_liqDiaCronDiario')
    .timeBased().everyDays(1).atHour(23).nearMinute(30).create();
  return { ok: true, msg: 'Trigger creado: _liqDiaCronDiario diario 23:30' };
}

// ============================================================
// STUBS — compat con frontend viejo (Liquidación semanal antigua).
// Quedan como NO-OP retornando datos vacíos para que nada explote
// mientras se completa la transición. El frontend nuevo usa la API v2.
// ============================================================
function getLiquidacionesPendientesSemana() { return { ok: true, data: [], deprecado: true }; }
function getDetalleDiasPendientes()         { return { ok: true, data: { dias: [] }, deprecado: true }; }
function emitirLiquidacion()                { return { ok: false, error: 'Endpoint deprecado. Usa marcarPagos.' }; }
function emitirLiquidacionesTodas()         { return { ok: false, error: 'Endpoint deprecado. Usa marcarPagos.' }; }
function marcarLiquidacionPagada()          { return { ok: false, error: 'Endpoint deprecado. Usa marcarPagos.' }; }
function anularLiquidacion(params)          { return anularPago(params); }
function getLiquidacionesEmitidas(params)   { return getLiquidacionesPagadas(params); }
function getLiquidacionDetalle(params)      { return getPagoDetalle(params); }
function anularJornadas()                   { return { ok: false, error: 'Endpoint deprecado.' }; }

// Helpers reusados
function _fechaOffset(fecha, dias) {
  var d = new Date(fecha + 'T12:00:00');
  d.setDate(d.getDate() + dias);
  return Utilities.formatDate(d, Session.getScriptTimeZone(), 'yyyy-MM-dd');
}
function _rangoFechas(desde, hasta) {
  var out = [];
  var d = new Date(desde + 'T12:00:00');
  var fin = new Date(hasta + 'T12:00:00');
  var tz = Session.getScriptTimeZone();
  while (d <= fin) {
    out.push(Utilities.formatDate(d, tz, 'yyyy-MM-dd'));
    d.setDate(d.getDate() + 1);
  }
  return out;
}
