// [755] Diff visual del build ESTÁTICO de Tailwind contra producción (que todavía usa el CDN).
// Un purge de más no se ve en un diff de archivos: se ve como una pantalla rota. Este script
// recorre las 10 vistas principales + los overlays pesados en DOS destinos y saca la misma
// captura de cada uno, además de un puñado de mediciones automáticas de "elemento sin estilo"
// (fondo claro donde debía ser oscuro, texto sin color, borde/padding perdido).
//
//   DEST=local  → sirve el worktree por http (build nuevo, sin CDN)
//   DEST=prod   → https://levo19.github.io/MOS/ (referencia, con CDN)
//
// Los PNG caen en browsercheck/_755_<dest>_<vista>.png (ignorados por .gitignore).
import { createRequire } from 'module';
const require = createRequire('C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/');
const { chromium } = require('playwright');
import http from 'http'; import fs from 'fs'; import path from 'path';

const ROOT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/.claude/worktrees/agent-aa328909aa8900a58';
const DEST = process.env.DEST || 'local';
const w = ms => new Promise(r => setTimeout(r, ms));
const MIME = { '.html':'text/html','.js':'text/javascript','.json':'application/json','.css':'text/css','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json','.md':'text/markdown' };

let srv = null, base = 'https://levo19.github.io/MOS/';
if (DEST === 'local') {
  srv = http.createServer((req, res) => {
    let rel = decodeURIComponent(req.url.split('?')[0]);
    if (rel === '/' || rel === '') rel = '/index.html';
    const f = path.join(ROOT, rel);
    fs.readFile(f, (e, buf) => {
      if (e) { res.writeHead(404).end('404'); return; }
      res.writeHead(200, { 'content-type': MIME[path.extname(f).toLowerCase()] || 'application/octet-stream', 'cache-control': 'no-store' });
      res.end(buf);
    });
  });
  await new Promise(r => srv.listen(0, '127.0.0.1', r));
  base = 'http://127.0.0.1:' + srv.address().port + '/';
}

// Devices FIJOS de prueba — jamás sembrar uno nuevo (ensuciaría mos.dispositivos).
const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906477',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude755' })
};

const VISTAS = ['dashboard','catalogo','almacen','zona','proveedores','cajas','finanzas','tributario','facturacion','config'];

// VW/VH permiten repetir el mismo recorrido en móvil (390x844), que es donde viven
// los breakpoints sm:/md:/lg: — la parte del CSS que un purge mal hecho rompe primero.
const VW = parseInt(process.env.VW || '1280', 10), VH = parseInt(process.env.VH || '1400', 10);
const SUF = VW === 1280 ? '' : '_' + VW;
const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: VW, height: VH }, deviceScaleFactor: 1 });
const p = await ctx.newPage();
const errs = []; p.on('pageerror', e => errs.push(String(e).slice(0, 140)));
const cdnHits = [];
p.on('request', r => { if (/cdn\.tailwindcss\.com/.test(r.url())) cdnHits.push(r.url()); });
// Se vuelve a sembrar en cada navegación PORQUE el "purgante" recarga la página una vez
// al arrancar limpio; sin re-sembrar, el segundo arranque cae en la pantalla de login.
await p.addInitScript(s => { for (const [k, v] of Object.entries(s)) localStorage.setItem(k, v); }, SEED);

await p.goto(base + '?nc=' + Date.now(), { waitUntil: 'domcontentloaded', timeout: 120000 });
await w(22000);
await p.evaluate(() => { const el = [...document.querySelectorAll('button,a')].find(x => /Entrar a MOS/i.test(x.textContent || '')); if (el) el.click(); });
await w(8000);
// Guardia: si seguimos en el login, la comparación no vale nada — mejor gritarlo.
const dentro = await p.evaluate(() => { const o = document.getElementById('loginOverlay'); return !o || o.classList.contains('hidden'); });
console.log('¿entró al panel?: ' + (dentro ? 'SI' : 'NO — la comparación NO sirve'));

// ── Sonda automática: ¿hay utilidades de Tailwind VIVAS? ───────────────────
// Se inyecta una probeta con clases representativas y se lee el estilo calculado.
// Si el purge se comió alguna, su valor sale vacío/transparente y salta acá, no en producción.
const probe = await p.evaluate(() => {
  const CLASES = ['text-rose-400','text-emerald-400','bg-slate-800','border-amber-900/50','text-[10px]','grid-cols-2','border-rose-500/30','border-amber-500/30','border-indigo-500/30','border-slate-500/30','flex','hidden','font-bold','rounded-lg','p-3','gap-2','truncate','shrink-0','font-mono','items-center'];
  const out = {};
  const host = document.createElement('div'); host.style.cssText = 'position:fixed;left:-9999px;top:0';
  document.body.appendChild(host);
  for (const c of CLASES) {
    const d = document.createElement('div'); d.className = c; host.appendChild(d);
    const cs = getComputedStyle(d);
    out[c] = [cs.color, cs.backgroundColor, cs.borderColor, cs.borderWidth, cs.fontSize, cs.display, cs.padding, cs.gap, cs.borderRadius, cs.fontWeight, cs.gridTemplateColumns, cs.fontFamily.slice(0, 18), cs.overflow, cs.flexShrink, cs.alignItems].join('|');
    d.remove();
  }
  host.remove();
  return out;
});

