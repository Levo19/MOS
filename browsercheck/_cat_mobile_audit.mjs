// Auditoría UX MÓVIL (390x844) de los modales/overlays del módulo Catálogo + Modal 1 de compras.
// Mide: tap targets < 40px, inputs con font-size < 16px (iOS zoom), overflow-x del body,
// textos truncados, y captura screenshots. Uso: node _cat_mobile_audit.mjs [tag]
import { chromium } from 'playwright';
import fs from 'fs';

const OUT = process.env.SHOTS_DIR || 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/audit390';
fs.mkdirSync(OUT, { recursive: true });
const TAG = process.argv[2] || 'now';
const URL = process.env.MOS_URL || 'https://levo19.github.io/MOS/';

const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906474',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' }),
};
const w = ms => new Promise(r => setTimeout(r, ms));

// medidor: corre dentro de la página sobre un selector raíz
const MEDIR = `(root) => {
  const R = document.querySelector(root); if (!R) return { err: 'no root ' + root };
  const out = { chicos: [], inputsChicos: [], overflowX: [], truncados: 0, alto: 0, ancho: 0 };
  const rr = R.getBoundingClientRect(); out.alto = Math.round(rr.height); out.ancho = Math.round(rr.width);
  R.querySelectorAll('button,a,[onclick],input,select,textarea,[role=button],.cat-fp-radio,.cat-fp-sub,.cat-fp-chk,.cat-fp-ord').forEach(el => {
    const r = el.getBoundingClientRect(); if (!r.width || !r.height) return;
    const cs = getComputedStyle(el);
    const tag = el.tagName.toLowerCase();
    const txt = (el.textContent || el.placeholder || '').trim().slice(0, 26);
    if (r.height < 40 || r.width < 34) out.chicos.push(tag + '·' + txt + '·' + Math.round(r.width) + 'x' + Math.round(r.height));
    if ((tag === 'input' || tag === 'select' || tag === 'textarea') && parseFloat(cs.fontSize) < 16)
      out.inputsChicos.push(tag + '·' + txt + '·' + cs.fontSize);
    if (r.right > innerWidth + 1 || r.left < -1) out.overflowX.push(tag + '·' + txt);
    if (el.scrollWidth > el.clientWidth + 2) out.truncados++;
  });
  R.querySelectorAll('*').forEach(el => { if (el.scrollWidth > el.clientWidth + 2 && getComputedStyle(el).overflow !== 'auto' && getComputedStyle(el).overflowX !== 'auto') out.truncados++; });
  out.bodyOverflow = document.documentElement.scrollWidth > innerWidth + 1;
  out.chicos = [...new Set(out.chicos)].slice(0, 14);
  out.inputsChicos = [...new Set(out.inputsChicos)].slice(0, 8);
  out.overflowX = [...new Set(out.overflowX)].slice(0, 8);
  return out;
}`;

const SUP = [
  ['00_catalogo', 'null', 'body', 'null'],
  ['01_filtro_categoria', `MOS.fpAbrir('cat')`, '#catFiltroPanelFloat', `MOS._cerrarFiltroFloat()`],
  ['02_filtro_subcat', `(()=>{MOS.setFiltroCategoria('ESPECIAS');MOS.fpAbrir('sub')})()`, '#catFiltroPanelFloat', `(()=>{MOS._cerrarFiltroFloat();MOS.limpiarFiltrosCat()})()`],
  ['03_filtro_tipo', `MOS.fpAbrir('tipo')`, '#catFiltroPanelFloat', `MOS._cerrarFiltroFloat()`],
  ['04_filtro_orden', `MOS.fpAbrir('orden')`, '#catFiltroPanelFloat', `MOS._cerrarFiltroFloat()`],
  ['05_pn_overlay', `MOS.abrirPNDesdeToolbar()`, '#pnOverlay', `MOS.abrirPNDesdeToolbar()`],
  ['06_promo_centro', `MOS.abrirPromoCentro()`, '#promoCentro', `document.getElementById('promoCentro')?.remove()`],
  ['07_modal_producto', `MOS.abrirModalProducto(null)`, '#modalProducto', `MOS.closeModal('modalProducto')`],
  ['08_modal_foto', `(()=>{const p=(MOS._Sdump?MOS._Sdump():null);const el=document.querySelector('[onclick*="abrirModalFotoProducto"]');if(el)el.click()})()`, '#catFotoModal', `(()=>{try{MOS.cerrarModalFotoProducto()}catch(_){document.getElementById('catFotoModal')?.remove()}})()`],
];

