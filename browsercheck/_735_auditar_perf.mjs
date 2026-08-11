// [735] Medición de rendimiento del botón "Auditar" (Personal del día).
// Mide: clic→primer feedback visual, long tasks (>50ms) con CPU throttling 4x,
// intervalos/timeouts/listeners vivos, y degradación tras navegar N veces.
//
// Uso: node _735_auditar_perf.mjs            (repo local, mide el código de trabajo)
//      PROD=1 node _735_auditar_perf.mjs     (producción levo19.github.io/MOS)
//      CPU=4  (default 4)  NAVS=20  LARGA=1  TAG=antes
import { chromium } from 'playwright';
import http from 'http';
import fs from 'fs';
import path from 'path';

const ROOT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS';
const OUT  = ROOT + '/browsercheck';
const PROD = process.env.PROD === '1';
const CPU  = parseInt(process.env.CPU || '4', 10);
const NAVS = parseInt(process.env.NAVS || '0', 10);
const TAG  = process.env.TAG || 'x';
const w    = ms => new Promise(r => setTimeout(r, ms));

const MIME = { '.html':'text/html', '.js':'text/javascript', '.json':'application/json',
  '.css':'text/css', '.png':'image/png', '.svg':'image/svg+xml', '.ico':'image/x-icon',
  '.webmanifest':'application/manifest+json' };

let base = 'https://levo19.github.io/MOS/';
let srv = null;
if (!PROD) {
  srv = http.createServer((req, res) => {
    let rel = decodeURIComponent(req.url.split('?')[0]);
    if (rel === '/' || rel === '') rel = '/index.html';
    const f = path.join(ROOT, rel);
    if (!f.startsWith(path.join(ROOT))) { res.writeHead(403).end(); return; }
    fs.readFile(f, (e, buf) => {
      if (e) { res.writeHead(404).end('404'); return; }
      res.writeHead(200, { 'content-type': MIME[path.extname(f).toLowerCase()] || 'application/octet-stream',
                           'cache-control': 'no-store' });
      res.end(buf);
    });
  });
  await new Promise(r => srv.listen(0, '127.0.0.1', r));
  base = 'http://127.0.0.1:' + srv.address().port + '/';
}
console.log('base =', base, '· cpuThrottle =', CPU + 'x', '· navs =', NAVS);

const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906477',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude735' })
};

// ── Instrumentación inyectada ANTES de todo script de la página ──
const INSTR = () => {
  const W = window;
  W.__M = {
    long: [],            // long tasks
    ivAlive: new Set(),  // intervalos vivos
    ivMade: 0, ivKilled: 0,
    toAlive: new Set(), toMade: 0,
    lis: 0, lisRm: 0,
    net: [],             // fetch: {url, ms, ts}
    marks: {}
  };
  // long tasks
  try {
    new PerformanceObserver(l => {
      for (const e of l.getEntries()) {
        W.__M.long.push({ t: Math.round(e.startTime), d: Math.round(e.duration),
          a: (e.attribution || []).map(x => x.name + ':' + (x.containerName || x.containerType || '')).join(',') });
      }
    }).observe({ entryTypes: ['longtask'] });
  } catch (_) {}
  // timers
  const oSI = W.setInterval, oCI = W.clearInterval, oST = W.setTimeout, oCT = W.clearTimeout;
  W.setInterval = function (fn, ms) {
    const id = oSI.apply(W, arguments);
    W.__M.ivAlive.add(id); W.__M.ivMade++;
    try { W.__M['ivSrc_' + id] = String(fn).slice(0, 90).replace(/\s+/g, ' '); } catch (_) {}
    return id;
  };
  W.clearInterval = function (id) { if (W.__M.ivAlive.delete(id)) W.__M.ivKilled++; return oCI.apply(W, arguments); };
  W.setTimeout = function (fn, ms) {
    const id = oST.apply(W, [function () { W.__M.toAlive.delete(id); try { return fn.apply(this, arguments); } catch (e) { throw e; } }, ms]);
    W.__M.toAlive.add(id); W.__M.toMade++;
    return id;
  };
  W.clearTimeout = function (id) { W.__M.toAlive.delete(id); return oCT.apply(W, arguments); };
  // listeners
  const oAdd = EventTarget.prototype.addEventListener, oRm = EventTarget.prototype.removeEventListener;
  EventTarget.prototype.addEventListener = function () { W.__M.lis++; return oAdd.apply(this, arguments); };
  EventTarget.prototype.removeEventListener = function () { W.__M.lisRm++; return oRm.apply(this, arguments); };
  // fetch timing
  const oF = W.fetch;
  W.fetch = function (u) {
    const t0 = performance.now();
    const url = String((u && u.url) || u || '');
    return oF.apply(W, arguments).then(r => {
      W.__M.net.push({ u: url.slice(0, 130), ms: Math.round(performance.now() - t0), ts: Math.round(t0), st: r.status });
      return r;
    }, e => { W.__M.net.push({ u: url.slice(0, 130), ms: Math.round(performance.now() - t0), ts: Math.round(t0), st: 'ERR' }); throw e; });
  };
};

