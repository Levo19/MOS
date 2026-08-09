// [714] Sonda corta: confirma que el botón único gira mientras carga y que las
// ideas nuevas entran con la clase de renovación. Uso: node _promo_v21_anim.mjs
import { chromium } from 'playwright';
import fs from 'fs';
const OUT = process.env.SHOTS_DIR || 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/promo715';
fs.mkdirSync(OUT, { recursive: true });
const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906474',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' }),
};
const w = ms => new Promise(r => setTimeout(r, ms));
const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 1280, height: 900 } });
const p = await ctx.newPage();
const errs = [];
p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0, 160)));
await p.addInitScript(seed => { for (const [k, v] of Object.entries(seed)) localStorage.setItem(k, v); }, SEED);
await p.goto('https://levo19.github.io/MOS/?nc=' + Date.now(), { waitUntil: 'domcontentloaded' });
await w(21000);
await p.evaluate(() => { const el = [...document.querySelectorAll('button,a')].find(x => /Entrar a MOS/i.test(x.textContent || '')); if (el) el.click(); });
await w(1800);
await p.evaluate(() => { try { MOS.nav('catalogo'); } catch (_) {} });
await w(7000);
await p.evaluate(() => MOS.abrirPromoCentro('mis'));
await w(7000);

// dispara y muestrea cada 120ms durante 4s
await p.evaluate(() => {
  window.__probe = { gira: 0, renueva: 0 };
  const t = setInterval(() => {
    if (document.querySelector('.pcx-btn-ref.girando')) window.__probe.gira++;
    if (document.querySelector('.pcx-renueva')) window.__probe.renueva++;
  }, 120);
  setTimeout(() => clearInterval(t), 12000);
  MOS._pcNuevasIdeas();
});
await w(700);
await p.screenshot({ path: `${OUT}/6_girando_pc.png` });
await w(11500);
const probe = await p.evaluate(() => window.__probe);
console.log('muestras con icono girando:', probe.gira, '· muestras con grid renovando:', probe.renueva);
console.log('pageerrors:', errs.length ? errs.join(' | ') : '0 ✓');
await b.close();
process.exitCode = (probe.gira > 0 && probe.renueva > 0 && errs.length === 0) ? 0 : 1;
