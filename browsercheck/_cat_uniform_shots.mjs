// Webcheck del MÓDULO CATÁLOGO: carga MOS con sesión TEST-CLAUDE, navega a catálogo y
// screenshotea la vista + CADA overlay/modal en 3 viewports (390 móvil / 768 tablet / 1366 PC).
// Uso: node _cat_uniform_shots.mjs [soloViewport]
import { chromium } from 'playwright';
import fs from 'fs';

const OUT = process.env.SHOTS_DIR || 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/catshots';
fs.mkdirSync(OUT, { recursive: true });
const VPS = process.argv[2] ? [[+process.argv[2], 900, 'x' + process.argv[2]]]
  : [[390, 844, 'movil'], [768, 1024, 'tablet'], [1366, 900, 'pc']];

const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906474',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' }),
};

const w = ms => new Promise(r => setTimeout(r, ms));

// [nombre, acción de apertura (corre en la página), cierre]
const SUPERFICIES = [
  ['00_catalogo', `null`, `null`],
  ['01_filtro_categoria', `MOS.fpAbrir('cat')`, `MOS._cerrarFiltroFloat()`],
  ['02_filtro_subcat', `(()=>{MOS.setFiltroCategoria('ESPECIAS');MOS.fpAbrir('sub');})()`, `(()=>{MOS._cerrarFiltroFloat();MOS.limpiarFiltrosCat();})()`],
  ['03_filtro_tipo', `MOS.fpAbrir('tipo')`, `MOS._cerrarFiltroFloat()`],
  ['04_filtro_orden', `MOS.fpAbrir('orden')`, `MOS._cerrarFiltroFloat()`],
  ['05_pn_overlay', `MOS.abrirPNDesdeToolbar()`, `MOS.abrirPNDesdeToolbar()`],
  ['06_promo_centro', `MOS.abrirPromoCentro()`, `document.getElementById('promoCentro')?.remove()`],
  ['07_promo_playbook', `(async()=>{await MOS.abrirPromoCentro();await new Promise(s=>setTimeout(s,800));document.querySelector('#pcTabs button[data-tab="playbook"]')?.click();})()`, `document.getElementById('promoCentro')?.remove()`],
  ['08_modal_producto', `MOS.abrirModalProducto(null)`, `MOS.closeModal('modalProducto')`],
  ['09_modal_foto', `(()=>{const el=document.querySelector('[onclick*="abrirModalFotoProducto"]');if(el)el.click();})()`, `(()=>{try{MOS.cerrarModalFotoProducto()}catch(_){document.querySelectorAll('.modal-backdrop').forEach(m=>m.remove())}})()`],
  ['10_plus_contextual', `(()=>{const b=document.querySelector('.cat-btn-plusctx');if(b)b.click();})()`, `document.getElementById('plusCtxMenu')?.remove()`],
  ['11_log_productos', `MOS.abrirLogProductos()`, `(()=>{const m=document.querySelector('.modal-backdrop.open:not(#modalProducto)');m&&m.remove&&m.remove();})()`],
  ['12_cesta_purga', `MOS.abrirCestaPurga()`, `(()=>{document.querySelectorAll('.modal-backdrop.open').forEach(m=>m.remove());})()`],
  ['13_pn_descartados', `MOS.pnVerOcultos()`, `document.getElementById('pnDescModal')?.remove()`],
];

const res = [];
const b = await chromium.launch();
for (const [W, H, tag] of VPS) {
  const ctx = await b.newContext({ viewport: { width: W, height: H }, hasTouch: W < 800 });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0, 100)));
  await p.addInitScript(seed => { for (const [k, v] of Object.entries(seed)) localStorage.setItem(k, v); }, SEED);
  await p.goto('https://levo19.github.io/MOS/?nc=' + Date.now(), { waitUntil: 'domcontentloaded' });
  await w(21000);
  // cerrar el wizard de permisos post-update si aparece (tapa TODA la app)
  await p.evaluate(() => { const b=[...document.querySelectorAll('button,a')].find(el=>/Entrar a MOS/i.test(el.textContent||'')); if (b) b.click(); });
  await w(1800);
  await p.evaluate(() => { try { MOS.nav('catalogo'); } catch (_) {} });
  await w(7000);
  const boot = await p.evaluate(() => { let mos='nd'; try { mos = typeof MOS; } catch(_){} const g=(document.body.innerText.match(/(\d+) grupos/)||[])[1]; return { mos, grupos: g||0 }; });
  console.log(`[${tag}] boot:`, JSON.stringify(boot), errs.length ? '· ERR: ' + errs.join(' | ') : '');
  if (boot.mos !== 'object' || !Number(boot.grupos)) { res.push([tag, 'BOOT FAIL', errs.join('|')]); await ctx.close(); continue; }

  for (const [nombre, abrir, cerrar] of SUPERFICIES) {
    try {
      if (abrir !== 'null') { await p.evaluate(a => eval(a), abrir); await w(nombre.includes('promo') ? 1600 : 900); }
      await p.screenshot({ path: `${OUT}/${nombre}_${tag}.png` });
      res.push([tag, nombre, 'ok']);
      if (cerrar !== 'null') { await p.evaluate(c => eval(c), cerrar); await w(400); }
    } catch (e) {
      res.push([tag, nombre, 'ERR ' + String(e.message).slice(0, 80)]);
      try { await p.evaluate(() => document.querySelectorAll('.modal-backdrop, #catFiltroPanelFloat, #promoCentro, #pnOverlay').forEach(m => m.remove())); } catch (_) {}
    }
  }
  if (errs.length) res.push([tag, '_pageerrors', errs.join(' | ')]);
  await ctx.close();
}
await b.close();
console.log('\nRESUMEN:');
res.forEach(r => console.log(' ', r.join(' · ')));
fs.writeFileSync(OUT + '/_resumen.json', JSON.stringify(res, null, 1));
