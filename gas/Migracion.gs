// ============================================================
// ProyectoMOS — Migracion.gs
// Migra PRODUCTO_BASE + PRESENTACIONES + EQUIVALENCIAS
// desde el Spreadsheet de MosExpress hacia PRODUCTOS_MASTER
// y EQUIVALENCIAS de ProyectoMOS.
//
// Estructura real confirmada de ME:
//   PRODUCTO_BASE:  SKU_Base | Nombre | Categoria | Cod_Tributo |
//                   IGV_Porcentaje | Cod_SUNAT | Tipo_IGV | Unidad_Medida
//   PRESENTACIONES: Cod_Barras | SKU_Base | Empaque | Factor | Precio_Venta
//   EQUIVALENCIAS:  Cod_Alias | Cod_Barras_Real
//
// JOIN:  PRESENTACIONES hereda SUNAT del PRODUCTO_BASE (via SKU_Base)
//        EQUIVALENCIAS resuelve skuBase buscando Cod_Barras_Real en PRESENTACIONES
//
// Requisitos previos:
//   1. setupMOS() ya ejecutado
//   2. Script Properties de ProyectoMOS:
//      ME_SS_ID = <ID del Google Sheet de MosExpress>
//
// Cómo ejecutar:
//   1. verificarColumnasME() — solo lectura, confirma columnas
//   2. migrarDesdeMosExpress() — migra todo
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

function _buildHeaderMap(headerRow) {
  var m = {};
  headerRow.forEach(function(h, i) { m[String(h).trim()] = i; });
  return m;
}

function _col(row, headerMap, name) {
  var idx = headerMap[name];
  if (idx === undefined) return '';
  var v = row[idx];
  return (v === null || v === undefined) ? '' : v;
}

