// [2.8.279] GUARD DE NOMBRE DUPLICADO EN LA MISMA ZONA (wizard de ME) — navegador REAL.
//
// Pedido del dueño: "si mañana vienen los dos Jesus... por programa tú lo obligas: le dices
// 'ya existe JESUS en esta zona'. Si eres otra persona usa otro nombre; si eres el mismo, usa
// la extensión de dispositivo".
//
// Escenarios:
//   (a) nombre libre en esa tienda            → entra normal (paso 3, elegir caja)
//   (b) nombre ocupado desde OTRO equipo      → BLOQUEA con los dos caminos
//   (c) el MISMO equipo de esa persona        → NO bloquea (reconexión / su extensión)
//   (d) el mismo nombre en OTRA tienda        → NO bloquea (es normal y correcto)
//   (e) la RPC caída / lenta                  → NO bloquea (regla de oro: nadie deja de vender)
//   (b2) "Soy otra persona"    → vuelve al campo con la sugerencia escrita y el foco puesto
//   (b3) "Soy yo, en otro equipo" → arranca el flujo de extensión por QR que ya existe
//
// Uso:  node _me_nombre_zona_guard.mjs [chromium|webkit] [390|1280]
//
// TRAMPAS DEL BOOT DE ME EN HEADLESS (de _me_guia_borradores.mjs, no tocar):
//   · token del PURGANTE (mosexpress_purgante_done) + get_flags stubbeado
//   · mosexpress_device_auth_id + caché de DeviceAuth (sin él onAprobado recarga en bucle)
//   · preflight CORS (OPTIONS) de las RPC: sin allow-headers el fetch muere
//   · registrar_presencia → debeCerrar:false · caja_activa_zona → hayCaja:true
//   · serviceWorkers:'block' (el controllerchange recarga la app a media prueba)
//   · acá NO se siembra mosexpress_config: la prueba necesita el WIZARD, no el POS.
import { chromium, webkit } from 'playwright';
import http from 'http';
import fs from 'fs';
import path from 'path';

const RAIZ_APP = 'C:/Users/ISO/ecosistema MOS/MosExpress';
const MOTOR    = (process.argv[2] || 'chromium').toLowerCase();
const ANCHO    = parseInt(process.argv[3] || '390', 10);
const PORT     = 8400 + (MOTOR === 'webkit' ? 1 : 0) + (ANCHO === 1280 ? 2 : 0);
const DEV_NUEVO   = '7e57c1a0-de1c-4a7e-b0de-c47a10906476';   // equipo que recién llega
const DEV_JESUS   = 'aaaa1111-de1c-4a7e-b0de-c47a10906476';   // el equipo con el que entró JESUS
const DEV_JESUSX  = 'bbbb2222-de1c-4a7e-b0de-c47a10906476';   // 2º equipo ya atado a JESUS
const Z1 = 'ZONA-01', Z2 = 'ZONA-02';
const PFX = '_nz_' + MOTOR + '_' + ANCHO + '_';

// ── servidor estático ──────────────────────────────────────────────────────────
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

// ── catálogo mínimo con DOS tiendas (el punto de la prueba) ────────────────────
const ITEMS = [['ARROZ COSTENO EXTRA 750G', '7751000000001', 4.50], ['LECHE GLORIA EVAPORADA 400G', '7751000000002', 4.20]];
function buildDb() {
  const PRODUCTO_BASE = [], PRESENTACIONES = [], STOCK_ZONAS = [];
  ITEMS.forEach(([nombre, cod, precio], i) => {
    const sku = 'SKU' + String(i + 1).padStart(3, '0');
    PRODUCTO_BASE.push({ SKU_Base: sku, Nombre: nombre, Cod_SUNAT: '', Tipo_IGV: 1, Unidad_Medida: 'NIU', Foto: '', Categoria: { categoria: 'ABARROTES', subcategoria: 'ABARROTES' } });
    PRESENTACIONES.push({ SKU_Base: sku, SKU: sku + '-U', Cod_Barras: cod, Factor: 1, Empaque: 'UNIDAD', Descripcion: 'UNIDAD', Precio_Venta: precio });
    STOCK_ZONAS.push({ Zona_ID: Z2, Cod_Barras: cod, Cantidad: 40 + i });
  });
  const ZONAS_CONFIG = [
    { idEstacion: 'EST-1', Zona_ID: Z1, Estacion_Nombre: 'Caja-01', PrintNode_ID: '0', Serie_Boleta: 'BM01', Serie_Factura: 'FM01' },
    { idEstacion: 'EST-2', Zona_ID: Z2, Estacion_Nombre: 'Caja-02', PrintNode_ID: '0', Serie_Boleta: 'BM02', Serie_Factura: 'FM02' }
  ];
  return { PRODUCTO_BASE, PRESENTACIONES, EQUIVALENCIAS: [], STOCK_ZONAS, PROMOCIONES: [], ZONAS_CONFIG, CLIENTES_FRECUENTES: [] };
}
const DB = buildDb();

