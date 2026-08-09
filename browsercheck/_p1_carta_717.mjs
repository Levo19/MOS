// [717] Modal 1 de compras — carta lateral retráctil de la factura.
//   Abre una compra REAL con foto (G_L17861131797225kwi4vv, 12 líneas) y captura
//   390 / 768 / 1280, carta expandida y retraída. Exige 0 pageerrors.
//   Uso: node _p1_carta_717.mjs   (SHOTS_DIR para cambiar destino)
import { chromium } from 'playwright';
import fs from 'fs';

const OUT = process.env.SHOTS_DIR || 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/p1_717';
const TAGSUF = process.env.SHOT_SUF || '';
fs.mkdirSync(OUT, { recursive: true });
const _ALL = [[390, 844, 'movil'], [768, 1024, 'tablet'], [1280, 900, 'pc'], [1600, 950, 'pcancho']];
const VPS = process.env.VP ? _ALL.filter(v => v[2] === process.env.VP) : _ALL;
const GUIA = process.env.GUIA || 'G_L17861131797225kwi4vv';
const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906474',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' }),
};
const w = ms => new Promise(r => setTimeout(r, ms));

const res = [];
let fallas = 0;
const b = await chromium.launch();
for (const [W, H, tag] of VPS) {
  const ctx = await b.newContext({ viewport: { width: W, height: H }, hasTouch: W < 800 });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0, 160)));
  await p.addInitScript(seed => { for (const [k, v] of Object.entries(seed)) localStorage.setItem(k, v); }, SEED);
  await p.goto('https://levo19.github.io/MOS/?nc=' + Date.now(), { waitUntil: 'domcontentloaded' });
  await w(21000);
  await p.evaluate(() => { const el = [...document.querySelectorAll('button,a')].find(x => /Entrar a MOS/i.test(x.textContent || '')); if (el) el.click(); });
  await w(2000);
  await p.evaluate(() => { try { MOS.nav('almacen'); } catch (_) {} });
  await w(9000);

  // abrir el Modal 1 de la compra real
  const abierto = await p.evaluate(async g => {
    try { MOS.opsEntrarModoCostos('WH', g); } catch (e) { return 'ERR ' + e.message; }
    return 'ok';
  }, GUIA);
  await w(6000);
  let vis = await p.evaluate(() => {
    const m = document.getElementById('modalCostosGuiaUnif');
    return m && !m.classList.contains('hidden');
  });
  if (!vis) {
    // fallback: por la Mesa de Compras
    await p.evaluate(() => { try { MOS.abrirMesaCompras && MOS.abrirMesaCompras(); } catch (_) {} });
    await w(5000);
    await p.evaluate(g => {
      const el = [...document.querySelectorAll('[onclick]')].find(x => (x.getAttribute('onclick') || '').includes(g));
      if (el) el.click();
    }, GUIA);
    await w(4000);
    vis = await p.evaluate(() => { const m = document.getElementById('modalCostosGuiaUnif'); return m && !m.classList.contains('hidden'); });
  }
  console.log(`[${tag}] modal visible = ${vis} (${abierto})`);
  if (!vis) { res.push([tag, 'MODAL', 'NO ABRIÓ']); fallas++; if (errs.length) res.push([tag, 'err', errs.join('|')]); await ctx.close(); continue; }

  const medir = () => p.evaluate(() => {
    const q = s => document.querySelector(s);
    const r = el => { if (!el) return null; const b = el.getBoundingClientRect(); return { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) }; };
    return {
      box:    r(q('#modalCostosGuiaUnif .p1-box')),
      carta:  r(q('#p1Carta')),
      foto:   r(q('.ops-p1-foto')),
      lista:  r(q('#modalCostosGuiaUnif .p1-lista')),
      thumb:  r(q('.p1-thumb')),
      cols:   getComputedStyle(q('#modalCostosGuiaUnif .p1-lista') || document.body).gridTemplateColumns,
      lineas: document.querySelectorAll('#modalCostosGuiaUnif .p1-lista > *').length,
      retraida: !!q('#p1Carta')?.classList.contains('is-off')
    };
  });

  const m1 = await medir();
  await p.screenshot({ path: `${OUT}/1_expandida_${tag}${TAGSUF}.png` });
  console.log(`[${tag}] expandida:`, JSON.stringify(m1));
  res.push([tag, 'expandida', `box=${m1.box?.w} lista=${m1.lista?.w} carta=${m1.carta ? m1.carta.w + 'x' + m1.carta.h : 'n/a'} cols=${m1.cols}`]);

  // retraer la carta (solo existe en >=768)
  const hayTab = await p.evaluate(() => !!document.getElementById('p1CartaTab'));
  if (hayTab) {
    await p.evaluate(() => document.getElementById('p1CartaTab').click());
    await w(900);
    const m2 = await medir();
    await p.screenshot({ path: `${OUT}/2_retraida_${tag}${TAGSUF}.png` });
    console.log(`[${tag}] retraída:`, JSON.stringify(m2));
    res.push([tag, 'retraida', `lista=${m2.lista?.w} (antes ${m1.lista?.w}) retraida=${m2.retraida}`]);
    if (!(m2.lista?.w > m1.lista?.w)) { res.push([tag, 'OJO', 'la lista no ganó ancho al retraer']); }
    // volver a expandir
    await p.evaluate(() => document.getElementById('p1CartaTab').click());
    await w(700);
  } else {
    res.push([tag, 'carta', W >= 1100 ? 'SIN PESTAÑA (¿no aplicó?)' : 'n/a angosto (thumb en header)']);
    if (W >= 1100) fallas++;
  }

  // móvil: el thumbnail del header abre el overlay de zoom
  if (W < 1100) {
    const th = await p.evaluate(() => !!document.querySelector('.p1-thumb'));
    if (th) {
      await p.evaluate(() => document.querySelector('.p1-thumb').click());
      await w(1400);
      await p.screenshot({ path: `${OUT}/3_zoom_${tag}${TAGSUF}.png` });
      const zoomOn = await p.evaluate(() => !!document.querySelector('#almFotoOverlay:not(.hidden)'));
      res.push([tag, 'thumb→zoom', zoomOn ? 'abre overlay ✓' : 'no abrió']);
      await p.keyboard.press('Escape');
      await w(500);
    } else res.push([tag, 'thumb', 'no hay thumb']);
  }

  if (errs.length) { res.push([tag, '_pageerrors', errs.join(' | ')]); fallas += errs.length; }
  else res.push([tag, '_pageerrors', '0 ✓']);
  await ctx.close();
}
await b.close();
console.log('\nRESUMEN:');
res.forEach(r => console.log(' ', r.join(' · ')));
fs.writeFileSync(OUT + '/_resumen' + TAGSUF + '.json', JSON.stringify(res, null, 1));
console.log(fallas ? `\n❌ ${fallas} problemas` : '\n✅ 0 pageerrors');
process.exitCode = fallas ? 1 : 0;
