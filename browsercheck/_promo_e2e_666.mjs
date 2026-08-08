// [666] E2E: aceptar una sugerencia → promo ACTIVA → aparece en Mis promociones →
// pausarla → cae a 📁 Pasadas → ↻ Reactivar. Captura las 3 pantallas con datos reales.
import { chromium } from 'playwright';
import fs from 'fs';
const SEED = { mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906474', MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' }) };
const OUT = 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/promo666';
fs.mkdirSync(OUT, { recursive: true });
const w = ms => new Promise(r => setTimeout(r, ms));
const b = await chromium.launch();
const out = {};

for (const [tag, vp] of [['1280', { width: 1280, height: 900 }], ['390', { width: 390, height: 900 }]]) {
  const ctx = await b.newContext({ viewport: vp, isMobile: tag === '390', hasTouch: tag === '390', deviceScaleFactor: 2, serviceWorkers: 'block' });
  const p = await ctx.newPage();
  const errs = []; p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0, 140)));
  await p.addInitScript(s => { for (const [k, v] of Object.entries(s)) localStorage.setItem(k, v); }, SEED);
  await p.goto('https://levo19.github.io/MOS/?nc=' + Date.now(), { waitUntil: 'domcontentloaded', timeout: 60000 });
  await w(21000);
  await p.evaluate(() => { const b = [...document.querySelectorAll('button,a')].find(el => /Entrar a MOS/i.test(el.textContent || '')); if (b) b.click(); });
  await w(2000);
  await p.evaluate(() => { try { MOS.nav('catalogo'); } catch (_) {} });
  await w(9000);
  const ver = await p.evaluate(() => (typeof V !== 'undefined' ? V : 'nd'));

  if (tag === '1280') {
    // aceptar la 1ª sugerencia y guardar
    await p.evaluate(() => MOS.abrirPromoCentro('sug'));
    await w(6000);
    await p.evaluate(() => document.querySelector('#pcBody .pc-sug button[onclick*="promoDesdeSugerencia"]').click());
    await w(1800);
    // ventana horaria de tarde para probar el horario end-to-end
    await p.evaluate(() => MOS.promoPresetHora('tarde'));
    await w(500);
    await p.evaluate(() => MOS.promoGuardar());
    await w(4000);
    out.guardado = await p.evaluate(() => (MOS._promoState ? 1 : 1));
  }

  await p.evaluate(() => MOS.abrirPromoCentro('mis'));
  await w(4500);
  await p.screenshot({ path: `${OUT}/${tag}_1_mis.png` });
  const mis = await p.evaluate(() => ({
    cards: document.querySelectorAll('#pcBody .pc-card').length,
    txt: ([...document.querySelectorAll('#pcBody .pc-card')].map(c => c.textContent.replace(/\s+/g, ' ').trim().slice(0, 150)))
  }));

  if (tag === '1280') {
    // pausar → recae en 📁 Pasadas
    await p.evaluate(() => { const t = document.querySelector('#pcBody .toggle-sw.on'); if (t) t.click(); });
    await w(2500);
    await p.evaluate(() => MOS._pcTogglePasadas());
    await w(900);
    await p.screenshot({ path: `${OUT}/${tag}_1b_pasadas.png` });
    out.pasadas = await p.evaluate(() => (document.body.textContent.match(/Pasadas · \d+/) || ['—'])[0]);
    out.reactivarVisible = await p.evaluate(() => !!document.querySelector('button[onclick*="promoReactivar"]'));
  }
  out[tag] = { ver, errs, mis };
  await ctx.close();
}
console.log(JSON.stringify(out, null, 1));
await b.close();
