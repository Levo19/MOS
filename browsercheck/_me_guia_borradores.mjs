// [2.8.277] BORRADORES PERSISTENTES DE GUÍAS en ME — verificación en navegador REAL.
//
// 7 escenarios exigidos por el dueño:
//   1. agrego 3 productos → salgo del módulo → vuelvo → ESTÁN
//   2. agrego → recargo la página (F5) → vuelvo a guías → ESTÁN
//   3. confirmo la guía con éxito → el borrador DESAPARECE
//   4. borrador de AYER → NO se restaura (y se descarta solo)
//   5. los 3 tipos (SALIDA / ENTRADA / RECIBIR) conviven sin pisarse
//   6. el aviso "falta terminar" (chip global + bandeja 📋 N en curso) SE VE
//   7. purga REAL del purgante (get_flags con token nuevo) → el borrador SOBREVIVE
//
// Uso:  node _me_guia_borradores.mjs [chromium|webkit] [390|1280]
//
// TRAMPAS DEL BOOT DE ME EN HEADLESS (respetadas abajo, no tocar):
//   · token del PURGANTE (mosexpress_purgante_done) + get_flags stubbeado
//   · mosexpress_device_auth_id + caché de DeviceAuth (sin él onAprobado recarga en bucle)
//   · preflight CORS (OPTIONS) de las RPC: sin allow-headers el fetch muere
//   · registrar_presencia → debeCerrar:false (si no, logout + reload a media prueba)
//   · caja_activa_zona → hayCaja:true (si no, la pantalla "esperando caja" se come los clicks)
//   · serviceWorkers:'block' (el controllerchange recarga la app a media prueba)
import { chromium, webkit } from 'playwright';
import http from 'http';
import fs from 'fs';
import path from 'path';

const RAIZ_APP = 'C:/Users/ISO/ecosistema MOS/MosExpress';
const MOTOR    = (process.argv[2] || 'chromium').toLowerCase();
const ANCHO    = parseInt(process.argv[3] || '390', 10);
const PORT     = 8300 + (MOTOR === 'webkit' ? 1 : 0) + (ANCHO === 1280 ? 2 : 0);
const DEV      = '7e57c1a0-de1c-4a7e-b0de-c47a10906476';
const ZONA     = 'TIENDA 1';
const VEND     = 'TEST CLAUDE';
const PFX      = '_gd_' + MOTOR + '_' + ANCHO + '_';

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

// ── catálogo de prueba ─────────────────────────────────────────────────────────
const ITEMS = [
  ['ARROZ COSTENO EXTRA 750G',   '7751000000001', 4.50],
  ['LECHE GLORIA EVAPORADA 400G','7751000000002', 4.20],
  ['GASEOSA INKA KOLA 3L',       '7751000000003', 10.50],
  ['ACEITE PRIMOR 900ML',        '7751000000004', 9.90],
  ['AZUCAR RUBIA 1KG',           '7751000000005', 4.80],
  ['FIDEOS DON VITTORIO 500G',   '7751000000006', 3.60]
];
function buildDb() {
  const PRODUCTO_BASE = [], PRESENTACIONES = [], STOCK_ZONAS = [];
  ITEMS.forEach(([nombre, cod, precio], i) => {
    const sku = 'SKU' + String(i + 1).padStart(3, '0');
    PRODUCTO_BASE.push({ SKU_Base: sku, Nombre: nombre, Cod_SUNAT: '', Tipo_IGV: 1, Unidad_Medida: 'NIU', Foto: '', Categoria: { categoria: 'ABARROTES', subcategoria: 'ABARROTES' } });
    PRESENTACIONES.push({ SKU_Base: sku, SKU: sku + '-U', Cod_Barras: cod, Factor: 1, Empaque: 'UNIDAD', Descripcion: 'UNIDAD', Precio_Venta: precio });
    STOCK_ZONAS.push({ Zona_ID: ZONA, Cod_Barras: cod, Cantidad: 40 + i });
  });
  const ZONAS_CONFIG = [
    { idEstacion: 'EST-TEST-1', Zona_ID: ZONA,      Estacion_Nombre: 'Caja-01', PrintNode_ID: '0', Serie_Boleta: 'BM01', Serie_Factura: 'FM01' },
    { idEstacion: 'EST-TEST-2', Zona_ID: 'TIENDA 2', Estacion_Nombre: 'Caja-02', PrintNode_ID: '0', Serie_Boleta: 'BM02', Serie_Factura: 'FM02' }
  ];
  return { PRODUCTO_BASE, PRESENTACIONES, EQUIVALENCIAS: [], STOCK_ZONAS, PROMOCIONES: [], ZONAS_CONFIG, CLIENTES_FRECUENTES: [] };
}
const DB = buildDb();

