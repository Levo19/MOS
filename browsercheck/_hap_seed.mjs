// Semilla compartida: deja ME con sesión de PRUEBA (vendedor TEST CLAUDE, caja local)
// y un catálogo falso en IndexedDB. NUNCA escribe en el servidor: se bloquean todos los
// POST/PATCH/DELETE a Supabase salvo los del gate de dispositivo.
export const DEV = '7e57c1a0-de1c-4a7e-b0de-c47a10906476';
export const ZONA = 'TIENDA 1';

const P = (sku, nombre, cat, precio, stock, npres, um, foto) => ({ sku, nombre, cat, precio, stock, npres, um, foto });
const CATALOGO = [
  P('SKU001', 'ARROZ COSTEÑO EXTRA 750G', 'ABARROTES', 4.5, 12, 3, 'NIU'),
  P('SKU002', 'ACEITE PRIMOR PREMIUM BOTELLA 900 ML', 'ACEITES Y VINAGRES', 11.9, 0, 4, 'NIU'),
  P('SKU003', 'LECHE GLORIA EVAPORADA ENTERA TARRO 400G', 'LACTEOS', 4.2, 8, 1, 'NIU'),
  P('SKU004', 'AZUCAR RUBIA A GRANEL', 'ABARROTES', 3.8, 25.5, 2, 'KGM'),
  P('SKU005', 'GASEOSA INKA KOLA 3L', 'BEBIDAS', 10.5, 0, 6, 'NIU'),
  P('SKU006', 'DETERGENTE BOLIVAR FLORAL 780G', 'LIMPIEZA', 9.9, 5, 1, 'NIU'),
  P('SKU007', 'ATUN FLORIDA FILETE EN ACEITE VEGETAL 170G', 'CONSERVAS', 6.9, 3, 2, 'NIU'),
  P('SKU008', 'PANETON DONOFRIO CAJA 900G', 'PANADERIA', 24.9, 2, 1, 'NIU'),
  P('SKU009', 'KIWICHA REAL A GRANEL', 'ABARROTES', 12, 9.25, 1, 'KGM'),
  P('SKU010', 'FIDEOS DON VITTORIO SPAGUETTI 500G', 'ABARROTES', 3.6, 40, 3, 'NIU'),
  P('SKU011', 'PAPEL HIGIENICO ELITE x4', 'LIMPIEZA', 7.5, 0, 2, 'NIU'),
  P('SKU012', 'GALLETA SODA FIELD PAQUETE', 'GALLETAS', 1, 60, 2, 'NIU')
];

export function buildDb() {
  const PRODUCTO_BASE = [], PRESENTACIONES = [], STOCK_ZONAS = [], EQUIVALENCIAS = [];
  CATALOGO.forEach((p, i) => {
    PRODUCTO_BASE.push({
      SKU_Base: p.sku, Nombre: p.nombre, Cod_SUNAT: '', Tipo_IGV: 1,
      Unidad_Medida: p.um, Foto: '', Categoria: { categoria: p.cat, subcategoria: p.cat }
    });
    const cod = '775100000' + String(i).padStart(2, '0');
    PRESENTACIONES.push({ SKU_Base: p.sku, SKU: p.sku + '-U', Cod_Barras: cod, Factor: 1, Empaque: 'UNIDAD', Descripcion: 'UNIDAD', Precio_Venta: p.precio });
    for (let k = 1; k < p.npres; k++) {
      PRESENTACIONES.push({
        SKU_Base: p.sku, SKU: p.sku + '-P' + k, Cod_Barras: cod + k, Factor: (k + 1) * 6,
        Empaque: 'CAJA x' + ((k + 1) * 6), Descripcion: 'CAJA x' + ((k + 1) * 6), Precio_Venta: +(p.precio * (k + 1) * 6 * 0.95).toFixed(2)
      });
    }
    STOCK_ZONAS.push({ Zona_ID: ZONA, Cod_Barras: cod, Cantidad: p.stock });
  });
  const hoy = new Date(); const y = hoy.getFullYear(), m = String(hoy.getMonth() + 1).padStart(2, '0'), d = String(hoy.getDate()).padStart(2, '0');
  const PROMOCIONES = [
    { SKU_Base: 'SKU003', Tipo_Promo: 'GRUPO', Cant_Min: 3, Valor_Promo: 3.9, Activa: true, Vigencia_Desde: y + '-01-01', Vigencia_Hasta: y + '-12-31' },
    { SKU_Base: 'SKU012', Tipo_Promo: 'PORCENTAJE', Cant_Min: 6, Valor_Promo: 15, Activa: true, Vigencia_Desde: y + '-01-01', Vigencia_Hasta: y + '-12-31' },
    { SKU_Base: 'SKU010', Tipo_Promo: 'GRUPO', Cant_Min: 2, Valor_Promo: 3.2, Activa: true, Vigencia_Desde: y + '-' + m + '-' + d, Vigencia_Hasta: y + '-12-31' }
  ];
  const ZONAS_CONFIG = [{ idEstacion: 'EST-TEST-1', Zona_ID: ZONA, Estacion_Nombre: 'Caja-01', PrintNode_ID: '0', Serie_Boleta: 'BM01', Serie_Factura: 'FM01' }];
  return { PRODUCTO_BASE, PRESENTACIONES, EQUIVALENCIAS, STOCK_ZONAS, PROMOCIONES, ZONAS_CONFIG, CLIENTES_FRECUENTES: [] };
}

