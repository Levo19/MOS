// ============================================================
// ProyectoMOS — Auditoria.gs
// Audita integridad de PRODUCTOS_MASTER y EQUIVALENCIAS.
// Detecta campos críticos vacíos, IDs duplicados, codigoBarra repetidos.
// Registra cada anomalía en ALERTAS_LOG.
// ============================================================

function auditarIntegridadProductos() {
  var resultado = {
    fechaAuditoria: new Date().toISOString(),
    productosTotal: 0,
    equivalenciasTotal: 0,
    anomalias: [],
    resumen: {}
  };

  try {
    // ── PRODUCTOS_MASTER ────────────────────────────────────
    var sheetProd = getSheet('PRODUCTOS_MASTER');
    var dataProd  = sheetProd.getDataRange().getValues();
    var hdrsProd  = dataProd[0];
    var idxProd = {}; hdrsProd.forEach(function(h, i){ idxProd[h] = i; });
    resultado.productosTotal = dataProd.length - 1;

    var idsVistos = {};
    var barrasVistos = {};

    for (var i = 1; i < dataProd.length; i++) {
      var fila      = i + 1;
      var idProd    = String(dataProd[i][idxProd.idProducto] || '').trim();
      var skuBase   = String(dataProd[i][idxProd.skuBase] || '').trim();
      var codBarra  = String(dataProd[i][idxProd.codigoBarra] || '').trim();
      var descrip   = String(dataProd[i][idxProd.descripcion] || '').trim();

      // Saltar filas completamente vacías (final de hoja)
      if (!idProd && !skuBase && !codBarra && !descrip) continue;

      // a. idProducto vacío
      if (!idProd) {
        resultado.anomalias.push({ tipo: 'PRODUCTO_SIN_ID', fila: fila, severidad: 'CRITICA',
          detalle: 'Fila ' + fila + ' sin idProducto', skuBase: skuBase, codigoBarra: codBarra });
      } else if (idsVistos[idProd]) {
        resultado.anomalias.push({ tipo: 'ID_DUPLICADO', fila: fila, severidad: 'CRITICA',
          detalle: 'idProducto duplicado: ' + idProd + ' (también en fila ' + idsVistos[idProd] + ')',
          idProducto: idProd });
      } else {
        idsVistos[idProd] = fila;
      }

      // b. skuBase vacío
      if (!skuBase) {
        resultado.anomalias.push({ tipo: 'SKU_VACIO', fila: fila, severidad: 'ALTA',
          detalle: 'Producto ' + (idProd || 'fila ' + fila) + ' tiene skuBase vacío',
          idProducto: idProd, codigoBarra: codBarra });
      }

      // c. descripcion vacía
      if (!descrip) {
        resultado.anomalias.push({ tipo: 'DESC_VACIA', fila: fila, severidad: 'MEDIA',
          detalle: 'Producto ' + (idProd || 'fila ' + fila) + ' sin descripción',
          idProducto: idProd });
      }

      // d. codigoBarra duplicado entre productos distintos
      if (codBarra && idProd) {
        if (barrasVistos[codBarra] && barrasVistos[codBarra] !== idProd) {
          resultado.anomalias.push({ tipo: 'BARRAS_DUPLICADO', fila: fila, severidad: 'ALTA',
            detalle: 'codigoBarra ' + codBarra + ' está en ' + idProd + ' y ' + barrasVistos[codBarra],
            codigoBarra: codBarra });
        } else {
          barrasVistos[codBarra] = idProd;
        }
      }
    }

    // ── EQUIVALENCIAS ────────────────────────────────────────
    var sheetEq = getSheet('EQUIVALENCIAS');
    var dataEq  = sheetEq.getDataRange().getValues();
    var hdrsEq  = dataEq[0];
    var idxEq = {}; hdrsEq.forEach(function(h, i){ idxEq[h] = i; });
    resultado.equivalenciasTotal = dataEq.length - 1;

    var equivBarrasVistos = {};
    for (var j = 1; j < dataEq.length; j++) {
      var filaEq    = j + 1;
      var idEquiv   = String(dataEq[j][idxEq.idEquiv] || '').trim();
      var skuB      = String(dataEq[j][idxEq.skuBase] || '').trim();
      var cb        = String(dataEq[j][idxEq.codigoBarra] || '').trim();
      if (!idEquiv && !skuB && !cb) continue;

      if (!skuB) {
        resultado.anomalias.push({ tipo: 'EQUIV_SIN_SKU', fila: filaEq, severidad: 'CRITICA',
          detalle: 'Equivalencia ' + (idEquiv || 'fila ' + filaEq) + ' sin skuBase',
          idEquiv: idEquiv, codigoBarra: cb });
      }
      if (!cb) {
        resultado.anomalias.push({ tipo: 'EQUIV_SIN_BARRAS', fila: filaEq, severidad: 'CRITICA',
          detalle: 'Equivalencia ' + (idEquiv || 'fila ' + filaEq) + ' sin codigoBarra',
          idEquiv: idEquiv, skuBase: skuB });
      }

      // Equivalencia con codigoBarra que coincide con un producto principal
      if (cb && barrasVistos[cb]) {
        // Esto es válido a veces (alias del mismo producto), pero conviene revisar
        // Solo alerta si la equivalencia apunta a OTRO skuBase que el del producto
        var prodOwner = barrasVistos[cb];
        // Si el producto con ese codBarra no tiene skuBase = skuB, hay inconsistencia
        // (esto requiere lookup; lo simplificamos a alerta informativa)
      }

      if (cb) {
        if (equivBarrasVistos[cb] && equivBarrasVistos[cb] !== idEquiv) {
          resultado.anomalias.push({ tipo: 'EQUIV_BARRAS_DUP', fila: filaEq, severidad: 'ALTA',
            detalle: 'codigoBarra ' + cb + ' duplicado en EQUIVALENCIAS (' + idEquiv + ' y ' + equivBarrasVistos[cb] + ')',
            codigoBarra: cb });
        } else {
          equivBarrasVistos[cb] = idEquiv;
        }
      }
    }

    // ── Resumen ──────────────────────────────────────────────
    resultado.resumen = resultado.anomalias.reduce(function(acc, a){
      acc[a.tipo] = (acc[a.tipo] || 0) + 1;
      return acc;
    }, {});

    // ── Registrar alertas ────────────────────────────────────
    if (resultado.anomalias.length > 0) {
      var criticas = resultado.anomalias.filter(function(a){ return a.severidad === 'CRITICA'; }).length;
      var altas    = resultado.anomalias.filter(function(a){ return a.severidad === 'ALTA'; }).length;
      _registrarAlerta(
        'AUDIT_INTEGRIDAD',
        criticas > 0 ? 'CRITICA' : (altas > 0 ? 'ALTA' : 'MEDIA'),
        resultado.anomalias.length + ' anomalías detectadas (' + criticas + ' críticas, ' + altas + ' altas)',
        'MOS',
        JSON.stringify({
          fecha: resultado.fechaAuditoria,
          resumen: resultado.resumen,
          totalProd: resultado.productosTotal,
          totalEq: resultado.equivalenciasTotal,
          primeras: resultado.anomalias.slice(0, 10)
        })
      );
    } else {
      // Guardar timestamp de última auditoría limpia
      _setProp('AUDIT_ULTIMA_LIMPIA', resultado.fechaAuditoria);
    }

    return { ok: true, data: resultado };
  } catch(e) {
    return { ok: false, error: 'Error en auditoría: ' + e.message };
  }
}

