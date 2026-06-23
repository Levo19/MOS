// ════════════════════════════════════════════════════════════════════
// [v2.43.51] PURGA DE CATÁLOGO — Eliminación irreversible solo MASTER
// ────────────────────────────────────────────────────────────────────
// Permite al MASTER eliminar items del catálogo (canónicos, presentaciones,
// equivalentes) que ya no se usan más. Toda eliminación queda registrada
// en PURGAS_HISTORICAS con un snapshot de la fila eliminada para auditoría
// y eventual recuperación manual.
//
// Política:
//   - Solo rol MASTER puede ejecutar (tier 3 de seguridad)
//   - Doble clave: el sistema verificarClaveAdmin ya consume 8 dígitos
//     (4 globales + 4 personales). El frontend pide los 8 juntos.
//   - Pre-validación: si un canónico tiene equivalentes/presentaciones,
//     el frontend debe enviarlos también o se bloquea (no dejamos huérfanos)
//   - Auditoría push automática a admin/master por verificarClaveAdmin
// ════════════════════════════════════════════════════════════════════

// ── 1. Lista candidatos: grupos con estructura ──────────────────────
// El frontend ya tiene cargados todos los productos + equivalencias en
// S.productos y S.equivMap. Este endpoint NO duplica esos datos; solo
// retorna {ok:true} con la firma de que el endpoint existe. El frontend
// arma la lista en memoria con sus caches.
//
// (Mantenemos el endpoint para futuras extensiones server-side: por ej,
// "veces vendido histórico" que requeriría joins con MosExpress y WH.)
function getCandidatosEliminacion(params) {
  return {
    ok: true,
    data: {
      mensaje: 'Frontend arma la lista desde S.productos + S.equivMap',
      modelo: 'cliente'
    }
  };
}

// ── 2. Eliminación atómica con auditoría ────────────────────────────
// params:
//   items: [{tipo:'CANONICO'|'PRESENTACION'|'EQUIVALENTE', id, skuBase, codigoBarra, descripcion}]
//   claveAdmin: 8 dígitos
//   appOrigen / dispositivo / detalle: contexto auditoría
function eliminarItemsCatalogo(params) {
  // 1) Validar payload
  if (!params || !Array.isArray(params.items) || !params.items.length) {
    return { ok: false, error: 'Requiere items[]' };
  }
  if (!params.claveAdmin) {
    return { ok: false, error: 'Requiere claveAdmin (8 dígitos)' };
  }
  // [v2.43.52] Validar cada item antes de procesar — items malformados
  // antes se ignoraban silenciosamente y el master pensaba que se eliminaron
  var tiposValidos = { CANONICO: 1, PRESENTACION: 1, EQUIVALENTE: 1 };
  for (var vi = 0; vi < params.items.length; vi++) {
    var it = params.items[vi];
    if (!it || typeof it !== 'object') {
      return { ok: false, error: 'Item #' + (vi + 1) + ' inválido (no es objeto)' };
    }
    if (!it.id || String(it.id).trim() === '') {
      return { ok: false, error: 'Item #' + (vi + 1) + ' sin id' };
    }
    var t = String(it.tipo || '').toUpperCase();
    if (!tiposValidos[t]) {
      return { ok: false, error: 'Item #' + (vi + 1) + ' tipo inválido: ' + it.tipo };
    }
  }

  // 2) Verificar clave (tier 3) Y rol MASTER explícitamente
  var auth = verificarClaveAdmin({
    clave:        params.claveAdmin,
    accion:       'PURGAR_CATALOGO',
    refDocumento: params.items.length + ' items',
    appOrigen:    params.appOrigen || 'MOS',
    dispositivo:  params.dispositivo || '',
    detalle:      params.detalle || '',
    deviceId:     params.deviceId || ''
  });
  if (!auth.ok) return auth;
  if (!auth.data || !auth.data.autorizado) {
    return { ok: false, error: (auth.data && auth.data.error) || 'No autorizado' };
  }
  // Solo MASTER puede ejecutar — enforce explícito (verificarClaveAdmin permite admin también)
  if (String(auth.data.rol || '').toUpperCase() !== 'MASTER') {
    return { ok: false, error: 'Solo MASTER puede ejecutar esta acción. Tu rol: ' + auth.data.rol };
  }

  // 3) Procesar bajo lock para no romper el catálogo en concurrencia
  var lock = LockService.getDocumentLock();
  try { lock.waitLock(15000); } catch(_) { return { ok: false, error: 'Lock timeout' }; }
  try {
    var resultado = _procesarEliminacionItems(params.items, {
      idPersonal: auth.data.idPersonal,
      nombre:     auth.data.nombre,
      detalle:    params.detalle || ''
    });
    // [v2.43.52] Si el procesamiento detectó huérfanos, devolver error
    // controlado al frontend (no eliminó nada — los huérfanos bloquearon)
    if (resultado && resultado._purgaIntegridadFail) {
      return {
        ok: false,
        error: resultado.mensaje,
        huerfanos: resultado.huerfanos,
        codigo: 'INTEGRIDAD'
      };
    }
    return { ok: true, data: resultado };
  } catch(e) {
    return { ok: false, error: e.message };
  } finally {
    try { lock.releaseLock(); } catch(_) {}
  }
}

