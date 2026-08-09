// [2.8.273] DESAMBIGUACION DE CODIGOS DUPLICADOS en el POS de ME.
// Prueba los 2 casos REALES del catalogo:
//   7758725000036 -> ...036A CABALLO DE ORO AZUL / ...036B CABALLO DE ORO DORADO   (2 variantes)
//   7750464444799 -> pelado LA CHINA TAMARINDO + ...799A/B/C/D FOCH                (5 variantes)
// Verifica: banner + grid filtrado a N cards + chip de sufijo por card + la X limpia el filtro
// + el codigo interno completo (...036A) NO dispara el filtro (resuelve directo) + 0 pageerrors.
import { chromium } from 'playwright';
import http from 'http';
import fs from 'fs';
import path from 'path';

const RAIZ_APP = 'C:/Users/ISO/ecosistema MOS/MosExpress';
const PORT = 8127;
const DEV = '7e57c1a0-de1c-4a7e-b0de-c47a10906476';
const ZONA = 'TIENDA 1';

// ── servidor estatico local ────────────────────────────────────────────────────
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.json': 'application/json', '.png': 'image/png', '.css': 'text/css' };
const srv = http.createServer((req, res) => {
  const p = path.join(RAIZ_APP, decodeURIComponent(req.url.split('?')[0]));
  fs.readFile(p, (e, b) => {
    if (e) { res.writeHead(404); return res.end('404'); }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(p).toLowerCase()] || 'application/octet-stream' });
    res.end(b);
  });
});
await new Promise(r => srv.listen(PORT, '127.0.0.1', r));

// ── catalogo de prueba con las FAMILIAS REALES ────────────────────────────────
function buildDb() {
  const PRODUCTO_BASE = [], PRESENTACIONES = [], STOCK_ZONAS = [];
  // [nombre, codigo interno, precio]
  const ITEMS = [
    // familia 7758725000036 (2 productos, sufijos A/B)
    ['CABALLO DE ORO AZUL PASTA WANTAN 500GR', '7758725000036A', 5.50],
    ['CABALLO DE ORO DORADO WANTAN 500GR',     '7758725000036B', 5.80],
    // familia 7750464444799 (5 productos: PELADO + A/B/C/D)
    ['LA CHINA TAMARINDO',        '7750464444799',  3.20],
    ['FOCH SALSA DE SOYA',        '7750464444799A', 4.10],
    ['FOCH ACEITE DE AJONJOLI',   '7750464444799B', 8.90],
    ['FOCH VINAGRE DE ARROZ',     '7750464444799C', 6.40],
    ['FOCH SALSA DE OSTION',      '7750464444799D', 7.30],
    // familia con letras NO correlativas (O / R)
    ['SIBARITA OREGANO ENTERO',   '737186519674O',  2.10],
    ['SIBARITA ROMERO ENTERO',    '737186519674R',  2.30],
    // ruido: producto normal sin familia (el 99% de los casos)
    ['ARROZ COSTENO EXTRA 750G',  '7751000000001',  4.50],
    ['LECHE GLORIA EVAPORADA 400G','7751000000002',  4.20],
    ['GASEOSA INKA KOLA 3L',      '7751000000003', 10.50]
  ];
  ITEMS.forEach(([nombre, cod, precio], i) => {
    const sku = 'SKU' + String(i + 1).padStart(3, '0');
    PRODUCTO_BASE.push({ SKU_Base: sku, Nombre: nombre, Cod_SUNAT: '', Tipo_IGV: 1, Unidad_Medida: 'NIU', Foto: '', Categoria: { categoria: 'ABARROTES', subcategoria: 'ABARROTES' } });
    PRESENTACIONES.push({ SKU_Base: sku, SKU: sku + '-U', Cod_Barras: cod, Factor: 1, Empaque: 'UNIDAD', Descripcion: 'UNIDAD', Precio_Venta: precio });
    STOCK_ZONAS.push({ Zona_ID: ZONA, Cod_Barras: cod, Cantidad: 10 + i });
  });
  const ZONAS_CONFIG = [{ idEstacion: 'EST-TEST-1', Zona_ID: ZONA, Estacion_Nombre: 'Caja-01', PrintNode_ID: '0', Serie_Boleta: 'BM01', Serie_Factura: 'FM01' }];
  return { PRODUCTO_BASE, PRESENTACIONES, EQUIVALENCIAS: [], STOCK_ZONAS, PROMOCIONES: [], ZONAS_CONFIG, CLIENTES_FRECUENTES: [] };
}

