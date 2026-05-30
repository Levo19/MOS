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

  // [v2.41.71] Invalidar cache backend de getLiquidacionesPagadas
  try {
    var _cp = CacheService.getScriptCache();
    var _hoy = _liqHoy();
    [29, 30, 89, 90].forEach(function(d){
      _cp.remove('liqPag_' + _fechaOffset(_hoy, -d) + '_' + _hoy);
    });
  } catch(_){}

  // [v2.41.73-B17] Push a admin/master con resumen del pago
  try {
    if (typeof _enviarPushTodos === 'function') {
      var nombrePago = String(params.nombre || params.idPersonal || 'personal');
      _enviarPushTodos(
        '💵 Pago liquidación · S/ ' + (Math.round(totalPago * 100) / 100).toFixed(2),
        nombrePago + ' · ' + filas.length + ' día(s) · por ' + String(params.pagadoPor || 'admin'),
        { idNotif: 'MOS_ADMIN_AUTH', excluirUsuario: String(params.pagadoPor || '') }
      );
    }
  } catch(_){}

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

  // [v2.41.71] Invalidar cache backend de getLiquidacionesPagadas
  try {
    var _ca = CacheService.getScriptCache();
    var _hoyA = _liqHoy();
    [29, 30, 89, 90].forEach(function(d){
      _ca.remove('liqPag_' + _fechaOffset(_hoyA, -d) + '_' + _hoyA);
    });
  } catch(_){}

  return { ok: true, data: { autorizado: true, anuladas: anuladas, nombre: nombrePago, anuladoPor: auth.data.validadoPor } };
}

// Pagos del rango (los que el user ve en pestaña "Pagadas")
// Agrupa por idPago para mostrarlos como batches.
function getLiquidacionesPagadas(params) {
  params = params || {};
  var hasta = params.hasta || _liqHoy();
  var desde = params.desde || _fechaOffset(hasta, -29);

  // [v2.41.71] Cache backend 60s — la tabla LIQUIDACIONES_PAGOS rara vez cambia
  // (solo cuando admin paga o anula). Antes leía TODA la hoja en cada llamada.
  // Polling 30s del frontend hacía esto 2x por minuto.
  var ssCache, cacheKey;
  if (!params._refresh) {
    try {
      ssCache = CacheService.getScriptCache();
      cacheKey = 'liqPag_' + desde + '_' + hasta;
      var hit = ssCache.get(cacheKey);
      if (hit) { try { return JSON.parse(hit); } catch(_){} }
    } catch(_){}
  }

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
  var resp = { ok: true, data: arr, rango: { desde: desde, hasta: hasta } };
  if (ssCache && cacheKey) {
    try {
      var ser = JSON.stringify(resp);
      if (ser.length < 95000) ssCache.put(cacheKey, ser, 60);
    } catch(_){}
  }
  return resp;
}