// ── 3. Procesamiento interno ────────────────────────────────────────
function _procesarEliminacionItems(items, ctx) {
  var hojaPM   = getSheet('PRODUCTOS_MASTER');
  var hojaEQ   = getSheet('EQUIVALENCIAS');
  var hojaAUD  = _garantizarHojaPurgasHistoricas();

  // Resolver índices en PRODUCTOS_MASTER
  var pmData = hojaPM.getDataRange().getValues();
  var pmHdrs = pmData[0];
  var pmIdxId  = pmHdrs.indexOf('idProducto');
  var pmIdxSku = pmHdrs.indexOf('skuBase');
  var pmIdxCb  = pmHdrs.indexOf('codigoBarra');

  // Resolver índices en EQUIVALENCIAS
  var eqData = hojaEQ ? hojaEQ.getDataRange().getValues() : [[]];
  var eqHdrs = eqData[0] || [];
  var eqIdxId  = eqHdrs.indexOf('idEquiv');
  var eqIdxCb  = eqHdrs.indexOf('codigoBarra');
  var eqIdxSku = eqHdrs.indexOf('skuBase');

  // Mapas idProducto/idEquiv → rowIndex (1-based para sheet API)
  var pmRowsToDelete = []; // [{row, snapshot}]
  var eqRowsToDelete = []; // [{row, snapshot}]
  var idsNoEncontrados = [];

  items.forEach(function(it) {
    var tipo = String(it.tipo || '').toUpperCase();
    if (tipo === 'CANONICO' || tipo === 'PRESENTACION') {
      // Buscar en PRODUCTOS_MASTER
      var found = false;
      for (var i = 1; i < pmData.length; i++) {
        if (String(pmData[i][pmIdxId]) === String(it.id)) {
          pmRowsToDelete.push({ row: i + 1, snapshot: _filaToObj(pmHdrs, pmData[i]) });
          found = true;
          break;
        }
      }
      if (!found) idsNoEncontrados.push(it.id + ' (' + tipo + ')');
    } else if (tipo === 'EQUIVALENTE') {
      // Buscar en EQUIVALENCIAS
      var foundEq = false;
      for (var j = 1; j < eqData.length; j++) {
        if (String(eqData[j][eqIdxId]) === String(it.id)) {
          eqRowsToDelete.push({ row: j + 1, snapshot: _filaToObj(eqHdrs, eqData[j]) });
          foundEq = true;
          break;
        }
      }
      if (!foundEq) idsNoEncontrados.push(it.id + ' (EQUIVALENTE)');
    }
  });

  // [v2.43.52] Validación integridad: si eliminás un canónico, sus presentaciones
  // y equivalentes deben estar incluidos en el batch — si no, quedan huérfanos.
  // Master debe seleccionar TODO el grupo.
  var canonicosAEliminar = {};
  pmRowsToDelete.forEach(function(r) {
    var p = r.snapshot;
    var f = parseFloat(p.factorConversion) || 1;
    if (f === 1) canonicosAEliminar[String(p.idProducto)] = String(p.skuBase || p.idProducto);
  });
  var huerfanosBloqueantes = [];
  Object.keys(canonicosAEliminar).forEach(function(canId) {
    var skuBaseDelCan = canonicosAEliminar[canId];
    // Presentaciones (mismo skuBase, factor != 1) que NO estén en el batch
    for (var pi = 1; pi < pmData.length; pi++) {
      var sb = String(pmData[pi][pmIdxSku] || '').trim();
      if (sb !== skuBaseDelCan) continue;
      var idProdRow = String(pmData[pi][pmIdxId]);
      if (idProdRow === canId) continue;  // el canónico mismo
      // ¿Está en el batch?
      var enBatch = pmRowsToDelete.some(function(r){ return String(r.snapshot.idProducto) === idProdRow; });
      if (!enBatch) huerfanosBloqueantes.push(idProdRow + ' (presentación de ' + canId + ')');
    }
    // Equivalentes con ese skuBase no incluidos
    for (var ej = 1; ej < eqData.length; ej++) {
      var skuEq = String(eqData[ej][eqIdxSku] || '').trim();
      if (skuEq !== skuBaseDelCan) continue;
      var idEqRow = String(eqData[ej][eqIdxId]);
      var enBatchEq = eqRowsToDelete.some(function(r){ return String(r.snapshot.idEquiv) === idEqRow; });
      if (!enBatchEq) huerfanosBloqueantes.push(idEqRow + ' (equivalente de ' + skuBaseDelCan + ')');
    }
  });
  if (huerfanosBloqueantes.length) {
    return {
      _purgaIntegridadFail: true,
      huerfanos: huerfanosBloqueantes,
      mensaje: 'Si eliminas el canónico debes incluir también sus presentaciones/equivalentes (' +
               huerfanosBloqueantes.length + ' huérfanos)'
    };
  }

  // Registrar snapshots en PURGAS_HISTORICAS ANTES de eliminar
  // (si la eliminación falla, el snapshot queda como evidencia del intento)
  var ts = new Date();
  var idLote = _generateId('PRG');
  pmRowsToDelete.forEach(function(r) {
    hojaAUD.appendRow([
      ts, idLote, ctx.idPersonal, ctx.nombre,
      'PRODUCTOS_MASTER', r.snapshot.idProducto || '',
      r.snapshot.skuBase || '', r.snapshot.codigoBarra || '',
      r.snapshot.descripcion || '',
      JSON.stringify(r.snapshot), ctx.detalle
    ]);
  });
  eqRowsToDelete.forEach(function(r) {
    hojaAUD.appendRow([
      ts, idLote, ctx.idPersonal, ctx.nombre,
      'EQUIVALENCIAS', r.snapshot.idEquiv || '',
      r.snapshot.skuBase || '', r.snapshot.codigoBarra || '',
      r.snapshot.descripcion || r.snapshot.descEquiv || '',
      JSON.stringify(r.snapshot), ctx.detalle
    ]);
  });

  // Eliminar filas (de mayor a menor para no desincronizar índices)
  pmRowsToDelete.sort(function(a, b){ return b.row - a.row; })
                 .forEach(function(r){ hojaPM.deleteRow(r.row); });
  eqRowsToDelete.sort(function(a, b){ return b.row - a.row; })
                 .forEach(function(r){ hojaEQ.deleteRow(r.row); });

  // [dual-write] Propagar el BORRADO a la sombra (best-effort; Sheets = verdad). El sync horario es
  // solo-upsert → NO borra por sí solo, así que sin esto las filas purgadas quedarían FANTASMA en
  // mos.productos / mos.equivalencias. 'eq.' es el operador PostgREST obligatorio (sin él → HTTP 400).
  pmRowsToDelete.forEach(function(r) {
    var idp = r.snapshot && r.snapshot.idProducto;
    if (!idp) return;
    try {
      var _dp = _sbDelete('mos.productos', { id_producto: 'eq.' + String(idp) });
      if (!_dp.ok) Logger.log('[purga dualWrite] _sbDelete mos.productos ' + idp + ' HTTP ' + _dp.code + ' ' + (_dp.error || ''));
    } catch (e) { Logger.log('[purga dualWrite] _sbDelete mos.productos ' + idp + ' excepción: ' + e); }
  });
  eqRowsToDelete.forEach(function(r) {
    var ide = r.snapshot && r.snapshot.idEquiv;
    if (!ide) return;
    try {
      var _de = _sbDelete('mos.equivalencias', { id_equiv: 'eq.' + String(ide) });
      if (!_de.ok) Logger.log('[purga dualWrite] _sbDelete mos.equivalencias ' + ide + ' HTTP ' + _de.code + ' ' + (_de.error || ''));
    } catch (e) { Logger.log('[purga dualWrite] _sbDelete mos.equivalencias ' + ide + ' excepción: ' + e); }
  });

  return {
    idLote:               idLote,
    eliminadosProductos:  pmRowsToDelete.length,
    eliminadosEquivs:     eqRowsToDelete.length,
    idsNoEncontrados:     idsNoEncontrados,
    timestamp:            ts.toISOString()
  };
}

// ── 4. Helpers ──────────────────────────────────────────────────────
function _filaToObj(hdrs, row) {
  var obj = {};
  hdrs.forEach(function(h, i) { obj[h] = row[i]; });
  return obj;
}

function _garantizarHojaPurgasHistoricas() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName('PURGAS_HISTORICAS');
  if (!sh) {
    sh = ss.insertSheet('PURGAS_HISTORICAS');
    sh.appendRow([
      'fecha', 'idLote', 'idPersonalMaster', 'nombreMaster',
      'tabla', 'idFila', 'skuBase', 'codigoBarra', 'descripcion',
      'snapshotJson', 'detalle'
    ]);
    sh.getRange(1, 1, 1, 11).setFontWeight('bold').setBackground('#7f1d1d').setFontColor('#fee2e2');
    sh.setFrozenRows(1);
  }
  return sh;
}