const DB = buildDb();
const browser = await chromium.launch({ headless: true });
// serviceWorkers:'block' — en la 1a carga el SW toma control (controllerchange) y la app se
// RECARGA sola a mitad de la prueba (el banner se quedaba vacio y el grid en 0 cards).
const ctx = await browser.newContext({ viewport: { width: 430, height: 900 }, hasTouch: true, serviceWorkers: 'block' });

// cortar TODA escritura al servidor (money-safe: esto es una prueba, no toca datos reales)
await ctx.route('**/*', route => {
  const r = route.request(), u = r.url(), m = r.method();
  if (/supabase\.co/.test(u) && m !== 'GET' &&
      /registrar_venta|crear_venta|guardar_venta|abrir_caja|cerrar_caja|anular|emitir|imprimir|cobrar|marcar_pago|registrar_guia|recibir_guia|adhesivo|membrete|devoluc/i.test(u)) return route.abort();
  return route.continue();
});
// El catalogo REAL pesa y tarda mas que el timeout de la app en headless: se responde la RPC
// con este catalogo de prueba (instantaneo) que trae las familias duplicadas REALES.
// OJO: el POST lleva headers custom (apikey/Authorization/Content-Profile) => hay PREFLIGHT
// OPTIONS. Si el preflight se responde sin allow-headers/allow-methods, el fetch muere y la
// app se queda en "Descargando catalogo..." para siempre.
const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'POST, GET, OPTIONS',
  'access-control-allow-headers': '*',
  'access-control-max-age': '86400'
};
// El heartbeat (registrar_presencia) le pregunta al backend si la sesion sigue viva. La sesion
// de este harness es LOCAL (no existe en el servidor) => el backend responde debeCerrar:true y
// la app hace logout + location.reload() a mitad de la prueba. Se responde ok/debeCerrar:false.
await ctx.route(/registrar_presencia/, route => {
  if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS, body: '' });
  return route.fulfill({ status: 200, contentType: 'application/json', headers: CORS, body: JSON.stringify({ ok: true, debeCerrar: false }) });
});
// Sin caja abierta EN EL SERVIDOR el POS muestra la pantalla "Esperando apertura de caja",
// que tapa el grid y se come los clicks. La caja de este harness es local => se simula abierta.
await ctx.route(/caja_activa_zona/, route => {
  if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS, body: '' });
  return route.fulfill({ status: 200, contentType: 'application/json', headers: CORS, body: JSON.stringify({
    ok: true, data: { hayCaja: true, cajero: 'TEST CLAUDE', idCaja: 'CAJA-LOCAL-TESTCLAUDE', abiertaTs: Date.now(), estacion: 'Caja-01' } }) });
});
await ctx.route(/catalogo_pos_rls/, route => {
  if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS, body: '' });
  return route.fulfill({ status: 200, contentType: 'application/json', headers: CORS, body: JSON.stringify({ status: 'success', data: DB }) });
});

const page = await ctx.newPage();
const errores = [], logs = [];
page.on('pageerror', e => errores.push('PAGEERROR: ' + e.message));
page.on('console', m => { if (m.type() === 'error') logs.push('[console.error] ' + m.text()); if (/\[dup\]/.test(m.text())) logs.push(m.text()); });