// Detalle de un batch (todos los días + montos)
function getPagoDetalle(params) {
  if (!params || !params.idPago) return { ok: false, error: 'Requiere idPago' };
  var sh = _liqGetSheet();
  var rows = _sheetToObjects(sh).filter(function(r){ return String(r.idPago) === String(params.idPago); });
  if (!rows.length) return { ok: false, error: 'idPago no encontrado' };
  var tz = Session.getScriptTimeZone();

  // [v2.41.37] Cargar LIQUIDACIONES_DIA + EVALUACIONES para enriquecer
  // cada día del pago con contexto: auditado, score, unidades, motivo sanción.
  var ldiaMap = {};  // key: idPersonal|fecha → fila
  try {
    var ldiaSh = _liqDiaGetSheet();
    _sheetToObjects(ldiaSh).forEach(function(r) {
      var f = _liqNormFecha(r.fecha, tz);
      var k = String(r.idPersonal) + '|' + f;
      ldiaMap[k] = r;
    });
  } catch(_) {}
  var sancionMotivoMap = {};  // key: idPersonal|fecha → motivo (último con sanción)
  try {
    var evalSh = _getEvalSheet();
    _sheetToObjects(evalSh).forEach(function(r) {
      var s = parseFloat(r.sancion) || 0;
      if (s <= 0) return;
      var f = _liqNormFecha(r.fecha, tz);
      var k = String(r.idPersonal) + '|' + f;
      sancionMotivoMap[k] = String(r.sancionMotivo || r.motivoSancion || 'sin motivo registrado');
    });
  } catch(_) {}

  var idPers = String(rows[0].idPersonal);
  var dias = rows.map(function(r){
    var f = _liqNormFecha(r.fecha, tz);
    var k = idPers + '|' + f;
    var ld = ldiaMap[k] || {};
    var pagoEnv = parseFloat(r.pagoEnvasado) || 0;
    var tarifa  = parseFloat(ld.tarifaEnvasado) || 0;
    var uds     = (tarifa > 0) ? Math.round(pagoEnv / tarifa) : 0;
    return {
      fecha: f,
      montoBase:    parseFloat(r.montoBase)    || 0,
      pagoEnvasado: pagoEnv,
      bonoMeta:     parseFloat(r.bonoMeta)     || 0,
      sancion:      parseFloat(r.sancion)      || 0,
      totalDia:     parseFloat(r.totalDia)     || 0,
      // Enriquecidos
      auditado:          (ld.auditado === true) || (String(ld.auditado).toLowerCase() === 'true'),
      scoreFinal:        parseFloat(ld.scoreFinal) || 0,
      evaluacionesCount: parseInt(ld.evaluacionesCount) || 0,
      tarifaEnvasado:    tarifa,
      unidadesEnvasadas: uds,
      sancionMotivo:     sancionMotivoMap[k] || ''
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

  // Detalle por día — [v2.41.37] con contexto enriquecido por día
  txt += _sHdr('DIAS LIQUIDADOS (' + d.dias.length + ')');
  // Acumuladores para el resumen final
  var diasAuditados = 0, diasConSancion = 0, totalEnvasados = 0, totalBonoMeta = 0, tarifaUsada = 0;
  d.dias.forEach(function(dia) {
    var f = dia.fecha;
    var d1 = new Date(f + 'T12:00:00');
    var dStr = Utilities.formatDate(d1, Session.getScriptTimeZone(), 'EEE dd MMM');
    txt += _pEnd(_norm(dStr), W-12) + _amtP(dia.totalDia, 12) + '\n';
    // Subcomponentes monetarios
    var sub = [];
    if (dia.montoBase    > 0) sub.push('base '   + dia.montoBase.toFixed(2));
    if (dia.pagoEnvasado > 0) {
      var udsTxt = dia.unidadesEnvasadas > 0 ? ' (' + dia.unidadesEnvasadas + ' uds)' : '';
      sub.push('env ' + dia.pagoEnvasado.toFixed(2) + udsTxt);
    }
    if (dia.bonoMeta     > 0) sub.push('+meta '  + dia.bonoMeta.toFixed(2));
    if (dia.sancion      > 0) sub.push('-san '   + dia.sancion.toFixed(2));
    if (sub.length) txt += '  ' + _norm(sub.join(' · ')) + '\n';
    // Contexto: auditado / score
    if (dia.auditado) {
      var scoreTxt = dia.scoreFinal > 0 ? ' · score ' + dia.scoreFinal.toFixed(1) + '/5' : '';
      txt += '  [OK] auditado' + scoreTxt + '\n';
      diasAuditados++;
    } else {
      txt += '  [!] SIN AUDITAR\n';
    }
    // Sanción con motivo si lo hay
    if (dia.sancion > 0) {
      diasConSancion++;
      var mot = (dia.sancionMotivo || '').substring(0, W - 16);
      if (mot) {
        txt += '  [!] Sancion: ' + _norm(mot) + '\n';
      } else {
        txt += '  [!] Sancion -S/' + dia.sancion.toFixed(2) + '\n';
      }
    }
    txt += '\n';
    // Acumular
    totalEnvasados += dia.unidadesEnvasadas || 0;
    totalBonoMeta  += dia.bonoMeta || 0;
    if (dia.tarifaEnvasado > 0) tarifaUsada = dia.tarifaEnvasado;
  });
  txt += SEPd;

  // Total
  txt += '\x1b\x21\x30';
  txt += _pEnd('TOTAL', W/2-6) + _amtP(d.total, W/2-4) + '\n';
  txt += '\x1b\x21\x00';
  txt += SEPd;

  // [v2.41.37] Resumen del período (contexto)
  txt += _sHdr('RESUMEN DEL PERIODO');
  txt += _pEnd('  Dias liquidados', W-6)  + _pSt(String(d.dias.length), 6) + '\n';
  var pctAud = d.dias.length > 0 ? Math.round((diasAuditados / d.dias.length) * 100) : 0;
  txt += _pEnd('  Dias auditados',  W-12) + _pSt(diasAuditados + '/' + d.dias.length + ' ' + pctAud + '%', 12) + '\n';
  txt += _pEnd('  Dias con sancion', W-6) + _pSt(String(diasConSancion), 6) + '\n';
  if (totalEnvasados > 0) {
    txt += _pEnd('  Total envasados', W-10) + _pSt(totalEnvasados + ' uds', 10) + '\n';
    if (tarifaUsada > 0) {
      txt += '    (a S/' + tarifaUsada.toFixed(2) + ' c/u)\n';
    }
  }
  if (totalBonoMeta > 0) {
    txt += _pEnd('  Bono meta logrado', W-12) + _amtP(totalBonoMeta, 12) + '\n';
  }
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
  'montoBase', 'pagoEnvasado', 'bonoMeta', 'bonificacion', 'sancion', 'totalDia',
  'auditado', 'evaluacionesCount', 'scoreFinal', 'tarifaEnvasado', 'presente',
  'estado', 'idPago', 'ts_creado', 'ts_actualizado',
  'bonificacionMotivo', 'sancionMotivo'  // [v2.41.66] motivos persistidos
];

function _liqDiaGetSheet() {
  var ss = getSpreadsheet();
  var sh = ss.getSheetByName(_LDIA_SHEET);
  if (sh) {
    // Auto-migración: agregar columnas faltantes
    try {
      var lc = sh.getLastColumn();
      var hdrs = sh.getRange(1, 1, 1, lc).getValues()[0];
      var faltantes = [];
      if (hdrs.indexOf('bonificacion') === -1) faltantes.push('bonificacion');
      if (hdrs.indexOf('bonificacionMotivo') === -1) faltantes.push('bonificacionMotivo');
      if (hdrs.indexOf('sancionMotivo') === -1) faltantes.push('sancionMotivo');
      faltantes.forEach(function(col, i) {
        sh.getRange(1, lc + 1 + i).setValue(col);
        sh.getRange(1, lc + 1 + i).setBackground('#7c3aed').setFontColor('#fff').setFontWeight('bold').setFontSize(10);
      });
    } catch(_){}
    return sh;
  }
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

// Upsert una fila desde un resumen ya computado (de getResumenDia.data).
//
// [v2.41.60] CAMBIO IMPORTANTE: LIQUIDACIONES_DIA es ahora la FUENTE DE
// VERDAD editable. Esta función PRESERVA bonificacion/sancion/estado de
// la fila existente — NO los sobreescribe con lo recalculado.
//   - bonificacion / sancion: solo se escriben si la fila no existe (fila
//     nueva). Si ya existe, mantener el valor (que pudo ser editado a mano
//     o seteado por crearEvaluacion).
//   - estado: ya se preservaba, sigue igual.
//   - montoBase / pagoEnvasado / bonoMeta: SÍ se recomputan (vienen de
//     actividad real: jornadas, envasados, ventas).
//   - totalDia: se recalcula con los valores FINALES (preservados +
//     recomputados).
function _liqDiaUpsertRow(rd, fecha) {
  if (!rd) return null;
  if (!rd.presente) return null;
  if (_liqDiaIsBlocked(rd.rol)) return null;

  var sh = _liqDiaGetSheet();
  var data = sh.getDataRange().getValues();
  var hdrs = data[0];
  var iIdDia    = hdrs.indexOf('idDia');
  var iEstado   = hdrs.indexOf('estado');
  var iIdPago   = hdrs.indexOf('idPago');
  var iTsCreado = hdrs.indexOf('ts_creado');
  var iBon      = hdrs.indexOf('bonificacion');
  var iSan      = hdrs.indexOf('sancion');

  var idDia = _liqDiaKey(rd.idPersonal, fecha);
  var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
  var idPersonalStr = String(rd.idPersonal);
  var isVirtual = idPersonalStr.indexOf('MEX:') === 0;

  // Buscar existing row
  var existingIdx = -1;
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iIdDia]) === idDia) { existingIdx = i; break; }
  }

  // Preserve estado/idPago/bonificacion/sancion si la fila ya existe
  var estadoExist = 'PENDIENTE', idPagoExist = '', tsCreadoExist = nowStr;
  var bonExist = null, sanExist = null;
  if (existingIdx >= 0) {
    estadoExist = String(data[existingIdx][iEstado] || 'PENDIENTE').toUpperCase();
    idPagoExist = String(data[existingIdx][iIdPago] || '');
    tsCreadoExist = data[existingIdx][iTsCreado] || nowStr;
    if (iBon >= 0) bonExist = parseFloat(data[existingIdx][iBon]) || 0;
    if (iSan >= 0) sanExist = parseFloat(data[existingIdx][iSan]) || 0;
  }

  // Valores finales: preservar si existe, sino usar rd
  var bonFinal = (bonExist !== null) ? bonExist : (parseFloat(rd.bonificacion) || 0);
  var sanFinal = (sanExist !== null) ? sanExist : (parseFloat(rd.sancion) || 0);

  // Recalcular totalDia con valores FINALES (no usar rd.totalDia que asumía
  // los recomputados — usamos los preservados + montos auto-recomputados).
  var baseV = parseFloat(rd.montoBase) || 0;
  var envV  = parseFloat(rd.pagoEnvasado) || 0;
  var metaV = parseFloat(rd.bonoMeta) || 0;
  var totalFinal = Math.max(0, Math.round((baseV + envV + metaV + bonFinal - sanFinal) * 100) / 100);

  var newRow = {
    idDia:             idDia,
    fecha:             fecha,
    idPersonal:        idPersonalStr,
    nombre:            String(rd.nombre || ''),
    rol:               String(rd.rol || '').toUpperCase(),
    appOrigen:         String(rd.appOrigen || ''),
    virtual:           isVirtual,
    montoBase:         baseV,
    pagoEnvasado:      envV,
    bonoMeta:          metaV,
    bonificacion:      bonFinal,
    sancion:           sanFinal,
    totalDia:          totalFinal,
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

// [v2.41.60] Setea bonificacion/sancion DIRECTAMENTE en LIQUIDACIONES_DIA
// (reemplaza, no suma). Llamado desde crearEvaluacion: el último audit
// "gana" — admin ve el valor actual y decide mantener/cambiar.
// También recomputa totalDia con los valores actualizados.
// [v2.41.67] opts.soloTipo: 'sancion'|'bonificacion'|null
//   - 'sancion'      → solo actualiza sancion + sancionMotivo. bonificacion se PRESERVA.
//   - 'bonificacion' → solo actualiza bonificacion + bonificacionMotivo. sancion se PRESERVA.
//   - null/undefined → actualiza ambos (comportamiento legacy).
// Esto evita que cuando admin solo cambia uno (sanción), se le borre el
// otro (bonificación) que ya tenía.
function _liqDiaSetBonSan(idPersonal, fecha, bonificacion, sancion, bonificacionMotivo, sancionMotivo, opts) {
  if (!idPersonal || !fecha) return false;
  opts = opts || {};
  var soloTipo = opts.soloTipo || null;
  try {
    var sh = _liqDiaGetSheet();
    var data = sh.getDataRange().getValues();
    var hdrs = data[0];
    var iIdDia = hdrs.indexOf('idDia');
    var iBon = hdrs.indexOf('bonificacion');
    var iSan = hdrs.indexOf('sancion');
    var iBonMot = hdrs.indexOf('bonificacionMotivo');
    var iSanMot = hdrs.indexOf('sancionMotivo');
    var iBase = hdrs.indexOf('montoBase');
    var iEnv  = hdrs.indexOf('pagoEnvasado');
    var iMeta = hdrs.indexOf('bonoMeta');
    var iTot  = hdrs.indexOf('totalDia');
    var iTs   = hdrs.indexOf('ts_actualizado');
    if (iBon < 0 || iSan < 0 || iTot < 0) return false;

    var idDia = _liqDiaKey(idPersonal, fecha);
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][iIdDia]) !== idDia) continue;

      var bonNueva = parseFloat(bonificacion) || 0;
      var sanNueva = parseFloat(sancion) || 0;
      var bonExist = parseFloat(data[i][iBon]) || 0;
      var sanExist = parseFloat(data[i][iSan]) || 0;
      var bonMotExist = iBonMot >= 0 ? String(data[i][iBonMot] || '') : '';
      var sanMotExist = iSanMot >= 0 ? String(data[i][iSanMot] || '') : '';

      // Resolver valores finales según soloTipo
      var bonFinal = bonNueva, sanFinal = sanNueva;
      var bonMotFinal = String(bonificacionMotivo || '');
      var sanMotFinal = String(sancionMotivo || '');
      if (soloTipo === 'sancion') {
        // Preservar bonificación + su motivo
        bonFinal = bonExist;
        bonMotFinal = bonMotExist;
      } else if (soloTipo === 'bonificacion') {
        // Preservar sanción + su motivo
        sanFinal = sanExist;
        sanMotFinal = sanMotExist;
      }

      var baseV = parseFloat(data[i][iBase]) || 0;
      var envV  = parseFloat(data[i][iEnv])  || 0;
      var metaV = parseFloat(data[i][iMeta]) || 0;
      var totalFinal = Math.max(0, Math.round((baseV + envV + metaV + bonFinal - sanFinal) * 100) / 100);
      sh.getRange(i + 1, iBon + 1).setValue(bonFinal);
      sh.getRange(i + 1, iSan + 1).setValue(sanFinal);
      sh.getRange(i + 1, iTot + 1).setValue(totalFinal);
      if (iBonMot >= 0) sh.getRange(i + 1, iBonMot + 1).setValue(bonMotFinal);
      if (iSanMot >= 0) sh.getRange(i + 1, iSanMot + 1).setValue(sanMotFinal);
      if (iTs >= 0) {
        sh.getRange(i + 1, iTs + 1).setValue(
          Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'")
        );
      }
      try { var _c1 = CacheService.getScriptCache(); _c1.remove('rsmTd2_' + fecha); _c1.remove('pdFast_' + fecha); } catch(_){}
      return true;
    }
    return false;
  } catch(e) { Logger.log('_liqDiaSetBonSan error: ' + e.message); return false; }
}