// ── Recorrido de vistas ────────────────────────────────────────────────────
const resumen = [];
for (const v of VISTAS) {
  await p.evaluate(vv => { try { MOS.nav(vv); } catch (_) {} }, v);
  await w(v === 'finanzas' || v === 'catalogo' || v === 'almacen' ? 14000 : 8000);
  await p.screenshot({ path: `_755_${DEST}${SUF}_${v}.png`, fullPage: false }).catch(() => {});
  // Medición de "sin estilo": nodos visibles con fondo claro dentro de una app oscura.
  const m = await p.evaluate(vv => {
    const sec = document.getElementById('view-' + vv);
    if (!sec) return { vista: vv, err: 'sin seccion' };
    const nodos = [...sec.querySelectorAll('*')].filter(e => e.offsetParent !== null);
    let claros = 0, sinColor = 0;
    for (const e of nodos.slice(0, 4000)) {
      const cs = getComputedStyle(e);
      const bg = cs.backgroundColor.match(/\d+/g);
      if (bg && bg.length >= 3 && (+bg[0] + +bg[1] + +bg[2]) > 600 && (bg[3] === undefined || +bg[3] > 0.5)) claros++;
      if (cs.color === 'rgb(0, 0, 0)') sinColor++;
    }
    return { vista: vv, nodos: nodos.length, bgClaros: claros, textoNegro: sinColor, alto: sec.scrollHeight };
  }, v);
  resumen.push(m);
}

// ── Overlays pesados ───────────────────────────────────────────────────────
// Solo LECTURA: se abren y se cierran con Escape. Ninguno escribe nada al abrirse.
async function overlay(nm, abrir, esperaSelector, msExtra) {
  try {
    await abrir();
    if (esperaSelector) await p.waitForSelector(esperaSelector, { timeout: 40000 }).catch(() => {});
    await w(msExtra || 6000);
    const abierto = esperaSelector ? await p.evaluate(s => !!document.querySelector(s), esperaSelector) : true;
    await p.screenshot({ path: `_755_${DEST}${SUF}_ov_${nm}.png`, fullPage: false }).catch(() => {});
    console.log('  overlay ' + nm + ': ' + (abierto ? 'ABIERTO' : 'NO ABRIÓ'));
  } catch (e) { console.log('  overlay ' + nm + ': falló → ' + String(e).slice(0, 80)); }
  await p.keyboard.press('Escape').catch(() => {});
  await w(2000);
}

console.log('\n-- overlays --');
// Mesa de compras → primera card → Modal 1 (Paso 1 · costos)
await overlay('mesa', async () => {
  await p.evaluate(() => { try { MOS.abrirMesaCompras(); } catch (_) {} });
}, '#mesaComprasModal .mesa-card', 7000);
await overlay('compras_p1', async () => {
  await p.evaluate(() => { try { MOS.abrirMesaCompras(); } catch (_) {} });
  await w(7000);
  await p.evaluate(() => { const c = document.querySelector('#mesaComprasModal .mesa-card'); if (c) c.click(); });
}, '#opsDetalleModal, .modal-backdrop.open', 9000);
// Auditar (Finanzas → Personal del día → botón Auditar de la primera card)
await overlay('auditar', async () => {
  await p.evaluate(() => { try { MOS.nav('finanzas'); } catch (_) {} });
  for (let i = 0; i < 30; i++) {
    const n = await p.evaluate(() => document.querySelectorAll('#finPersonalList .eval-card').length);
    if (n > 0) break;
    await w(1500);
  }
  await p.evaluate(() => { const b2 = [...document.querySelectorAll('#finPersonalList button')].find(x => /Auditar/i.test(x.getAttribute('aria-label') || x.textContent || '')); if (b2) b2.click(); });
}, '#modalAuditar:not(.hidden)', 8000);
// Centro de Promociones
await overlay('promos', async () => {
  await p.evaluate(() => { try { MOS.abrirPromoCentro('mis'); } catch (_) {} });
}, '#promoCentro', 8000);

console.log('\n═══ DEST=' + DEST + ' ═══');
console.log('hits a cdn.tailwindcss.com: ' + cdnHits.length);
console.log('errores de página: ' + errs.length + (errs.length ? ' → ' + errs.slice(0, 5).join(' ; ') : ''));
console.log('\n-- utilidades vivas (clase → color|bg|bordeColor|bordeAncho|fontSize|display|padding|gap|radius|weight|cols|font|overflow|shrink|align) --');
for (const [k, v] of Object.entries(probe)) console.log('  ' + k.padEnd(22) + v);
console.log('\n-- vistas --');
for (const r of resumen) console.log('  ' + JSON.stringify(r));
await b.close(); if (srv) srv.close(); process.exit(0);
