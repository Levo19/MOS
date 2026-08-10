// REPRO del cuelgue "Verificando dispositivo" de MOS 2.43.725
// Escenario que mis pruebas NO cubrieron: el equipo YA tenía 2.43.724 instalado
// (service worker activo + localStorage del modulo 1.0.29) y RECIBE el 725.
// Sirve MOS desde disco y cambia el arbol 724 -> 725 entre cargas.
import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';
import http from 'http';

const SP = 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad';
const LIVE = path.join(SP, 'mos_live');
const DEV = '7e57c1a0-de1c-4a7e-b0de-c47a10906474';
const PORT = 4141;

function copiar(src) {
  fs.rmSync(LIVE, { recursive: true, force: true });
  fs.cpSync(src, LIVE, { recursive: true });
}

const MIME = { '.html': 'text/html', '.js': 'application/javascript', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.css': 'text/css' };
function servir() {
  return http.createServer((req, res) => {
    let p = decodeURIComponent(req.url.split('?')[0]);
    if (p === '/' || p.endsWith('/')) p += 'index.html';
    const f = path.join(LIVE, p);
    if (!f.startsWith(LIVE) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); res.end('no'); return; }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(f)] || 'text/plain', 'Cache-Control': 'no-cache' });
    res.end(fs.readFileSync(f));
  }).listen(PORT);
}

async function mirar(page, etiqueta, ms) {
  const t0 = Date.now();
  let final = null;
  while (Date.now() - t0 < ms) {
    const r = await page.evaluate(() => {
      const da = window.DeviceAuth;
      const st = da && da.estado ? da.estado() : null;
      const ov = document.getElementById('deviceAuthOverlay');
      return {
        v: da ? da.VERSION : null,
        e: st ? st.estado : null,
        g: !!(da && da.enGracia && da.enGracia()),
        ov: !!ov,
        txt: ov ? (ov.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 70) : '',
        pb: document.documentElement.classList.contains('da-pre-block')
      };
    }).catch(() => null);
    if (r && r.e && r.e !== 'VERIFICANDO' && r.e !== 'INIT') { final = { ...r, t: Date.now() - t0 }; break; }
    await page.waitForTimeout(500);
  }
  const ult = await page.evaluate(() => {
    const da = window.DeviceAuth; const st = da && da.estado ? da.estado() : null;
    const ov = document.getElementById('deviceAuthOverlay');
    return { v: da ? da.VERSION : null, e: st ? st.estado : null, g: !!(da && da.enGracia && da.enGracia()),
             ov: !!ov, txt: ov ? (ov.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 70) : '',
             pb: document.documentElement.classList.contains('da-pre-block') };
  }).catch(() => ({}));
  console.log(`  ${etiqueta}: DA v${ult.v} estado=${ult.e} gracia=${ult.g} overlay=${ult.ov} preBlock=${ult.pb}`);
  if (ult.txt) console.log(`     overlay: "${ult.txt}"`);
  console.log(`     -> estado terminal ${final ? 'a los ' + final.t + 'ms' : 'NUNCA (colgado en ' + ult.e + ')'}`);
  return final;
}

(async () => {
  copiar(path.join(SP, 'mos724'));
  const srv = servir();
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(String(e.message || e)));
  const cons = []; page.on('console', m => { const t = m.text(); if (/DeviceAuth|prefetch|Error|error/.test(t)) cons.push(t.slice(0, 150)); });

  // El index apunta al modulo por URL absoluta del CDN -> lo servimos desde el arbol local.
  await ctx.route('**/levo19.github.io/MOS/assets/auth/device-auth.js*', route => {
    route.fulfill({ status: 200, contentType: 'application/javascript',
      body: fs.readFileSync(path.join(LIVE, 'assets/auth/device-auth.js'), 'utf8') });
  });
  await ctx.route('**/levo19.github.io/MOS/assets/**', route => {
    const rel = new URL(route.request().url()).pathname.replace('/MOS/', '');
    const f = path.join(LIVE, rel);
    if (fs.existsSync(f)) route.fulfill({ status: 200, contentType: 'application/javascript', body: fs.readFileSync(f, 'utf8') });
    else route.fulfill({ status: 200, contentType: 'application/javascript', body: '' });
  });

  await page.addInitScript((d) => localStorage.setItem('mos_device_id', d), DEV);

  console.log('\n=== FASE 1 · instala 2.43.724 (estado del dueño ANTES) ===');
  await page.goto(`http://localhost:${PORT}/`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await mirar(page, '724 primera carga', 40000);
  await page.waitForTimeout(6000);   // deja que el SW instale/active y precachee
  const sw1 = await page.evaluate(async () => {
    const rs = await navigator.serviceWorker.getRegistrations();
    return rs.map(r => ({ active: !!r.active, sc: r.scope }));
  });
  console.log('  service workers:', JSON.stringify(sw1));

  console.log('\n=== FASE 2 · llega 2.43.725 y el dueño recarga ===');
  copiar(path.join(SP, 'mos725'));
  errs.length = 0; cons.length = 0;
  await page.reload({ waitUntil: 'domcontentloaded', timeout: 60000 }).catch(e => console.log('  reload: ' + e.message));
  const f2 = await mirar(page, '725 tras el upgrade', 60000);
  console.log('  pageerrors:', errs.length, errs.slice(0, 5));
  console.log('  consola:', cons.slice(0, 12));

  if (!f2) {
    console.log('\n=== FASE 3 · segunda recarga (SW 725 ya activo) ===');
    errs.length = 0; cons.length = 0;
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 60000 }).catch(() => {});
    await mirar(page, '725 recarga 2', 60000);
    console.log('  pageerrors:', errs.length, errs.slice(0, 5));
    console.log('  consola:', cons.slice(0, 12));
  }

  await browser.close();
  srv.close();
})();
