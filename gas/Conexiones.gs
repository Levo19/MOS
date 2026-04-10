// ============================================================
// ProyectoMOS — Conexiones.gs
// Bridge de datos entre MOS y las apps hijas.
//
// ESTRATEGIA:
//  - LECTURA directa por SS_ID (mismo Google account, sin HTTP)
//  - ESCRITURA vía GAS URL (respeta lógica de negocio de cada app)
//
// Para activar warehouseMos:
//   Script Properties de este proyecto → WH_SS_ID + WH_GAS_URL
//
// Para activar MosExpress (Phase 2):
//   Script Properties → ME_SS_ID + ME_GAS_URL
// ============================================================

function _getProp(key) {
  return PropertiesService.getScriptProperties().getProperty(key) || '';
}

function _abrirWhSheet(nombreHoja) {
  var ssId = _getProp('WH_SS_ID');
  if (!ssId) throw new Error('WH_SS_ID no configurado. Ir a Script Properties de ProyectoMOS.');
  return SpreadsheetApp.openById(ssId).getSheetByName(nombreHoja);
}

function _abrirMeSheet(nombreHoja) {
  var ssId = _getProp('ME_SS_ID');
  if (!ssId) throw new Error('ME_SS_ID no configurado (Phase 2 — MosExpress pendiente).');
  return SpreadsheetApp.openById(ssId).getSheetByName(nombreHoja);
}

function _sheetToObjectsLocal(sheet) {
  var data = sheet.getDataRange().getValues();
  if (data.length < 2) return [];
  var headers = data[0];
  return data.slice(1).map(function(row) {
    var obj = {};
    headers.forEach(function(h, i) {
      var v = row[i];
      obj[h] = v instanceof Date ? Utilities.formatDate(v, Session.getScriptTimeZone(), 'yyyy-MM-dd') : v;
    });
    return obj;
  }).filter(function(obj) {
    return Object.values(obj).some(function(v){ return v !== '' && v !== null && v !== undefined; });
  });
}

// ════════════════════════════════════════════════
// LECTURA DESDE warehouseMos
// ════════════════════════════════════════════════

function getStockWarehouse(params) {
  try {
    var stock    = _sheetToObjectsLocal(_abrirWhSheet('STOCK'));
    var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
    var prodMap = {};
    productos.forEach(function(p){ prodMap[p.idProducto] = p; });

    stock = stock.map(function(s) {
      var p = prodMap[s.codigoProducto] || {};
      s.descripcion  = p.descripcion || s.codigoProducto;
      s.skuBase      = p.skuBase     || '';
      s.stockMinimo  = p.stockMinimo || 0;
      s.alertaMinimo = parseFloat(s.cantidadDisponible) < parseFloat(p.stockMinimo || 0);
      return s;
    });

    if (params && params.soloAlertas === 'true') {
      stock = stock.filter(function(s){ return s.alertaMinimo; });
    }
    return { ok: true, data: stock };
  } catch(e) {
    return { ok: false, error: 'warehouseMos no conectado: ' + e.message };
  }
}

function getAlertasWarehouse() {
  try {
    var lotes = _sheetToObjectsLocal(_abrirWhSheet('LOTES_VENCIMIENTO'));
    var hoy   = new Date();
    var diasAlerta = 30;

    lotes.forEach(function(l) {
      if (l.fechaVencimiento && l.estado === 'ACTIVO') {
        l.diasRestantes = Math.ceil((new Date(l.fechaVencimiento) - hoy) / (1000*60*60*24));
      } else {
        l.diasRestantes = 9999;
      }
    });

    var activos = lotes.filter(function(l){
      return l.diasRestantes <= diasAlerta && parseFloat(l.cantidadActual) > 0;
    });
    activos.sort(function(a,b){ return a.diasRestantes - b.diasRestantes; });

    return {
      ok: true,
      data: {
        criticos: activos.filter(function(l){ return l.diasRestantes <= 7; }),
        alertas:  activos.filter(function(l){ return l.diasRestantes > 7; })
      }
    };
  } catch(e) {
    return { ok: false, error: 'warehouseMos no conectado: ' + e.message };
  }
}