// [v2.41.60] Obtener bonificacion/sancion ACTUALES de LIQUIDACIONES_DIA.
// Usado por el modal de Auditoría para mostrar al admin lo que ya está
// registrado antes de que decida mantener o cambiar.
function getLiqDiaBonSan(params) {
  var idPersonal = params && params.idPersonal;
  var fecha      = params && params.fecha;
  if (!idPersonal || !fecha) return { ok: false, error: 'idPersonal+fecha requeridos' };
  try {
    var sh = _liqDiaGetSheet();
    var data = sh.getDataRange().getValues();
    var hdrs = data[0];
    var iIdDia = hdrs.indexOf('idDia');
    var iBon = hdrs.indexOf('bonificacion');
    var iSan = hdrs.indexOf('sancion');
    var iBonMot = hdrs.indexOf('bonificacionMotivo');
    var iSanMot = hdrs.indexOf('sancionMotivo');
    var idDia = _liqDiaKey(idPersonal, fecha);
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][iIdDia]) !== idDia) continue;
      return { ok: true, data: {
        bonificacion: parseFloat(data[i][iBon]) || 0,
        sancion:      parseFloat(data[i][iSan]) || 0,
        bonificacionMotivo: iBonMot >= 0 ? String(data[i][iBonMot] || '') : '',
        sancionMotivo:      iSanMot >= 0 ? String(data[i][iSanMot] || '') : '',
        existe:       true
      }};
    }
    return { ok: true, data: { bonificacion: 0, sancion: 0, bonificacionMotivo: '', sancionMotivo: '', existe: false } };
  } catch(e) { return { ok: false, error: e.message }; }
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

  // [v2.41.34] NO sync inline dentro del endpoint — causa timeouts cuando
  // getResumenTodosDia tarda. El sync corre en trigger time-based horario
  // (_liqSyncJob, setup con setupLiqSyncTrigger). El endpoint solo lee.
  // Auto-instalación del trigger si no existe (silencioso, 1 sola vez).
  try { _liqEnsureSyncTrigger(); } catch(_){}
  // [v2.41.38] También auto-instala el trigger de cierre nocturno 23h.
  try { _liqEnsureCierreNocturnoTrigger(); } catch(_){}

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
      bonificacion:      parseFloat(r.bonificacion) || 0,
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

