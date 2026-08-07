// MosGo 0.5.17 · el pre-pedido del catálogo NO se da por hecho.
//   node _mosgo_catv_flujo.mjs <url> <tag>
// Prueba la regla nueva del dueño:
//   · "Convertir en pedido" SOLO pre-carga el carrito → la solicitud sigue PENDIENTE.
//   · Confirmar el pedido SÍ la marca ATENDIDA con el nombre del vendedor.
//   · Vaciar el carrito la SUELTA (sigue PENDIENTE, para cualquiera).
//   · St.solEnCurso sobrevive a una recarga.
// ruta_pedido_crear va interceptada: se prueba el enganche sin ensuciar ruta.pedidos
// de producción. El catv_atender que dispara es REAL y se verifica contra la tabla.
import { chromium } from 'playwright';
import http from 'http';
import fs from 'fs';
import path from 'path';
import pkg from 'pg';
const { Client } = pkg;

const RAIZ = 'C:/Users/ISO/ecosistema MOS/MosGo';
const OUT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/';
const TAG = process.argv[3] || 'local';
const DEV = '7e57c1a0-de00-4c1a-9de0-7e57c1a0de00';
const VENDEDOR = 'CLAUDE TEST';
const UA_QA = 'harness-flujo-657-' + Date.now();

let URL_BASE = process.argv[2] || '';
let srv = null;
if (!URL_BASE) {
  srv = http.createServer((rq, rs) => {
    const u = decodeURIComponent(rq.url.split('?')[0]);
    const f = path.join(RAIZ, u === '/' ? 'index.html' : u);
    fs.readFile(f, (e, b) => e ? rs.writeHead(404).end()
      : rs.writeHead(200, { 'Content-Type': /\.html$/.test(f) ? 'text/html; charset=utf-8'
        : /\.json$/.test(f) ? 'application/json' : 'text/javascript' }).end(b));
  });
  await new Promise(r => srv.listen(8814, '127.0.0.1', r));
  URL_BASE = 'http://127.0.0.1:8814/index.html';
}

const db = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await db.connect();
const T = []; const chk = (n, cond, x) => { T.push([cond ? '✅' : '❌', n, x === undefined ? '' : String(x)]); return cond; };
const tomas = [];

// ── siembra: 2 solicitudes reales por la RPC pública, como anon ───────────────
const CAT = (await db.query(`select mos.catalogo_virtual() r`)).rows[0].r;
const F = (CAT.familias || []).filter(f => (f.escalones || []).length)[0];
// se barre lo que hayan dejado corridas anteriores: si no, el anti-abuso de 5/hora
// (por teléfono O por user_agent) rechaza la siembra y el test falla por el sitio
// equivocado. Por eso también el teléfono es único por corrida.
await db.query(`delete from mos.catv_solicitudes where coalesce(user_agent,'') like 'harness-flujo-657%'`);
const TEL_QA = '955' + String(Date.now()).slice(-6);
async function sembrar(nombre) {
  await db.query('begin'); await db.query('set local role anon');
  const r = (await db.query(`select mos.catv_solicitar($1::jsonb) r`, [JSON.stringify({
    lineas: [{ id: F.id, escalon_idx: 0, cantidad: 2 }],
    nombre: nombre, telefono: TEL_QA, ua: UA_QA + '-' + nombre
  })])).rows[0].r;
  await db.query('reset role'); await db.query('commit');
  if (!r || !r.codigo) throw new Error('la siembra no devolvió código: ' + JSON.stringify(r));
  return r.codigo;
}
const SOL_A = await sembrar('QA FLUJO A');
const SOL_B = await sembrar('QA FLUJO B');
chk('siembra: 2 solicitudes creadas', !!SOL_A && !!SOL_B, SOL_A + ' / ' + SOL_B);

const estado = async cod => (await db.query(
  `select estado, atendido_por from mos.catv_solicitudes where codigo = $1`, [cod])).rows[0];