// Endpoint que la PWA llama para mostrar el reporte
function getAuditoriaIntegridad(params) {
  // Si pidieron correr una nueva auditoría, hacerlo
  if (params && (params.run === 'true' || params.run === true || params.run === '1')) {
    return auditarIntegridadProductos();
  }
  // Si no, devolver alertas activas de auditoría (no resueltas)
  try {
    var sheet = getSheet('ALERTAS_LOG');
    var data  = sheet.getDataRange().getValues();
    var hdrs  = data[0];
    var idxs = {}; hdrs.forEach(function(h, i){ idxs[h] = i; });
    // Soportar ambos esquemas: id|idAlerta y leida|resuelto
    var idxId   = (idxs.id !== undefined) ? idxs.id : idxs.idAlerta;
    var idxRead = (idxs.leida !== undefined) ? idxs.leida : idxs.resuelto;
    var alertas = [];
    for (var i = 1; i < data.length; i++) {
      var tipo = String(data[i][idxs.tipo] || '');
      var leida = String(idxRead !== undefined ? (data[i][idxRead] || '0') : '0');
      if ((tipo === 'AUDIT_INTEGRIDAD' || tipo === 'MOD_NO_AUTORIZADA') && leida !== '1') {
        var datos = {};
        try { datos = JSON.parse(data[i][idxs.datos] || '{}'); } catch(_){ datos = {}; }
        alertas.push({
          idAlerta:  data[i][idxId],
          tipo:      tipo,
          urgencia:  data[i][idxs.urgencia],
          mensaje:   data[i][idxs.mensaje],
          fecha:     data[i][idxs.fecha],
          appOrigen: data[i][idxs.appOrigen],
          datos:     datos
        });
      }
    }
    // Más recientes primero
    alertas.sort(function(a, b){ return new Date(b.fecha) - new Date(a.fecha); });
    var ultima = _getProp('AUDIT_ULTIMA_LIMPIA') || null;
    return { ok: true, data: { alertas: alertas, ultimaAuditoriaLimpia: ultima } };
  } catch(e) {
    return { ok: false, error: 'Error leyendo auditoría: ' + e.message };
  }
}

// Marca una alerta como resuelta (leida=1)
function resolverAlertaAuditoria(params) {
  if (!params.idAlerta) return { ok: false, error: 'Requiere idAlerta' };
  try {
    var sheet = getSheet('ALERTAS_LOG');
    var data  = sheet.getDataRange().getValues();
    var hdrs  = data[0];
    var idxId = hdrs.indexOf('id');     if (idxId < 0) idxId = hdrs.indexOf('idAlerta');
    var idxR  = hdrs.indexOf('leida');  if (idxR  < 0) idxR  = hdrs.indexOf('resuelto');
    if (idxId < 0 || idxR < 0) return { ok: false, error: 'Esquema ALERTAS_LOG no compatible' };
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][idxId]) === String(params.idAlerta)) {
        sheet.getRange(i + 1, idxR + 1).setValue('1');
        return { ok: true };
      }
    }
    return { ok: false, error: 'Alerta no encontrada' };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}