// ── "servidor" de guías (lo que el antiduplicado consultará como verdad) ───────
const GUIAS_SERVIDOR = [];
let   PURGANTE_TOKEN = '1786159982';        // igual al sembrado ⇒ NO purga
let   REGISTRAR_OK   = true;

// ── navegador ──────────────────────────────────────────────────────────────────
const tipo = MOTOR === 'webkit' ? webkit : chromium;
const browser = await tipo.launch({ headless: true });
const ctx = await browser.newContext({
  viewport: { width: ANCHO, height: ANCHO === 1280 ? 900 : 860 },
  hasTouch: ANCHO < 800, serviceWorkers: 'block'
});

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'POST, GET, OPTIONS',
  'access-control-allow-headers': '*',
  'access-control-max-age': '86400'
};
const json = (route, obj) => {
  if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS, body: '' });
  return route.fulfill({ status: 200, contentType: 'application/json', headers: CORS, body: JSON.stringify(obj) });
};

// ⚠ ORDEN: Playwright resuelve las rutas en orden INVERSO de registro (la última gana).
//   El catch-all va PRIMERO; los stubs concretos después, para que tengan prioridad.
await ctx.route('**/*', route => {
  const r = route.request(), u = r.url(), m = r.method();
  // money-safe: ninguna escritura real de venta/caja/impresión sale de esta prueba
  if (/supabase\.co/.test(u) && m !== 'GET' &&
      /registrar_venta|crear_venta|guardar_venta|abrir_caja|cerrar_caja|anular|emitir|imprimir|cobrar|marcar_pago|adhesivo|membrete|devoluc/i.test(u)) return route.abort();
  return route.continue();
});

// Toda escritura real al backend queda ABORTADA salvo lo que stubbeamos explícitamente.
await ctx.route(/get_flags/,           r => json(r, { purganteToken: PURGANTE_TOKEN }));
await ctx.route(/purgante_reportar/,   r => json(r, { ok: true }));
await ctx.route(/mint-me/,             r => json(r, { ok: true, token: 'TOKEN-TEST-CLAUDE', exp: Math.floor(Date.now() / 1000) + 3600 }));
await ctx.route(/registrar_presencia/, r => json(r, { ok: true, debeCerrar: false }));
await ctx.route(/caja_activa_zona/,    r => json(r, { ok: true, data: { hayCaja: true, cajero: VEND, idCaja: 'CAJA-LOCAL-TESTCLAUDE', abiertaTs: Date.now(), estacion: 'Caja-01' } }));
await ctx.route(/catalogo_pos_rls/,    r => json(r, { status: 'success', data: DB }));
await ctx.route(/zona_stock/,          r => json(r, { ok: true, stock: DB.STOCK_ZONAS }));
await ctx.route(/zona_guias_listar/,   r => json(r, { ok: true, guias: GUIAS_SERVIDOR.slice() }));
await ctx.route(/zona_guia_detalle/,   r => json(r, { ok: true, items: [] }));
await ctx.route(/registrar_guia_directo/, r => {
  if (r.request().method() === 'OPTIONS') return json(r, {});
  let p = {};
  try { p = JSON.parse(r.request().postData() || '{}').p || {}; } catch (_) {}
  if (!REGISTRAR_OK) return r.fulfill({ status: 500, headers: CORS, contentType: 'application/json', body: JSON.stringify({ ok: false, error: 'caida simulada' }) });
  GUIAS_SERVIDOR.unshift({ id_guia: p.idGuia, fecha: new Date().toISOString(), vendedor: p.vendedor, zona: p.zona, tipo: p.tipo, observacion: p.observacion || '', zona_destino: p.zona_destino || '', estado: 'ABIERTA' });
  return json(r, { ok: true, idGuia: p.idGuia, estado: 'ABIERTA' });
});
await ctx.route(/recibir_guia_wh_cerrar/, r => json(r, { ok: true, data: { estado: 'COMPLETO', total_enviado: 3, total_escaneado: 3, lineas_dif: 0, detalle: [] } }));
await ctx.route(/recibir_guia_wh/, r => json(r, { ok: true, data: {
  idGuiaWH: 'G1786000000001', zonaWH: ZONA, verificada: false,
  detalle: ITEMS.slice(0, 3).map(([n, c]) => ({ codBarra: c, descripcion: n, cantidad: 5 }))
} }));
const page = await ctx.newPage();
const errores = [];      // pageerrors = excepciones JS reales (deben ser 0)
const ruido   = [];      // console.error de red: la prueba usa un token falso → 401 esperables
page.on('pageerror', e => errores.push('PAGEERROR: ' + e.message));
page.on('console', m => {
  if (m.type() !== 'error') return;
  const t = m.text();
  // Ruido del entorno headless, ajeno al cambio: 401 por el token falso, el realtime que el
  // harness no deja abrir y el prompt de notificaciones que WebKit exige tras un gesto real.
  if (/Failed to load resource|favicon|net::ERR|401|403|CORS|WebSocket|Notification prompting/i.test(t)) { ruido.push(t); return; }
  errores.push('[console.error] ' + t);
});