// ── navegador ─────────────────────────────────────────────────────────────────
const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
const errs = [], cons = [];
ctx.on('page', p => {
  p.on('pageerror', e => errs.push(String(e)));
  p.on('console', m => { if (m.type() === 'error') cons.push(m.text()); });
});
// el pedido real NO se crea: se prueba el enganche, no ruta_pedido_crear
let pedidoIntentado = null;
await ctx.route('**/rest/v1/rpc/ruta_pedido_crear', async r => {
  pedidoIntentado = JSON.parse(r.request().postData() || '{}');
  await r.fulfill({ status: 200, contentType: 'application/json',
    body: JSON.stringify({ ok: true, id_pedido: 'PED-QA-657', total: 14, ajustados: 0 }) });
});
const pg = await ctx.newPage();
await pg.addInitScript(([dev, ven]) => {
  localStorage.setItem('mosgo_test', '1');
  localStorage.setItem('mosgo_deviceId', dev);
  localStorage.setItem('mosgo_session', JSON.stringify({ nombre: ven, id_personal: null, rol: 'ADMIN', ts: Date.now() }));
  // addInitScript corre en CADA navegación, recarga incluida: si se borrara siempre,
  // el propio test destruiría la venta en curso que quiere comprobar que sobrevive.
  if (!sessionStorage.getItem('qa_init')) {
    sessionStorage.setItem('qa_init', '1');
    localStorage.removeItem('mosgo_venta');
  }
}, [DEV, VENDEDOR]);
// el boot es asíncrono: esperar por D.loaded en vez de por un reloj (si no, openCart
// se encuentra con un catálogo a medio cargar y calc() da 0)
// OJO: `const D = {...}` en un script clásico NO es window.D — hay que preguntar por el
// binding, no por la propiedad (regla vieja del ecosistema, y aquí muerde otra vez).
const listo = () => pg.waitForFunction(
  () => typeof D !== 'undefined' && D.loaded && D.escalones.length > 0, { timeout: 30000 });
await pg.goto(URL_BASE, { waitUntil: 'networkidle' });
await listo();
await pg.waitForTimeout(600);
chk('MosGo arranca en 0.5.17', (await pg.evaluate(() => window.V)) === '0.5.17', await pg.evaluate(() => window.V));

const abrirSol = async cod => {
  await pg.click('#tb1');
  await pg.waitForSelector('.catvsec', { timeout: 20000 });
  await pg.waitForTimeout(700);
  await pg.evaluate(c => UI.openCatv(c), cod);
  await pg.waitForSelector('#ov.open', { timeout: 8000 });
  await pg.waitForTimeout(500);
};

// ═══ 1 · CONVERTIR → pre-carga y NADA MÁS ═══
await abrirSol(SOL_A);
await pg.click('#sheet .btn:not(.ghost)');
await pg.waitForTimeout(1600);

const c1 = await pg.evaluate(() => ({
  sol: St.solEnCurso, tab: St.tab, packs: Object.values(St.cart).reduce((a, x) => a + x, 0),
  guardado: (JSON.parse(localStorage.getItem('mosgo_venta') || '{}')).sol,
  sigueEnLista: (D.catv || []).some(x => x.codigo === window.__a),
  toast: (document.getElementById('toast') || {}).textContent
}));
chk('convertir · St.solEnCurso apunta a la solicitud', c1.sol === SOL_A, c1.sol);
chk('convertir · el carrito quedó pre-cargado', c1.packs > 0, 'packs=' + c1.packs);
chk('convertir · lleva a la pestaña Vender', c1.tab === 0);
chk('convertir · solEnCurso persistido en mosgo_venta', c1.guardado === SOL_A, c1.guardado);
chk('convertir · el toast dice "ajústalo y genera el pedido"',
  /en tu carrito — ajústalo y genera el pedido/.test(c1.toast || ''), (c1.toast || '').trim());

const e1 = await estado(SOL_A);
chk('★ convertir NO marca ATENDIDA (sigue PENDIENTE en la base)',
  e1.estado === 'PENDIENTE' && e1.atendido_por === null, JSON.stringify(e1));

// la card sigue en la sección, ahora con el chip "en tu carrito"
await pg.click('#tb1');
await pg.waitForTimeout(900);
const chip = await pg.evaluate(cod => {
  const cards = [...document.querySelectorAll('.catvsec .ped')];
  const c = cards.find(x => (x.querySelector('.r1 b') || {}).textContent === cod);
  return c ? { existe: true, pill: (c.querySelector('.pill') || {}).textContent.trim(),
    mia: c.classList.contains('catvmia'), pie: (c.querySelectorAll('.r2')[1] || {}).textContent.trim() } : { existe: false };
}, SOL_A);
chk('convertir · la card SIGUE en la sección', chip.existe === true);
chk('convertir · chip "EN TU CARRITO"', /EN TU CARRITO/.test(chip.pill || ''), chip.pill);
chk('convertir · la card se marca como tuya', chip.mia === true);
chk('convertir · el pie invita a generar el pedido', /genera el pedido/.test(chip.pie || ''), chip.pie);
const f1 = OUT + `mosgo_flujo_1encarrito_${TAG}.png`;
await pg.screenshot({ path: f1 }); tomas.push(f1);