// ── "servidor" de sesiones vivas: JESUS trabajando en ZONA-02 desde las 07:29 ──
const SESIONES = [{ nombre: 'Jesus', zona: Z2, hora: '07:29', equipos: [DEV_JESUS, DEV_JESUSX] }];
let   RPC_CAIDA = false;      // escenario (e)
let   RPC_LENTA = false;      // escenario (e2): responde a los 8 s (más que el techo de 3 s)
const LLAMADAS  = [];         // lo que el wizard le manda realmente a la RPC
let   PEDIR_EXT = [];         // requests de extensión disparadas por "Soy yo, en otro equipo"

const norm = s => String(s || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase().replace(/[^A-Z ]+/g, '').replace(/ {2,}/g, ' ').trim();
const zeq  = (a, b) => String(a || '').toUpperCase().replace(/[^A-Z0-9]/g, '') === String(b || '').toUpperCase().replace(/[^A-Z0-9]/g, '');

// Réplica fiel de mos.nombre_zona_ocupado (SQL 734) para poder ejercitar la UI sin tocar PROD.
function nombreZonaOcupado(p) {
  const nombre = norm(p.nombre), zona = p.zona || '', dev = p.deviceId || '';
  if (!nombre || !zona) return { ok: true, ocupado: false, motivo: 'SIN_DATOS' };
  const s = SESIONES.find(x => norm(x.nombre) === nombre && zeq(x.zona, zona));
  if (!s) return { ok: true, ocupado: false, motivo: 'LIBRE' };
  if (dev && s.equipos.indexOf(dev) > -1) return { ok: true, ocupado: false, motivo: 'MI_EQUIPO' };
  return {
    ok: true, ocupado: true, motivo: 'OCUPADO',
    nombre, nombreReal: s.nombre, zona: s.zona, zonaReal: s.zona,
    idDia: 'LDIA-TEST-' + nombre, rol: 'VENDEDOR', estadoSesion: 'ACTIVA',
    horaIngresoTxt: s.hora, equipos: s.equipos.length, equiposActivos: s.equipos.length,
    sugerencia: nombre + ' A', sugerencias: [nombre + ' A', nombre + ' B', nombre + ' C']
  };
}

// ── navegador ──────────────────────────────────────────────────────────────────
const tipo = MOTOR === 'webkit' ? webkit : chromium;
const browser = await tipo.launch({ headless: true });
const ctx = await browser.newContext({
  viewport: { width: ANCHO, height: ANCHO === 1280 ? 900 : 860 },
  hasTouch: ANCHO < 800, serviceWorkers: 'block'
});
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-methods': 'POST, GET, OPTIONS', 'access-control-allow-headers': '*', 'access-control-max-age': '86400' };
const json = (route, obj) => {
  if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS, body: '' });
  return route.fulfill({ status: 200, contentType: 'application/json', headers: CORS, body: JSON.stringify(obj) });
};
// ⚠ Playwright resuelve las rutas en orden INVERSO de registro: el catch-all va PRIMERO.
await ctx.route('**/*', route => {
  const r = route.request(), u = r.url(), m = r.method();
  if (/supabase\.co/.test(u) && m !== 'GET' &&
      /registrar_venta|crear_venta|guardar_venta|abrir_caja|cerrar_caja|anular|emitir|imprimir|cobrar|marcar_pago|adhesivo|membrete|devoluc/i.test(u)) return route.abort();
  return route.continue();
});
const DEVOK = { ok: true, app: 'mosExpress', estado: 'ACTIVO', autorizado: true, registrado: true, forzar_push: false, forzar_logout: false, forzar_wizard: false, nombre_equipo: 'TEST-CLAUDE-ME' };
await ctx.route(/verificar_dispositivo/,        r => json(r, DEVOK));
await ctx.route(/consultar_estado_dispositivo/, r => json(r, { ok: true, data: Object.assign({ nombre: 'TEST-CLAUDE-ME' }, DEVOK) }));
await ctx.route(/registrar_dispositivo/,        r => json(r, { ok: true, nuevo: false, estado: 'ACTIVO', autorizado: true }));
await ctx.route(/get_device_state/,             r => json(r, { ok: true, data: DEVOK }));
await ctx.route(/get_flags/,           r => json(r, { purganteToken: '1786159982' }));
await ctx.route(/purgante_reportar/,   r => json(r, { ok: true }));
await ctx.route(/mint-me/,             r => json(r, { ok: true, token: 'TOKEN-TEST-CLAUDE', exp: Math.floor(Date.now() / 1000) + 3600 }));
await ctx.route(/registrar_presencia/, r => json(r, { ok: true, debeCerrar: false }));
await ctx.route(/caja_activa_zona/,    r => json(r, { ok: true, data: { hayCaja: false } }));
await ctx.route(/catalogo_pos_rls/,    r => json(r, { status: 'success', data: DB }));
await ctx.route(/cajeros_activos_todos/, r => json(r, { status: 'success', porZona: {} }));
// JESUS aparece como VENDEDOR (no cajero) para que "+ Cajero" y "+ Vendedor" sigan disponibles.
await ctx.route(/presencia_por_zona/, r => json(r, {
  [Z1]: { zona_nombre: 'Zona 01', cajero: null, vendedores: [] },
  [Z2]: { zona_nombre: 'Zona 02', cajero: null, vendedores: [{ nombre: 'Jesus', estacion: 'Caja-02', desde: Date.now() - 3600000 }] }
}));
await ctx.route(/extension_activos_zona/, r => json(r, { ok: true, data: [
  { idDia: 'LDIA-TEST-JESUS', nombre: 'Jesus', rol: 'VENDEDOR', zona: Z2, principalDeviceId: DEV_JESUS, ultimaConexion: new Date().toISOString() }] }));