// ============================================================
// [v2.41.62] getPersonalDiaFast — endpoint OPTIMIZADO para UI
// ------------------------------------------------------------
// Lee DIRECTO de LIQUIDACIONES_DIA (tabla materializada plana) para 1
// fecha específica. <500ms vs los 5-15s de getResumenTodosDia que
// recompute todo desde EVALUACIONES + ENVASADOS + VENTAS + AUDITORIAS.
//
// Devuelve el mismo formato que la UI de Personal del Día consume,
// con totalDia, bonificacion, sancion, estado, score, etc. ya
// persistidos en la tabla.
//
// Cache 60s (CacheService) para hits repetidos del polling.
//
// Para auditar (que SÍ necesita kpis live como envasados/ventas en vivo),
// la UI sigue usando getResumenDia individual al abrir el modal.
// ============================================================
function getPersonalDiaFast(params) {
  params = params || {};
  var fecha = params.fecha || _liqHoy();

  // Cache 60s — alivia el polling 30s del frontend
  var ssCache, cacheKey;
  if (!params._refresh) {
    try {
      ssCache = CacheService.getScriptCache();
      cacheKey = 'pdFast_' + fecha;
      var hit = ssCache.get(cacheKey);
      if (hit) { try { return JSON.parse(hit); } catch(_){} }
    } catch(_){}
  }

  var sh = _liqDiaGetSheet();
  var rows = _sheetToObjects(sh);
  var tz = Session.getScriptTimeZone();

  var data = rows.filter(function(r) {
    var f = r.fecha instanceof Date
      ? Utilities.formatDate(r.fecha, tz, 'yyyy-MM-dd')
      : String(r.fecha || '').substring(0, 10);
    return f === fecha;
  }).map(function(r) {
    var liqEstado = String(r.estado || 'PENDIENTE').toUpperCase();
    var totalDia  = parseFloat(r.totalDia) || 0;
    return {
      idPersonal:        String(r.idPersonal || ''),
      nombre:            String(r.nombre || ''),
      rol:               String(r.rol || '').toUpperCase(),
      appOrigen:         String(r.appOrigen || ''),
      virtual:           (typeof r.virtual === 'boolean') ? r.virtual : (String(r.virtual).toLowerCase() === 'true'),
      fecha:             fecha,
      presente:          true,
      auditado:          (r.auditado === true) || (String(r.auditado).toLowerCase() === 'true'),
      evaluacionesCount: parseInt(r.evaluacionesCount) || 0,
      scoreFinal:        parseFloat(r.scoreFinal) || 0,
      montoBase:         parseFloat(r.montoBase) || 0,
      pagoEnvasado:      parseFloat(r.pagoEnvasado) || 0,
      bonoMeta:          parseFloat(r.bonoMeta) || 0,
      bonificacion:      parseFloat(r.bonificacion) || 0,
      sancion:           parseFloat(r.sancion) || 0,
      bonificacionMotivo: String(r.bonificacionMotivo || ''),
      sancionMotivo:      String(r.sancionMotivo || ''),
      totalDia:          totalDia,
      tarifaEnvasado:    parseFloat(r.tarifaEnvasado) || 0.1,
      unidadesEnvasadas: (parseFloat(r.pagoEnvasado) || 0) / (parseFloat(r.tarifaEnvasado) || 0.1),
      // Estado workflow (fuente: LIQUIDACIONES_DIA.estado)
      liqEstado:         liqEstado,
      vetada:            liqEstado === 'VETADA',
      idPago:            String(r.idPago || ''),
      // KPIs stub — la UI rica los pide bajo demanda al abrir audit
      kpis:              { ventasReales: 0, ventasPct: 0, auditoriasHechas: 0, envasados: 0, guias: 0 },
      manual:            { limpiezaPct: 0, limpiezaProfPct: 0, checksAcum: {}, checkCount: 0, checkTotal: 0, controlPct: 0, comentarios: '' }
    };
  });

  // Ordenar: cajeros primero, después almacén, después otros — alfabético
  data.sort(function(a, b) {
    var clasA = _clasiRol(a.rol);
    var clasB = _clasiRol(b.rol);
    if (clasA !== clasB) return clasA - clasB;
    return String(a.nombre).localeCompare(String(b.nombre));
  });

  var resp = { ok: true, data: data, fast: true, fecha: fecha };
  if (ssCache && cacheKey) {
    try {
      var ser = JSON.stringify(resp);
      if (ser.length < 95000) ssCache.put(cacheKey, ser, 60);
    } catch(_){}
  }
  return resp;
}

function _clasiRol(rol) {
  var r = String(rol || '').toUpperCase();
  if (r === 'CAJERO' || r === 'VENDEDOR') return 1;
  if (r === 'ALMACENERO' || r === 'ENVASADOR') return 2;
  return 3;
}

// [v2.41.31] VETAR / DESVETAR — alternativa rápida a marcar como pagado.
// El operador toca el botón 🚫 inline y la liquidación del día queda VETADA
// (no aparece más en Pendientes). Puede desvetar después si fue por error.
// VETADA NO se cobra ni computa para liquidaciones; es como un "skip".
// [v2.41.35] Helper robusto para normalizar fechas de la hoja a yyyy-MM-dd.
// Acepta Date, ISO, M/D/YYYY (US), D/M/YYYY (LATAM con heurística dd>12).
function _liqNormFecha(raw, tz) {
  if (raw == null || raw === '') return '';
  if (raw instanceof Date) return Utilities.formatDate(raw, tz, 'yyyy-MM-dd');
  var s = String(raw).trim();
  if (!s) return '';
  // ISO yyyy-MM-dd o con T
  var iso = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/);
  if (iso) {
    return iso[1] + '-' + ('0' + iso[2]).slice(-2) + '-' + ('0' + iso[3]).slice(-2);
  }
  // M/D/YYYY o D/M/YYYY (heurística: si primer número > 12 es DD)
  var slash = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/);
  if (slash) {
    var a = parseInt(slash[1], 10), b = parseInt(slash[2], 10), yy = slash[3];
    var m, d;
    if (a > 12)      { d = a; m = b; }   // D/M/YYYY
    else             { m = a; d = b; }   // default US M/D/YYYY
    return yy + '-' + ('0' + m).slice(-2) + '-' + ('0' + d).slice(-2);
  }
  // Fallback: dejar pasar el string como vino (substring 10)
  return s.substring(0, 10);
}

function vetarLiquidacionDia(params) {
  var idPersonal = String(params.idPersonal || '').trim();
  var fecha      = String(params.fecha || '').trim();
  if (!idPersonal || !fecha) return { ok: false, error: 'idPersonal y fecha requeridos' };
  var sh = _liqDiaGetSheet();
  var hdrs = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
  var iIdDia      = hdrs.indexOf('idDia');
  var iIdPersonal = hdrs.indexOf('idPersonal');
  var iFecha      = hdrs.indexOf('fecha');
  var iEstado     = hdrs.indexOf('estado');
  var iTsAct      = hdrs.indexOf('ts_actualizado');
  if (iEstado < 0) return { ok: false, error: 'Hoja sin columna estado' };

  // [v2.41.40] FAST PATH: buscar por idDia con TextFinder (O(log n))
  // en lugar de iterar toda la hoja (que para hojas grandes timeout-ea).
  // _liqDiaKey ya nos da la clave compuesta única.
  try {
    var idDia = _liqDiaKey(idPersonal, fecha);
    var finder = sh.getRange(1, iIdDia + 1, sh.getLastRow(), 1).createTextFinder(idDia).matchEntireCell(true);
    var hit = finder.findNext();
    if (hit) {
      var row = hit.getRow();
      var estCell = sh.getRange(row, iEstado + 1).getValue();
      var est = String(estCell || '').toUpperCase();
      if (est === 'PAGADA') return { ok: false, error: 'YA_PAGADA' };
      sh.getRange(row, iEstado + 1).setValue('VETADA');
      if (iTsAct >= 0) {
        sh.getRange(row, iTsAct + 1).setValue(
          Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'")
        );
      }
      // Invalidar caches backend (getResumenTodosDia + getPersonalDiaFast)
      try { var _cv = CacheService.getScriptCache(); _cv.remove('rsmTd2_' + fecha); _cv.remove('pdFast_' + fecha); } catch(_){}
      return { ok: true };
    }
  } catch(eF) { Logger.log('[vetar] TextFinder error: ' + eF.message); }

  // FALLBACK lento: si TextFinder no encuentra (idDia distinto) iterar
  // por idPersonal+fecha
  if (iIdPersonal < 0 || iFecha < 0) {
    return { ok: false, error: 'Hoja sin columnas requeridas' };
  }
  var data = sh.getDataRange().getValues();
  var tz = Session.getScriptTimeZone();
  for (var i = 1; i < data.length; i++) {
    var idP = String(data[i][iIdPersonal] || '').trim();
    var f   = _liqNormFecha(data[i][iFecha], tz);
    if (idP === idPersonal && f === fecha) {
      var est2 = String(data[i][iEstado] || '').toUpperCase();
      if (est2 === 'PAGADA') return { ok: false, error: 'YA_PAGADA' };
      sh.getRange(i + 1, iEstado + 1).setValue('VETADA');
      if (iTsAct >= 0) {
        sh.getRange(i + 1, iTsAct + 1).setValue(
          Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'")
        );
      }
      return { ok: true };
    }
  }
  Logger.log('[vetar] NO encontrada idPersonal=' + idPersonal + ' fecha=' + fecha + ' filas=' + (data.length - 1));
  return { ok: false, error: 'NO_ENCONTRADA', mensaje: 'No hay fila para ' + idPersonal + ' @ ' + fecha };
}