function getMermasWarehouse(params) {
  try {
    var rows = _sheetToObjectsLocal(_abrirWhSheet('MERMAS'));
    if (params && params.estado) {
      rows = rows.filter(function(r){ return String(r.estado) === String(params.estado); });
    }
    return { ok: true, data: rows };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

function getEnvasadosWarehouse(params) {
  try {
    var rows = _sheetToObjectsLocal(_abrirWhSheet('ENVASADOS'));
    if (params && params.limit) rows = rows.slice(-parseInt(params.limit));
    return { ok: true, data: rows };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

function getGuiasWarehouse(params) {
  try {
    var rows = _sheetToObjectsLocal(_abrirWhSheet('GUIAS'));
    if (params && params.tipo)   rows = rows.filter(function(r){ return r.tipo === params.tipo; });
    if (params && params.estado) rows = rows.filter(function(r){ return r.estado === params.estado; });
    if (params && params.mes) {
      rows = rows.filter(function(r){ return (r.fecha || '').toString().startsWith(params.mes); });
    }
    return { ok: true, data: rows };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

// ════════════════════════════════════════════════
// LECTURA DESDE MosExpress (Phase 2)
// ════════════════════════════════════════════════

function getVentasMosExpress(params) {
  try {
    var ventas = _sheetToObjectsLocal(_abrirMeSheet('VENTAS'));
    if (params && params.fecha) {
      ventas = ventas.filter(function(v){ return (v.fecha || '').startsWith(params.fecha); });
    }
    return { ok: true, data: ventas };
  } catch(e) {
    return { ok: false, error: 'MosExpress no conectado: ' + e.message };
  }
}

// ════════════════════════════════════════════════
// ANÁLISIS CRUZADO
// ════════════════════════════════════════════════

// Rotación = ventas del mes / stock actual → días de cobertura
function getRotacionProductos(params) {
  try {
    var stockRes = getStockWarehouse(params || {});
    if (!stockRes.ok) return stockRes;

    var ventasMap = {};
    try {
      var mes = params && params.mes
        ? params.mes  // 'YYYY-MM'
        : Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM');

      var ventasRes = getVentasMosExpress({ fecha: mes });
      if (ventasRes.ok) {
        ventasRes.data.forEach(function(v) {
          var key = v.skuBase || v.codigoBarra || v.codigoProducto || '';
          if (!ventasMap[key]) ventasMap[key] = 0;
          ventasMap[key] += parseFloat(v.cantidad || v.cantidadVendida || 0);
        });
      }
    } catch(e) {
      // MosExpress no conectado aún — rotación sin ventas
    }

    var rotacion = stockRes.data.map(function(s) {
      var vendidasMes = ventasMap[s.skuBase] || ventasMap[s.codigoProducto] || 0;
      var diasCobertura = vendidasMes > 0
        ? Math.round(parseFloat(s.cantidadDisponible) / vendidasMes * 30)
        : null;
      return {
        codigoProducto: s.codigoProducto,
        descripcion:    s.descripcion,
        skuBase:        s.skuBase,
        stockActual:    s.cantidadDisponible,
        vendidasMes:    vendidasMes,
        diasCobertura:  diasCobertura,
        alertaMinimo:   s.alertaMinimo
      };
    });

    // Más críticos primero (menos cobertura)
    rotacion.sort(function(a, b) {
      var da = a.diasCobertura === null ? 9999 : a.diasCobertura;
      var db = b.diasCobertura === null ? 9999 : b.diasCobertura;
      return da - db;
    });

    return { ok: true, data: rotacion };
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

// ════════════════════════════════════════════════
// ESCRITURA HACIA warehouseMos (vía GAS URL)
// Usar solo cuando la operación debe pasar por
// la lógica de negocio de warehouseMos
// ════════════════════════════════════════════════

function postToWarehouse(action, params) {
  var url = _getProp('WH_GAS_URL');
  if (!url) return { ok: false, error: 'WH_GAS_URL no configurado' };
  try {
    var payload = JSON.stringify(Object.assign({ action: action }, params));
    var res = UrlFetchApp.fetch(url, {
      method: 'post',
      contentType: 'text/plain',
      payload: payload,
      muteHttpExceptions: true
    });
    return JSON.parse(res.getContentText());
  } catch(e) {
    return { ok: false, error: e.message };
  }
}

// ════════════════════════════════════════════════
// GESTIÓN DE CONEXIONES
// ════════════════════════════════════════════════

function getConexiones() {
  return { ok: true, data: _sheetToObjects(getSheet('CONEXIONES')) };
}

function setConexion(params) {
  var sheet = getSheet('CONEXIONES');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];

  for (var i = 1; i < data.length; i++) {
    if (data[i][0] !== params.idApp) continue;

    if (params.gasUrl) sheet.getRange(i+1, hdrs.indexOf('gasUrl')+1).setValue(params.gasUrl);
    if (params.ssId)   sheet.getRange(i+1, hdrs.indexOf('ssId')+1).setValue(params.ssId);
    if (params.activo !== undefined) sheet.getRange(i+1, hdrs.indexOf('activo')+1).setValue(params.activo);
    sheet.getRange(i+1, hdrs.indexOf('ultimaSync')+1).setValue(new Date());

    // Sincronizar también en Script Properties para acceso directo
    var propMap = {
      warehouseMos: { gasUrl: 'WH_GAS_URL', ssId: 'WH_SS_ID' },
      mosExpress:   { gasUrl: 'ME_GAS_URL', ssId: 'ME_SS_ID' }
    };
    var props = propMap[params.idApp];
    if (props) {
      var updates = {};
      if (params.gasUrl) updates[props.gasUrl] = params.gasUrl;
      if (params.ssId)   updates[props.ssId]   = params.ssId;
      if (Object.keys(updates).length) {
        PropertiesService.getScriptProperties().setProperties(updates);
      }
    }
    return { ok: true };
  }
  return { ok: false, error: 'Conexión no encontrada: ' + params.idApp };
}
