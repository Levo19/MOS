// ============================================================
// ProyectoMOS — Migracion.gs
// Migra PRODUCTO_BASE + PRESENTACIONES + EQUIVALENCIAS
// desde el Spreadsheet de MosExpress hacia PRODUCTOS_MASTER
// y EQUIVALENCIAS de ProyectoMOS.
//
// Lógica de JOIN:
//   PRODUCTO_BASE  → filas base (precio=0, factor vacío)
//                    + datos SUNAT (Tipo_IGV, Unidad_Medida, Cod_SUNAT)
//   PRESENTACIONES → filas derivadas con precio y factor propios,
//                    heredando SUNAT del base vía SKU_Base
//   EQUIVALENCIAS  → se copia directo a MOS
//
// Requisitos previos:
//   1. setupMOS() ya ejecutado
//   2. Script Properties de ProyectoMOS:
//      ME_SS_ID = <ID del Google Sheet de MosExpress>
//
// Cómo ejecutar:
//   1. verificarColumnasME() primero (solo lectura, no escribe)
//   2. migrarDesdeMosExpress() para migrar
//   Es seguro re-ejecutar: duplicados se omiten.
// ============================================================

var _PM_COLS = [
  'idProducto','skuBase','codigoBarra','descripcion','marca',
  'idCategoria','unidad','precioVenta','precioCosto',
  'Cod_Tributo','IGV_Porcentaje','Cod_SUNAT','Tipo_IGV','Unidad_Medida',
  'estado','esEnvasable','codigoProductoBase','factorConversion',
  'mermaEsperadaPct','stockMinimo','stockMaximo','zona',
  'fechaCreacion','creadoPor'
];

// ── Primer valor no-vacío entre los nombres de columna dados ────────────────
function _v(row, headerMap, nombres, defVal) {
  for (var i = 0; i < nombres.length; i++) {
    var idx = headerMap[nombres[i]];
    if (idx !== undefined) {
      var val = row[idx];
      if (val !== '' && val !== null && val !== undefined) return val;
    }
  }
  return defVal !== undefined ? defVal : '';
}

function _buildHeaderMap(headerRow) {
  var m = {};
  headerRow.forEach(function(h, i) { m[String(h).trim()] = i; });
  return m;
}

// ============================================================
// VERIFICACIÓN — ejecutar antes de migrar (solo lectura)
// ============================================================
function verificarColumnasME() {
  var meSsId = PropertiesService.getScriptProperties().getProperty('ME_SS_ID');
  if (!meSsId) throw new Error('ME_SS_ID no configurado en Script Properties de ProyectoMOS.');

  var meSS = SpreadsheetApp.openById(meSsId);

  ['PRODUCTO_BASE', 'PRESENTACIONES', 'EQUIVALENCIAS'].forEach(function(nombre) {
    var sh = meSS.getSheetByName(nombre);
    if (!sh) { Logger.log(nombre + ': *** NO ENCONTRADA ***'); return; }
    var headers = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
    Logger.log('');
    Logger.log(nombre + '  (' + (sh.getLastRow() - 1) + ' filas de datos)');
    Logger.log('  Columnas: ' + headers.map(function(h,i){ return i+'='+h; }).join(' | '));
  });
}