await page.addInitScript(([dev, zona, vend, db]) => {
  const L = localStorage;
  L.setItem('mosexpress_deviceId', dev);
  L.setItem('mosexpress_purgante_done', '1786159982');
  L.setItem('mosexpress_device_auth_date', String(Date.now()));
  L.setItem('mosexpress_device_auth_id', dev);
  L.setItem('mosexpress_device_auth_date_lima', new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Lima' }).format(new Date()));
  L.setItem('mosexpress_device_verify_version', '999999');
  L.setItem('mosexpress_last_autosync', String(Date.now()));
  L.setItem('mosexpress_session_date', new Date().toDateString());
  L.setItem('mosexpress_config', JSON.stringify({
    completado: true, vendedor: vend, zona: zona, esCajero: false,
    estacion: { idEstacion: 'EST-TEST-1', Zona_ID: zona, Estacion_Nombre: 'Caja-01', PrintNode_ID: '0', Serie_Boleta: 'BM01', Serie_Factura: 'FM01' }
  }));
  L.setItem('mosexpress_caja_activa', JSON.stringify({ idCaja: 'CAJA-LOCAL-TESTCLAUDE', monto: 50, fecha: Date.now() }));
  const _gi = L.getItem.bind(L);
  L.getItem = k => (String(k).indexOf('me_perms_done_v') === 0 ? '1' : _gi(k));
  // El overlay de permisos se auto-abre ~3 s tras el load (en WebKit siempre) y se come los
  // clicks: en la prueba se mantiene cerrado, como si el usuario ya lo hubiera aceptado.
  setInterval(() => { try { const ov = document.getElementById('mePermsOverlay'); if (ov) ov.classList.remove('is-open'); } catch (_) {} }, 250);
  const req = indexedDB.open('mosexpress_idb', 1);
  req.onupgradeneeded = () => { try { req.result.createObjectStore('kv'); } catch (_) {} };
  req.onsuccess = () => { try { req.result.transaction('kv', 'readwrite').objectStore('kv').put(db, 'mosexpress_db'); } catch (_) {} };
}, [DEV, ZONA, VEND, DB]);

// ── utilidades ─────────────────────────────────────────────────────────────────
const R = [];
const chk = (nombre, cond, detalle) => {
  R.push({ nombre, ok: !!cond, detalle });
  console.log((cond ? 'PASS  ' : 'FAIL  ') + nombre + (detalle ? '   → ' + detalle : ''));
};
const shot = async (n) => { const f = PFX + n + '.png'; await page.screenshot({ path: f }); return f; };
const SHOTS = [];
const shotOk = async (n) => { SHOTS.push(await shot(n)); };

const bootear = async () => {
  await page.goto('http://127.0.0.1:' + PORT + '/index.html', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('[data-navtab="TOOLS"]', { state: 'attached', timeout: 90000 });
  await page.waitForTimeout(1500);
};
// El overlay de permisos (#mePermsOverlay) se auto-abre 3 s tras el load y se come los
// clicks. En WebKit aparece siempre; se cierra como lo haría el usuario con "Listo".
const cerrarOverlayPermisos = async () => {
  await page.evaluate(() => {
    const ov = document.getElementById('mePermsOverlay');
    if (ov && ov.classList.contains('is-open')) ov.classList.remove('is-open');
  });
};
const irAGuias = async () => {
  await cerrarOverlayPermisos();
  // En escritorio la nav inferior se auto-colapsa (modoPro + navColapsado): se la despierta
  // con el mismo mouseenter que usa un usuario real antes de tocar el tab.
  await page.evaluate(() => { const n = document.querySelector('[data-nav-root]'); if (n) n.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true })); });
  await page.waitForTimeout(450);
  await page.click('[data-navtab="TOOLS"]');
  await page.waitForTimeout(500);
  await page.click('[data-guia-abrir]');
  await page.waitForSelector('[data-guia-cerrar]', { timeout: 15000 });
  await page.waitForTimeout(900);
};
const salirDeGuias = async () => { await page.click('[data-guia-cerrar]'); await page.waitForTimeout(700); };
const elegirSubtipo = async (texto) => {
  await page.click('button:has(p:text-is("' + texto + '"))');
  await page.waitForTimeout(600);
};
const agregar = async (cod) => {
  const inp = page.locator('[data-ctx-input="guiaBusq"]:visible').first();
  await inp.click(); await inp.fill('');
  await inp.type(cod, { delay: 6 });
  await page.keyboard.press('Enter');
  await page.waitForTimeout(450);
};
const nFilas = () => page.locator('[data-guia-row]').count();
const drafts = () => page.evaluate(() => {
  const out = {};
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    if (k && k.indexOf('mosexpress_guia_draft_') === 0) { try { out[k] = JSON.parse(localStorage.getItem(k)); } catch (_) { out[k] = 'ILEGIBLE'; } }
  }
  return out;
});
const draftDe = async (tipoD) => {
  const d = await drafts();
  const k = Object.keys(d).find(x => x.indexOf('mosexpress_guia_draft_' + tipoD + '_') === 0);
  return k ? d[k] : null;
};