await ctx.route(/pedir_extension/, r => {
  if (r.request().method() === 'OPTIONS') return json(r, {});
  let p = {}; try { p = JSON.parse(r.request().postData() || '{}').p || {}; } catch (_) {}
  PEDIR_EXT.push(p);
  return json(r, { ok: true, needsApproval: true, idReq: 'EXT-TEST-1', codigo: '123', idDia: 'LDIA-TEST-JESUS', principalDeviceId: DEV_JESUS });
});
await ctx.route(/extension_estado|extension_mi_estado/, r => json(r, { ok: true, estado: 'PENDIENTE', vinculado: false }));
// ── LA RPC DEL GUARD ──
await ctx.route(/nombre_zona_ocupado/, r => {
  if (r.request().method() === 'OPTIONS') return json(r, {});
  let p = {}; try { p = JSON.parse(r.request().postData() || '{}').p || {}; } catch (_) {}
  LLAMADAS.push(p);
  if (RPC_CAIDA) return r.fulfill({ status: 500, headers: CORS, contentType: 'application/json', body: JSON.stringify({ message: 'boom' }) });
  if (RPC_LENTA) return new Promise(res => setTimeout(() => res(json(r, nombreZonaOcupado(p))), 8000));
  return json(r, nombreZonaOcupado(p));
});

const page = await ctx.newPage();
const ruido = [], errores = [];
// WebKit reporta como `pageerror` cada request que el harness bloquea/aborta ("due to access
// control checks", "Load failed"). No son excepciones de la app: son ruido del entorno headless
// (token falso + rutas stubbeadas). Se separan para que "0 pageerrors" siga significando algo.
const RED_RUIDO = /due to access control checks|Load failed|Failed to fetch|NetworkError|supabase\.co|open-meteo\.com|googleapis\.com/i;
page.on('pageerror', e => (RED_RUIDO.test(e.message) ? ruido : errores).push('PAGEERROR: ' + e.message));
page.on('console', m => {
  if (m.type() !== 'error') return;
  const t = m.text();
  if (/Failed to load resource|favicon|net::ERR|401|403|CORS|WebSocket|Notification prompting/i.test(t)) { ruido.push(t); return; }
  // la prueba recarga a propósito entre escenarios: el fetch del catálogo en vuelo muere ahí
  if (/Fallo descarga catalogo.*(Failed to fetch|aborted|NetworkError)/i.test(t)) { ruido.push(t); return; }
  errores.push('[console.error] ' + t);
});

