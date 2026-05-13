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
function getLiquidacionesPendientes(params) {
  params = params || {};
  var hasta = params.hasta || _liqHoy();
  // Default: últimos 7 días. Cada llamada a getResumenTodosDia es costosa
  // (~3s); 7 días = ~21s en peor caso. Si el admin necesita ver más atrás
  // puede pedir desde explícito. Lo normal es liquidar al menos semanal.
  var desde = params.desde || _fechaOffset(hasta, -6);
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