function desvetarLiquidacionDia(params) {
  var idPersonal = String(params.idPersonal || '').trim();
  var fecha      = String(params.fecha || '').trim();
  if (!idPersonal || !fecha) return { ok: false, error: 'idPersonal y fecha requeridos' };
  var sh = _liqDiaGetSheet();
  var hdrs = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
  var iIdDia      = hdrs.indexOf('idDia');
  var iEstado     = hdrs.indexOf('estado');
  var iTsAct      = hdrs.indexOf('ts_actualizado');
  if (iEstado < 0) return { ok: false, error: 'Hoja sin columna estado' };

  // [v2.41.40] FAST PATH con TextFinder por idDia
  try {
    var idDia = _liqDiaKey(idPersonal, fecha);
    var finder = sh.getRange(1, iIdDia + 1, sh.getLastRow(), 1).createTextFinder(idDia).matchEntireCell(true);
    var hit = finder.findNext();
    if (hit) {
      var row = hit.getRow();
      var est = String(sh.getRange(row, iEstado + 1).getValue() || '').toUpperCase();
      if (est !== 'VETADA') return { ok: false, error: 'NO_VETADA', mensaje: 'Estado actual: ' + est };
      sh.getRange(row, iEstado + 1).setValue('PENDIENTE');
      if (iTsAct >= 0) {
        sh.getRange(row, iTsAct + 1).setValue(
          Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'")
        );
      }
      // Invalidar caches backend (getResumenTodosDia + getPersonalDiaFast)
      try { var _cv = CacheService.getScriptCache(); _cv.remove('rsmTd2_' + fecha); _cv.remove('pdFast_' + fecha); } catch(_){}
      return { ok: true };
    }
  } catch(eF) { Logger.log('[desvetar] TextFinder error: ' + eF.message); }

  // Fallback
  var iIdPersonal = hdrs.indexOf('idPersonal');
  var iFecha      = hdrs.indexOf('fecha');
  if (iIdPersonal < 0 || iFecha < 0) return { ok: false, error: 'Hoja sin columnas requeridas' };
  var data = sh.getDataRange().getValues();
  var tz = Session.getScriptTimeZone();
  for (var i = 1; i < data.length; i++) {
    var idP = String(data[i][iIdPersonal] || '').trim();
    var f   = _liqNormFecha(data[i][iFecha], tz);
    if (idP === idPersonal && f === fecha) {
      var est2 = String(data[i][iEstado] || '').toUpperCase();
      if (est2 !== 'VETADA') return { ok: false, error: 'NO_VETADA', mensaje: 'Estado actual: ' + est2 };
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
    // [v2.41.62] Invalidar caches de cada fecha afectada
    try {
      var _cmp = CacheService.getScriptCache();
      fechas.forEach(function(f) { _cmp.remove('rsmTd2_' + f); _cmp.remove('pdFast_' + f); });
    } catch(_){}
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
    var iFecha  = hdrs.indexOf('fecha');
    var iEst    = hdrs.indexOf('estado');
    var iIdPago = hdrs.indexOf('idPago');
    var iTsAct  = hdrs.indexOf('ts_actualizado');
    var nowStr = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
    var tz = Session.getScriptTimeZone();
    var fechasAfect = {};
    var revertidas = 0;
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][iIdPago]) === String(idPago)) {
        sh.getRange(i + 1, iEst    + 1).setValue('PENDIENTE');
        sh.getRange(i + 1, iIdPago + 1).setValue('');
        sh.getRange(i + 1, iTsAct  + 1).setValue(nowStr);
        var fAfect = data[i][iFecha] instanceof Date
          ? Utilities.formatDate(data[i][iFecha], tz, 'yyyy-MM-dd')
          : String(data[i][iFecha] || '').substring(0, 10);
        if (fAfect) fechasAfect[fAfect] = true;
        revertidas++;
      }
    }
    // [v2.41.62] Invalidar caches de las fechas afectadas
    try {
      var _cr = CacheService.getScriptCache();
      Object.keys(fechasAfect).forEach(function(f) {
        _cr.remove('rsmTd2_' + f); _cr.remove('pdFast_' + f);
      });
    } catch(_){}
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

// ============================================================
// [v2.41.34] AUTO-SYNC LIQUIDACIONES_DIA — trigger time-based
// ------------------------------------------------------------
// Antes el endpoint público sincronizaba dentro de la respuesta
// (HOY cada 5min, últimos 3d cada 1h). Esto causaba timeouts cuando
// getResumenTodosDia tardaba (~3-8s × 3 días = hasta 30s bloqueando
// al operador). Solución: mover el sync a un trigger time-based
// horario que corre en background, totalmente desacoplado de las
// requests UI. El endpoint solo LEE de la hoja, instantáneo.
// ============================================================

// Job que corre el trigger horario — sync de HOY + últimos 3 días
function _liqSyncJob() {
  try {
    var hoy = _liqHoy();
    Logger.log('[LiqSyncJob] inicio · hoy=' + hoy);
    try { _liqDiaSync(hoy); } catch(e1) { Logger.log('  HOY error: ' + e1.message); }
    // [v2.41.60] Ampliado de 3 a 14 días — cubre reauditorías retroactivas
    // (admin que edita un día pasado, eval que llega tarde, columna nueva
    // que necesita backfill). Sync solo toca montos auto (envasado/base/meta);
    // bonificacion/sancion/estado se preservan (LIQUIDACIONES_DIA es la fuente).
    for (var dk = 1; dk <= 14; dk++) {
      try {
        var fDk = _fechaOffset(hoy, -dk);
        _liqDiaSync(fDk);
      } catch(e2) { Logger.log('  -' + dk + 'd error: ' + e2.message); }
    }
    Logger.log('[LiqSyncJob] fin OK');
  } catch(e) { Logger.log('[LiqSyncJob] fatal: ' + e.message); }
}

// Setup público — el operador lo ejecuta UNA vez desde el editor para
// crear el trigger horario. Idempotente: borra triggers viejos del
// mismo handler antes de crear.
function setupLiqSyncTrigger() {
  var TRG = '_liqSyncJob';
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === TRG) ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger(TRG).timeBased().everyHours(1).create();
  Logger.log('[Trigger] ' + TRG + ' creado · cada 1 hora');
  return { ok: true, mensaje: 'Trigger horario creado' };
}