// ============================================================
// MIGRACIÓN PRINCIPAL
// ============================================================
function migrarDesdeMosExpress() {
  var props   = PropertiesService.getScriptProperties();
  var meSsId  = props.getProperty('ME_SS_ID');
  var mosSsId = props.getProperty('SPREADSHEET_ID');

  if (!meSsId)  throw new Error('ME_SS_ID no configurado en Script Properties de ProyectoMOS.');
  if (!mosSsId) throw new Error('SPREADSHEET_ID no encontrado. Ejecuta setupMOS() primero.');

  var meSS  = SpreadsheetApp.openById(meSsId);
  var mosSS = SpreadsheetApp.openById(mosSsId);
  var hoy   = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');

  var stats = { basesNuevas:0, basesDup:0, derivadasNuevas:0, derivadasDup:0,
                equivNuevas:0, equivDup:0, errores:[] };

  // ── 1. IDs ya existentes en PRODUCTOS_MASTER (para deduplicar) ─────────────
  var pmSheet = mosSS.getSheetByName('PRODUCTOS_MASTER');
  if (!pmSheet) throw new Error('PRODUCTOS_MASTER no encontrada en MOS.');

  var pmData  = pmSheet.getDataRange().getValues();
  var pmIdIdx = _buildHeaderMap(pmData[0])['idProducto'];
  var yaExiste = {};
  for (var i = 1; i < pmData.length; i++) {
    var eid = String(pmData[i][pmIdIdx] || '').trim();
    if (eid) yaExiste[eid] = true;
  }
  Logger.log('Productos ya en MOS: ' + Object.keys(yaExiste).length);

  // ── 2. Leer PRODUCTO_BASE → mapa SUNAT + filas base ────────────────────────
  var baseSheet = meSS.getSheetByName('PRODUCTO_BASE');
  if (!baseSheet) throw new Error('Hoja PRODUCTO_BASE no encontrada en ME.');

  var baseData = baseSheet.getDataRange().getValues();
  var bH       = _buildHeaderMap(baseData[0]);
  Logger.log('PRODUCTO_BASE: ' + (baseData.length - 1) + ' filas');

  // Mapa SKU_Base → objeto con todos los campos del base
  // Necesario para que PRESENTACIONES herede SUNAT, marca, categoría, etc.
  var baseMap = {};   // key: skuBase  →  value: objeto con campos del base

  var nuevasFilas = [];

  for (var r = 1; r < baseData.length; r++) {
    var b     = baseData[r];
    var idBase = String(_v(b, bH, ['SKU_Base','SKU','idProducto','ID'], '')).trim();
    if (!idBase) continue;

    var baseObj = {
      id:            idBase,
      descripcion:   String(_v(b, bH, ['Nombre','descripcion','Descripcion'], '')).trim(),
      marca:         String(_v(b, bH, ['Marca','marca'], '')).trim(),
      categoria:     String(_v(b, bH, ['Categoria','categoria','idCategoria'], '')).trim(),
      unidad:        String(_v(b, bH, ['Unidad','unidad','UnidadAlmacen'], 'KG')).trim(),
      precioCosto:   parseFloat(_v(b, bH, ['Costo','costo','Costo_Base','precioCosto'], 0)) || 0,
      codTributo:    String(_v(b, bH, ['Cod_Tributo','CodTributo'], '1000')).trim() || '1000',
      igvPct:        parseFloat(_v(b, bH, ['IGV_Porcentaje','IGV','igv'], 18)) || 18,
      codSunat:      String(_v(b, bH, ['Cod_SUNAT','CodSUNAT','cod_sunat'], '10000000')).trim() || '10000000',
      tipoIgv:       parseInt(_v(b, bH, ['Tipo_IGV','TipoIGV','tipoIgv'], 1)) || 1,
      unidadMedida:  String(_v(b, bH, ['Unidad_Medida','UnidadMedida'], 'NIU')).trim() || 'NIU',
      estado:        String(_v(b, bH, ['Estado','estado','Activo'], '1')).trim() || '1',
      esEnvasable:   String(_v(b, bH, ['esEnvasable','EsEnvasable','Envasable'], '0')).trim() || '0',
      merma:         parseFloat(_v(b, bH, ['mermaEsperadaPct','MermaEsperada','Merma_Pct'], 0)) || 0,
      stockMin:      parseFloat(_v(b, bH, ['stockMinimo','StockMinimo','Stock_Min'], 0)) || 0,
      stockMax:      parseFloat(_v(b, bH, ['stockMaximo','StockMaximo','Stock_Max'], 0)) || 0,
      zona:          String(_v(b, bH, ['zona','Zona','almacen'], '')).trim()
    };

    baseMap[idBase] = baseObj;

    if (yaExiste[idBase]) { stats.basesDup++; continue; }

    // Fila base: precioVenta=0 (el precio real vive en las presentaciones)
    nuevasFilas.push([
      idBase,              // idProducto
      idBase,              // skuBase  (auto-referencia: el base es su propio grupo)
      '',                  // codigoBarra (vacío: el barcode va en las presentaciones)
      baseObj.descripcion,
      baseObj.marca,
      baseObj.categoria,
      baseObj.unidad,
      0,                   // precioVenta → 0, el precio real está en cada presentación
      baseObj.precioCosto,
      baseObj.codTributo,
      baseObj.igvPct,
      baseObj.codSunat,
      baseObj.tipoIgv,
      baseObj.unidadMedida,
      baseObj.estado,
      baseObj.esEnvasable,
      '',                  // codigoProductoBase → vacío (ES el base)
      '',                  // factorConversion   → vacío (ES el base)
      baseObj.merma,
      baseObj.stockMin,
      baseObj.stockMax,
      baseObj.zona,
      hoy,
      'MIGRACION_ME'
    ]);
    yaExiste[idBase] = true;
    stats.basesNuevas++;
  }
  Logger.log('Bases nuevas: ' + stats.basesNuevas + ' | Duplicadas: ' + stats.basesDup);

  // ── 3. Leer PRESENTACIONES → filas derivadas con JOIN al base ──────────────
  var presSheet = meSS.getSheetByName('PRESENTACIONES');
  if (!presSheet) {
    stats.errores.push('Hoja PRESENTACIONES no encontrada — se omite.');
  } else {
    var presData = presSheet.getDataRange().getValues();
    var pH       = _buildHeaderMap(presData[0]);
    Logger.log('PRESENTACIONES: ' + (presData.length - 1) + ' filas');

    for (var r2 = 1; r2 < presData.length; r2++) {
      var p = presData[r2];

      var idPres  = String(_v(p, pH, ['SKU','sku','idProducto','ID_Presentacion','Cod_Interno'], '')).trim();
      var skuBase = String(_v(p, pH, ['SKU_Base','skuBase','SKU_BASE','Cod_Base'], '')).trim();
      if (!idPres || !skuBase) continue;

      if (yaExiste[idPres]) { stats.derivadasDup++; continue; }

      // ── JOIN: traer campos SUNAT + categoría + marca desde el base ──────────
      var base = baseMap[skuBase] || {};
      // Si no hay base en el mapa, usar defaults seguros
      var tipoIgv     = parseInt(_v(p, pH, ['Tipo_IGV','TipoIGV'],        base.tipoIgv      || 1));
      var unidadMed   = String( _v(p, pH, ['Unidad_Medida','UnidadMedida'], base.unidadMedida || 'NIU')).trim();
      var codSunat    = String( _v(p, pH, ['Cod_SUNAT','CodSUNAT'],         base.codSunat     || '10000000')).trim();
      var codTributo  = String( _v(p, pH, ['Cod_Tributo','CodTributo'],     base.codTributo   || '1000')).trim();
      var igvPct      = parseFloat(_v(p, pH, ['IGV_Porcentaje','IGV'],      base.igvPct       || 18));
      var marca       = String( _v(p, pH, ['Marca','marca'],                base.marca        || '')).trim();
      var categoria   = String( _v(p, pH, ['Categoria','categoria'],        base.categoria    || '')).trim();

      // ── Campos propios de la presentación ────────────────────────────────────
      var precioVenta = parseFloat(_v(p, pH, ['Precio','Precio_Venta','precioVenta','Precio_Unitario','P_Venta'], 0)) || 0;
      var precioCosto = parseFloat(_v(p, pH, ['Costo','costo','precioCosto','Costo_Unit','P_Costo'],             0)) || 0;
      var factor      = parseFloat(_v(p, pH, ['Factor','factor','factorConversion','Factor_Conv','FACTOR'],      1)) || 1;
      var empaque     = String( _v(p, pH, ['Empaque','empaque','Unidad','unidad','TipoEmpaque'], 'UNIDAD')).trim();
      var codBarras   = String( _v(p, pH, ['Cod_Barras','Cod_Barras_Real','codigoBarra','EAN','Barcode'], '')).trim();
      var nombre      = String( _v(p, pH, ['Nombre','descripcion','Descripcion','NOMBRE'], '')).trim();
      var estado      = String( _v(p, pH, ['Estado','estado','Activo'], base.estado || '1')).trim() || '1';

      try {
        nuevasFilas.push([
          idPres,         // idProducto  (SKU único de la presentación)
          skuBase,        // skuBase     (agrupa todas las presentaciones del mismo base)
          codBarras,      // codigoBarra (barcode escaneado en caja)
          nombre,         // descripcion
          marca,          // hereda del base si no está en presentaciones
          categoria,      // hereda del base si no está en presentaciones
          empaque,        // unidad de almacén para WH (BOLSA / CAJA / SACO…)
          precioVenta,    // ← precio real de venta de esta presentación
          precioCosto,    // ← costo de esta presentación
          codTributo,     // hereda del base
          igvPct,         // hereda del base
          codSunat,       // hereda del base
          tipoIgv,        // hereda del base (1=Gravado / 2=Exonerado / 3=Inafecto)
          unidadMed,      // hereda del base (NIU / KGM / ZZ…)
          estado,
          '0',            // esEnvasable: las presentaciones no se envasan (el base sí)
          skuBase,        // codigoProductoBase → apunta al base
          factor,         // ← factor de conversión (ej. 1, 5, 25 para KG)
          0,              // mermaEsperadaPct
          0,              // stockMinimo
          0,              // stockMaximo
          '',             // zona
          hoy,
          'MIGRACION_ME'
        ]);
        yaExiste[idPres] = true;
        stats.derivadasNuevas++;
      } catch(ex) {
        stats.errores.push('PRES fila ' + (r2+1) + ' (' + idPres + '): ' + ex.message);
      }
    }
    Logger.log('Derivadas nuevas: ' + stats.derivadasNuevas + ' | Duplicadas: ' + stats.derivadasDup);
  }

  // ── 4. Escritura en lote (bloques de 500 para evitar timeout) ─────────────
  if (nuevasFilas.length > 0) {
    var BLOQUE        = 500;
    var primeraFila   = pmSheet.getLastRow() + 1;
    for (var b2 = 0; b2 < nuevasFilas.length; b2 += BLOQUE) {
      var bloque = nuevasFilas.slice(b2, b2 + BLOQUE);
      pmSheet.getRange(primeraFila + b2, 1, bloque.length, _PM_COLS.length).setValues(bloque);
      Logger.log('  Escrito bloque ' + (Math.floor(b2/BLOQUE)+1) + ': filas ' + (primeraFila+b2) + '–' + (primeraFila+b2+bloque.length-1));
    }
  } else {
    Logger.log('Nada nuevo para escribir en PRODUCTOS_MASTER.');
  }

  // ── 5. EQUIVALENCIAS ──────────────────────────────────────────────────────
  var eqSrc  = meSS.getSheetByName('EQUIVALENCIAS');
  var eqDest = mosSS.getSheetByName('EQUIVALENCIAS');

  if (!eqSrc) {
    Logger.log('EQUIVALENCIAS no encontrada en ME — se omite.');
  } else if (!eqDest) {
    Logger.log('EQUIVALENCIAS no encontrada en MOS — se omite.');
  } else {
    var eqData = eqSrc.getDataRange().getValues();
    var eqH    = _buildHeaderMap(eqData[0]);

    // Deduplicar por par (skuBase + codigoBarra)
    var eqDestData = eqDest.getDataRange().getValues();
    var eqExiste   = {};
    for (var ei = 1; ei < eqDestData.length; ei++) {
      eqExiste[String(eqDestData[ei][1]||'') + '|' + String(eqDestData[ei][2]||'')] = true;
    }

    var nuevasEq = [];
    for (var er = 1; er < eqData.length; er++) {
      var eq      = eqData[er];
      var eqBase  = String(_v(eq, eqH, ['SKU_Base','skuBase','SKU_BASE','Cod_Base'], '')).trim();
      var eqBarr  = String(_v(eq, eqH, ['Cod_Barras','codigoBarra','Cod_Barras_Real','EAN','Barcode'], '')).trim();
      if (!eqBase || !eqBarr) continue;

      var eqKey = eqBase + '|' + eqBarr;
      if (eqExiste[eqKey]) { stats.equivDup++; continue; }

      var eqId = String(_v(eq, eqH, ['idEquiv','ID_Equiv','id','ID'], '')).trim();
      if (!eqId) eqId = 'EQ-' + er + '-' + new Date().getTime();

      nuevasEq.push([
        eqId,
        eqBase,
        eqBarr,
        String(_v(eq, eqH, ['descripcion','Descripcion','Nombre'], '')).trim(),
        String(_v(eq, eqH, ['activo','Activo','Estado'], '1')).trim() || '1'
      ]);
      eqExiste[eqKey] = true;
      stats.equivNuevas++;
    }

    if (nuevasEq.length > 0) {
      eqDest.getRange(eqDest.getLastRow() + 1, 1, nuevasEq.length, 5).setValues(nuevasEq);
    }
    Logger.log('Equivalencias nuevas: ' + stats.equivNuevas + ' | Dup: ' + stats.equivDup);
  }

  // ── 6. Resumen ────────────────────────────────────────────────────────────
  Logger.log('');
  Logger.log('==========================================');
  Logger.log('MIGRACIÓN COMPLETADA');
  Logger.log('==========================================');
  Logger.log('Bases        → nuevas: '     + stats.basesNuevas      + '  dup: ' + stats.basesDup);
  Logger.log('Presentaciones → nuevas: '   + stats.derivadasNuevas  + '  dup: ' + stats.derivadasDup);
  Logger.log('Equivalencias → nuevas: '    + stats.equivNuevas      + '  dup: ' + stats.equivDup);
  Logger.log('Total insertados: '          + (stats.basesNuevas + stats.derivadasNuevas + stats.equivNuevas));
  if (stats.errores.length > 0) {
    Logger.log('');
    Logger.log('ADVERTENCIAS (' + stats.errores.length + '):');
    stats.errores.forEach(function(e) { Logger.log('  ! ' + e); });
  }

  return stats;
}
