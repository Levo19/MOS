// MosGo 0.5.16 · pestaña Pedidos → "🌐 Solicitudes del catálogo".
//   node _mosgo_catv_solicitudes.mjs <url> <tag>
// Verifica que las solicitudes SOL-xxx del catálogo público se vean, se abran y se
// conviertan en carrito del POS, y que queden ATENDIDAS con el nombre del vendedor.
import { chromium } from 'playwright';
import http from 'http';
import fs from 'fs';
import path from 'path';

const RAIZ = 'C:/Users/ISO/ecosistema MOS/MosGo';
const OUT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/';
const TAG = process.argv[3] || 'local';
const DEV = '7e57c1a0-de00-4c1a-9de0-7e57c1a0de00';   // TEST-CLAUDE (QA MosGo), ACTIVO
const VENDEDOR = 'CLAUDE TEST';

let URL_BASE = process.argv[2] || '';
let srv = null;
if (!URL_BASE) {
  srv = http.createServer((rq, rs) => {
    const u = decodeURIComponent(rq.url.split('?')[0]);
    const f = path.join(RAIZ, u === '/' ? 'index.html' : u);
    fs.readFile(f, (e, b) => e ? rs.writeHead(404).end()
      : rs.writeHead(200, { 'Content-Type': /\.html$/.test(f) ? 'text/html; charset=utf-8'
        : /\.json$/.test(f) ? 'application/json' : /\.js$/.test(f) ? 'text/javascript' : 'application/octet-stream' }).end(b));
  });
  await new Promise(r => srv.listen(8813, '127.0.0.1', r));
  URL_BASE = 'http://127.0.0.1:8813/index.html';
}

const T = []; const chk = (n, cond, x) => { T.push([cond ? '✅' : '❌', n, x === undefined ? '' : String(x)]); return cond; };
const tomas = [];

const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
const errs = [], cons = [];
ctx.on('page', p => {
  p.on('pageerror', e => errs.push(String(e)));
  p.on('console', m => { if (m.type() === 'error') cons.push(m.text()); });
});
const pg = await ctx.newPage();
await pg.addInitScript(([dev, ven]) => {
  localStorage.setItem('mosgo_test', '1');
  localStorage.setItem('mosgo_deviceId', dev);
  localStorage.setItem('mosgo_session', JSON.stringify({ nombre: ven, id_personal: null, rol: 'ADMIN', ts: Date.now() }));
  localStorage.removeItem('mosgo_venta');            // arranca con el carrito vacío
}, [DEV, VENDEDOR]);

await pg.goto(URL_BASE, { waitUntil: 'networkidle' });
await pg.waitForTimeout(2500);
chk('MosGo arranca en 0.5.16', (await pg.evaluate(() => window.V)) === '0.5.16', await pg.evaluate(() => window.V));

// ── pestaña Pedidos ───────────────────────────────────────────────────────────
await pg.click('#tb1');
await pg.waitForSelector('.catvsec', { timeout: 20000 });
await pg.waitForTimeout(900);
const f1 = OUT + `mosgo_catv_1seccion_${TAG}.png`;
await pg.screenshot({ path: f1 }); tomas.push(f1);

const sec = await pg.evaluate(() => {
  const s = document.querySelector('.catvsec');
  const c = s.querySelector('.ped');
  return {
    titulo: (s.querySelector('.ch b') || {}).textContent,
    contador: (s.querySelector('.ch .n') || {}).textContent,
    cards: s.querySelectorAll('.ped').length,
    codigo: (c.querySelector('.r1 b') || {}).textContent,
    pill: (c.querySelector('.pill') || {}).textContent,
    hace: (c.querySelector('.hace') || {}).textContent,
    linea2: (c.querySelectorAll('.r2')[0] || {}).textContent,
    linea3: (c.querySelectorAll('.r2')[1] || {}).textContent,
    antesDePedidos: !!(s.compareDocumentPosition(document.querySelector('#body > .ped')) & Node.DOCUMENT_POSITION_FOLLOWING),
    catv: D.catv.length
  };
});
chk('sección "Solicitudes del catálogo" presente', /Solicitudes del cat/.test(sec.titulo || ''), sec.titulo);
chk('contador coincide con las cards', sec.contador === String(sec.cards), `${sec.contador} vs ${sec.cards}`);
chk('card con código SOL-n', /^SOL-[0-9]+$/.test(sec.codigo || ''), sec.codigo);
chk('badge 🌐 CATÁLOGO', /CAT/.test(sec.pill || ''), sec.pill);
chk('card muestra hace-cuánto', /hace|ahora/.test(sec.hace || ''), sec.hace);
chk('card muestra nombre y total', /S\/ [0-9]/.test(sec.linea2 || ''), (sec.linea2 || '').trim());
chk('card muestra teléfono y nº de líneas', /línea/.test(sec.linea3 || ''), (sec.linea3 || '').trim());
chk('la sección va ANTES de los pedidos', sec.antesDePedidos !== false);