// ============================================================
// [v2.41.36] CIERRE NOCTURNO TOTAL — 23:00 diario
// ------------------------------------------------------------
// Cierra automáticamente:
//   - SESIONES en WH (almaceneros, envasadores) que quedaron ACTIVAS
//   - CAJAS en MosExpress (cajeros, vendedores) que quedaron ABIERTAS
// Push al MOS rol admin/master con resumen.
// MASTER/ADMINISTRADOR no se les cierra sesión (24/7 sin restricción).
// ============================================================
function cierreNocturnoTodos() {
  var tStart = new Date();
  var resultado = {
    fecha:  Utilities.formatDate(tStart, Session.getScriptTimeZone(), 'yyyy-MM-dd HH:mm'),
    wh:     { cerradas: 0, omitidas: 0, errores: 0, detalles: [] },
    me:     { cerradas: 0, errores: 0, detalles: [] },
    // [v2.41.76] Forzar logout en TODOS los dispositivos ME/WH activos
    devices:{ marcados: 0, omitidos: 0, errores: 0 }
  };

  // ── 1. WH SESIONES ──
  try {
    var whSh = _abrirWhSheet('SESIONES');
    if (whSh) {
      var d = whSh.getDataRange().getValues();
      var h = d[0];
      var iEstado = h.indexOf('estado');
      var iIdP    = h.indexOf('idPersonal');
      var iFFin   = h.indexOf('fechaFin');
      var iHFin   = h.indexOf('horaFin');
      var iMinAct = h.indexOf('minutosActivos');
      var iFIni   = h.indexOf('fechaInicio');
      var iHIni   = h.indexOf('horaInicio');

      // Cargar mapa idPersonal → rol (para excluir admin/master)
      var rolMap = {};
      try {
        var perSh = _abrirWhSheet('PERSONAL');
        if (perSh) {
          _sheetToObjects(perSh).forEach(function(p) {
            rolMap[String(p.idPersonal)] = String(p.rol || '').toUpperCase();
          });
        }
      } catch(_) {}

      var tz = Session.getScriptTimeZone();
      var now = new Date();
      var fechaStr = Utilities.formatDate(now, tz, 'yyyy-MM-dd');
      var horaStr  = Utilities.formatDate(now, tz, 'HH:mm');
      for (var i = 1; i < d.length; i++) {
        var est = String(d[i][iEstado] || '').toUpperCase();
        if (est !== 'ACTIVA') continue;
        var idPers = String(d[i][iIdP] || '');
        var rolP   = rolMap[idPers] || '';
        if (rolP === 'MASTER' || rolP === 'ADMINISTRADOR') {
          resultado.wh.omitidas++;
          continue;
        }
        try {
          whSh.getRange(i + 1, iEstado + 1).setValue('CERRADA_AUTO');
          if (iFFin >= 0) whSh.getRange(i + 1, iFFin + 1).setValue(fechaStr);
          if (iHFin >= 0) whSh.getRange(i + 1, iHFin + 1).setValue(horaStr);
          // Calcular minutos activos si tenemos fechaInicio/horaInicio
          if (iMinAct >= 0 && iFIni >= 0 && iHIni >= 0) {
            try {
              var fIni = String(d[i][iFIni] || '').substring(0, 10);
              var hIni = String(d[i][iHIni] || '00:00');
              var ini = new Date(fIni + 'T' + hIni + ':00');
              if (!isNaN(ini.getTime())) {
                var mins = Math.round((now - ini) / 60000);
                whSh.getRange(i + 1, iMinAct + 1).setValue(Math.max(0, mins));
              }
            } catch(_){}
          }
          resultado.wh.cerradas++;
          resultado.wh.detalles.push(idPers);
        } catch(eS) {
          resultado.wh.errores++;
          Logger.log('[CierreNoct] WH error idPersonal=' + idPers + ': ' + eS.message);
        }
      }
    }
  } catch(eW) {
    resultado.wh.errores++;
    Logger.log('[CierreNoct] WH fatal: ' + eW.message);
  }

  // ── 2. ME CAJAS ──
  // [v2.43.24] Trackeamos los VENDEDORES de cajas con error para excluirlos
  // del paso 3 (forzar_logout). Sin esto, una caja que no se cerró bien
  // queda huérfana (ABIERTA en CAJAS) y el cajero queda bloqueado al volver.
  var vendedoresConCajaError = {};
  resultado.me.cajasNoCerradas = [];
  try {
    var meSs = _meSS();
    var meCajas = meSs.getSheetByName('CAJAS');
    if (meCajas) {
      var dC = meCajas.getDataRange().getValues();
      var hC = dC[0];
      var iEstC = hC.indexOf('Estado');
      var iIdC  = hC.indexOf('idCaja');
      var iVenC = hC.indexOf('Vendedor');
      if (iEstC < 0) iEstC = 0;
      if (iIdC  < 0) iIdC  = 0;
      for (var j = 1; j < dC.length; j++) {
        var estC = String(dC[j][iEstC] || '').toUpperCase().trim();
        if (estC !== 'ABIERTA') continue;
        var idCaja = String(dC[j][iIdC] || '');
        if (!idCaja) continue;
        var vendedorCaja = iVenC >= 0 ? String(dC[j][iVenC] || '') : '';
        try {
          // Llamar al bridge ME — el endpoint del lado ME calcula totales y cierra
          var r = _meBridgeEvento('CIERRE_CAJA_FORZADO', {
            idCaja: idCaja,
            motivo: 'cierre_nocturno_auto_23h',
            auth: { nombre: 'sistema_cron_MOS', rol: 'SYSTEM' },
            adminAuth: { nombre: 'sistema', rol: 'SYSTEM', via: 'CRON' }
          });
          // [v2.43.24] El bridge puede devolver ok=true, status='success', o
          // yaCerrada=true (idempotencia). Cualquiera de esos = OK.
          var bridgeOk = r && (r.ok === true || r.status === 'success' || r.yaCerrada === true);
          if (bridgeOk) {
            resultado.me.cerradas++;
            resultado.me.detalles.push(idCaja);
          } else {
            resultado.me.errores++;
            resultado.me.cajasNoCerradas.push(idCaja);
            if (vendedorCaja) vendedoresConCajaError[vendedorCaja.toLowerCase().trim()] = true;
            Logger.log('[CierreNoct] ME error idCaja=' + idCaja + ' vendedor=' + vendedorCaja + ': ' + JSON.stringify(r));
          }
        } catch(eC) {
          resultado.me.errores++;
          resultado.me.cajasNoCerradas.push(idCaja);
          if (vendedorCaja) vendedoresConCajaError[vendedorCaja.toLowerCase().trim()] = true;
          Logger.log('[CierreNoct] ME excepción idCaja=' + idCaja + ' vendedor=' + vendedorCaja + ': ' + eC.message);
        }
      }
    }
  } catch(eM) {
    resultado.me.errores++;
    Logger.log('[CierreNoct] ME fatal: ' + eM.message);
  }

  // ── 3. DISPOSITIVOS — marcar Forzar_Logout para apps operativas ──
  // [v2.41.76] Por cada dispositivo de mosExpress/warehouseMos cuyo
  // Ultima_Sesion NO sea admin/master, marca Forzar_Logout='1' + ts.
  // La PWA cliente, al hacer su próximo heartbeat consultarEstadoDispositivo,
  // recibe forzar_logout=true y cierra sesión local + caja (si aplica).
  try {
    if (typeof _garantizarColumnasDispositivos === 'function') _garantizarColumnasDispositivos();
    var dispoSh = getSheet('DISPOSITIVOS');
    if (dispoSh) {
      var dd = dispoSh.getDataRange().getValues();
      var hdrs = dd[0] || [];
      var iApp = hdrs.indexOf('App');
      var iSes = hdrs.indexOf('Ultima_Sesion');
      var iEst = hdrs.indexOf('Estado');
      var iFL  = hdrs.indexOf('Forzar_Logout');
      var iFLts= hdrs.indexOf('Logout_Auto_Ts');
      // Set de nombres admin/master para EXCLUIRLOS del logout forzado
      var adminsNorm = {};
      try {
        var perAll = _sheetToObjects(getSheet('PERSONAL_MASTER'));
        perAll.forEach(function(p) {
          var rol = String(p.rol || '').toUpperCase();
          if (rol === 'MASTER' || rol === 'ADMINISTRADOR' || rol === 'ADMIN' ||
              String(p.appOrigen || '') === 'MOS') {
            var n2 = (String(p.nombre || '') + ' ' + String(p.apellido || '')).toLowerCase().trim();
            if (n2) adminsNorm[n2] = true;
            var n1 = String(p.nombre || '').toLowerCase().trim();
            if (n1) adminsNorm[n1] = true;
          }
        });
      } catch(_){}
      var nowStrUTC = Utilities.formatDate(new Date(), 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
      for (var rd = 1; rd < dd.length; rd++) {
        var app = String(dd[rd][iApp] || '').toLowerCase();
        // Solo apps operativas — mos es panel admin, se excluye
        if (app !== 'mosexpress' && app !== 'warehousemos') {
          resultado.devices.omitidos++;
          continue;
        }
        var ses = String(dd[rd][iSes] || '').toLowerCase().trim();
        if (ses && adminsNorm[ses]) {
          resultado.devices.omitidos++;
          continue;
        }
        var est = String(dd[rd][iEst] || '').toUpperCase();
        if (est === 'INACTIVO' || est === 'PENDIENTE_APROBACION') {
          resultado.devices.omitidos++;
          continue;
        }
        // [v2.43.24] CRÍTICO: si este vendedor tenía una caja ABIERTA que el
        // bridge NO logró cerrar, NO marcar forzar_logout. Sino el frontend
        // mata local y la caja queda HUÉRFANA (ABIERTA en CAJAS sin owner
        // local). Mejor el cajero vuelve, ve su caja y la cierra manual.
        if (ses && vendedoresConCajaError[ses]) {
          resultado.devices.omitidos++;
          Logger.log('[CierreNoct] OMITIENDO forzar_logout para "' + ses + '" — su caja no cerró bien (cajas: ' + JSON.stringify(resultado.me.cajasNoCerradas) + ')');
          continue;
        }
        try {
          if (iFL >= 0)   dispoSh.getRange(rd + 1, iFL + 1).setValue('1');
          if (iFLts >= 0) dispoSh.getRange(rd + 1, iFLts + 1).setValue(nowStrUTC);
          resultado.devices.marcados++;
        } catch(eD) {
          resultado.devices.errores++;
          Logger.log('[CierreNoct] device error fila=' + (rd+1) + ': ' + eD.message);
        }
      }
    }
  } catch(eD2) {
    resultado.devices.errores++;
    Logger.log('[CierreNoct] DISPOSITIVOS fatal: ' + eD2.message);
  }

  // ── 4. Log persistente CIERRE_NOCT_LOG ──
  // [v2.41.76] Sin este log no sabemos si el trigger está corriendo.
  // Hoja se auto-crea con headers al primer use.
  try {
    var ss = getSpreadsheet();
    var logSh = ss.getSheetByName('CIERRE_NOCT_LOG');
    if (!logSh) {
      logSh = ss.insertSheet('CIERRE_NOCT_LOG');
      logSh.appendRow(['ts_inicio', 'ts_fin', 'duracion_ms',
                       'wh_cerradas', 'wh_omitidas', 'wh_errores',
                       'me_cerradas', 'me_errores',
                       'dev_marcados', 'dev_omitidos', 'dev_errores',
                       'detalles_json']);
      logSh.getRange(1, 1, 1, 12).setFontWeight('bold')
           .setBackground('#1f2937').setFontColor('#fff');
    }
    var tEnd = new Date();
    var dur = tEnd.getTime() - tStart.getTime();
    logSh.appendRow([
      Utilities.formatDate(tStart, Session.getScriptTimeZone(), 'yyyy-MM-dd HH:mm:ss'),
      Utilities.formatDate(tEnd,   Session.getScriptTimeZone(), 'yyyy-MM-dd HH:mm:ss'),
      dur,
      resultado.wh.cerradas, resultado.wh.omitidas, resultado.wh.errores,
      resultado.me.cerradas, resultado.me.errores,
      resultado.devices.marcados, resultado.devices.omitidos, resultado.devices.errores,
      JSON.stringify({ wh: resultado.wh.detalles, me: resultado.me.detalles })
    ]);
  } catch(eLog) { Logger.log('[CierreNoct] log fallo: ' + eLog.message); }

  // ── 5. Push al MOS admin/master ──
  try {
    if (resultado.wh.cerradas + resultado.me.cerradas + resultado.devices.marcados > 0 ||
        resultado.wh.errores  + resultado.me.errores  + resultado.devices.errores  > 0) {
      var titulo = '🌙 Cierre nocturno auto · 23h';
      var partes = [];
      partes.push('WH: ' + resultado.wh.cerradas + ' sesiones cerradas');
      if (resultado.wh.omitidas) partes.push(resultado.wh.omitidas + ' admin omitidas');
      partes.push('ME: ' + resultado.me.cerradas + ' cajas cerradas');
      partes.push('Dev: ' + resultado.devices.marcados + ' deslog forz.');
      var errTotal = resultado.wh.errores + resultado.me.errores + resultado.devices.errores;
      if (errTotal > 0) partes.push('⚠ ' + errTotal + ' errores (ver Logger)');
      var cuerpo = partes.join(' · ');
      // [v2.41.59] Usar _enviarPushTodos con idNotif del catálogo. Antes
      // llamaba _notificarMOS (función que no existe) → push silencioso.
      try {
        if (typeof _enviarPushTodos === 'function') {
          _enviarPushTodos(titulo, cuerpo, { idNotif: 'MOS_CIERRE_NOCTURNO' });
        }
      } catch(_){}
    }
  } catch(eP) { Logger.log('[CierreNoct] push fallo: ' + eP.message); }

  Logger.log('[CierreNoct] DONE · ' + JSON.stringify(resultado));
  return { ok: true, data: resultado };
}

function setupCierreNocturnoTrigger() {
  var TRG = 'cierreNocturnoTodos';
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === TRG) ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger(TRG).timeBased().atHour(23).everyDays(1).create();
  Logger.log('[Trigger] ' + TRG + ' creado · diario 23:00');
  return { ok: true, mensaje: 'Trigger creado · diario 23:00' };
}