console.log('\n╔═══ BORRADORES DE GUÍAS · ' + MOTOR.toUpperCase() + ' @' + ANCHO + ' ═══╗\n');
await bootear();
chk('boot: la app carga y llega al POS', await page.locator('[data-navtab="TOOLS"]').count() > 0);

// ═══ ESCENARIO 1 · agrego 3 productos → salgo → vuelvo → están ═══════════════
console.log('\n=== E1 · 3 productos → salir del módulo → volver ===');
await irAGuias();
await elegirSubtipo('Pedido de jefa');
await agregar(ITEMS[0][1]); await agregar(ITEMS[1][1]); await agregar(ITEMS[2][1]);
const e1a = await nFilas();
await page.waitForTimeout(700);                       // deja correr el debounce de 400 ms
const d1 = await draftDe('SALIDA');
await shotOk('e1a_antes_de_salir');
chk('E1 los 3 productos están en el formulario', e1a === 3, e1a + ' filas');
chk('E1 el borrador de SALIDA bajó a disco', !!d1 && (d1.items || []).length === 3, d1 ? d1.items.length + ' items · ' + d1.subtipo : 'sin borrador');
chk('E1 el JSON del borrador trae fecha/tocadoEn/zona', !!d1 && d1.fecha === new Date().toDateString() && !!d1.tocadoEn && d1.zona === ZONA, d1 ? d1.fecha + ' · ' + d1.zona : '');
await salirDeGuias();
chk('E1 al salir el módulo se cerró', await page.locator('[data-guia-cerrar]').count() === 0);
await irAGuias();
const e1b = await nFilas();
await shotOk('e1b_al_volver');
chk('E1 ✅ AL VOLVER LOS 3 PRODUCTOS SIGUEN AHÍ', e1b === 3, e1b + ' filas');
chk('E1 se ve el aviso "retomamos tu guía a medio hacer"', await page.locator('[data-gd-aviso]').count() > 0);
chk('E1 se retomó el subtipo correcto (Pedido de jefa)', /Pedido de jefa/.test(await page.locator('[data-gd-aviso]').innerText().catch(() => '')));

// ═══ ESCENARIO 2 · F5 ════════════════════════════════════════════════════════
console.log('\n=== E2 · agrego uno más → F5 → vuelvo a guías ===');
await agregar(ITEMS[3][1]);
const e2a = await nFilas();
await page.waitForTimeout(700);
await page.reload({ waitUntil: 'domcontentloaded' });
await page.waitForSelector('[data-navtab="TOOLS"]', { state: 'attached', timeout: 90000 });
await page.waitForTimeout(1500);
await irAGuias();
const e2b = await nFilas();
await shotOk('e2_tras_F5');
chk('E2 ✅ TRAS RECARGAR (F5) LOS PRODUCTOS SIGUEN AHÍ', e2b === e2a && e2b === 4, 'antes ' + e2a + ' · después ' + e2b);