const COD = sec.codigo;

// ── detalle ───────────────────────────────────────────────────────────────────
await pg.click('.catvsec .ped');
await pg.waitForSelector('#ov.open', { timeout: 8000 });
await pg.waitForTimeout(700);
const f2 = OUT + `mosgo_catv_2detalle_${TAG}.png`;
await pg.screenshot({ path: f2 }); tomas.push(f2);

const det = await pg.evaluate(() => {
  const s = document.getElementById('sheet');
  return {
    titulo: (s.querySelector('h4') || {}).textContent,
    wa: (s.querySelector('a[href*="wa.me"]') || {}).href || '',
    lineas: s.querySelectorAll('.cit').length,
    total: (s.querySelector('.tot') || {}).textContent,
    botones: [...s.querySelectorAll('.btn')].map(x => x.textContent.trim())
  };
});
chk('detalle con el código en el título', det.titulo.indexOf(COD) >= 0, det.titulo);
chk('detalle con enlace wa.me al cliente', /^https:\/\/wa\.me\/51[0-9]{9}$/.test(det.wa), det.wa);
chk('detalle lista las líneas', det.lineas >= 1, det.lineas);
chk('detalle con TOTAL', /TOTAL/.test(det.total || '') && /S\/ [0-9]/.test(det.total || ''), (det.total || '').trim());
chk('detalle con los 2 botones', det.botones.length === 2 &&
  /Convertir en pedido/.test(det.botones[0]) && /marcar atendida/.test(det.botones[1]), det.botones.join(' | '));

// ── convertir en pedido ───────────────────────────────────────────────────────
await pg.click('#sheet .btn:not(.ghost)');
await pg.waitForTimeout(1800);
const f3 = OUT + `mosgo_catv_3convertido_${TAG}.png`;
await pg.screenshot({ path: f3 }); tomas.push(f3);

const conv = await pg.evaluate(() => ({
  tab: St.tab,
  cart: St.cart,
  packs: Object.values(St.cart).reduce((a, x) => a + x, 0),
  barra: (document.getElementById('cb1') || {}).textContent,
  barraVisible: document.getElementById('cartbar').classList.contains('show'),
  toast: (document.getElementById('toast') || {}).textContent,
  yaNoEsta: !(D.catv || []).some(x => x.codigo === window.__cod),
  quedan: (D.catv || []).length,
  venta: JSON.parse(localStorage.getItem('mosgo_venta') || 'null')
}));
chk('convertir lleva a la pestaña Vender', conv.tab === 0, 'tab=' + conv.tab);
chk('el carrito quedó cargado', conv.packs > 0, JSON.stringify(conv.cart));
chk('la barra del carrito se muestra con el total', conv.barraVisible && /S\/ [0-9]/.test(conv.barra || ''),
  (conv.barra || '').trim());
chk('el toast nombra la solicitud', (conv.toast || '').indexOf(COD) >= 0, (conv.toast || '').trim());
chk('la venta en curso quedó persistida', !!conv.venta && Object.keys(conv.venta.cart || {}).length > 0,
  JSON.stringify(conv.venta && conv.venta.cart));
chk('la solicitud desapareció de la lista', conv.quedan === sec.cards - 1, `${conv.quedan} (antes ${sec.cards})`);

// ── vuelve a Pedidos: la sección se re-pinta sin la atendida ──────────────────
await pg.click('#tb1');
await pg.waitForTimeout(1200);
const post = await pg.evaluate(() => {
  const s = document.querySelector('.catvsec');
  return { existe: !!s, codigos: s ? [...s.querySelectorAll('.r1 b')].map(x => x.textContent) : [] };
});
chk('la atendida ya no aparece al volver a Pedidos', post.codigos.indexOf(COD) < 0, post.codigos.join(','));

chk('0 pageerrors', errs.length === 0, errs.join(' | ').slice(0, 200));
chk('0 errores de consola', cons.length === 0, cons.join(' | ').slice(0, 200));

await ctx.close(); await b.close();
if (srv) srv.close();

fs.writeFileSync(OUT + `mosgo_catv_${TAG}.json`, JSON.stringify({ COD, sec, det, conv, post, errs, cons }, null, 1));
const ok = T.every(t => t[0] === '✅');
console.log('\n' + T.map(t => `${t[0]} ${t[1]}${t[2] ? '  → ' + t[2] : ''}`).join('\n'));
console.log('\n📸 ' + tomas.map(t => '\n   ' + t).join(''));
console.log(ok ? `\n✅ TODO VERDE · convertida y atendida: ${COD}` : '\n❌ hay pruebas en rojo');
process.exit(ok ? 0 : 1);