// [v2.41.76] Diagnóstico de triggers + última corrida del cierre nocturno.
// Lee CIERRE_NOCT_LOG (auto-creada en cierreNocturnoTodos).
function getCronStatus() {
  var out = {
    triggers: [],
    cierreNocturno: {
      trigger_instalado: false,
      hora_programada:   null,
      tz_script:         Session.getScriptTimeZone(),
      ahora_script:      Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd HH:mm:ss'),
      ultima_corrida:    null,
      total_corridas:    0,
      ultimas_5:         []
    }
  };
  try {
    ScriptApp.getProjectTriggers().forEach(function(t) {
      var info = {
        handler:    t.getHandlerFunction(),
        type:       String(t.getEventType()),
        triggerId:  t.getUniqueId()
      };
      try {
        // Para time-based, no hay método público para leer la hora exacta.
        // Usamos el handler como pista.
      } catch(_){}
      out.triggers.push(info);
      if (t.getHandlerFunction() === 'cierreNocturnoTodos') {
        out.cierreNocturno.trigger_instalado = true;
        out.cierreNocturno.hora_programada = '23:00 (Lima)';
      }
    });
  } catch(eT) { out.triggersError = eT.message; }

  // Leer log de últimas corridas
  try {
    var ss = getSpreadsheet();
    var logSh = ss.getSheetByName('CIERRE_NOCT_LOG');
    if (logSh) {
      var last = logSh.getLastRow();
      out.cierreNocturno.total_corridas = Math.max(0, last - 1);
      if (last > 1) {
        var ini = Math.max(2, last - 4);
        var data = logSh.getRange(ini, 1, last - ini + 1, 12).getValues();
        var hdrs = ['ts_inicio','ts_fin','duracion_ms',
                    'wh_cerradas','wh_omitidas','wh_errores',
                    'me_cerradas','me_errores',
                    'dev_marcados','dev_omitidos','dev_errores',
                    'detalles_json'];
        out.cierreNocturno.ultimas_5 = data.map(function(row) {
          var obj = {};
          hdrs.forEach(function(h, i) { obj[h] = row[i]; });
          return obj;
        }).reverse();
        out.cierreNocturno.ultima_corrida = out.cierreNocturno.ultimas_5[0];
      }
    }
  } catch(eL) { out.cierreNocturnoLogError = eL.message; }

  return { ok: true, data: out };
}