// ═══ ESCENARIO 6 · el aviso "falta terminar" se ve ═══════════════════════════
console.log('\n=== E6 · chip global "falta terminar" + bandeja 📋 N en curso ===');
const bandejaVisible = await page.locator('[data-gd-bandeja-btn]').count() > 0;
const txtBandeja = bandejaVisible ? (await page.locator('[data-gd-bandeja-btn]').innerText()).replace(/\s+/g, ' ').trim() : '';
await page.click('[data-gd-bandeja-btn]');
await page.waitForTimeout(500);
const filasBandeja = await page.locator('[data-gd-fila]').count();
await shotOk('e6a_bandeja_en_curso');
chk('E6 la bandeja "📋 N en curso" existe y cuenta', bandejaVisible && /1 en curso/i.test(txtBandeja), txtBandeja);
chk('E6 la bandeja lista el borrador vivo', filasBandeja === 1, filasBandeja + ' filas');
await page.click('[data-gd-bandeja-btn]');            // colapsar
await salirDeGuias();
await page.waitForTimeout(600);
const chipVisible = await page.locator('[data-gd-chip]').isVisible().catch(() => false);
const chipTxt = chipVisible ? (await page.locator('[data-gd-chip]').innerText()).replace(/\s+/g, ' ').trim() : '';
await shotOk('e6b_chip_falta_terminar');
chk('E6 ✅ FUERA DEL MÓDULO SE VE EL CHIP "guía a medio hacer"', chipVisible && /medio hacer/i.test(chipTxt), chipTxt);
// un tap en el chip retoma
await page.click('[data-gd-chip]');
await page.waitForSelector('[data-guia-cerrar]', { timeout: 15000 });
await page.waitForTimeout(1000);
chk('E6 un tap en el chip abre guías y retoma el borrador', await nFilas() === 4, (await nFilas()) + ' filas');

// ═══ ESCENARIO 5 · los 3 tipos conviven ══════════════════════════════════════
console.log('\n=== E5 · SALIDA + ENTRADA + RECIBIR conviven sin pisarse ===');
// ENTRADA (ingreso libre)
await page.click('button:has-text("↑ Entrada")');
await page.waitForTimeout(600);
await elegirSubtipo('Ingreso libre');
await agregar(ITEMS[4][1]); await agregar(ITEMS[5][1]);
await page.waitForTimeout(700);
const dSal = await draftDe('SALIDA'), dEnt = await draftDe('ENTRADA');
chk('E5 el borrador de SALIDA NO fue pisado por el de ENTRADA', !!dSal && dSal.items.length === 4, dSal ? dSal.items.length + ' items' : 'perdido');
chk('E5 el borrador de ENTRADA se guardó aparte', !!dEnt && dEnt.items.length === 2, dEnt ? dEnt.items.length + ' items · ' + dEnt.subtipo : 'sin borrador');
// RECIBIR de almacén
await page.click('button:has-text("↑ Entrada")');
await page.waitForTimeout(500);
await page.click('button:has(p:text-is("Recibir guía de almacén"))');
await page.waitForTimeout(700);
const rwInput = page.locator('[data-ctx-input="rwIdGuia"]').first();
await rwInput.click(); await rwInput.fill('G1786000000001');
await page.keyboard.press('Enter');
await page.waitForTimeout(1200);
const rwIn = page.locator('[data-ctx-input="rwBusq"]').first();
for (const c of [ITEMS[0][1], ITEMS[1][1]]) { await rwIn.click(); await rwIn.fill(''); await rwIn.type(c, { delay: 6 }); await page.keyboard.press('Enter'); await page.waitForTimeout(400); }
await page.waitForTimeout(700);
const dRec = await draftDe('RECIBIR');
await shotOk('e5a_recibir_conteo');
chk('E5 el borrador de RECIBIR se guardó', !!dRec && dRec.items.length === 2, dRec ? dRec.items.length + ' items' : 'sin borrador');
const todos = await drafts();
chk('E5 ✅ LOS 3 TIPOS COEXISTEN (3 claves distintas)', Object.keys(todos).length === 3, Object.keys(todos).map(k => k.split('_draft_')[1]).join(' | '));
// salir de recibir y volver → el conteo sigue
await page.click('[data-rw-cerrar]');
await page.waitForTimeout(600);
await page.click('button:has-text("↑ Entrada")');
await page.waitForTimeout(400);
await page.click('button:has(p:text-is("Recibir guía de almacén"))');
await page.waitForTimeout(900);
const rwFilas = await page.locator('[data-rw-row]').count();
await shotOk('e5b_recibir_retomado');
chk('E5 el conteo de RECIBIR se retoma al reabrir', rwFilas === 2, rwFilas + ' líneas');
await page.click('[data-rw-cerrar]');
await page.waitForTimeout(500);
// bandeja con los 3
await page.click('[data-gd-bandeja-btn]');
await page.waitForTimeout(500);
const txt3 = (await page.locator('[data-gd-bandeja-btn]').innerText()).replace(/\s+/g, ' ').trim();
await shotOk('e5c_bandeja_3_tipos');
chk('E5 la bandeja muestra los 3 en curso', /3 en curso/i.test(txt3), txt3);
await page.click('[data-gd-bandeja-btn]');
await page.waitForTimeout(300);

