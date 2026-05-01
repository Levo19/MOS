// ============================================================
// ProyectoMOS — Promociones.gs
// CRUD de PROMOCIONES escribiendo directo en la hoja PROMOCIONES
// del Spreadsheet de MosExpress (single source of truth: ME).
// MosExpress sigue leyendo desde su propia hoja, MOS solo administra.
//
// Schema PROMOCIONES (ME):
//   SKU_Base | Tipo_Promo | Cant_Min | Valor_Promo
//
// Tipos soportados (compatibles con ME):
//   GRUPO       → "Lleva N por S/ X" (Cant_Min=N, Valor_Promo = precio unit en promo)
//   PORCENTAJE  → "% descuento desde N unidades" (Cant_Min=N, Valor_Promo = % dcto)
//
// Extensión opcional (columnas adicionales que ME ignora pero MOS muestra):
//   Descripcion | Vigencia_Desde | Vigencia_Hasta | Activa | Notas
// ============================================================

function _getPromocionesSheet() {
  var ss    = SpreadsheetApp.openById(_getProp('ME_SS_ID'));
  var sheet = ss.getSheetByName('PROMOCIONES');
  if (!sheet) {
    sheet = ss.insertSheet('PROMOCIONES');
    sheet.appendRow([
      'SKU_Base', 'Tipo_Promo', 'Cant_Min', 'Valor_Promo',
      'Descripcion', 'Vigencia_Desde', 'Vigencia_Hasta', 'Activa', 'Notas',
      'idPromo', 'Items_JSON'
    ]);
    sheet.setFrozenRows(1);
  } else {
    // Asegurar que las columnas extra existan (idempotente)
    var headers = sheet.getRange(1, 1, 1, Math.max(sheet.getLastColumn(), 4)).getValues()[0];
    var extras  = ['Descripcion', 'Vigencia_Desde', 'Vigencia_Hasta', 'Activa', 'Notas', 'idPromo', 'Items_JSON'];
    extras.forEach(function(h){
      if (headers.indexOf(h) < 0) {
        var col = sheet.getLastColumn() + 1;
        sheet.getRange(1, col).setValue(h);
        headers.push(h);
      }
    });
  }
  return sheet;
}

function _promoToObj(row, headers) {
  var o = {};
  headers.forEach(function(h, i){ o[h] = row[i]; });
  var items = [];
  if (o.Items_JSON) {
    try { items = JSON.parse(o.Items_JSON); if (!Array.isArray(items)) items = []; } catch(_){ items = []; }
  }
  return {
    idPromo:        o.idPromo || o.SKU_Base,
    skuBase:        o.SKU_Base,
    tipo:           o.Tipo_Promo,
    cantMin:        parseFloat(o.Cant_Min) || 0,
    valorPromo:     parseFloat(o.Valor_Promo) || 0,
    items:          items,
    descripcion:    o.Descripcion || '',
    vigenciaDesde:  o.Vigencia_Desde || '',
    vigenciaHasta:  o.Vigencia_Hasta || '',
    activa:         o.Activa === false || String(o.Activa) === '0' || String(o.Activa).toLowerCase() === 'false' ? false : true,
    notas:          o.Notas || ''
  };
}

// Lee todas las promociones (incluye inactivas, MosExpress filtra por su lado)
function getPromociones(params) {
  try {
    var sheet = _getPromocionesSheet();
    var data  = sheet.getDataRange().getValues();
    if (data.length < 2) return { ok: true, data: [] };
    var headers = data[0];
    var rows = data.slice(1).filter(function(r){ return r[0]; }).map(function(r){
      return _promoToObj(r, headers);
    });
    if (params && params.activa) {
      rows = rows.filter(function(r){ return r.activa; });
    }
    return { ok: true, data: rows };
  } catch(e) {
    return { ok: false, error: 'Error promociones: ' + e.message };
  }
}

