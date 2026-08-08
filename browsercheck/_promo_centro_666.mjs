// [666] Centro de Promociones unificado: 0 pageerrors + capturas 390 / 1280
// de las 3 secciones (mis promociones · sugerencias · playbook) y del form.
import { chromium } from 'playwright';
import fs from 'fs';

const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906474',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' }),
};
const OUT = process.env.SHOTS_DIR || 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/promo666';
fs.mkdirSync(OUT, { recursive: true });
const w = ms => new Promise(r => setTimeout(r, ms));

const b = await chromium.launch();
const resumen = {};

for (const [tag, vp] of [['390', { width: 390, height: 900 }], ['1280', { width: 1280, height: 900 }]]) {
  const ctx = await b.newContext({ viewport: vp, hasTouch: tag === '390', isMobile: tag === '390', deviceScaleFactor: 2, serviceWorkers: 'block' });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0, 160)));
  p.on('console', m => { if (m.type() === 'error' && !/favicon|net::ERR|Failed to load resource/i.test(m.text())) errs.push('console: ' + m.text().slice(0, 140)); });
  await p.addInitScript(s => { for (const [k, v] of Object.entries(s)) localStorage.setItem(k, v); }, SEED);
  await p.goto('https://levo19.github.io/MOS/?nc=' + Date.now(), { waitUntil: 'domcontentloaded', timeout: 60000 });
  await w(21000);
  await p.evaluate(() => { const b = [...document.querySelectorAll('button,a')].find(el => /Entrar a MOS/i.test(el.textContent || '')); if (b) b.click(); });
  await w(2000);
  await p.evaluate(() => { try { MOS.nav('catalogo'); } catch (_) {} });
  await w(9000);
  const ver = await p.evaluate(() => (typeof V !== 'undefined' ? V : 'nd'));

  // 1 · MIS PROMOCIONES
  await p.evaluate(() => MOS.abrirPromoCentro('mis'));
  await w(3500);
  await p.screenshot({ path: `${OUT}/${tag}_1_mis.png`, fullPage: false });

  // 2 · SUGERENCIAS
  await p.evaluate(() => MOS._pcIr('sug'));
  await w(6000);
  await p.screenshot({ path: `${OUT}/${tag}_2_sugerencias.png`, fullPage: false });
  const sug = await p.evaluate(() => {
    const cards = [...document.querySelectorAll('#pcBody .pc-sug')];
    return {
      n: cards.length,
      textos: cards.slice(0, 6).map(c => (c.querySelector('.pc-card-name') || {}).textContent || ''),
      overflowX: document.documentElement.scrollWidth > window.innerWidth + 1
    };
  });

  // 2b · ¿Por qué? expandido
  const primerId = await p.evaluate(() => (window.__pcIds = null, (document.querySelector('#pcBody .pc-sug button[onclick*="_pcWhy"]') || {}).getAttribute?.('onclick') || ''));
  if (primerId) {
    await p.evaluate(() => { const b = document.querySelector('#pcBody .pc-sug button[onclick*="_pcWhy"]'); if (b) b.click(); });
    await w(700);
    await p.screenshot({ path: `${OUT}/${tag}_2b_porque.png`, fullPage: false });
  }

  // 3 · PLAYBOOK
  await p.evaluate(() => MOS._pcIr('play'));
  await w(3500);
  await p.screenshot({ path: `${OUT}/${tag}_3_playbook.png`, fullPage: false });

  // 4 · FORM desde una sugerencia (precargado)
  await p.evaluate(() => MOS._pcIr('sug'));
  await w(1200);
  const abrio = await p.evaluate(() => {
    const b = document.querySelector('#pcBody .pc-sug button[onclick*="promoDesdeSugerencia"]');
    if (!b) return false; b.click(); return true;
  });
  await w(1800);
  await p.screenshot({ path: `${OUT}/${tag}_4_form_sugerencia.png`, fullPage: false });
  const form = await p.evaluate(() => ({
    abierto: !document.getElementById('modalPromoEdit').classList.contains('hidden'),
    sku: (document.getElementById('promoSkuBase') || {}).value,
    desc: (document.getElementById('promoDesc') || {}).value,
    desde: (document.getElementById('promoFDesde') || {}).value,
    hasta: (document.getElementById('promoFHasta') || {}).value,
    margen: ((document.getElementById('promoMargenBox') || {}).textContent || '').replace(/\s+/g, ' ').trim().slice(0, 120),
    estrategiaChip: ((document.getElementById('promoEstrChip') || {}).textContent || '').trim().slice(0, 40),
    nota: !document.getElementById('promoSugNota').classList.contains('hidden')
  }));

  // 5 · FORM manual con paso cero (grid de 9 jugadas)
  await p.evaluate(() => MOS.promoVolverLista());
  await w(600);
  await p.evaluate(() => MOS.abrirPromoCentro('mis'));
  await w(1500);
  await p.evaluate(() => MOS.promoAbrirNueva());
  await w(1200);
  await p.screenshot({ path: `${OUT}/${tag}_5_form_pasocero.png`, fullPage: false });
  const paso0 = await p.evaluate(() => ({
    jugadas: document.querySelectorAll('#promoEstrGrid .promo-estr').length,
    horaPresets: document.querySelectorAll('#promoHoraPresets .promo-modo-btn').length,
    vigPresets: document.querySelectorAll('#promoVigPresets .promo-modo-btn').length
  }));

  // 6 · elegir jugada "horas valle" → preconfigura horario
  await p.evaluate(() => MOS.promoSetEstrategia('valle'));
  await w(800);
  const valle = await p.evaluate(() => ({
    hd: (document.getElementById('promoHDesde') || {}).value,
    hh: (document.getElementById('promoHHasta') || {}).value,
    tipo: (document.querySelector('input[name="promoTipo"]:checked') || {}).value
  }));
  await p.screenshot({ path: `${OUT}/${tag}_6_form_valle.png`, fullPage: false });

  resumen[tag] = { ver, errs, sug, form, paso0, valle, abrio };
  await ctx.close();
}

console.log(JSON.stringify(resumen, null, 1));
const totalErrs = Object.values(resumen).reduce((a, r) => a + r.errs.length, 0);
console.log('\nSHOTS →', OUT);
console.log(totalErrs === 0 ? 'PAGEERRORS: 0 ✓' : 'PAGEERRORS: ' + totalErrs + ' ✗');
await b.close();
process.exit(totalErrs === 0 ? 0 : 1);