// ═══ ESCENARIO 3 · confirmo con éxito → el borrador desaparece ═══════════════
console.log('\n=== E3 · confirmar la guía de SALIDA con éxito ===');
await page.click('button:has-text("↓ Salida")');
await page.waitForTimeout(600);
await page.click('[data-gd-bandeja-btn]');
await page.waitForTimeout(400);
await page.click('[data-gd-fila="SALIDA"]');
await page.waitForTimeout(900);
const antesConf = await nFilas();
await shotOk('e3a_antes_de_confirmar');
chk('E3 el borrador de SALIDA se retomó para confirmarlo', antesConf === 4, antesConf + ' filas');
await page.click('[data-guia-confirmar]:visible');
await page.waitForTimeout(4000);                       // POST + reconciliación
const dSalPost = await draftDe('SALIDA');
await shotOk('e3b_tras_confirmar');
chk('E3 ✅ TRAS CONFIRMAR CON ÉXITO EL BORRADOR DESAPARECE', dSalPost === null, dSalPost ? JSON.stringify(dSalPost).slice(0, 120) : 'clave borrada');
chk('E3 la guía llegó al servidor de prueba', GUIAS_SERVIDOR.length === 1, GUIAS_SERVIDOR.length + ' guías · ' + (GUIAS_SERVIDOR[0] || {}).id_guia);
const quedan = await drafts();
chk('E3 los otros dos borradores siguen intactos', Object.keys(quedan).length === 2, Object.keys(quedan).map(k => k.split('_draft_')[1]).join(' | '));

// ═══ ANTIDUPLICADO · el POST se cae → el borrador queda `envio` y se resuelve ══
console.log('\n=== ANTIDUPLICADO · POST caído → el borrador NO se ofrece a ciegas ===');
REGISTRAR_OK = false;
await elegirSubtipo('Pedido de jefa');
await agregar(ITEMS[0][1]); await agregar(ITEMS[1][1]);
await page.waitForTimeout(700);
await page.click('[data-guia-confirmar]:visible');
await page.waitForTimeout(1200);
const dEnvio = await draftDe('SALIDA');
chk('AD el borrador queda marcado `envio` con el idGuia idempotente',
    !!dEnvio && !!dEnvio.envio && /^G-/.test(String(dEnvio.envio.idGuia)) && (dEnvio.envio.items || []).length === 2,
    dEnvio && dEnvio.envio ? dEnvio.envio.idGuia + ' · ' + dEnvio.envio.items.length + ' items' : 'sin marca');
await salirDeGuias(); await page.waitForTimeout(400);
await irAGuias();                                       // resolver: el servidor NO tiene la guía…
await page.waitForTimeout(1500);
const dEnvio2 = await draftDe('SALIDA');
chk('AD antes de los 90 s de gracia sigue marcado "⏳ enviándose" (no se ofrece a ciegas)',
    !!dEnvio2 && !!dEnvio2.envio, dEnvio2 && dEnvio2.envio ? 'sigue en vuelo' : 'se ofreció demasiado pronto');
const enVuelo = await page.locator('[data-gd-bandeja-btn]').innerText().catch(() => '');
await shotOk('ad_en_vuelo');
await page.click('[data-gd-bandeja-btn]'); await page.waitForTimeout(400);
const filaSalRetomable = await page.locator('[data-gd-fila="SALIDA"]').count();
await page.click('[data-gd-bandeja-btn]'); await page.waitForTimeout(200);
chk('AD la bandeja lo cuenta como "en curso" pero NO lo ofrece como retomable',
    /en curso/i.test(enVuelo.replace(/\s+/g, ' ')) && filaSalRetomable === 0,
    enVuelo.replace(/\s+/g, ' ').trim() + ' · filas retomables SALIDA=' + filaSalRetomable);