export async function prepararPagina(page, ctx) {
  // corta cualquier escritura al servidor
  await ctx.route('**/*', route => {
    const r = route.request(), u = r.url(), m = r.method();
    // denylist: solo se cortan las RPC que ESCRIBEN dinero/almacén. El catálogo, la
    // analítica y el gate de dispositivo tienen que pasar o la app nunca llega al POS.
    if (/supabase\.co/.test(u) && m !== 'GET' &&
        /registrar_venta|crear_venta|guardar_venta|abrir_caja|cerrar_caja|anular|emitir|imprimir|cobrar|marcar_pago|registrar_guia|recibir_guia|adhesivo|membrete|devoluc/i.test(u)) return route.abort();
    return route.continue();
  });
  const DB = buildDb();
  // El catálogo REAL pesa y tarda más que el timeout de 90s de la app en headless.
  // Se responde la RPC con un catálogo de prueba: instantáneo y con los casos que
  // importan (agotados, presentaciones, promos, granel).
  await ctx.route(/catalogo_pos_rls/, route => route.fulfill({
    status: 200, contentType: 'application/json',
    headers: { 'access-control-allow-origin': '*' },
    body: JSON.stringify({ status: 'success', data: DB })
  }));
  await page.addInitScript(([dev, zona, db]) => {
    const L = localStorage;
    L.setItem('mosexpress_deviceId', dev);
    L.setItem('mosexpress_purgante_done', '1');
    L.setItem('mosexpress_device_auth_date', String(Date.now()));
    L.setItem('mosexpress_last_autosync', String(Date.now()));
    L.setItem('mosexpress_session_date', new Date().toDateString());
    L.setItem('mosexpress_config', JSON.stringify({
      completado: true, vendedor: 'TEST CLAUDE', zona: zona, esCajero: false,
      estacion: { idEstacion: 'EST-TEST-1', Zona_ID: zona, Estacion_Nombre: 'Caja-01', PrintNode_ID: '0', Serie_Boleta: 'BM01', Serie_Factura: 'FM01' }
    }));
    L.setItem('mosexpress_caja_activa', JSON.stringify({ idCaja: 'CAJA-LOCAL-TESTCLAUDE', monto: 50, fecha: Date.now() }));
    L.setItem('me_perms_done_v1', '1');
    // catálogo → IndexedDB (mosexpress_idb / kv / mosexpress_db)
    const req = indexedDB.open('mosexpress_idb', 1);
    req.onupgradeneeded = () => { try { req.result.createObjectStore('kv'); } catch (_) {} };
    req.onsuccess = () => {
      try {
        const tx = req.result.transaction('kv', 'readwrite');
        tx.objectStore('kv').put(db, 'mosexpress_db');
      } catch (_) {}
    };
  }, [DEV, ZONA, DB]);
}