const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true, deviceScaleFactor: 2, serviceWorkers: 'block' });
const p = await ctx.newPage();
const errs = [];
p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0, 140)));
await p.addInitScript(seed => { for (const [k, v] of Object.entries(seed)) localStorage.setItem(k, v); }, SEED);
await p.goto(URL + '?nc=' + Date.now(), { waitUntil: 'domcontentloaded' });
await w(21000);
await p.evaluate(() => { const b = [...document.querySelectorAll('button,a')].find(el => /Entrar a MOS/i.test(el.textContent || '')); if (b) b.click(); });
await w(1800);
await p.evaluate(() => { try { MOS.nav('catalogo'); } catch (_) {} });
await w(9000);
const boot = await p.evaluate(() => {
  let mos = 'nd'; try { mos = typeof MOS; } catch (_) {}
  const t = document.body.innerText;
  return { mos, grupos: (t.match(/(\d+)\s+grupos/) || [])[1] || null, prods: (t.match(/(\d+)\s+productos/) || [])[1] || null, ver: (t.match(/2\.43\.\d+/) || [])[0] || null, cards: document.querySelectorAll('.cat-card,[id^=grupo_],.cat-grupo').length };
});
console.log('BOOT', JSON.stringify(boot), errs.length ? 'ERR: ' + errs.join(' | ') : 'sin errores');

const res = {};
for (const [nombre, abrir, root, cerrar] of SUP) {
  try {
    if (abrir !== 'null') { await p.evaluate(a => eval(a), abrir); await w(nombre.includes('promo') ? 2200 : 1100); }
    await p.screenshot({ path: `${OUT}/${TAG}_${nombre}.png` });
    res[nombre] = await p.evaluate(new Function('return ' + MEDIR)(), root);
    if (cerrar !== 'null') { await p.evaluate(c => eval(c), cerrar); await w(500); }
  } catch (e) {
    res[nombre] = { err: String(e.message).slice(0, 120) };
    try { await p.evaluate(() => document.querySelectorAll('#catFiltroPanelFloat,#promoCentro,#pnOverlay,#catFotoModal').forEach(m => m.remove())); } catch (_) {}
  }
}

// ── Modal 1 de compras (costos) ─────────────────────────────────────────
try {
  await p.evaluate(() => MOS.abrirMesaCompras && MOS.abrirMesaCompras());
  await w(14000);
  await p.screenshot({ path: `${OUT}/${TAG}_20_mesa_compras.png` });
  res['20_mesa_compras'] = await p.evaluate(new Function('return ' + MEDIR)(), '.mesa-sheet');
  // elegir una guía con 3+ líneas
  const pick = await p.evaluate(() => {
    const cards = [...document.querySelectorAll('.mesa-card')];
    const best = cards.map(c => ({ c, n: +((c.querySelector('.mesa-prods-n')?.textContent || '').match(/(\d+)/) || [0, 0])[1] }))
      .filter(x => x.n >= 3).sort((a, b) => b.n - a.n)[0];
    if (!best) return { ok: false, cards: cards.length };
    best.c.click();
    return { ok: true, n: best.n, id: best.c.id };
  });
  console.log('PICK', JSON.stringify(pick));
  await w(4500);
  await p.screenshot({ path: `${OUT}/${TAG}_21_costos_top.png` });
  res['21_costos'] = await p.evaluate(new Function('return ' + MEDIR)(), '#modalCostosGuiaUnif');
  // scroll al fondo del body de costos
  await p.evaluate(() => { const b = document.getElementById('opsCostosBody'); if (b) b.scrollTop = b.scrollHeight; });
  await w(700);
  await p.screenshot({ path: `${OUT}/${TAG}_22_costos_fondo.png` });
  // enfocar el primer input de costo → simular teclado
  await p.evaluate(() => { const i = document.querySelector('#opsCostosBody input'); if (i) i.focus(); });
  await w(600);
  await p.screenshot({ path: `${OUT}/${TAG}_23_costos_input_focus.png` });
  res['23_costos_focus'] = await p.evaluate(() => {
    const i = document.activeElement;
    if (!i || i.tagName !== 'INPUT') return { err: 'sin foco' };
    const r = i.getBoundingClientRect(); const cs = getComputedStyle(i);
    return { top: Math.round(r.top), bottom: Math.round(r.bottom), vh: innerHeight, fontSize: cs.fontSize, inputmode: i.getAttribute('inputmode'), type: i.type, tapado_por_teclado_336: r.bottom > innerHeight - 336 };
  });
} catch (e) { console.log('mesa err', e.message); res['20_mesa_compras'] = { err: e.message }; }

if (errs.length) res._pageerrors = errs;
fs.writeFileSync(`${OUT}/${TAG}_audit.json`, JSON.stringify({ boot, res }, null, 1));
console.log(JSON.stringify(res, null, 1));
await b.close();
