// Chequeo puntual de las pestañas del Centro de Promociones a 390px (fix 708).
import { chromium } from 'playwright';
const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906474',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' }),
};
const OUT = process.env.SHOTS_DIR || 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/audit390';
const w = ms => new Promise(r => setTimeout(r, ms));
const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true, deviceScaleFactor: 2, serviceWorkers: 'block' });
const p = await ctx.newPage();
const errs = []; p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0, 120)));
await p.addInitScript(s => { for (const [k, v] of Object.entries(s)) localStorage.setItem(k, v); }, SEED);
await p.goto('https://levo19.github.io/MOS/?nc=' + Date.now(), { waitUntil: 'domcontentloaded', timeout: 60000 });
await w(21000);
await p.evaluate(() => { const b = [...document.querySelectorAll('button,a')].find(el => /Entrar a MOS/i.test(el.textContent || '')); if (b) b.click(); });
await w(1500);
await p.evaluate(() => { try { MOS.nav('catalogo'); } catch (_) {} });
await w(8000);
const ver = await p.evaluate(() => (typeof V !== 'undefined' ? V : 'nd'));
await p.evaluate(() => MOS.abrirPromoCentro());
await w(2500);
await p.screenshot({ path: OUT + '/promo_tabs_fix.png' });
const r = await p.evaluate(() => {
  const t = document.getElementById('pcTabs'); if (!t) return { err: 'sin pcTabs' };
  const cs = getComputedStyle(t);
  return {
    filaAlto: Math.round(t.getBoundingClientRect().height),
    wrap: cs.flexWrap, overflowX: cs.overflowX,
    tabs: [...t.querySelectorAll('button')].map(b => {
      const r = b.getBoundingClientRect();
      return b.textContent.trim().slice(0, 16) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height) + (r.right > 390 ? ' ⚠FUERA' : '') + (r.bottom > t.getBoundingClientRect().bottom + 1 ? ' ⚠CORTADO' : '');
    })
  };
});
console.log('V=' + ver, JSON.stringify(r, null, 1), 'errs:', errs.length);
await b.close();