// ============================================================
// VERIFICACIÓN — solo lectura
// ============================================================
function verificarColumnasME() {
  var meSsId = PropertiesService.getScriptProperties().getProperty('ME_SS_ID');
  if (!meSsId) throw new Error('ME_SS_ID no configurado en Script Properties de ProyectoMOS.');
  var meSS = SpreadsheetApp.openById(meSsId);
  ['PRODUCTO_BASE','PRESENTACIONES','EQUIVALENCIAS'].forEach(function(nombre) {
    var sh = meSS.getSheetByName(nombre);
    if (!sh) { Logger.log(nombre + ': NO ENCONTRADA'); return; }
    var headers = sh.getRange(1,1,1,sh.getLastColumn()).getValues()[0];
    Logger.log('');
    Logger.log(nombre + '  (' + (sh.getLastRow()-1) + ' filas de datos)');
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
  if (!meSsId)  throw new Error('ME_SS_ID no configurado.');
  if (!mosSsId) throw new Error('SPREADSHEET_ID no encontrado. Ejecuta setupMOS() primero.');

  var meSS  = SpreadsheetApp.openById(meSsId);
  var mosSS = SpreadsheetApp.openById(mosSsId);
  var hoy   = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');

  var stats = { basesNuevas:0, basesDup:0, derivadasNuevas:0, derivadasDup:0,
                equivNuevas:0, equivDup:0, errores:[] };

  // ── 1. IDs ya existentes en PRODUCTOS_MASTER ─────────────────
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

  // ── 2. Leer PRODUCTO_BASE ─────────────────────────────────────
  // Columnas: SKU_Base | Nombre | Categoria | Cod_Tributo |
  //           IGV_Porcentaje | Cod_SUNAT | Tipo_IGV | Unidad_Medida
  var baseSheet = meSS.getSheetByName('PRODUCTO_BASE');
  if (!baseSheet) throw new Error('PRODUCTO_BASE no encontrada en ME.');
  var baseData = baseSheet.getDataRange().getValues();
  var bH = _buildHeaderMap(baseData[0]);
  Logger.log('PRODUCTO_BASE: ' + (baseData.length-1) + ' filas');

  // Mapa skuBase → objeto con campos SUNAT (para que PRESENTACIONES los herede)
  var baseMap = {};
  var nuevasFilas = [];

  for (var r = 1; r < baseData.length; r++) {
    var b = baseData[r];
    var idBase = String(_col(b, bH, 'SKU_Base')).trim();
    if (!idBase) continue;

    var baseObj = {
      descripcion:  String(_col(b, bH, 'Nombre')).trim(),
      categoria:    String(_col(b, bH, 'Categoria')).trim(),
      codTributo:   String(_col(b, bH, 'Cod_Tributo') || '1000').trim(),
      igvPct:       parseFloat(_col(b, bH, 'IGV_Porcentaje')) || 18,
      codSunat:     String(_col(b, bH, 'Cod_SUNAT') || '10000000').trim(),
      tipoIgv:      parseInt(_col(b, bH, 'Tipo_IGV'))   || 1,
      unidadMedida: String(_col(b, bH, 'Unidad_Medida') || 'NIU').trim()
    };
    baseMap[idBase] = baseObj;

    if (yaExiste[idBase]) { stats.basesDup++; continue; }

    nuevasFilas.push([
      idBase,             // idProducto
      idBase,             // skuBase (auto-referencia)
      '',                 // codigoBarra (vacío: barcodes van en presentaciones)
      baseObj.descripcion,
      '',                 // marca (no existe en ME)
      baseObj.categoria,
      '',                 // unidad de almacén (no existe en ME — warehouseMos la llenará)
      0,                  // precioVenta → 0 (el precio vive en cada presentación)
      0,                  // precioCosto (no existe en ME)
      baseObj.codTributo,
      baseObj.igvPct,
      baseObj.codSunat,
      baseObj.tipoIgv,
      baseObj.unidadMedida,
      '1',                // estado activo
      '0',                // esEnvasable (se ajusta manualmente en WH si aplica)
      '',                 // codigoProductoBase → vacío (ES el base)
      '',                 // factorConversion   → vacío (ES el base)
      0, 0, 0, '',
      hoy,
      'MIGRACION_ME'
    ]);
    yaExiste[idBase] = true;
    stats.basesNuevas++;
  }
  Logger.log('Bases nuevas: ' + stats.basesNuevas + ' | Duplicadas: ' + stats.basesDup);

  // ── 3. Leer PRESENTACIONES ────────────────────────────────────
  // Columnas: Cod_Barras | SKU_Base | Empaque | Factor | Precio_Venta
  // ► idProducto = Cod_Barras  (no hay SKU propio — el barcode ES el ID)
  // ► Nombre = "Descripcion_Base Empaque"  (construido)
  var presSheet = meSS.getSheetByName('PRESENTACIONES');
  if (!presSheet) {
    stats.errores.push('PRESENTACIONES no encontrada — se omite.');
  } else {
    var presData = presSheet.getDataRange().getValues();
    var pH = _buildHeaderMap(presData[0]);
    Logger.log('PRESENTACIONES: ' + (presData.length-1) + ' filas');

    for (var r2 = 1; r2 < presData.length; r2++) {
      var p = presData[r2];

      var codBarras = String(_col(p, pH, 'Cod_Barras')).trim();
      var skuBase   = String(_col(p, pH, 'SKU_Base')).trim();
      if (!codBarras || !skuBase) continue;

      // idProducto = Cod_Barras (único por presentación)
      var idPres = codBarras;
      if (yaExiste[idPres]) { stats.derivadasDup++; continue; }

      var empaque     = String(_col(p, pH, 'Empaque') || '').trim();
      var factor      = parseFloat(_col(p, pH, 'Factor'))      || 1;
      var precioVenta = parseFloat(_col(p, pH, 'Precio_Venta')) || 0;

      // Nombre construido: "Descripcion_Base Empaque"
      var base        = baseMap[skuBase] || {};
      var nombreBase  = base.descripcion || skuBase;
      var nombre      = empaque ? (nombreBase + ' ' + empaque) : nombreBase;

      // SUNAT: heredado del base
      var codTributo  = base.codTributo   || '1000';
      var igvPct      = base.igvPct       || 18;
      var codSunat    = base.codSunat     || '10000000';
      var tipoIgv     = base.tipoIgv      || 1;
      var unidadMed   = base.unidadMedida || 'NIU';
      var categoria   = base.categoria    || '';

      try {
        nuevasFilas.push([
          idPres,       // idProducto = Cod_Barras
          skuBase,      // skuBase → agrupa presentaciones del mismo base
          codBarras,    // codigoBarra = mismo Cod_Barras
          nombre,       // descripcion construida
          '',           // marca
          categoria,    // hereda del base
          empaque,      // unidad (BOLSA, CAJA, SACO, etc.)
          precioVenta,  // ← precio real de venta de esta presentación
          0,            // precioCosto (no disponible en ME)
          codTributo,
          igvPct,
          codSunat,
          tipoIgv,
          unidadMed,
          '1',          // estado
          '0',          // esEnvasable
          skuBase,      // codigoProductoBase
          factor,       // ← factor de conversión
          0, 0, 0, '',
          hoy,
          'MIGRACION_ME'
        ]);
        yaExiste[idPres] = true;
        stats.derivadasNuevas++;
      } catch(ex) {
        stats.errores.push('PRES fila '+(r2+1)+' ('+idPres+'): '+ex.message);
      }
    }
    Logger.log('Derivadas nuevas: ' + stats.derivadasNuevas + ' | Duplicadas: ' + stats.derivadasDup);
  }

  // ── 4. Escritura en lote — bloques de 500 ────────────────────
  if (nuevasFilas.length > 0) {
    var BLOQUE      = 500;
    var primeraFila = pmSheet.getLastRow() + 1;
    for (var bl = 0; bl < nuevasFilas.length; bl += BLOQUE) {
      var bloque = nuevasFilas.slice(bl, bl + BLOQUE);
      pmSheet.getRange(primeraFila + bl, 1, bloque.length, _PM_COLS.length).setValues(bloque);
      Logger.log('  Bloque ' + (Math.floor(bl/BLOQUE)+1) + ' escrito (' + bloque.length + ' filas)');
    }
  } else {
    Logger.log('Nada nuevo para escribir en PRODUCTOS_MASTER.');
  }

  // ── 5. EQUIVALENCIAS ─────────────────────────────────────────
  // Columnas ME: Cod_Alias | Cod_Barras_Real
  // Lógica: Cod_Barras_Real está en PRESENTACIONES → busco su SKU_Base
  //         Resultado en MOS: skuBase=SKU_Base, codigoBarra=Cod_Alias
  var eqSrc  = meSS.getSheetByName('EQUIVALENCIAS');
  var eqDest = mosSS.getSheetByName('EQUIVALENCIAS');

  if (!eqSrc) {
    Logger.log('EQUIVALENCIAS no encontrada en ME — se omite.');
  } else if (!eqDest) {
    Logger.log('EQUIVALENCIAS no encontrada en MOS — se omite.');
  } else {
    // Mapa Cod_Barras → SKU_Base (desde PRESENTACIONES ya leída)
    var barrasABase = {};
    if (presSheet) {
      var presData2 = presSheet.getDataRange().getValues();
      var pH2 = _buildHeaderMap(presData2[0]);
      for (var pr = 1; pr < presData2.length; pr++) {
        var cb  = String(_col(presData2[pr], pH2, 'Cod_Barras')).trim();
        var sb  = String(_col(presData2[pr], pH2, 'SKU_Base')).trim();
        if (cb && sb) barrasABase[cb] = sb;
      }
    }

    var eqData    = eqSrc.getDataRange().getValues();
    var eqH       = _buildHeaderMap(eqData[0]);
    var eqDestData = eqDest.getDataRange().getValues();

    // Deduplicar por Cod_Alias
    var eqExiste = {};
    for (var ei = 1; ei < eqDestData.length; ei++) {
      if (eqDestData[ei][2]) eqExiste[String(eqDestData[ei][2])] = true;
    }

    var nuevasEq = [];
    for (var er = 1; er < eqData.length; er++) {
      var codAlias    = String(_col(eqData[er], eqH, 'Cod_Alias')).trim();
      var codReal     = String(_col(eqData[er], eqH, 'Cod_Barras_Real')).trim();
      if (!codAlias || !codReal) continue;
      if (eqExiste[codAlias]) { stats.equivDup++; continue; }

      // Buscar skuBase por Cod_Barras_Real
      var skuBaseEq = barrasABase[codReal] || codReal;

      nuevasEq.push([
        'EQ-' + er + '-' + new Date().getTime(),  // idEquiv
        skuBaseEq,   // skuBase
        codAlias,    // codigoBarra (el alias que se escanea)
        '',          // descripcion
        '1'          // activo
      ]);
      eqExiste[codAlias] = true;
      stats.equivNuevas++;
    }

    if (nuevasEq.length > 0) {
      eqDest.getRange(eqDest.getLastRow()+1, 1, nuevasEq.length, 5).setValues(nuevasEq);
    }
    Logger.log('Equivalencias nuevas: ' + stats.equivNuevas + ' | Dup: ' + stats.equivDup);
  }

  // ── 6. Resumen ────────────────────────────────────────────────
  Logger.log('');
  Logger.log('==========================================');
  Logger.log('MIGRACIÓN COMPLETADA');
  Logger.log('==========================================');
  Logger.log('Bases          → nuevas: ' + stats.basesNuevas     + '  dup: ' + stats.basesDup);
  Logger.log('Presentaciones → nuevas: ' + stats.derivadasNuevas + '  dup: ' + stats.derivadasDup);
  Logger.log('Equivalencias  → nuevas: ' + stats.equivNuevas     + '  dup: ' + stats.equivDup);
  Logger.log('Total insertados: ' + (stats.basesNuevas + stats.derivadasNuevas + stats.equivNuevas));
  if (stats.errores.length > 0) {
    Logger.log('ADVERTENCIAS (' + stats.errores.length + '):');
    stats.errores.forEach(function(e) { Logger.log('  ! ' + e); });
  }
  return stats;
}
