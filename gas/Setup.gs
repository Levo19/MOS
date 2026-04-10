// ============================================================
// ProyectoMOS — Setup.gs
// Ejecutar setupMOS() UNA sola vez para crear el Spreadsheet
// maestro del ecosistema InversionMos.
// ============================================================

var MOS_SHEET_NAMES = {
  CONFIG_MOS:        'CONFIG_MOS',
  PRODUCTOS_MASTER:  'PRODUCTOS_MASTER',
  EQUIVALENCIAS:     'EQUIVALENCIAS',
  PROVEEDORES_MASTER:'PROVEEDORES_MASTER',
  HISTORIAL_PRECIOS: 'HISTORIAL_PRECIOS',
  PEDIDOS_PROVEEDOR: 'PEDIDOS_PROVEEDOR',
  PAGOS_PROVEEDOR:   'PAGOS_PROVEEDOR',
  CONEXIONES:        'CONEXIONES',
  ALERTAS_LOG:       'ALERTAS_LOG'
};

var MOS_HEADERS = {
  CONFIG_MOS:        ['clave','valor','descripcion'],

  // Catálogo maestro de productos
  // skuBase: clave de agrupación para MosExpress (= codigoBarra en derivados)
  // codigoBarra: barcode individual (detalle para warehouseMos)
  PRODUCTOS_MASTER:  ['idProducto','skuBase','codigoBarra','descripcion','marca',
                      'idCategoria','unidad','precioVenta','precioCosto',
                      'Cod_Tributo','IGV_Porcentaje','Cod_SUNAT','Tipo_IGV','estado',
                      'esEnvasable','codigoProductoBase','factorConversion',
                      'mermaEsperadaPct','stockMinimo','stockMaximo','zona',
                      'fechaCreacion','creadoPor'],

  // Equivalencias: barcodes alternativos que apuntan al mismo skuBase
  EQUIVALENCIAS:     ['idEquiv','skuBase','codigoBarra','descripcion','activo'],

  // Proveedor único por toda la empresa
  PROVEEDORES_MASTER:['idProveedor','nombre','ruc','imagen','telefono','banco',
                      'numeroCuenta','cci','email','diaPedido','diaPago','diaEntrega',
                      'formaPago','plazoCredito','responsable','categoriaProducto','estado'],

  // Historial cada vez que cambia el precio de un producto
  HISTORIAL_PRECIOS: ['id','skuBase','codigoBarra','descripcion',
                      'precioAnterior','precioNuevo','usuario','motivo','appOrigen','fecha'],

  // Pedidos de compra generados (manual o automático)
  PEDIDOS_PROVEEDOR: ['idPedido','idProveedor','items','montoEstimado',
                      'estado','fechaCreacion','fechaEstimada','usuario','notas'],

  // Registro de pagos a proveedores
  PAGOS_PROVEEDOR:   ['idPago','idProveedor','monto','fecha','numeroFactura',
                      'estado','observacion','registradoPor'],

  // Registry de apps hijas y sus credenciales de acceso
  CONEXIONES:        ['idApp','nombre','gasUrl','ssId','activo','ultimaSync','descripcion'],

  // Log de alertas generadas para las apps hijas o admins
  ALERTAS_LOG:       ['id','tipo','urgencia','mensaje','appOrigen','datos','fecha','leida']
};

// ============================================================
// FUNCIÓN PRINCIPAL — ejecutar una vez
// ============================================================
function setupMOS() {
  var ss = SpreadsheetApp.create('ProyectoMOS_DB');
  var ssId = ss.getId();

  PropertiesService.getScriptProperties().setProperties({
    'SPREADSHEET_ID': ssId,
    'WH_SS_ID':       '',   // ← ID Spreadsheet warehouseMos (Script Properties > warehouseMos)
    'WH_GAS_URL':     '',   // ← URL Web App warehouseMos
    'ME_SS_ID':       '',   // ← ID Spreadsheet MosExpress (futuro — Phase 2)
    'ME_GAS_URL':     ''    // ← URL Web App MosExpress (futuro — Phase 2)
  });

  Logger.log('✅ ProyectoMOS Spreadsheet creado');
  Logger.log('URL: ' + ss.getUrl());
  Logger.log('ID:  ' + ssId);

  _crearHojasMOS(ss);
  _seedConfigMOS(ss);
  _seedConexiones(ss);
  _formatearCabeceras(ss);

  Logger.log('');
  Logger.log('⚠️  Pasos siguientes:');
  Logger.log('1. Copiar ID anterior en Script Properties de warehouseMos como MOS_SS_ID');
  Logger.log('2. Ir a Script Properties de este proyecto y completar WH_SS_ID y WH_GAS_URL');
  Logger.log('3. Ejecutar setConexion desde MOS con los datos de warehouseMos');

  return ssId;
}

function _crearHojasMOS(ss) {
  // Renombrar hoja por defecto
  var defaultSheet = ss.getSheets()[0];
  defaultSheet.setName(MOS_SHEET_NAMES.CONFIG_MOS);
  defaultSheet.getRange(1, 1, 1, MOS_HEADERS.CONFIG_MOS.length)
              .setValues([MOS_HEADERS.CONFIG_MOS]);

  Object.keys(MOS_SHEET_NAMES).forEach(function(key) {
    if (key === 'CONFIG_MOS') return;
    var sheet = ss.insertSheet(MOS_SHEET_NAMES[key]);
    if (MOS_HEADERS[key]) {
      sheet.getRange(1, 1, 1, MOS_HEADERS[key].length).setValues([MOS_HEADERS[key]]);
    }
  });
}

function _formatearCabeceras(ss) {
  ss.getSheets().forEach(function(sheet) {
    var lastCol = sheet.getLastColumn();
    if (lastCol < 1) return;
    sheet.getRange(1, 1, 1, lastCol)
         .setBackground('#0f3460')
         .setFontColor('#e2e8f0')
         .setFontWeight('bold')
         .setFontSize(10);
    sheet.setFrozenRows(1);
    sheet.setColumnWidths(1, lastCol, 150);
  });
}

function _seedConfigMOS(ss) {
  var sheet = ss.getSheetByName(MOS_SHEET_NAMES.CONFIG_MOS);
  var rows = [
    ['EMPRESA_NOMBRE',     'InversionMos',  'Nombre de la empresa'],
    ['EMPRESA_RUC',        '',              'RUC de la empresa'],
    ['DIAS_ALERTA_VENC',   '30',            'Días alerta vencimiento (compartido con WH)'],
    ['STOCK_ALERTA_PCT',   '20',            'Alerta cuando stock < X% del máximo'],
    ['AUTO_PEDIDO',        'false',         'Generar pedidos automáticos al llegar a stock mínimo'],
    ['MARGEN_MIN_PCT',     '25',            'Margen mínimo aceptable en precio de venta (%)'],
    ['VERSION',            '1.0.0',         'Versión del sistema MOS']
  ];
  sheet.getRange(2, 1, rows.length, 3).setValues(rows);
}

function _seedConexiones(ss) {
  var sheet = ss.getSheetByName(MOS_SHEET_NAMES.CONEXIONES);
  // Las URLs/IDs se completan en Script Properties y luego con setConexion()
  var rows = [
    ['warehouseMos', 'Almacén Central',  '', '', '0', '',
     'warehouseMos PWA — gestión de stock, guías, envasado, mermas'],
    ['mosExpress',   'Punto de Venta',   '', '', '0', '',
     'MosExpress POS — ventas, caja, turnos (Phase 2)']
  ];
  sheet.getRange(2, 1, rows.length, MOS_HEADERS.CONEXIONES.length).setValues(rows);
}
