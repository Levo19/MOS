// Diagnostico: en WH, con la red colgada y SIN verificacion previa, el modulo
// resuelve a SIN_VERIFICAR pero el overlay sigue diciendo "Verificando dispositivo".
// Traza estado + texto del overlay + quien lo re-renderiza, en el tiempo.
import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';
import http from 'http';

const SP = 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad';
const LIVE = path.join(SP, 'mos_live');
const DA_LOCAL = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/assets/auth/device-auth.js';
const DEV = '7e57c1a0-de1c-4a7e-b0de-c47a10906475';
const PORT = 4147;
const SB = 'rzbzdeipbtqkzjqdchqk.supabase.co';

const MIME = { '.html': 'text/html', '.js': 'application/javascript', '.json': 'application/json', '.css': 'text/css' };
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

(async () => {
  fs.rmSync(LIVE, { recursive: true, force: true });
  fs.cpSync(path.join(SP, 'wh547'), LIVE, { recursive: true });
  const srv = servir();
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  page.on('pageerror', e => console.log('  PAGEERROR:', String(e.message || e).slice(0, 120)));
  page.on('console', m => { const t = m.text(); if (/DeviceAuth|gate|watchdog|Reintent/i.test(t)) console.log('  CONSOLA:', t.slice(0, 150)); });
  await ctx.route(u => String(u).includes(SB), () => {});
  await ctx.route('**/levo19.github.io/MOS/assets/**', route => {
    const u = route.request().url();
    if (u.includes('/auth/device-auth.js')) return route.fulfill({ status: 200, contentType: 'application/javascript', body: fs.readFileSync(DA_LOCAL, 'utf8') });
    const rel = new URL(u).pathname.replace('/MOS/', '');
    const f = path.join(LIVE, rel);
    route.fulfill({ status: 200, contentType: 'application/javascript', body: fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : '' });
  });
  // Espiar quien crea/quita el overlay del modulo
  await page.addInitScript((d) => {
    localStorage.setItem('wh_device_id', d);
    window.__traza = [];
    const t0 = Date.now();
    const obs = new MutationObserver(() => {
      const ov = document.getElementById('deviceAuthOverlay');
      const txt = ov ? (ov.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 34) : '(sin overlay)';
      const ult = window.__traza[window.__traza.length - 1];
      if (!ult || ult.txt !== txt) window.__traza.push({ t: Date.now() - t0, txt });
    });
    document.addEventListener('DOMContentLoaded', () => obs.observe(document.body, { childList: true, subtree: true, characterData: true }));
  }, DEV);

  await page.goto(`http://localhost:${PORT}/`, { waitUntil: 'domcontentloaded', timeout: 60000 }).catch(() => {});
  for (let i = 0; i < 9; i++) {
    await page.waitForTimeout(2500);
    const r = await page.evaluate(() => {
      const da = window.DeviceAuth; const st = da && da.estado ? da.estado() : null;
      const ov = document.getElementById('deviceAuthOverlay');
      return {
        e: st ? st.estado : null,
        wd: st ? !!st.watchdogTimer : null,
        ovTxt: ov ? (ov.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 40) : '(sin overlay)',
        nOv: document.querySelectorAll('#deviceAuthOverlay').length,
        pb: document.documentElement.classList.contains('da-pre-block'),
        whwd: !!window._whGateWatchdog
      };
    }).catch(() => ({}));
    console.log(`  t=${(i + 1) * 2.5}s estado=${String(r.e).padEnd(14)} overlay(${r.nOv})="${r.ovTxt}" preBlock=${r.pb} whWatchdog=${r.whwd}`);
  }
  const tr = await page.evaluate(() => window.__traza || []);
  console.log('\n  TRAZA de cambios del overlay:');
  tr.forEach(x => console.log(`    ${x.t}ms  "${x.txt}"`));
  await browser.close(); srv.close();
})();