await page.addInitScript(([dev, zona, db]) => {
  const L = localStorage;
  L.setItem('mosexpress_deviceId', dev);
  // el PURGANTE remoto (SQL 658) borra localStorage y recarga si este token no coincide
  L.setItem('mosexpress_purgante_done', '1786159982');
  // SIN device_auth_id el gate hace la ronda de red completa y cargarDatos() se queda a medias
  L.setItem('mosexpress_device_auth_date', String(Date.now()));
  L.setItem('mosexpress_device_auth_id', dev);
  // cache de DeviceAuth (device-auth.js): sin esto el modulo re-verifica, dispara
  // onAprobado y la app se RECARGA en bucle a mitad de la prueba.
  L.setItem('mosexpress_device_auth_date_lima', new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Lima' }).format(new Date()));
  L.setItem('mosexpress_device_verify_version', '999999');
  L.setItem('mosexpress_last_autosync', String(Date.now()));
  L.setItem('mosexpress_session_date', new Date().toDateString());
  L.setItem('mosexpress_config', JSON.stringify({
    completado: true, vendedor: 'TEST CLAUDE', zona: zona, esCajero: false,
    estacion: { idEstacion: 'EST-TEST-1', Zona_ID: zona, Estacion_Nombre: 'Caja-01', PrintNode_ID: '0', Serie_Boleta: 'BM01', Serie_Factura: 'FM01' }
  }));
  L.setItem('mosexpress_caja_activa', JSON.stringify({ idCaja: 'CAJA-LOCAL-TESTCLAUDE', monto: 50, fecha: Date.now() }));
  // La pantalla de permisos usa la clave me_perms_done_v<VERSION>; el harness no sabe la
  // version que se va a desplegar, asi que responde '1' a cualquiera de esas claves.
  const _gi = L.getItem.bind(L);
  L.getItem = k => (String(k).indexOf('me_perms_done_v') === 0 ? '1' : _gi(k));
  const req = indexedDB.open('mosexpress_idb', 1);
  req.onupgradeneeded = () => { try { req.result.createObjectStore('kv'); } catch (_) {} };
  req.onsuccess = () => { try { req.result.transaction('kv', 'readwrite').objectStore('kv').put(db, 'mosexpress_db'); } catch (_) {} };
}, [DEV, ZONA, DB]);

await page.goto(`http://127.0.0.1:${PORT}/index.html`, { waitUntil: 'domcontentloaded' });
await page.waitForSelector('.pos-card', { timeout: 90000 });
await page.waitForTimeout(1200);

const INPUT = 'input[placeholder="Buscar o Escanear..."]';

// Lee el estado del grid + banner
const leer = () => page.evaluate(() => {
  const b = document.querySelector('.dup-banner');
  const cards = [...document.querySelectorAll('.pos-card')];
  return {
    banner: b ? (b.innerText || '').replace(/\s+/g, ' ').trim() : null,
    bannerVisible: !!(b && b.getBoundingClientRect().height > 0),
    nCards: cards.length,
    nombres: cards.map(c => (c.querySelector('h3') || {}).innerText || '').map(s => s.trim()),
    chips: cards.map(c => { const x = c.querySelector('.dup-chip'); return x ? x.innerText.trim() : null; }),
    conBorde: cards.filter(c => c.classList.contains('dup-card')).length,
    carrito: (document.body.innerText.match(/S\/ ?[0-9]+\.[0-9]{2}/g) || []).length
  };
});

// Simula un ESCANEO: el lector mete los chars a ~5ms y remata con Enter.
const escanear = async (cod) => {
  await page.click(INPUT);
  await page.fill(INPUT, '');
  await page.type(INPUT, cod, { delay: 5 });
  await page.keyboard.press('Enter');
  await page.waitForTimeout(700);
};

const R = [];
const chk = (nombre, cond, detalle) => { R.push({ nombre, ok: !!cond, detalle }); console.log((cond ? 'PASS  ' : 'FAIL  ') + nombre + (detalle ? '   → ' + detalle : '')); };

const base = await leer();
console.log('\n=== CATALOGO CARGADO ===');
console.log('cards iniciales:', base.nCards, '| banner:', base.banner);
chk('catalogo completo al inicio (12 cards, sin banner)', base.nCards === 12 && base.banner === null, base.nCards + ' cards');

// ── CASO 1: escanear el PELADO 7758725000036 (CABALLO DE ORO) ────────────────
console.log('\n=== CASO 1 · escaneo del pelado 7758725000036 (CABALLO DE ORO) ===');
await escanear('7758725000036');
const c1 = await leer();
console.log(JSON.stringify(c1, null, 1));
await page.screenshot({ path: '_me_dup_1_caballo_390.png' });
chk('C1 banner visible', c1.bannerVisible, c1.banner);
chk('C1 banner dice 2 productos + el codigo raiz', /2 productos comparten el c[oó]digo 7758725000036/i.test(c1.banner || ''));
chk('C1 grid filtrado a 2 cards', c1.nCards === 2, c1.nCards + ' cards: ' + c1.nombres.join(' | '));
chk('C1 son AZUL y DORADO', /AZUL/.test(c1.nombres.join('|')) && /DORADO/.test(c1.nombres.join('|')));
chk('C1 cada card con su chip de sufijo …036A / …036B', c1.chips.filter(Boolean).length === 2 && c1.chips.join(',').includes('036A') && c1.chips.join(',').includes('036B'), c1.chips.join(' , '));
chk('C1 cards resaltadas (dup-card)', c1.conBorde === 2);
chk('C1 el input quedo limpio (listo para el siguiente escaneo)', (await page.inputValue(INPUT)) === '');

// la ✕ limpia el filtro → catalogo completo
await page.click('.dup-banner button');
await page.waitForTimeout(400);
const c1b = await leer();
chk('C1 la ✕ devuelve el catalogo completo', c1b.nCards === 12 && c1b.banner === null, c1b.nCards + ' cards');

// ── CASO 2: escanear el PELADO 7750464444799 (5 variantes) ───────────────────
console.log('\n=== CASO 2 · escaneo del pelado 7750464444799 (LA CHINA + 4 FOCH) ===');
await escanear('7750464444799');
const c2 = await leer();
console.log(JSON.stringify(c2, null, 1));
await page.screenshot({ path: '_me_dup_2_foch_390.png' });
chk('C2 banner visible', c2.bannerVisible, c2.banner);
chk('C2 banner dice 5 productos + el codigo raiz', /5 productos comparten el c[oó]digo 7750464444799/i.test(c2.banner || ''));
chk('C2 grid filtrado a 5 cards', c2.nCards === 5, c2.nCards + ' cards: ' + c2.nombres.join(' | '));
chk('C2 incluye el PELADO (LA CHINA) + los 4 FOCH', /LA CHINA/.test(c2.nombres.join('|')) && c2.nombres.filter(n => /FOCH/.test(n)).length === 4);
chk('C2 los 5 chips (…799, …799A/B/C/D)', c2.chips.filter(Boolean).length === 5, c2.chips.join(' , '));

// desktop shot del mismo caso
await page.setViewportSize({ width: 1280, height: 860 });
await page.waitForTimeout(500);
await page.screenshot({ path: '_me_dup_2_foch_1280.png' });
await page.setViewportSize({ width: 430, height: 900 });
await page.waitForTimeout(400);

// ── CASO 3: el codigo INTERNO completo NO debe filtrar (resuelve directo) ────
console.log('\n=== CASO 3 · escaneo del interno completo 7758725000036A (sin ambiguedad) ===');
await page.click('.dup-banner button'); await page.waitForTimeout(300);
const antesCarrito = await page.evaluate(() => document.querySelectorAll('[data-cart-idx]').length);
await escanear('7758725000036A');
const c3 = await leer();
const despuesCarrito = await page.evaluate(() => document.querySelectorAll('[data-cart-idx]').length);
console.log('banner:', c3.banner, '| cards:', c3.nCards, '| items carrito', antesCarrito, '->', despuesCarrito);
await page.screenshot({ path: '_me_dup_3_interno_390.png' });
chk('C3 NO aparece el banner (el codigo interno es inequivoco)', c3.banner === null);
chk('C3 el producto entro al carrito (venta normal, cero friccion)', despuesCarrito > antesCarrito, antesCarrito + ' -> ' + despuesCarrito);

// ── CASO 4: producto normal (99% de los escaneos) — camino intacto ──────────
console.log('\n=== CASO 4 · producto SIN familia 7751000000001 (camino actual intacto) ===');
const antes4 = await page.evaluate(() => document.querySelectorAll('[data-cart-idx]').length);
await escanear('7751000000001');
const c4 = await leer();
const despues4 = await page.evaluate(() => document.querySelectorAll('[data-cart-idx]').length);
chk('C4 sin banner', c4.banner === null);
chk('C4 entro al carrito', despues4 > antes4, antes4 + ' -> ' + despues4);

// ── CASO 5: TECLEADO (no escaneo) del pelado → tambien desambigua ───────────
// A 430px con el carrito lleno el panel del catalogo se oculta (vista carrito). Los casos
// que faltan necesitan ver el grid => se pasa a escritorio, donde conviven ambos paneles.
console.log('\n=== CASO 5 · TECLEADO lento del pelado 737186519674 (oregano/romero, letras O y R) ===');
await page.setViewportSize({ width: 1280, height: 860 });
await page.waitForTimeout(600);
await page.click(INPUT); await page.fill(INPUT, '');
await page.type(INPUT, '737186519674', { delay: 90 });   // lento = humano, no scanner
await page.keyboard.press('Enter');
await page.waitForTimeout(700);
const c5 = await leer();
console.log(JSON.stringify(c5, null, 1));
await page.screenshot({ path: '_me_dup_5_tecleado_1280.png' });
chk('C5 tecleado tambien desambigua (2 cards + banner)', c5.bannerVisible && c5.nCards === 2 && /2 productos comparten/i.test(c5.banner || ''), c5.nombres.join(' | '));
chk('C5 chips con letras NO correlativas …674O / …674R', c5.chips.join(',').includes('674O') && c5.chips.join(',').includes('674R'), c5.chips.join(' , '));

// ── CASO 6: tocar una card del filtro = venta normal + filtro se limpia ─────
console.log('\n=== CASO 6 · tocar la card correcta dentro del filtro ===');
const antes6 = await page.evaluate(() => document.querySelectorAll('[data-cart-idx]').length);
await page.click('.pos-card >> nth=0');
await page.waitForTimeout(900);
const c6 = await leer();
const despues6 = await page.evaluate(() => document.querySelectorAll('[data-cart-idx]').length);
chk('C6 un tap agrega al carrito', despues6 > antes6, antes6 + ' -> ' + despues6);
chk('C6 el filtro se limpia solo tras vender', c6.banner === null && c6.nCards === 12, c6.nCards + ' cards');
await page.screenshot({ path: '_me_dup_6_tras_venta_1280.png' });

// ── errores de pagina ──────────────────────────────────────────────────────
console.log('\n=== CONSOLA ===');
logs.forEach(l => console.log('  ' + l));
console.log('\n=== PAGEERRORS: ' + errores.length + ' ===');
errores.forEach(e => console.log('  ' + e));
chk('0 pageerrors', errores.length === 0, errores.join(' ; '));

const fail = R.filter(r => !r.ok).length;
console.log('\n════════ ' + (R.length - fail) + ' PASS / ' + fail + ' FAIL ════════');
await browser.close();
srv.close();
process.exit(fail ? 1 : 0);
