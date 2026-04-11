// ============================================================
// ProyectoMOS — Setup.gs
// Ejecutar setupMOS() UNA sola vez para crear el Spreadsheet
// maestro del ecosistema InversionMos.
// ============================================================

var MOS_SHEET_NAMES = {
  CONFIG_MOS:           'CONFIG_MOS',
  PRODUCTOS_MASTER:     'PRODUCTOS_MASTER',
  EQUIVALENCIAS:        'EQUIVALENCIAS',
  PROVEEDORES_MASTER:   'PROVEEDORES_MASTER',
  HISTORIAL_PRECIOS:    'HISTORIAL_PRECIOS',
  PEDIDOS_PROVEEDOR:    'PEDIDOS_PROVEEDOR',
  PAGOS_PROVEEDOR:      'PAGOS_PROVEEDOR',
  CONEXIONES:           'CONEXIONES',
  ALERTAS_LOG:          'ALERTAS_LOG',
  // ── Configuración centralizada del ecosistema ──────────────
  ESTACIONES:           'ESTACIONES',          // Zonas/cajas ME + almacenes WH
  IMPRESORAS:           'IMPRESORAS',           // PrintNode IDs por estación
  SERIES_DOCUMENTALES:  'SERIES_DOCUMENTALES', // NV/Boleta/Factura por estación
  PERSONAL_MASTER:      'PERSONAL_MASTER'      // OPERADORES(WH) + VENDEDORES(ME)
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
  ALERTAS_LOG:       ['id','tipo','urgencia','mensaje','appOrigen','datos','fecha','leida'],

  // Estaciones físicas: cajas MosExpress + almacenes warehouseMos
  // adminPin: PIN para anulaciones/créditos en ME, o edición sensible en WH
  ESTACIONES:          ['idEstacion','idZona','nombre','tipo','appOrigen','adminPin','activo','descripcion'],

  // Dispositivos PrintNode (ticket o adhesivo) por estación
  // printNodeId: vacío hasta que se configure — reemplaza Script Properties de WH
  IMPRESORAS:          ['idImpresora','nombre','printNodeId','tipo','idEstacion','idZona','appOrigen','activo','descripcion'],

  // Series documentales para NubeFact/SUNAT por estación
  SERIES_DOCUMENTALES: ['idSerie','idEstacion','idZona','tipoDocumento','serie','correlativo','activo'],

  // Personal unificado: OPERADORES(WH, PIN fijo) + vendedores(ME, nombre libre, sin cuenta)
  PERSONAL_MASTER:     ['idPersonal','nombre','apellido','tipo','appOrigen','rol','pin','color','tarifaHora','montoBase','estado','fechaIngreso','foto']
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
  _seedEstaciones(ss);
  _seedImpresoras(ss);
  _seedSeriesDocumentales(ss);
  _seedPersonalMaster(ss);
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
    ['VERSION',            '1.0.0',         'Versión del sistema MOS'],
    ['PIN_ADMIN_WH',       '0000',          'PIN administrador warehouseMos — autoriza ajustes, auditorías y edición de documentos']
  ];
  sheet.getRange(2, 1, rows.length, 3).setValues(rows);
}

// ============================================================
// SEED — ESTACIONES
// Zonas de MosExpress (CAJA) + almacenes de warehouseMos (ALMACEN)
// ============================================================
function _seedEstaciones(ss) {
  var sheet = ss.getSheetByName(MOS_SHEET_NAMES.ESTACIONES);
  // idEstacion | idZona | nombre | tipo | appOrigen | adminPin | activo | descripcion
  var rows = [
    ['ES001','ZONA-01','Caja Central 01','CAJA','mosExpress','666','1','POS estación 1 — Zona Central'],
    ['ES002','ZONA-01','Caja Central 02','CAJA','mosExpress','666','1','POS estación 2 — Zona Central'],
    ['ES003','ZONA-02','Pasillo Pedidos','CAJA','mosExpress','666','1','POS pedidos — Zona Pasillo'],
    ['ES004','ALMACEN','Almacén Central','ALMACEN','warehouseMos','','1','Almacén operacional InversionMos']
  ];
  sheet.getRange(2, 1, rows.length, MOS_HEADERS.ESTACIONES.length).setValues(rows);
}

