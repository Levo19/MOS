// [716-diag] ¿Por qué "alacena personal" da 0 resultados? Mide el estado REAL
// en producción antes de tocar nada: score del producto, filtros activos y conteo.
import { chromium } from 'playwright';
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
await w(8000);

const info = await p.evaluate(() => {
  const norm = s => (s || '').toString().toLowerCase().normalize('NFD').replace(/\p{Mn}/gu, '');
  const cands = (window.S?.productos || []).filter(x => norm(x.descripcion).includes('alacena'));
  return {
    totalProd: (window.S?.productos || []).length,
    alacena: cands.slice(0, 6).map(x => ({ d: x.descripcion, sku: x.skuBase, id: x.idProducto, factor: x.factorConversion })),
    tieneInput: !!document.getElementById('searchCatalogo')
  };
});
console.log('catálogo:', JSON.stringify(info, null, 1));

const probar = async (q, alertas) => {
  await p.evaluate(a => {
    const btn = document.getElementById('btnAlertasCat');
    const on = btn && btn.classList.contains('active');
    if (a !== on && btn) btn.click();
  }, alertas);
  await w(500);
  await p.evaluate(q => { const i = document.getElementById('searchCatalogo'); i.value = q; MOS.filterCatalogo(); }, q);
  await w(1400);
  return await p.evaluate(() => ({
    stats: document.getElementById('catStats')?.textContent || '',
    cards: document.querySelectorAll('#listCatalogo .cat-card, #listCatalogo [data-idprod]').length,
    vacio: (document.getElementById('listCatalogo')?.innerText || '').slice(0, 220).replace(/\n+/g, ' | '),
    alertasOn: !!document.getElementById('btnAlertasCat')?.classList.contains('active')
  }));
};

console.log('SIN filtros · "alacena personal":', JSON.stringify(await probar('alacena personal', false), null, 1));
console.log('SIN filtros · "alacena mayonesa":', JSON.stringify(await probar('alacena mayonesa', false), null, 1));
console.log('CON solo-alertas · "alacena personal":', JSON.stringify(await probar('alacena personal', true), null, 1));
console.log('pageerrors:', errs.length ? errs.join(' | ') : '0 ✓');
await b.close();