function crearPromocion(params) {
  var tipo = String(params.tipo || '').toUpperCase();
  if (tipo !== 'GRUPO' && tipo !== 'PORCENTAJE' && tipo !== 'COMBO') {
    return { ok: false, error: 'tipo debe ser GRUPO, PORCENTAJE o COMBO' };
  }
  if (tipo === 'COMBO') {
    if (!params.items || !Array.isArray(params.items) || !params.items.length) {
      return { ok: false, error: 'COMBO requiere lista de items' };
    }
  } else {
    if (!params.skuBase) return { ok: false, error: 'skuBase requerido' };
  }

  var sheet = _getPromocionesSheet();
  var headers = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  var idxs = {}; headers.forEach(function(h, i){ idxs[h] = i; });

  // Para GRUPO/PORCENTAJE: si ya existe una promo con ese SKU, reemplazar
  if (tipo !== 'COMBO') {
    var data = sheet.getDataRange().getValues();
    for (var i = 1; i < data.length; i++) {
      if (String(data[i][idxs.SKU_Base]) === String(params.skuBase)) {
        params.idPromo = data[i][idxs.idPromo] || params.skuBase;
        return actualizarPromocion(params);
      }
    }
  }

  // Generar idPromo (timestamp)
  var idPromo = params.idPromo || ('PROMO' + new Date().getTime());
  // Construir fila respetando orden de headers
  var rowArr = headers.map(function(h){
    switch(h) {
      case 'SKU_Base':       return tipo === 'COMBO' ? '' : (params.skuBase || '');
      case 'Tipo_Promo':     return tipo;
      case 'Cant_Min':       return parseFloat(params.cantMin) || 0;
      case 'Valor_Promo':    return parseFloat(params.valorPromo) || 0;
      case 'Descripcion':    return params.descripcion || '';
      case 'Vigencia_Desde': return params.vigenciaDesde || '';
      case 'Vigencia_Hasta': return params.vigenciaHasta || '';
      case 'Activa':         return params.activa === false || String(params.activa) === 'false' ? false : true;
      case 'Notas':          return params.notas || '';
      case 'idPromo':        return idPromo;
      case 'Items_JSON':     return tipo === 'COMBO' ? JSON.stringify(params.items || []) : '';
      default:               return '';
    }
  });
  sheet.appendRow(rowArr);
  return { ok: true, data: { idPromo: idPromo, skuBase: params.skuBase, tipo: tipo } };
}

function actualizarPromocion(params) {
  if (!params.idPromo && !params.skuBase) return { ok: false, error: 'idPromo o skuBase requerido' };
  var sheet   = _getPromocionesSheet();
  var data    = sheet.getDataRange().getValues();
  var headers = data[0];
  var idxs = {};
  headers.forEach(function(h, i){ idxs[h] = i; });
  var idxIdPromo = idxs.idPromo;
  var idxSku     = idxs.SKU_Base;

  for (var i = 1; i < data.length; i++) {
    var matchById  = idxIdPromo !== undefined && String(data[i][idxIdPromo]) === String(params.idPromo || '') && params.idPromo;
    var matchBySku = !matchById && String(data[i][idxSku]) === String(params.skuBase || '') && params.skuBase;
    if (matchById || matchBySku) {
      var fila = i + 1;
      function set(col, val) {
        if (idxs[col] !== undefined && val !== undefined) {
          sheet.getRange(fila, idxs[col] + 1).setValue(val);
        }
      }
      if (params.tipo)        set('Tipo_Promo', String(params.tipo).toUpperCase());
      if (params.skuBase    !== undefined) set('SKU_Base',     params.skuBase);
      if (params.cantMin    !== undefined) set('Cant_Min',     parseFloat(params.cantMin)    || 0);
      if (params.valorPromo !== undefined) set('Valor_Promo',  parseFloat(params.valorPromo) || 0);
      if (params.descripcion !== undefined)   set('Descripcion',    params.descripcion);
      if (params.vigenciaDesde !== undefined) set('Vigencia_Desde', params.vigenciaDesde);
      if (params.vigenciaHasta !== undefined) set('Vigencia_Hasta', params.vigenciaHasta);
      if (params.activa !== undefined)        set('Activa',         params.activa === false || String(params.activa) === 'false' ? false : true);
      if (params.notas !== undefined)         set('Notas',          params.notas);
      if (params.items !== undefined)         set('Items_JSON',     Array.isArray(params.items) ? JSON.stringify(params.items) : '');
      return { ok: true, data: { idPromo: params.idPromo, skuBase: params.skuBase } };
    }
  }
  return { ok: false, error: 'Promoción no encontrada' };
}

function eliminarPromocion(params) {
  if (!params.idPromo && !params.skuBase) return { ok: false, error: 'idPromo o skuBase requerido' };
  var sheet = _getPromocionesSheet();
  var data  = sheet.getDataRange().getValues();
  var headers = data[0];
  var idxs = {}; headers.forEach(function(h, i){ idxs[h] = i; });
  for (var i = 1; i < data.length; i++) {
    var byId  = params.idPromo && idxs.idPromo !== undefined && String(data[i][idxs.idPromo]) === String(params.idPromo);
    var bySku = !byId && params.skuBase && String(data[i][idxs.SKU_Base]) === String(params.skuBase);
    if (byId || bySku) {
      sheet.deleteRow(i + 1);
      return { ok: true };
    }
  }
  return { ok: false, error: 'Promoción no encontrada' };
}