// ============================================================
// SEED — IMPRESORAS
// PrintNode IDs de MosExpress (reales) + placeholders de warehouseMos
// ============================================================
function _seedImpresoras(ss) {
  var sheet = ss.getSheetByName(MOS_SHEET_NAMES.IMPRESORAS);
  // idImpresora | nombre | printNodeId | tipo | idEstacion | idZona | appOrigen | activo | descripcion
  var rows = [
    ['IMP001','Ticket Caja 01','75338007','TICKET','ES001','ZONA-01','mosExpress','1','Impresora ticket Caja Central 01'],
    ['IMP002','Ticket Caja 02','723457',  'TICKET','ES002','ZONA-01','mosExpress','1','Impresora ticket Caja Central 02'],
    ['IMP003','Ticket Pasillo','75287158','TICKET','ES003','ZONA-02','mosExpress','1','Impresora ticket Pasillo Pedidos'],
    ['IMP004','Etiquetas Almacén','',     'ADHESIVO','ES004','ALMACEN','warehouseMos','1','Impresora etiquetas adhesivas almacén — completar PrintNode ID'],
    ['IMP005','Tickets Almacén','',       'TICKET',  'ES004','ALMACEN','warehouseMos','1','Impresora tickets/reportes almacén — completar PrintNode ID']
  ];
  sheet.getRange(2, 1, rows.length, MOS_HEADERS.IMPRESORAS.length).setValues(rows);
}

// ============================================================
// SEED — SERIES DOCUMENTALES
// NV/Boleta/Factura por estación (datos del cliente)
// ============================================================
function _seedSeriesDocumentales(ss) {
  var sheet = ss.getSheetByName(MOS_SHEET_NAMES.SERIES_DOCUMENTALES);
  // idSerie | idEstacion | idZona | tipoDocumento | serie | correlativo | activo
  var rows = [
    // Estación ES001 (Caja Central 01) — ZONA-01
    ['SER001','ES001','ZONA-01','NOTA_VENTA','NV01',1,'1'],
    ['SER002','ES001','ZONA-01','BOLETA',    'B001',1,'1'],
    ['SER003','ES001','ZONA-01','FACTURA',   'F001',1,'1'],
    // Estación ES002 (Caja Central 02) — ZONA-01
    ['SER004','ES002','ZONA-01','NOTA_VENTA','NV01',1,'1'],
    ['SER005','ES002','ZONA-01','BOLETA',    'B001',1,'1'],
    ['SER006','ES002','ZONA-01','FACTURA',   'F001',1,'1'],
    // Estación ES003 (Pasillo Pedidos) — ZONA-02
    ['SER007','ES003','ZONA-02','NOTA_VENTA','NV02',1,'1'],
    ['SER008','ES003','ZONA-02','BOLETA',    'B002',1,'1'],
    ['SER009','ES003','ZONA-02','FACTURA',   'F002',1,'1']
  ];
  sheet.getRange(2, 1, rows.length, MOS_HEADERS.SERIES_DOCUMENTALES.length).setValues(rows);
}

// ============================================================
// SEED — PERSONAL MASTER
// Solo OPERADORES de warehouseMos (empleados fijos con PIN).
// Los vendedores/cajeros de MosExpress usan nombres libres → no tienen cuenta.
// ============================================================
function _seedPersonalMaster(ss) {
  var sheet = ss.getSheetByName(MOS_SHEET_NAMES.PERSONAL_MASTER);
  var hoy = new Date();
  // idPersonal | nombre | apellido | tipo | appOrigen | rol | pin | color | tarifaHora | montoBase | estado | fechaIngreso | foto
  var rows = [
    ['OP001','Carlos','Ramos', 'OPERADOR','warehouseMos','ALMACENERO','1234','#3b82f6',5.00,1200,'1',hoy,''],
    ['OP002','Ana',   'Torres','OPERADOR','warehouseMos','ENVASADOR', '5678','#22c55e',4.50,1100,'1',hoy,''],
    ['OP003','Luis',  'Medina','OPERADOR','warehouseMos','ALMACENERO','9012','#f59e0b',5.00,1200,'1',hoy,'']
  ];
  sheet.getRange(2, 1, rows.length, MOS_HEADERS.PERSONAL_MASTER.length).setValues(rows);
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