// ═══ 2 · sobrevive a una recarga ═══
await pg.reload({ waitUntil: 'networkidle' });
await listo();
await pg.waitForTimeout(600);
const rec = await pg.evaluate(() => ({ sol: St.solEnCurso, packs: Object.values(St.cart).reduce((a, x) => a + x, 0),
  calcN: UI.calc().n }));
chk('recarga · solEnCurso y carrito sobreviven', rec.sol === SOL_A && rec.packs > 0 && rec.calcN > 0, JSON.stringify(rec));

// ═══ 3 · CONFIRMAR el pedido → AHÍ SÍ se marca ATENDIDA ═══
await pg.evaluate(() => UI.go(0));
await pg.waitForTimeout(400);
await pg.evaluate(() => UI.openCart());
await pg.waitForTimeout(500);
await pg.waitForSelector('#btnConfirmar', { timeout: 8000 });
await pg.waitForTimeout(500);
await pg.click('#btnConfirmar');
await pg.waitForTimeout(3500);

chk('confirmar · se intentó crear el pedido real', !!pedidoIntentado && !!(pedidoIntentado.p || {}).items,
  JSON.stringify((pedidoIntentado || {}).p && (pedidoIntentado.p.items || []).length + ' ítems'));
const c3 = await pg.evaluate(() => ({
  sol: St.solEnCurso, packs: Object.values(St.cart).reduce((a, x) => a + x, 0),
  // UI.render() vuelve a llamar a Venta.save() después del clear, así que la clave
  // existe pero VACÍA: lo que importa es que no quede ni carrito ni solicitud pegada.
  guardado: JSON.parse(localStorage.getItem('mosgo_venta') || 'null')
}));
chk('confirmar · solEnCurso limpiado', c3.sol === '', JSON.stringify(c3.sol));
chk('confirmar · carrito y venta en curso vaciados',
  c3.packs === 0 && (!c3.guardado || (!Object.keys(c3.guardado.cart || {}).length && !c3.guardado.sol)),
  JSON.stringify(c3.guardado));

const e3 = await estado(SOL_A);
chk('★ confirmar SÍ marca ATENDIDA con el vendedor',
  e3.estado === 'ATENDIDA' && e3.atendido_por === VENDEDOR, JSON.stringify(e3));
const f3 = OUT + `mosgo_flujo_2confirmado_${TAG}.png`;
await pg.screenshot({ path: f3 }); tomas.push(f3);

// ═══ 4 · vaciar el carrito SUELTA la solicitud ═══
await pg.evaluate(() => { UI.close(); });
await abrirSol(SOL_B);
await pg.click('#sheet .btn:not(.ghost)');
await pg.waitForTimeout(1500);
chk('vaciar · primero se jala SOL_B', (await pg.evaluate(() => St.solEnCurso)) === SOL_B);
await pg.evaluate(() => { UI.openCart(); UI.vaciarCart(); });
await pg.waitForTimeout(400);
await pg.click('#vacConf .btn:not(.ghost)');
await pg.waitForTimeout(1400);
const c4 = await pg.evaluate(() => ({ sol: St.solEnCurso, packs: Object.values(St.cart).reduce((a, x) => a + x, 0) }));
chk('vaciar · solEnCurso se soltó', c4.sol === '' && c4.packs === 0, JSON.stringify(c4));
const e4 = await estado(SOL_B);
chk('★ vaciar el carrito deja la solicitud PENDIENTE para cualquiera',
  e4.estado === 'PENDIENTE' && e4.atendido_por === null, JSON.stringify(e4));

chk('0 pageerrors', errs.length === 0, errs.join(' | ').slice(0, 200));
chk('0 errores de consola', cons.length === 0, cons.join(' | ').slice(0, 200));

await ctx.close(); await b.close();
if (srv) srv.close();

// ── limpieza de lo sembrado ───────────────────────────────────────────────────
const del = (await db.query(`delete from mos.catv_solicitudes where coalesce(user_agent,'') like 'harness-flujo-657%'`)).rowCount;
console.log('\n🧹 limpieza: ' + del + ' solicitudes de QA borradas');
console.log('   quedan en la tabla: ' + (await db.query(`select count(*)::int n from mos.catv_solicitudes`)).rows[0].n);
await db.end();

const ok = T.every(t => t[0] === '✅');
console.log('\n' + T.map(t => `${t[0]} ${t[1]}${t[2] ? '  → ' + t[2] : ''}`).join('\n'));
console.log('\n📸' + tomas.map(t => '\n   ' + t).join(''));
console.log(ok ? '\n✅ TODO VERDE · convertir no atiende · confirmar sí' : '\n❌ hay pruebas en rojo');
process.exit(ok ? 0 : 1);