const snap = () => ({
  iv: window.__M.ivAlive.size, ivMade: window.__M.ivMade, ivKilled: window.__M.ivKilled,
  to: window.__M.toAlive.size, toMade: window.__M.toMade,
  lis: window.__M.lis, lisRm: window.__M.lisRm, lisNet: window.__M.lis - window.__M.lisRm,
  dom: document.getElementsByTagName('*').length,
  heapMB: performance.memory ? +(performance.memory.usedJSHeapSize / 1048576).toFixed(1) : null,
  canales: (function () { try { return (window.__MOS_RT_CH && window.__MOS_RT_CH.length) || null; } catch (_) { return null; } })()
});

const b = await chromium.launch({ args: ['--enable-precise-memory-info'] });
const ctx = await b.newContext({ viewport: { width: 1280, height: 1400 } });
const p = await ctx.newPage();
const errs = [];
p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0, 180)));
await p.addInitScript(seed => { for (const [k, v] of Object.entries(seed)) localStorage.setItem(k, v); }, SEED);
await p.addInitScript(INSTR);

const cdp = await ctx.newCDPSession(p);
await cdp.send('Emulation.setCPUThrottlingRate', { rate: CPU });

const T0 = Date.now();
p.setDefaultTimeout(120000);
await p.goto(base + '?nc=' + Date.now(), { waitUntil: 'domcontentloaded', timeout: 120000 });
await w(24000);
await p.evaluate(() => { const el = [...document.querySelectorAll('button,a')].find(x => /Entrar a MOS/i.test(x.textContent || '')); if (el) el.click(); });
await w(3000);
const sBoot = await p.evaluate(snap);
console.log('\n── tras BOOT ──', JSON.stringify(sBoot));

await p.evaluate(() => { try { MOS.nav('finanzas'); } catch (_) {} });
let listo = false;
for (let i = 0; i < 45 && !listo; i++) {
  await w(1500);
  listo = await p.evaluate(() => document.querySelectorAll('#finPersonalList .eval-card').length > 0);
}
console.log(listo ? '✓ Personal del día pintó' : '⚠ Personal del día NO pintó');
// esperar quietud
let prev = '', quieto = 0;
for (let i = 0; i < 30 && quieto < 3; i++) {
  await w(1500);
  const h = await p.evaluate(() => (document.getElementById('finPersonalList') || {}).innerHTML || '');
  quieto = (h && h === prev) ? quieto + 1 : 0; prev = h;
}
const sFin = await p.evaluate(snap);
console.log('── tras FINANZAS ──', JSON.stringify(sFin));

// long tasks del boot+render
const longBoot = await p.evaluate(() => window.__M.long.slice());
const top = longBoot.slice().sort((a, b2) => b2.d - a.d).slice(0, 12);
console.log('longtasks boot+finanzas: n=' + longBoot.length,
  '· total=' + longBoot.reduce((s, x) => s + x.d, 0) + 'ms',
  '· >200ms=' + longBoot.filter(x => x.d > 200).length);
console.log('  top:', top.map(x => x.d + 'ms@' + x.t).join(' '));

// ══════════ MEDICIÓN DEL CLIC EN "AUDITAR" ══════════
const BTN_SEL = '#finPersonalList button[onclick*="abrirAuditar"]';
const esperarBoton = async () => {
  for (let i = 0; i < 60; i++) {
    const n = await p.evaluate(s => document.querySelectorAll(s).length, BTN_SEL);
    if (n > 0) return n;
    await w(1000);
  }
  const diag = await p.evaluate(() => {
    const c = document.getElementById('finPersonalList');
    return { view: (window.S && window.S.view) || '?', cards: c ? c.querySelectorAll('.eval-card').length : -1,
             btns: c ? c.querySelectorAll('button').length : -1, html: c ? c.innerHTML.slice(0, 200) : 'sin cont' };
  });
  console.log('⚠ sin botón Auditar. diag=', JSON.stringify(diag));
  return 0;
};

