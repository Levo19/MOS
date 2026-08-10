// [734] Webcheck de "Personal del día" agrupado POR ZONA.
// Exige 0 pageerrors y captura la sección agrupada en 390 / 768 / 1280.
// Sirve el repo LOCAL (para probar el cambio antes de desplegar) o, con
// PROD=1, la app desplegada en levo19.github.io/MOS.
//
// Pass A: datos reales del día (zonas con política).
// Pass B: intercepta las RPC para forzar los dos casos que el dueño quiere
//         vigilar — una persona SIN zona y una zona SIN política configurada.
//
// Uso: node _734_personal_por_zona.mjs        (local)
//      PROD=1 node _734_personal_por_zona.mjs (producción)
import { chromium } from 'playwright';
import http from 'http';
import fs from 'fs';
import path from 'path';

const ROOT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS';
const OUT  = process.env.SHOTS_DIR || 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck';
const PROD = process.env.PROD === '1';
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
console.log('base =', base);

const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906477',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude734' })
};

// Viewport ALTO a propósito: el screenshot de un elemento más alto que la ventana
// sale con la mitad de abajo en negro (Chromium lo cose por trozos). Con la ventana
// más alta que la card, la captura entra de una sola pieza.
const VPS = [[390, 2600, '390'], [768, 2000, '768'], [1280, 1500, '1280']];
let errTotal = 0;
const resumen = [];

// Reescritura de las RPC para el pass B (casos borde).
// Ojo: NO reusar `response: r` al reescribir el cuerpo — arrastra content-encoding:gzip
// y el navegador no puede decodificar el JSON plano (la lista sale vacía sin error visible).
function limpiaHdrs(r) {
  const h = { ...r.headers() };
  delete h['content-encoding']; delete h['content-length'];
  return h;
}
async function rutearBordes(p) {
  await p.route('**/rest/v1/rpc/zonas_lista', async route => {
    const r = await route.fetch();
    let j; try { j = await r.json(); } catch (_) { return route.fulfill({ response: r }); }
    const arr = (j && j.data) || [];
    arr.forEach(z => { if (String(z.idZona).toUpperCase() === 'ZONA-02') z.politicaJSON = ''; });
    return route.fulfill({ status: r.status(), headers: limpiaHdrs(r), body: JSON.stringify(j) });
  });
  await p.route('**/rest/v1/rpc/personal_dia_lista', async route => {
    const r = await route.fetch();
    let j; try { j = await r.json(); } catch (_) { return route.fulfill({ response: r }); }
    const arr = (j && j.data) || [];
    const pos = arr.filter(x => ['CAJERO', 'VENDEDOR'].includes(String(x.rol || '').toUpperCase()));
    if (pos.length) { pos[0].zonaSesion = ''; if (pos[0].kpis) pos[0].kpis.zonaPrincipal = ''; }
    return route.fulfill({ status: r.status(), headers: limpiaHdrs(r), body: JSON.stringify(j) });
  });
}