let DEV_ACTUAL = DEV_NUEVO;
await page.addInitScript(() => {
  const L = localStorage;
  L.setItem('mosexpress_purgante_done', '1786159982');
  L.setItem('mosexpress_device_auth_date', String(Date.now()));
  L.setItem('mosexpress_device_auth_date_lima', new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Lima' }).format(new Date()));
  L.setItem('mosexpress_device_verify_version', '999999');
  L.setItem('mosexpress_last_autosync', String(Date.now()));
  L.setItem('mosexpress_session_date', new Date().toDateString());
  const _gi = L.getItem.bind(L);
  L.getItem = k => (String(k).indexOf('me_perms_done_v') === 0 ? '1' : _gi(k));
  setInterval(() => { try { const ov = document.getElementById('mePermsOverlay'); if (ov) ov.classList.remove('is-open'); } catch (_) {} }, 250);
});
// El deviceId cambia por escenario → se siembra en un init script propio, re-registrado por prueba.
const sembrarDevice = async (dev) => {
  DEV_ACTUAL = dev;
  await ctx.addInitScript(([d, db]) => {
    localStorage.setItem('mosexpress_deviceId', d);
    localStorage.setItem('mosexpress_device_auth_id', d);
    const req = indexedDB.open('mosexpress_idb', 1);
    req.onupgradeneeded = () => { try { req.result.createObjectStore('kv'); } catch (_) {} };
    req.onsuccess = () => { try { req.result.transaction('kv', 'readwrite').objectStore('kv').put(db, 'mosexpress_db'); } catch (_) {} };
  }, [dev, DB]);
};

// ── utilidades ─────────────────────────────────────────────────────────────────
const R = [], SHOTS = [];
const chk = (nombre, cond, detalle) => { R.push({ nombre, ok: !!cond, detalle }); console.log((cond ? 'PASS  ' : 'FAIL  ') + nombre + (detalle ? '   → ' + detalle : '')); };
const shotOk = async (n) => { const f = PFX + n + '.png'; await page.screenshot({ path: f }); SHOTS.push(f); return f; };
const txt = async (sel) => (await page.locator(sel).innerText().catch(() => '')).replace(/\s+/g, ' ').trim();

const bootWizard = async () => {
  await page.goto('http://127.0.0.1:' + PORT + '/index.html', { waitUntil: 'domcontentloaded' });
  // Cada escenario arranca de cero: se limpia lo que dejó el anterior (el init script vuelve a
  // sembrar deviceId/purgante/auth en la recarga) para que el wizard siempre empiece en el paso 1.
  await page.evaluate(() => { try { localStorage.clear(); sessionStorage.clear(); } catch (e) {} });
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#wizNombreInput', { state: 'visible', timeout: 90000 });
  // dbCargada: el botón "2º equipo" solo existe con el catálogo ya descargado.
  await page.waitForSelector('button:has-text("2º equipo")', { timeout: 90000 });
  await page.waitForTimeout(400);
};
// Paso 1 → escribe el nombre y continúa. Paso 2 → toca "+ Vendedor" de la tienda pedida.
const tipearNombre = async (nombre) => {
  const inp = page.locator('#wizNombreInput');
  await inp.click(); await inp.fill('');
  await inp.type(nombre, { delay: 12 });
  await page.waitForTimeout(200);
};
const continuar = async () => {
  await page.click('button:has-text("Continuar")');
  await page.waitForTimeout(900);                     // presencia en vivo
};
const tocarVendedorDe = async (zonaNombre) => {
  const card = page.locator('.wiz-tienda', { hasText: zonaNombre }).first();
  await card.locator('button:has-text("+ Vendedor")').click();
  await page.waitForTimeout(2600);                    // RPC del guard + seleccionarZonaWizard
};
const avisoVisible = () => page.locator('h3:has-text("Ese nombre ya está trabajando acá")').isVisible().catch(() => false);
// El paso 3 tarda: wizZonaAddVendedor hace await de seleccionarZonaWizard (red). Se ESPERA,
// no se mira un instante suelto (esa fue la trampa: la captura salía bien y el assert fallaba).
const enPaso3      = async (ms = 12000) => {
  try { await page.waitForFunction(() => Array.from(document.querySelectorAll("h1")).some(h => /Tu caja/i.test(h.textContent)), null, { timeout: ms }); return true; }
  catch (e) { return false; }
};

console.log('\n╔═══ GUARD NOMBRE DUPLICADO POR ZONA · ' + MOTOR.toUpperCase() + ' @' + ANCHO + ' ═══╗\n');

// ═══ (a) NOMBRE LIBRE → ENTRA NORMAL ═══════════════════════════════════════════
console.log('=== (a) nombre libre en esa tienda → entra normal ===');
await sembrarDevice(DEV_NUEVO);
await bootWizard();
await tipearNombre('MARIA'); await continuar();
await shotOk('a1_paso2_tiendas');
await tocarVendedorDe('Zona 02');
const aAviso = await avisoVisible(), aPaso3 = await enPaso3();
await shotOk('a2_entro_normal');
chk('(a) un nombre libre NO dispara el aviso', !aAviso);
chk('(a) ✅ sigue derecho al paso 3 (elegir caja)', aPaso3);
chk('(a) la RPC recibió nombre normalizado + zona + deviceId',
    LLAMADAS.length === 1 && LLAMADAS[0].nombre === 'MARIA' && LLAMADAS[0].zona === Z2 && LLAMADAS[0].deviceId === DEV_NUEVO,
    JSON.stringify(LLAMADAS[LLAMADAS.length - 1]));

// ═══ (b) NOMBRE OCUPADO DESDE OTRO EQUIPO → BLOQUEA ════════════════════════════
console.log('\n=== (b) "JESUS" en Zona 02 desde OTRO equipo → bloquea con los dos caminos ===');
LLAMADAS.length = 0;
await bootWizard();
await tipearNombre('JESUS'); await continuar();
await tocarVendedorDe('Zona 02');
const bAviso = await avisoVisible();
const bTexto = await txt('div.z-\\[60\\]');
await shotOk('b1_bloqueado');
chk('(b) ✅ SE BLOQUEA: aparece el aviso', bAviso);
chk('(b) NO pasó al paso 3', !(await enPaso3(1500)));
chk('(b) el aviso dice el nombre, la tienda y la hora', /JESUS/.test(bTexto) && /Zona 02/.test(bTexto) && /07:29/.test(bTexto), bTexto.slice(0, 150));
chk('(b) el aviso dice cuántos equipos tiene', /2 equipos/.test(bTexto), (bTexto.match(/\(\d+ equipos?\)/) || [''])[0]);
chk('(b) explica POR QUÉ (ventas y comisión se mezclan)', /se mezclan/.test(bTexto) && /comisión/.test(bTexto));
chk('(b) ofrece "Soy otra persona" con sugerencia concreta', /Soy otra persona/.test(bTexto) && /JESUS A/.test(bTexto), (bTexto.match(/Entrar como [^(]+/) || [''])[0]);
chk('(b) ofrece "Soy yo, en otro equipo" hacia el QR', /Soy yo, en otro equipo/.test(bTexto) && /QR/.test(bTexto));
chk('(b) cero diálogos nativos (es un overlay del sistema)', await page.locator('div.z-\\[60\\]').count() > 0);

// ═══ (b2) "SOY OTRA PERSONA" → vuelve al campo con la sugerencia y el foco ═════
console.log('\n=== (b2) "Soy otra persona" → nombre sugerido + foco en el campo ===');
await page.click('button:has-text("Soy otra persona")');
await page.waitForTimeout(700);
const valor  = await page.locator('#wizNombreInput').inputValue().catch(() => '');
const foco   = await page.evaluate(() => document.activeElement && document.activeElement.id);
const enPaso1 = await page.locator('#wizNombreInput').isVisible().catch(() => false);
await shotOk('b2_sugerencia_y_foco');
chk('(b2) ✅ vuelve al paso 1 con la sugerencia ya escrita', enPaso1 && valor === 'JESUS A', 'input="' + valor + '"');
chk('(b2) el foco quedó en el campo del nombre', foco === 'wizNombreInput', 'activeElement=' + foco);
chk('(b2) el aviso se cerró', !(await avisoVisible()));
// y con el nombre nuevo YA puede entrar
await continuar();
await tocarVendedorDe('Zona 02');
await shotOk('b2b_entra_con_nombre_nuevo');
chk('(b2) ✅ con el nombre alternativo entra sin problema', await enPaso3());

// ═══ (b3) "SOY YO, EN OTRO EQUIPO" → flujo de extensión por QR ═════════════════
console.log('\n=== (b3) "Soy yo, en otro equipo" → arranca la extensión por QR ===');
PEDIR_EXT = [];
await bootWizard();
await tipearNombre('JESUS'); await continuar();
await tocarVendedorDe('Zona 02');
chk('(b3) el aviso volvió a salir', await avisoVisible());
await page.click('button:has-text("Soy yo, en otro equipo")');
await page.waitForTimeout(1800);
const hayOverlayExt = await page.locator('._extCard').count() > 0;
await shotOk('b3_extension_qr');
chk('(b3) ✅ se pidió la extensión al servidor con el nombre y la zona del que ya está',
    PEDIR_EXT.length === 1 && PEDIR_EXT[0].nombre === 'Jesus' && PEDIR_EXT[0].zona === Z2 && PEDIR_EXT[0].deviceId === DEV_NUEVO,
    JSON.stringify(PEDIR_EXT[0] || {}));
chk('(b3) se abrió el overlay del flujo de extensión (espera del QR)', hayOverlayExt);

// ═══ (c) EL MISMO EQUIPO DE ESA PERSONA → NO BLOQUEA ══════════════════════════
console.log('\n=== (c) el MISMO equipo de JESUS (o su extensión ya atada) → NO bloquea ===');
await sembrarDevice(DEV_JESUS);
await bootWizard();
await tipearNombre('JESUS'); await continuar();
await tocarVendedorDe('Zona 02');
await shotOk('c_mismo_equipo_pasa');
chk('(c) ✅ su propio equipo NO se bloquea', !(await avisoVisible()));
chk('(c) entra derecho al paso 3', await enPaso3());

// ═══ (d) EL MISMO NOMBRE EN OTRA TIENDA → NO BLOQUEA ══════════════════════════
console.log('\n=== (d) "JESUS" pero en Zona 01 → NO bloquea (dos zonas conviven) ===');
await sembrarDevice(DEV_NUEVO);
await bootWizard();
await tipearNombre('JESUS'); await continuar();
await tocarVendedorDe('Zona 01');
await shotOk('d_otra_zona_pasa');
chk('(d) ✅ el mismo nombre en OTRA tienda entra sin aviso', !(await avisoVisible()));
chk('(d) entra derecho al paso 3', await enPaso3());

// ═══ (e) RPC CAÍDA → NO BLOQUEA (regla de oro) ════════════════════════════════
console.log('\n=== (e) la RPC del guard se cae → NO bloquea, se deja vender ===');
RPC_CAIDA = true;
await bootWizard();
await tipearNombre('JESUS'); await continuar();
await tocarVendedorDe('Zona 02');
await shotOk('e_rpc_caida_deja_pasar');
chk('(e) ✅ con la RPC caída NO se bloquea a nadie', !(await avisoVisible()));
chk('(e) entra igual al paso 3', await enPaso3());
RPC_CAIDA = false;

// ═══ (e2) RPC LENTA (>3 s) → tampoco bloquea: techo blando del guard ══════════
console.log('\n=== (e2) la RPC tarda más de 3 s → el wizard no espera ni bloquea ===');
RPC_LENTA = true;
await bootWizard();
await tipearNombre('JESUS'); await continuar();
const t0 = Date.now();
await tocarVendedorDe('Zona 02');
const paso3Lento = await enPaso3();
await shotOk('e2_rpc_lenta_deja_pasar');
chk('(e2) ✅ una RPC lenta NO bloquea (techo blando de 3 s)', !(await avisoVisible()) && paso3Lento, 'tardó ' + (Date.now() - t0) + ' ms');
RPC_LENTA = false;

// ── errores ────────────────────────────────────────────────────────────────────
console.log('\n=== PAGEERRORS / console.error de la app: ' + errores.length + ' ===');
errores.slice(0, 20).forEach(e => console.log('  ' + e));
console.log('(ruido de red esperado con token falso: ' + ruido.length + ')');
chk('0 pageerrors', errores.length === 0, errores.slice(0, 3).join(' ; '));

const fail = R.filter(r => !r.ok).length;
console.log('\n════════ ' + MOTOR + '@' + ANCHO + ' · ' + (R.length - fail) + ' PASS / ' + fail + ' FAIL ════════');
console.log('screenshots: ' + SHOTS.join(', '));
await browser.close();
srv.close();
process.exit(fail ? 1 : 0);
