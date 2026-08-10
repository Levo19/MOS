// Mide el TIEMPO HASTA ESTADO RESUELTO (no "VERIFICANDO") con TODA la red a
// Supabase COLGADA. Compara 2.43.724 (estable) contra 2.43.725 (el que colgó).
// Variantes de cache local: sin cache · cache de hoy (lo que tenía el dueño).
// Uso: node _repro_deadline.mjs
import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';
import http from 'http';

const SP = 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad';
const LIVE = path.join(SP, 'mos_live');
const DEV = '7e57c1a0-de1c-4a7e-b0de-c47a10906474';
const PORT = 4142;
const SB = 'rzbzdeipbtqkzjqdchqk.supabase.co';
const LIMITE = 60000;

const MIME = { '.html': 'text/html', '.js': 'application/javascript', '.json': 'application/json' };
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
function copiar(src) { fs.rmSync(LIVE, { recursive: true, force: true }); fs.cpSync(src, LIVE, { recursive: true }); }

async function correr(browser, etiqueta, arbol, conCache) {
  copiar(path.join(SP, arbol));
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(String(e.message || e)));
  // TODA petición a Supabase queda COLGADA (nunca resuelve) — socket muerto.
  await ctx.route(u => String(u).includes(SB), () => {});
  await ctx.route('**/levo19.github.io/MOS/assets/**', route => {
    const rel = new URL(route.request().url()).pathname.replace('/MOS/', '');
    const f = path.join(LIVE, rel);
    route.fulfill({ status: 200, contentType: 'application/javascript', body: fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : '' });
  });
  await page.addInitScript(([d, cache]) => {
    localStorage.setItem('mos_device_id', d);
    if (cache) {
      // Lo que tenía el dueño: verificado HOY con el modulo 1.0.29 (sin marca _ok_ms).
      localStorage.setItem('mos_device_auth_devid', d);
      localStorage.setItem('mos_device_auth_date_lima', new Date().toLocaleString('en-CA', { timeZone: 'America/Lima' }).slice(0, 10));
    }
  }, [DEV, conCache]);

  const t0 = Date.now();
  await page.goto(`http://localhost:${PORT}/`, { waitUntil: 'domcontentloaded', timeout: 60000 }).catch(() => {});
  let tFinal = null, estFinal = null;
  while (Date.now() - t0 < LIMITE) {
    const r = await page.evaluate(() => {
      const da = window.DeviceAuth; const st = da && da.estado ? da.estado() : null;
      const ov = document.getElementById('deviceAuthOverlay');
      return { e: st ? st.estado : null, g: !!(da && da.enGracia && da.enGracia()),
               ovTxt: ov ? (ov.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 40) : '' };
    }).catch(() => null);
    if (r && r.e && r.e !== 'VERIFICANDO' && r.e !== 'INIT') { tFinal = Date.now() - t0; estFinal = r; break; }
    await page.waitForTimeout(250);
  }
  const fin = await page.evaluate(() => {
    const da = window.DeviceAuth; const st = da && da.estado ? da.estado() : null;
    const ov = document.getElementById('deviceAuthOverlay');
    return { v: da ? da.VERSION : null, e: st ? st.estado : null, g: !!(da && da.enGracia && da.enGracia()),
             ov: !!ov, txt: ov ? (ov.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 45) : '',
             pb: document.documentElement.classList.contains('da-pre-block') };
  }).catch(() => ({}));
  console.log(`  ${etiqueta.padEnd(34)} DA v${fin.v} · estado=${String(fin.e).padEnd(16)} gracia=${fin.g}`);
  console.log(`     tiempo hasta estado RESUELTO: ${tFinal === null ? '>' + LIMITE + 'ms  ❌ COLGADO EN VERIFICANDO' : tFinal + 'ms'}`);
  console.log(`     overlay="${fin.txt}" preBlock=${fin.pb} pageerrors=${errs.length}`);
  await ctx.close();
  return tFinal;
}

(async () => {
  const srv = servir();
  const browser = await chromium.launch({ headless: true });
  console.log('\n### TIEMPO HASTA ESTADO RESUELTO con TODA la red a Supabase COLGADA ###');
  await correr(browser, '724 · sin cache previo', 'mos724', false);
  await correr(browser, '724 · con cache de hoy', 'mos724', true);
  await correr(browser, '725 · sin cache previo', 'mos725', false);
  await correr(browser, '725 · con cache de hoy', 'mos725', true);
  await browser.close();
  srv.close();
})();
