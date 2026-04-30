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
      'Descripcion', 'Vigencia_Desde', 'Vigencia_Hasta', 'Activa', 'Notas'
    ]);
    sheet.setFrozenRows(1);
  } else {
    // Asegurar que las columnas extra existan (idempotente)
    var headers = sheet.getRange(1, 1, 1, Math.max(sheet.getLastColumn(), 4)).getValues()[0];
    var extras  = ['Descripcion', 'Vigencia_Desde', 'Vigencia_Hasta', 'Activa', 'Notas'];
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
  return {
    skuBase:        o.SKU_Base,
    tipo:           o.Tipo_Promo,
    cantMin:        parseFloat(o.Cant_Min) || 0,
    valorPromo:     parseFloat(o.Valor_Promo) || 0,
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
  if (!params.skuBase) return { ok: false, error: 'skuBase requerido' };
  if (!params.tipo)    return { ok: false, error: 'tipo requerido (GRUPO o PORCENTAJE)' };
  var tipo = String(params.tipo).toUpperCase();
  if (tipo !== 'GRUPO' && tipo !== 'PORCENTAJE') {
    return { ok: false, error: 'tipo debe ser GRUPO o PORCENTAJE' };
  }
  var sheet = _getPromocionesSheet();
  // Verificar si ya existe una promo con ese SKU y reemplazarla (1 promo por sku)
  var data = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === String(params.skuBase)) {
      // Sobrescribir
      return actualizarPromocion(params);
    }
  }
  sheet.appendRow([
    params.skuBase,
    tipo,
    parseFloat(params.cantMin)    || 0,
    parseFloat(params.valorPromo) || 0,
    params.descripcion   || '',
    params.vigenciaDesde || '',
    params.vigenciaHasta || '',
    params.activa === false || String(params.activa) === 'false' ? false : true,
    params.notas || ''
  ]);
  return { ok: true, data: { skuBase: params.skuBase } };
}

function actualizarPromocion(params) {
  if (!params.skuBase) return { ok: false, error: 'skuBase requerido' };
  var sheet   = _getPromocionesSheet();
  var data    = sheet.getDataRange().getValues();
  var headers = data[0];
  var idxs = {};
  headers.forEach(function(h, i){ idxs[h] = i; });

  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === String(params.skuBase)) {
      var fila = i + 1;
      // Solo actualizar campos que vengan en params
      function set(col, val) {
        if (idxs[col] !== undefined && val !== undefined) {
          sheet.getRange(fila, idxs[col] + 1).setValue(val);
        }
      }
      if (params.tipo)        set('Tipo_Promo', String(params.tipo).toUpperCase());
      if (params.cantMin    !== undefined) set('Cant_Min',    parseFloat(params.cantMin)    || 0);
      if (params.valorPromo !== undefined) set('Valor_Promo', parseFloat(params.valorPromo) || 0);
      if (params.descripcion !== undefined)   set('Descripcion',    params.descripcion);
      if (params.vigenciaDesde !== undefined) set('Vigencia_Desde', params.vigenciaDesde);
      if (params.vigenciaHasta !== undefined) set('Vigencia_Hasta', params.vigenciaHasta);
      if (params.activa !== undefined)        set('Activa',         params.activa === false || String(params.activa) === 'false' ? false : true);
      if (params.notas !== undefined)         set('Notas',          params.notas);
      return { ok: true, data: { skuBase: params.skuBase } };
    }
  }
  return { ok: false, error: 'Promoción no encontrada para skuBase ' + params.skuBase };
}

function eliminarPromocion(params) {
  if (!params.skuBase) return { ok: false, error: 'skuBase requerido' };
  var sheet = _getPromocionesSheet();
  var data  = sheet.getDataRange().getValues();
  for (var i = 1; i < data.length; i++) {
    if (String(data[i][0]) === String(params.skuBase)) {
      sheet.deleteRow(i + 1);
      return { ok: true };
    }
  }
  return { ok: false, error: 'Promoción no encontrada' };
}
