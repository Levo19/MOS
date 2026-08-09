// Genera _me_dup_db.json: catalogo de prueba con las FAMILIAS REALES de codigo duplicado.
import fs from 'fs';
const ZONA = 'TIENDA 1';
const ITEMS = [
  ['CABALLO DE ORO AZUL PASTA WANTAN 500GR', '7758725000036A', 5.50],
  ['CABALLO DE ORO DORADO WANTAN 500GR',     '7758725000036B', 5.80],
  ['LA CHINA TAMARINDO',        '7750464444799',  3.20],
  ['FOCH SALSA DE SOYA',        '7750464444799A', 4.10],
  ['FOCH ACEITE DE AJONJOLI',   '7750464444799B', 8.90],
  ['FOCH VINAGRE DE ARROZ',     '7750464444799C', 6.40],
  ['FOCH SALSA DE OSTION',      '7750464444799D', 7.30],
  ['SIBARITA OREGANO ENTERO',   '737186519674O',  2.10],
  ['SIBARITA ROMERO ENTERO',    '737186519674R',  2.30],
  ['ARROZ COSTENO EXTRA 750G',  '7751000000001',  4.50],
  ['LECHE GLORIA EVAPORADA 400G','7751000000002',  4.20],
  ['GASEOSA INKA KOLA 3L',      '7751000000003', 10.50]
];
const PRODUCTO_BASE = [], PRESENTACIONES = [], STOCK_ZONAS = [];
ITEMS.forEach(([nombre, cod, precio], i) => {
  const sku = 'SKU' + String(i + 1).padStart(3, '0');
  PRODUCTO_BASE.push({ SKU_Base: sku, Nombre: nombre, Cod_SUNAT: '', Tipo_IGV: 1, Unidad_Medida: 'NIU', Foto: '', Categoria: { categoria: 'ABARROTES', subcategoria: 'ABARROTES' } });
  PRESENTACIONES.push({ SKU_Base: sku, SKU: sku + '-U', Cod_Barras: cod, Factor: 1, Empaque: 'UNIDAD', Descripcion: 'UNIDAD', Precio_Venta: precio });
  STOCK_ZONAS.push({ Zona_ID: ZONA, Cod_Barras: cod, Cantidad: 10 + i });
});
const ZONAS_CONFIG = [{ idEstacion: 'EST-TEST-1', Zona_ID: ZONA, Estacion_Nombre: 'Caja-01', PrintNode_ID: '0', Serie_Boleta: 'BM01', Serie_Factura: 'FM01' }];
fs.writeFileSync('./_me_dup_db.json', JSON.stringify({ PRODUCTO_BASE, PRESENTACIONES, EQUIVALENCIAS: [], STOCK_ZONAS, PROMOCIONES: [], ZONAS_CONFIG, CLIENTES_FRECUENTES: [] }, null, 1));
console.log('ok', PRODUCTO_BASE.length, 'productos');