// envejecemos la marca >90 s y volvemos: el servidor sigue sin la guía ⇒ retomable
await page.evaluate(() => {
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    if (k && k.indexOf('mosexpress_guia_draft_SALIDA_') === 0) {
      const o = JSON.parse(localStorage.getItem(k));
      if (o.envio) { o.envio.ts = Date.now() - 200000; localStorage.setItem(k, JSON.stringify(o)); }
    }
  }
});
await salirDeGuias(); await page.waitForTimeout(400);
await irAGuias(); await page.waitForTimeout(2500);
const dRes = await draftDe('SALIDA');
chk('AD ✅ con el servidor RESPONDIENDO y sin la guía, el borrador vuelve a ser retomable',
    !!dRes && !dRes.envio && dRes.reintento === true && (dRes.items || []).length === 2,
    dRes ? ('envio=' + JSON.stringify(dRes.envio) + ' reintento=' + dRes.reintento + ' items=' + (dRes.items || []).length) : 'se perdió');
await shotOk('ad_retomable');
// y ahora al revés: la guía SÍ existe en el servidor ⇒ el borrador se limpia solo
REGISTRAR_OK = true;
await page.evaluate(() => {
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    if (k && k.indexOf('mosexpress_guia_draft_SALIDA_') === 0) {
      const o = JSON.parse(localStorage.getItem(k));
      o.envio = { idGuia: 'G-YA-EXISTE-EN-SERVIDOR', localId: 'G-LOCAL-x', ts: Date.now() - 200000, items: o.items };
      o.items = [];
      localStorage.setItem(k, JSON.stringify(o));
    }
  }
});
GUIAS_SERVIDOR.unshift({ id_guia: 'G-YA-EXISTE-EN-SERVIDOR', fecha: new Date().toISOString(), vendedor: VEND, zona: ZONA, tipo: 'SALIDA_JEFA', observacion: '', zona_destino: '', estado: 'ABIERTA' });
await salirDeGuias(); await page.waitForTimeout(400);
await irAGuias(); await page.waitForTimeout(2500);
const dYa = await draftDe('SALIDA');
chk('AD ✅ si la guía SÍ está en el historial real, el borrador se borra (cero duplicados)', dYa === null, dYa ? JSON.stringify(dYa).slice(0, 140) : 'clave borrada');

// ═══ ESCENARIO 4 · borrador de AYER ══════════════════════════════════════════
console.log('\n=== E4 · borrador de AYER → no se restaura ===');
await salirDeGuias(); await page.waitForTimeout(400);
// se limpian los otros tipos para que el ÚNICO candidato a restaurar sea el de ayer
await page.evaluate(() => { for (let i = localStorage.length - 1; i >= 0; i--) { const k = localStorage.key(i); if (k && k.indexOf('mosexpress_guia_draft_') === 0) localStorage.removeItem(k); } });
await page.evaluate(([zona, vend, codigos]) => {
  const ayer = new Date(Date.now() - 86400000).toDateString();
  localStorage.setItem('mosexpress_guia_draft_SALIDA_' + zona + '_' + vend, JSON.stringify({
    v: 1, tipo: 'SALIDA', subtipo: 'SALIDA_JEFA', zona: zona, zonaDestino: '', obs: 'de ayer',
    items: codigos.map((c, i) => ({ cod_barras: c, nombre: 'VIEJO ' + i, cantidad: 3, stockActual: 9, unidadMedida: 'NIU' })),
    guiaWH: null, fecha: ayer, tocadoEn: Date.now() - 86400000, envio: null, reintento: false
  }));
}, [ZONA, VEND, [ITEMS[0][1], ITEMS[1][1], ITEMS[2][1]]]);
await irAGuias();
await page.waitForTimeout(1200);
const e4Filas = await nFilas();
const dAyer = await draftDe('SALIDA');
const chipTrasAyer = await page.locator('[data-gd-fila="SALIDA"]').count();
await shotOk('e4_borrador_de_ayer');
chk('E4 ✅ EL BORRADOR DE AYER NO SE RESTAURA', e4Filas === 0, e4Filas + ' filas en el formulario');
chk('E4 el borrador de ayer se descarta solo (clave eliminada)', dAyer === null, dAyer ? 'sobrevivió' : 'descartado en silencio');
chk('E4 tampoco aparece en la bandeja de "en curso"', chipTrasAyer === 0, chipTrasAyer + ' filas de SALIDA');