// [v2.41.76] El cliente llama esto tras honrar el flag Forzar_Logout
// para que no quede en bucle (sino la próxima sesión también se cerraría
// inmediatamente). Limpia el flag pero deja Logout_Auto_Ts como log.
function marcarLogoutHonrado(params) {
  var deviceId = String(params.deviceId || params.ID_Dispositivo || '').trim();
  if (!deviceId) return { ok: false, error: 'Requiere deviceId' };
  if (typeof _garantizarColumnasDispositivos === 'function') _garantizarColumnasDispositivos();
  var sheet = getSheet('DISPOSITIVOS');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0] || [];
  var iId   = hdrs.indexOf('ID_Dispositivo');
  var iFL   = hdrs.indexOf('Forzar_Logout');
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][iId]) !== deviceId) continue;
    if (iFL >= 0) sheet.getRange(i + 1, iFL + 1).setValue('');
    return { ok: true };
  }
  return { ok: false, error: 'Dispositivo no encontrado' };
}

// [v2.41.38] Auto-instalación silenciosa del trigger de cierre nocturno.
// Mismo patrón que _liqEnsureSyncTrigger. Throttle 1h para retries.
function _liqEnsureCierreNocturnoTrigger() {
  var ssCache;
  try { ssCache = CacheService.getScriptCache(); } catch(_) { return; }
  if (!ssCache) return;
  if (ssCache.get('cierrenoct_trg_check')) return;
  ssCache.put('cierrenoct_trg_check', '1', 3600);
  try {
    var existe = ScriptApp.getProjectTriggers().some(function(t) {
      return t.getHandlerFunction() === 'cierreNocturnoTodos';
    });
    if (!existe) {
      ScriptApp.newTrigger('cierreNocturnoTodos').timeBased().atHour(23).everyDays(1).create();
      Logger.log('[CierreNocturnoTrigger] auto-instalado · diario 23:00');
    }
  } catch(e) { Logger.log('[CierreNocturnoTrigger] auto fallo: ' + e.message); }
}

// Auto-instalación silenciosa: si NO existe el trigger, crearlo.
// Marca un cache para no reintentarlo más de 1 vez por hora si falla.
function _liqEnsureSyncTrigger() {
  var ssCache;
  try { ssCache = CacheService.getScriptCache(); } catch(_) { return; }
  if (!ssCache) return;
  if (ssCache.get('ldia_trg_check')) return;
  ssCache.put('ldia_trg_check', '1', 3600);
  try {
    var existe = ScriptApp.getProjectTriggers().some(function(t) {
      return t.getHandlerFunction() === '_liqSyncJob';
    });
    if (!existe) {
      ScriptApp.newTrigger('_liqSyncJob').timeBased().everyHours(1).create();
      Logger.log('[LiqSyncTrigger] auto-instalado');
    }
  } catch(e) { Logger.log('[LiqSyncTrigger] auto-instalación fallo: ' + e.message); }
}

// ════════════════════════════════════════════════════════════════════
// [v2.43.29] Cron MOS 22:30 — Salud de stock WH
// Corre DESPUÉS de la auditoría WH 22:00. Lee alertas pendientes y
// notifica push agrupado a MASTER + ADMIN si hay desbalances.
// ════════════════════════════════════════════════════════════════════
function cronSaludStockWH() {
  try {
    // [v2.43.56] Retry con backoff exponencial — Apps Script a veces devuelve
    // "Service Spreadsheets failed" en cargas pico, pero al reintentar funciona.
    var auditRes = _retryPostWHTransitorio('auditarStockGlobal', {}, 3);
    if (!auditRes || !auditRes.ok) {
      Logger.log('[saludStock] auditarStockGlobal WH fallo tras retries: ' + JSON.stringify(auditRes));
    }
    var alertRes = _retryPostWHTransitorio('getAlertasStock', { soloPendientes: true }, 3);
    if (!alertRes || !alertRes.ok) return { ok: false, error: 'getAlertasStock fallo tras retries' };
    var pendientes = (alertRes.data || []);
    if (pendientes.length === 0) {
      Logger.log('[saludStock] sin desbalances · stock WH cuadra ✓');
      return { ok: true, data: { pendientes: 0 } };
    }
    // 3. Push agrupado a admins
    try {
      var totalAbs = pendientes.reduce(function(s, a) { return s + Math.abs(parseFloat(a.diferencia) || 0); }, 0);
      var titulo   = '⚠ Salud stock WH · ' + pendientes.length + ' producto' + (pendientes.length === 1 ? '' : 's');
      var cuerpo   = '|Δ| total: ' + totalAbs.toFixed(1) + 'u · revisa panel "Salud Stock"';
      if (typeof _enviarPushTodos === 'function') {
        _enviarPushTodos(titulo, cuerpo, { idNotif: 'MOS_SALUD_STOCK_WH' });
      }
    } catch(eP) { Logger.log('[saludStock] push fallo: ' + eP.message); }
    return { ok: true, data: { pendientes: pendientes.length } };
  } catch(e) {
    Logger.log('[saludStock] excepción: ' + e.message);
    return { ok: false, error: e.message };
  }
}

function setupSaludStockTrigger() {
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === 'cronSaludStockWH') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('cronSaludStockWH').timeBased().atHour(22).nearMinute(30).everyDays(1).create();
  Logger.log('[saludStock] cron instalado 22:30 daily');
  return { ok: true, data: { instalado: true, hora: '22:30' } };
}

// [v2.43.56] Status del trigger — para diagnóstico desde el panel
function verificarTriggerSalud() {
  var encontrado = null;
  ScriptApp.getProjectTriggers().forEach(function(t) {
    if (t.getHandlerFunction() === 'cronSaludStockWH') {
      encontrado = {
        handler:  t.getHandlerFunction(),
        tipo:     String(t.getEventType()),
        tipoCron: String(t.getTriggerSource())
      };
    }
  });
  return {
    ok: true,
    data: {
      instalado: !!encontrado,
      detalle:   encontrado,
      mensaje:   encontrado
        ? 'Cron activo · corre diario a las 22:30'
        : 'Cron NO instalado — ejecuta setupSaludStockTrigger una vez'
    }
  };
}

// [v2.43.56] Helper de retry para postToWarehouse con backoff.
// Reintenta hasta N veces si el error es "Service Spreadsheets failed",
// "rate limit", "quota", "timeout", etc. Backoff exponencial 2s/4s/8s.
function _retryPostWHTransitorio(accion, params, maxIntentos) {
  var max = maxIntentos || 3;
  var ultimoErr = null;
  var delays = [2000, 4000, 8000];
  for (var i = 0; i < max; i++) {
    try {
      var r = postToWarehouse(accion, params);
      if (r && r.ok !== false) return r;
      ultimoErr = (r && r.error) || 'sin respuesta';
      var et = String(ultimoErr).toLowerCase();
      var transit = et.indexOf('service spreadsheets') >= 0 ||
                    et.indexOf('rate limit') >= 0 ||
                    et.indexOf('quota') >= 0 ||
                    et.indexOf('failed while accessing') >= 0 ||
                    et.indexOf('timeout') >= 0;
      if (!transit) return r;
      Logger.log('[retry] ' + accion + ' fallo transitorio intento ' + (i + 1) + ': ' + ultimoErr);
    } catch(e) {
      ultimoErr = e.message;
      Logger.log('[retry] ' + accion + ' excepcion intento ' + (i + 1) + ': ' + ultimoErr);
    }
    if (i < max - 1) {
      try { Utilities.sleep(delays[i] || 2000); } catch(_){}
    }
  }
  return { ok: false, error: 'Tras ' + max + ' intentos: ' + ultimoErr };
}
