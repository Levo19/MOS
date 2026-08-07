// Verificación del Paso 1 (overlay de costos) reformado — 390 / 768 / 1280.
// Abre la Mesa de compras, entra a una guía con 3+ productos y fotografía:
//  a) estado inicial  b) con costo escrito y línea chipeada  c) tras el salto guiado
// Exige 0 pageerrors. Uso: node _p1_costos_shots.mjs
import { chromium } from 'playwright';
import fs from 'fs';

const OUT = process.env.SHOTS_DIR || 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/p1shots';
fs.mkdirSync(OUT, { recursive: true });
const URL = process.env.MOS_URL || 'https://levo19.github.io/MOS/';
const TODAS = [[390, 844, 'movil'], [768, 1024, 'tablet'], [1280, 860, 'pc']];
// arg opcional: solo un viewport (movil|tablet|pc)
const VPS = process.argv[2] ? TODAS.filter(v => v[2] === process.argv[2]) : TODAS;

const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906474',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' }),
};
const w = ms => new Promise(r => setTimeout(r, ms));
const out = [];

const b = await chromium.launch();
for (const [W, H, tag] of VPS) {
  const ctx = await b.newContext({ viewport: { width: W, height: H }, hasTouch: W < 900, isMobile: W < 900, deviceScaleFactor: W < 900 ? 2 : 1, serviceWorkers: 'block' });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0, 160)));
  await p.addInitScript(seed => { for (const [k, v] of Object.entries(seed)) localStorage.setItem(k, v); }, SEED);
  // GitHub Pages a veces tarda cuando acaba de re-desplegar → 60s + 1 reintento
  try { await p.goto(URL + '?nc=' + Date.now(), { waitUntil: 'domcontentloaded', timeout: 60000 }); }
  catch (_) { await w(4000); await p.goto(URL + '?nc=' + Date.now(), { waitUntil: 'domcontentloaded', timeout: 60000 }); }
  await w(21000);
  await p.evaluate(() => { const b = [...document.querySelectorAll('button,a')].find(el => /Entrar a MOS/i.test(el.textContent || '')); if (b) b.click(); });
  await w(1500);
  await p.evaluate(() => { try { MOS.nav('catalogo'); } catch (_) {} });
  await w(8000);
  const boot = await p.evaluate(() => {
    let mos = 'nd'; try { mos = typeof MOS; } catch (_) {}
    return { mos, grupos: (document.body.innerText.match(/(\d+)\s+grupos/) || [])[1] || null, ver: (typeof V !== 'undefined' ? V : null) };
  });
  await p.screenshot({ path: `${OUT}/00_catalogo_${tag}.png` });

  await p.evaluate(() => MOS.abrirMesaCompras && MOS.abrirMesaCompras());
  await w(14000);
  await p.screenshot({ path: `${OUT}/01_mesa_${tag}.png` });
  const pick = await p.evaluate(() => {
    const cards = [...document.querySelectorAll('.mesa-card')];
    const best = cards.map(c => ({ c, n: +((c.querySelector('.mesa-prods-n')?.textContent || '').match(/(\d+)/) || [0, 0])[1] }))
      .filter(x => x.n >= 3).sort((a, b) => a.n - b.n)[0];   // la más chica con 3+ (no una de 34)
    if (!best) return { ok: false, cards: cards.length };
    best.c.click();
    return { ok: true, n: best.n };
  });
  await w(4500);
  await p.screenshot({ path: `${OUT}/02_costos_inicial_${tag}.png` });

  // medición del overlay
  const med = await p.evaluate(() => {
    const M = document.getElementById('modalCostosGuiaUnif'); if (!M) return { err: 'sin modal' };
    const body = document.getElementById('opsCostosBody');
    const chicos = [];
    M.querySelectorAll('button,input,select').forEach(el => {
      const r = el.getBoundingClientRect(); if (!r.width || !r.height) return;
      if (r.height < 40 || r.width < 34) chicos.push(el.tagName.toLowerCase() + '·' + (el.textContent || el.placeholder || '').trim().slice(0, 22) + '·' + Math.round(r.width) + 'x' + Math.round(r.height));
    });
    const inp = body && body.querySelector('.alm-v-costo-input');
    const foot = document.getElementById('opsCostosFooter');
    return {
      lineas: M.querySelectorAll('.alm-v-costo-line').length,
      scrollVisible: body ? Math.round(body.getBoundingClientRect().height) : 0,
      pieAlto: foot ? Math.round(foot.getBoundingClientRect().height) : 0,
      cabAlto: Math.round((document.getElementById('opsCostosSubheader')?.getBoundingClientRect().height || 0) + (M.querySelector('.p1-head')?.getBoundingClientRect().height || 0)),
      inputFont: inp ? getComputedStyle(inp).fontSize : null,
      inputMode: inp ? inp.getAttribute('inputmode') : null,
      inputAlto: inp ? Math.round(inp.getBoundingClientRect().height) : 0,
      colsLista: body ? getComputedStyle(body.querySelector('.p1-lista') || body).gridTemplateColumns : null,
      totalVisible: !!document.getElementById('costosGuiaTotalBruto'),
      cta: document.getElementById('costosCtaGuiada')?.textContent.trim().slice(0, 40),
      botonViejo: /Aplicar costos al cat/i.test(M.textContent) || /precios publicados:/i.test(M.textContent),
      chicos: [...new Set(chicos)].slice(0, 10),
    };
  });

  // escribir un costo en la 1ª línea y salir del campo -> debe quedar chipeada
  const flujo = await p.evaluate(async () => {
    const inp = document.querySelector('#opsCostosBody .alm-v-costo-input'); if (!inp) return { err: 'sin input' };
    inp.focus();
    inp.value = '12.50';
    inp.dispatchEvent(new Event('input', { bubbles: true }));
    await new Promise(r => setTimeout(r, 300));
    const fSel = { top: Math.round(inp.getBoundingClientRect().top), vh: innerHeight };
    inp.blur();
    await new Promise(r => setTimeout(r, 400));
    const row = document.getElementById('costoGuiaLinea_0');
    return {
      chipeada: !!row && row.classList.contains('is-collapsed'),
      chipTxt: document.getElementById('costoGuiaSum_0')?.textContent,
      botonPrecio: /Poner precio|precio puesto/i.test(document.getElementById('costoGuiaAcc_0')?.textContent || ''),
      total: document.getElementById('costosGuiaTotalBruto')?.textContent,
      sello: document.getElementById('costosSaveState')?.textContent,
      cta: document.getElementById('costosCtaGuiada')?.textContent.trim().slice(0, 40),
      centrado: fSel,
    };
  });
  await w(900);
  await p.screenshot({ path: `${OUT}/03_costos_chipeada_${tag}.png` });

  // salto guiado al siguiente sin costo
  await p.evaluate(() => { try { MOS._costosSiguientePendiente(); } catch (e) { return String(e); } });
  await w(900);
  await p.screenshot({ path: `${OUT}/04_costos_salto_${tag}.png` });
  const salto = await p.evaluate(() => {
    const a = document.activeElement;
    return { enfocado: a && a.classList && a.classList.contains('alm-v-costo-input'), linea: a && a.closest && a.closest('.alm-v-costo-line')?.id };
  });

  // desplegar la cabecera avanzada (foto de factura + modos)
  await p.evaluate(() => { try { MOS._costosToggleAvanzado(); } catch (_) {} });
  await w(700);
  await p.screenshot({ path: `${OUT}/05_costos_avanzado_${tag}.png` });

  out.push({ tag, boot, pick, med, flujo, salto, pageerrors: errs });
  console.log(`\n[${tag}]`, JSON.stringify({ boot, pick, med, flujo, salto, errs }, null, 1));
  await ctx.close();
}
await b.close();
fs.writeFileSync(OUT + '/_resumen.json', JSON.stringify(out, null, 1));
const totErr = out.reduce((a, x) => a + x.pageerrors.length, 0);
console.log('\n═══ PAGEERRORS TOTALES:', totErr, '═══');
