// [714] Webcheck de la DIETA v2.1 del Centro de Promociones.
//   Exige 0 pageerrors y verifica: 2 pestañas (sin "Sugerencias del día"),
//   un solo botón de refresco ("🔀 Nuevas ideas"), cards sin la línea 📊 ni
//   el texto "toca para ver la estrategia", fechas cortas sin año y grid parejo.
//   Viewports 390 y 1280. Uso: node _promo_v21_dieta.mjs
import { chromium } from 'playwright';
import fs from 'fs';

const OUT = process.env.SHOTS_DIR || 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/promo715';
fs.mkdirSync(OUT, { recursive: true });
const VPS = [[390, 844, 'movil'], [1280, 900, 'pc']];

const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906474',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' }),
};
const w = ms => new Promise(r => setTimeout(r, ms));

const res = [];
let errTotal = 0;
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
  await w(1800);
  await p.evaluate(() => { try { MOS.nav('catalogo'); } catch (_) {} });
  await w(7000);

  const boot = await p.evaluate(() => {
    let mos = 'nd'; try { mos = typeof MOS; } catch (_) {}
    return { mos, ver: (window.MOS_VER || document.getElementById('appVersion')?.textContent || '') };
  });
  console.log(`[${tag}] boot:`, JSON.stringify(boot), errs.length ? '· ERR: ' + errs.join(' | ') : '· sin pageerrors');
  if (boot.mos !== 'object') { res.push([tag, 'BOOT FAIL', errs.join('|')]); errTotal += 1; await ctx.close(); continue; }

  // ── 1) vista integrada a dieta ──
  await p.evaluate(() => MOS.abrirPromoCentro('mis'));
  await w(7000);
  const vista = await p.evaluate(() => {
    const cards = [...document.querySelectorAll('.pcx-card')];
    const alturas = [...document.querySelectorAll('#pcxIdeas .pcx-card')].map(c => Math.round(c.getBoundingClientRect().height));
    const uno = document.querySelector('.pcx-idea');
    return {
      tabs:     [...document.querySelectorAll('#pcTabs button')].map(x => x.textContent.trim()),
      botones:  [...document.querySelectorAll('.pcx-barra button')].map(x => x.textContent.trim()),
      ideas:    document.querySelectorAll('.pcx-idea').length,
      activas:  document.querySelectorAll('#pcxActivas .pcx-card').length,
      porque:   document.querySelectorAll('.pcx-porque').length,
      tocaPara: (document.getElementById('pcBody')?.innerText || '').includes('toca para ver la estrategia'),
      alturas,
      cardIdea: uno ? uno.innerText.replace(/\n+/g, ' | ') : null,
      cardProm: (document.querySelector('#pcxActivas .pcx-card')?.innerText || '').replace(/\n+/g, ' | '),
      fechas:   [...document.querySelectorAll('#pcxActivas .pcx-fechas')].slice(0, 4).map(x => x.textContent.trim()),
      altCards: cards.length
    };
  });
  console.log(`[${tag}] vista:`, JSON.stringify(vista, null, 1));
  await p.screenshot({ path: `${OUT}/1_dieta_${tag}.png`, fullPage: false });
  res.push([tag, 'tabs', vista.tabs.join(' + ')]);
  res.push([tag, 'barra', vista.botones.join(' + ')]);
  res.push([tag, 'cards', `ideas=${vista.ideas} activas=${vista.activas} porque=${vista.porque} tocaPara=${vista.tocaPara}`]);
  res.push([tag, 'fechas', vista.fechas.join(' ; ')]);
  if (vista.tabs.length !== 2) { res.push([tag, 'FALLA', 'esperaba 2 pestañas, hay ' + vista.tabs.length]); errTotal += 1; }
  if (vista.tabs.some(t => /Ideas del día|Sugerencias/i.test(t))) { res.push([tag, 'FALLA', 'la pestaña de sugerencias sigue viva']); errTotal += 1; }
  if (vista.botones.filter(t => /refresc|ideas|🔄|🔀/i.test(t)).length !== 1) { res.push([tag, 'FALLA', 'no hay exactamente 1 botón de refresco']); errTotal += 1; }
  if (vista.porque > 0 || vista.tocaPara) { res.push([tag, 'FALLA', 'la card sigue con stats o con "toca para ver"']); errTotal += 1; }
  if (vista.fechas.some(f => /20[0-9]{2}/.test(f))) { res.push([tag, 'OJO', 'una fecha muestra año (¿cruza de año?): ' + vista.fechas.join(';')]); }
  const uniq = [...new Set(vista.alturas)];
  if (W > 800 && uniq.length > 1) { res.push([tag, 'OJO', 'alturas de ideas no uniformes: ' + vista.alturas.join(',')]); }
  else res.push([tag, 'grid', 'alturas ' + (vista.alturas.join(',') || 'n/a')]);

  // ── 2) el sheet conserva el detalle (stats + porqué) ──
  const idSug = await p.evaluate(() => document.querySelector('.pcx-idea')?.getAttribute('data-pcsug') || null);
  if (idSug) {
    await p.evaluate(id => MOS._pcSheet(id), idSug);
    await w(900);
    await p.screenshot({ path: `${OUT}/2_sheet_${tag}.png` });
    const sh = await p.evaluate(() => {
      const s = document.getElementById('pcSheet');
      return s ? { tit: s.querySelector('.pcx-sheet-tit')?.textContent, datos: s.querySelectorAll('.pcx-dato').length, porque: !!s.innerText.includes('Por qué esta jugada') } : null;
    });
    console.log(`[${tag}] sheet:`, JSON.stringify(sh));
    res.push([tag, 'sheet', sh ? `datos=${sh.datos} porque=${sh.porque}` : 'NO ABRIO']);
    await p.evaluate(() => MOS._pcCerrarSheet());
    await w(500);
  } else res.push([tag, 'sheet', 'sin ideas']);

  // ── 3) detalle de una promo guardada (fechas largas siguen ahí) ──
  const idProm = await p.evaluate(() => (document.querySelector('#pcxActivas .pcx-card') || document.querySelector('.pcx-card:not(.pcx-idea)'))?.getAttribute('data-pcid') || null);
  if (idProm) {
    await p.evaluate(id => MOS._pcDetalle(id), idProm);
    await w(800);
    await p.screenshot({ path: `${OUT}/3_detalle_${tag}.png` });
    const det = await p.evaluate(() => {
      const d = document.getElementById('promoDetalle');
      return d ? { deal: d.querySelector('.pcx-det-deal-big')?.textContent, z: +getComputedStyle(d).zIndex, zc: +getComputedStyle(document.getElementById('promoCentro')).zIndex } : null;
    });
    console.log(`[${tag}] detalle:`, JSON.stringify(det));
    res.push([tag, 'detalle', det ? `z=${det.z}>${det.zc}` : 'NO ABRIO']);
    if (det && !(det.z > det.zc)) { res.push([tag, 'FALLA', 'el detalle NO queda encima']); errTotal += 1; }
    await p.evaluate(() => MOS._pcCerrarDetalle());
    await w(400);
  } else res.push([tag, 'detalle', 'sin promos']);

  // ── 4) el botón único: re-baraja ideas Y refresca promos en una pasada ──
  const antes = await p.evaluate(() => [...document.querySelectorAll('.pcx-idea')].map(c => c.getAttribute('data-pcsug')).join('|'));
  await p.evaluate(() => MOS._pcNuevasIdeas());
  await w(600);
  const girando = await p.evaluate(() => !!document.querySelector('.pcx-btn-ref.girando'));
  await w(8000);
  const despues = await p.evaluate(() => [...document.querySelectorAll('.pcx-idea')].map(c => c.getAttribute('data-pcsug')).join('|'));
  await p.screenshot({ path: `${OUT}/4_nuevas_ideas_${tag}.png` });
  console.log(`[${tag}] refresco: girando=${girando} cambio=${antes !== despues}`);
  res.push([tag, 'nuevasIdeas', `girando=${girando} cambio=${antes !== despues}`]);

  // ── 5) playbook (la otra pestaña sobreviviente) ──
  await p.evaluate(() => { const b = [...document.querySelectorAll('#pcTabs button')].find(x => /Playbook/.test(x.textContent)); if (b) b.click(); });
  await w(2500);
  await p.screenshot({ path: `${OUT}/5_playbook_${tag}.png` });
  res.push([tag, 'playbook', await p.evaluate(() => document.querySelectorAll('#pcBody .pc-card').length + ' jugadas')]);

  if (errs.length) { res.push([tag, '_pageerrors', errs.join(' | ')]); errTotal += errs.length; }
  else res.push([tag, '_pageerrors', '0 ✓']);
  await ctx.close();
}
await b.close();
console.log('\nRESUMEN:');
res.forEach(r => console.log(' ', r.join(' · ')));
fs.writeFileSync(OUT + '/_resumen.json', JSON.stringify(res, null, 1));
console.log(errTotal ? `\n❌ ${errTotal} problemas` : '\n✅ 0 pageerrors y dieta OK');
process.exitCode = errTotal ? 1 : 0;