// ═══ ESCENARIO 7 · purga REAL del purgante ═══════════════════════════════════
console.log('\n=== E7 · purga REAL (get_flags con token nuevo) → el borrador sobrevive ===');
await page.click('button:has-text("↓ Salida")'); await page.waitForTimeout(600);
await elegirSubtipo('Pedido de jefa');
await agregar(ITEMS[0][1]); await agregar(ITEMS[2][1]); await agregar(ITEMS[3][1]);
await page.waitForTimeout(800);
const dPre = await draftDe('SALIDA');
const nAntes = await page.evaluate(() => localStorage.length);
chk('E7 hay un borrador de 3 productos antes de purgar', !!dPre && dPre.items.length === 3, dPre ? dPre.items.length + ' items' : 'sin borrador');
PURGANTE_TOKEN = String(Date.now());                    // el servidor "ordena" purga
await page.reload({ waitUntil: 'domcontentloaded' });
await page.waitForTimeout(4000);                        // el purgante limpia y hace location.replace
await page.waitForSelector('[data-navtab="TOOLS"]', { state: 'attached', timeout: 90000 });
await page.waitForTimeout(2000);
const doneTok  = await page.evaluate(() => localStorage.getItem('mosexpress_purgante_done'));
const urlPv    = page.url();
const nDespues = await page.evaluate(() => localStorage.length);
const dPost = await draftDe('SALIDA');
await shotOk('e7a_tras_purga');
chk('E7 el purgante REALMENTE corrió (token consumido + recarga ?pv=)',
    doneTok === PURGANTE_TOKEN && urlPv.indexOf('pv=' + PURGANTE_TOKEN) > -1,
    'done=' + doneTok + ' · url=' + urlPv.split('/').pop() + ' · claves ' + nAntes + ' → ' + nDespues);
chk('E7 ✅ EL BORRADOR SOBREVIVIÓ A LA PURGA', !!dPost && (dPost.items || []).length === 3, dPost ? dPost.items.length + ' items' : 'SE PERDIÓ TRABAJO');
await irAGuias();
await page.waitForTimeout(1200);
const e7Filas = await nFilas();
await shotOk('e7b_retomado_tras_purga');
chk('E7 y se retoma normal tras la purga', e7Filas === 3, e7Filas + ' filas');

// ═══ EXTRA · descartar con confirmación no-nativa ════════════════════════════
console.log('\n=== EXTRA · descartar (confirmación en dos toques, sin diálogo nativo) ===');
const hayAviso = await page.locator('[data-gd-aviso]').count() > 0;
if (hayAviso) {
  await page.click('[data-gd-aviso] button:has-text("Descartar")');
  await page.waitForTimeout(400);
  const pideConf = await page.locator('[data-gd-descartar-si]').count() > 0;
  await shotOk('extra_descartar_confirma');
  chk('EXTRA descartar pide confirmación (no borra al primer toque)', pideConf && (await draftDe('SALIDA')) !== null);
  if (pideConf) {
    await page.click('[data-gd-descartar-si]');
    await page.waitForTimeout(800);
    chk('EXTRA al confirmar, el borrador se borra y el formulario queda limpio',
        (await draftDe('SALIDA')) === null && (await nFilas()) === 0);
  }
} else {
  chk('EXTRA aviso de retoma presente para probar el descarte', false, 'no se pintó el aviso');
}

// ═══ EXTRA · el reloj de inactividad es de 2 h ═══════════════════════════════
const ms2h = await page.evaluate(() => {
  const src = document.documentElement.innerHTML;
  return /GUIA_INACTIVIDAD_MS = 2 \* 60 \* 60 \* 1000/.test(src);
});
chk('EXTRA el reloj de inactividad de guías es de 2 HORAS', ms2h);

// ── errores ────────────────────────────────────────────────────────────────────
console.log('\n=== PAGEERRORS / console.error de la app: ' + errores.length + ' ===');
errores.slice(0, 20).forEach(e => console.log('  ' + e));
console.log('(ruido de red esperado con token falso: ' + ruido.length + ' respuestas 401/CORS de supabase)');
chk('0 pageerrors', errores.length === 0, errores.slice(0, 3).join(' ; '));

const fail = R.filter(r => !r.ok).length;
console.log('\n════════ ' + MOTOR + '@' + ANCHO + ' · ' + (R.length - fail) + ' PASS / ' + fail + ' FAIL ════════');
console.log('screenshots: ' + SHOTS.join(', '));
await browser.close();
srv.close();
process.exit(fail ? 1 : 0);