const b = await chromium.launch();
for (const modo of ['A', 'B']) {
  for (const [W, H, tag] of VPS) {
    if (modo === 'B' && tag !== '390' && tag !== '1280') continue;
    const ctx = await b.newContext({ viewport: { width: W, height: H }, hasTouch: W < 800 });
    const p = await ctx.newPage();
    const errs = [];
    p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0, 160)));
    await p.addInitScript(seed => { for (const [k, v] of Object.entries(seed)) localStorage.setItem(k, v); }, SEED);
    if (modo === 'B') await rutearBordes(p);

    await p.goto(base + '?nc=' + Date.now(), { waitUntil: 'domcontentloaded' });
    await w(21000);
    await p.evaluate(() => { const el = [...document.querySelectorAll('button,a')].find(x => /Entrar a MOS/i.test(x.textContent || '')); if (el) el.click(); });
    await w(2000);
    await p.evaluate(() => { try { MOS.nav('finanzas'); } catch (_) {} });
    // El P&L del día tarda: esperar a que la sección Personal pinte de verdad.
    let listo = false;
    for (let i = 0; i < 40 && !listo; i++) {
      await w(1500);
      listo = await p.evaluate(() => document.querySelectorAll('#finPersonalList .fin-pers-group').length > 0);
    }
    if (!listo) console.log('⚠ la sección Personal no pintó grupos en 60s');
    // La sección repinta varias veces (cache → getPersonalDiaFast → accesosDuplicados).
    // Esperar a que el HTML quede QUIETO: si no, el screenshot sale de un paint intermedio.
    let prev = '', quieto = 0;
    for (let i = 0; i < 40 && quieto < 3; i++) {
      await w(1500);
      const h = await p.evaluate(() => (document.getElementById('finPersonalList') || {}).innerHTML || '');
      quieto = (h && h === prev) ? quieto + 1 : 0;
      prev = h;
    }

    const info = await p.evaluate(() => {
      const cont = document.getElementById('finPersonalList');
      if (!cont) return { error: 'sin #finPersonalList' };
      const grupos = [...cont.querySelectorAll('.fin-pers-group')].map(g => ({
        area: g.getAttribute('data-area'),
        tit:  g.querySelector('.fin-pers-group-tit')?.textContent.trim(),
        zonas: [...g.querySelectorAll('.fin-zgrp')].map(z => ({
          nom:    z.querySelector('.fin-zgrp-nom')?.textContent.trim(),
          n:      z.querySelector('.fin-zgrp-n')?.textContent.trim(),
          reglas: (z.querySelector('.fin-zgrp-regla') || z.querySelector('.fin-zgrp-warn'))?.textContent.trim(),
          venta:  z.querySelector('.fin-zgrp-venta')?.textContent.trim(),
          alto:   Math.round(z.getBoundingClientRect().height)
        })),
        cards: g.querySelectorAll('.eval-card').length
      }));
      const desborde = document.documentElement.scrollWidth > window.innerWidth + 1;
      return { ver: window.MOS_VER || '', grupos, desborde, scrollW: document.documentElement.scrollWidth, innerW: window.innerWidth };
    });

    console.log(`\n── pass ${modo} · ${tag}px ──`);
    console.log(JSON.stringify(info, null, 1));
    if (errs.length) { errTotal += errs.length; console.log('🚨 pageerrors:', errs.join(' | ')); }
    else console.log('✓ 0 pageerrors');
    if (info.desborde) console.log('🚨 scroll horizontal del body');

    const file = `${OUT}/_734_personal_zona_${modo}_${tag}.png`;
    try {
      await p.evaluate(() => {
        const c = document.querySelector('.fin-modcard-personal') || document.getElementById('finPersonalList');
        if (c) c.scrollIntoView({ block: 'start' });
      });
      await w(900);
      const el = await p.$('.fin-modcard-personal');
      if (el) await el.screenshot({ path: file, timeout: 15000 });
      else await p.screenshot({ path: file, fullPage: false });
    } catch (e) {
      console.log('⚠ shot de la card falló (' + String(e).split('\n')[0].slice(0, 80) + '), voy con la página');
      await p.screenshot({ path: file, fullPage: false });
    }
    console.log('shot →', file);
    resumen.push([modo, tag, errs.length, info.desborde ? 'DESBORDE' : 'ok', (info.grupos || []).map(g => g.area + ':' + g.zonas.length + 'z/' + g.cards + 'p').join(' ')]);
    await p.unrouteAll({ behavior: 'ignoreErrors' }).catch(() => {});
    await ctx.close();
  }
}
await b.close();
if (srv) srv.close();
console.log('\n═══ RESUMEN ═══');
resumen.forEach(r => console.log(r.join(' · ')));
console.log(errTotal === 0 ? '✓ TOTAL pageerrors = 0' : '🚨 pageerrors = ' + errTotal);
process.exit(errTotal === 0 ? 0 : 1);