const medirClic = async (etiqueta) => {
  await esperarBoton();
  const res = await p.evaluate(async (sel) => {
    const btn = document.querySelector(sel);
    if (!btn) return { error: 'sin botón Auditar' };
    window.__M.long.length = 0;
    const modal = document.getElementById('modalAuditar');
    const t0 = performance.now();
    let tFeedback = null, tModal = null;
    // Observa CUALQUIER cambio visual: clase/atributo/estilo del botón, o modal visible
    const obs = new MutationObserver(() => {
      if (tFeedback == null) tFeedback = performance.now() - t0;
    });
    obs.observe(btn, { attributes: true, childList: true, subtree: true, characterData: true });
    const obsM = new MutationObserver(() => {
      if (tModal == null && modal && !modal.classList.contains('hidden')) tModal = performance.now() - t0;
    });
    if (modal) obsM.observe(modal, { attributes: true, attributeFilter: ['class', 'style'] });
    const netAntes = window.__M.net.length;
    btn.click();
    // esperar hasta 20s a que el modal se vea
    for (let i = 0; i < 200; i++) {
      await new Promise(r => setTimeout(r, 100));
      if (modal && !modal.classList.contains('hidden')) { if (tModal == null) tModal = performance.now() - t0; break; }
    }
    await new Promise(r => setTimeout(r, 1200));
    obs.disconnect(); obsM.disconnect();
    const net = window.__M.net.slice(netAntes).map(x => ({ u: x.u.replace(/^https?:\/\/[^/]+/, ''), ms: x.ms, st: x.st }));
    const lt = window.__M.long.slice();
    return {
      feedbackMs: tFeedback == null ? null : Math.round(tFeedback),
      modalMs: tModal == null ? null : Math.round(tModal),
      btnDisabled: btn.disabled,
      redes: net,
      long: lt, longTotal: lt.reduce((s, x) => s + x.d, 0), longMax: lt.length ? Math.max(...lt.map(x => x.d)) : 0
    };
  }, BTN_SEL);
  if (res.error) { console.log(`\n══ CLIC AUDITAR [${etiqueta}] ══ ${res.error}`); return res; }
  console.log(`\n══ CLIC AUDITAR [${etiqueta}] ══`);
  console.log(' feedback visual : ' + res.feedbackMs + ' ms');
  console.log(' modal visible   : ' + res.modalMs + ' ms');
  console.log(' long tasks      : n=' + (res.long || []).length + ' total=' + res.longTotal + 'ms max=' + res.longMax + 'ms');
  console.log(' red disparada   : ' + JSON.stringify(res.redes));
  return res;
};

const clic1 = await medirClic('1er clic');
await p.screenshot({ path: `${OUT}/_735_${TAG}_modal.png` });
await p.evaluate(() => { try { MOS.cerrarAuditar(); } catch (_) {} });
await w(1500);
const clic2 = await medirClic('2do clic (cache caliente)');
await p.evaluate(() => { try { MOS.cerrarAuditar(); } catch (_) {} });
await w(1000);

// ══════════ TRIPLE CLIC (usuario impaciente) ══════════
await esperarBoton();
const triple = await p.evaluate(async (sel) => {
  const btn = document.querySelector(sel);
  if (!btn) return { error: 'sin botón' };
  const n0 = window.__M.net.length;
  btn.click(); await new Promise(r => setTimeout(r, 120));
  btn.click(); await new Promise(r => setTimeout(r, 120));
  btn.click();
  await new Promise(r => setTimeout(r, 9000));
  const net = window.__M.net.slice(n0).map(x => x.u.replace(/^https?:\/\/[^/]+/, '').slice(0, 60));
  return { total: net.length, resumen: net.reduce((a, u) => { a[u] = (a[u] || 0) + 1; return a; }, {}) };
}, BTN_SEL);
console.log('\n══ TRIPLE CLIC ══', JSON.stringify(triple, null, 1));
await p.evaluate(() => { try { MOS.cerrarAuditar(); } catch (_) {} });

// ══════════ SESIÓN LARGA ══════════
if (NAVS > 0) {
  const vistas = ['dashboard', 'finanzas', 'catalogo', 'liquidaciones', 'finanzas'];
  for (let i = 0; i < NAVS; i++) {
    const v = vistas[i % vistas.length];
    await p.evaluate(vv => { try { MOS.nav(vv); } catch (_) {} }, v);
    await w(2500);
  }
  await p.evaluate(() => { try { MOS.nav('finanzas'); } catch (_) {} });
  await w(8000);
  const sNav = await p.evaluate(snap);
  console.log(`\n── tras ${NAVS} navegaciones ──`, JSON.stringify(sNav));
  const huerf = await p.evaluate(() => {
    const out = {};
    window.__M.ivAlive.forEach(id => { const s = window.__M['ivSrc_' + id] || '?'; out[s] = (out[s] || 0) + 1; });
    return out;
  });
  console.log(' intervalos vivos por origen:');
  Object.entries(huerf).sort((a, b2) => b2[1] - a[1]).forEach(([k, v]) => console.log('   ' + String(v).padStart(3) + '× ' + k));
  if (process.env.LARGA === '1') {
    console.log('\n… reposando 10 min con los pollers vivos …');
    for (let i = 0; i < 10; i++) { await w(60000); process.stdout.write('.'); }
    const sLarga = await p.evaluate(snap);
    console.log('\n── tras 10 min de reposo ──', JSON.stringify(sLarga));
    const c3 = await medirClic('tras sesión larga');
    void c3;
  }
}

console.log('\nerrs:', errs.length ? errs.join(' | ') : '0 pageerrors');
console.log('duración total del run:', Math.round((Date.now() - T0) / 1000) + 's');
await b.close();
if (srv) srv.close();
process.exit(0);
