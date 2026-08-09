// [667] Webcheck del CENTRO DE PROMOCIONES v2 — exige 0 pageerrors y captura
// la vista integrada (ideas + activas), el form con el panel del piso vivo,
// el detalle de una card y el sheet de una idea. Viewports 390 y 1280.
// Uso: node _promo_v2_shots.mjs
import { chromium } from 'playwright';
import fs from 'fs';

const OUT = process.env.SHOTS_DIR || 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/promoshots';
fs.mkdirSync(OUT, { recursive: true });
const VPS = [[390, 844, 'movil'], [1280, 900, 'pc']];

const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906474',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' }),
};
const w = ms => new Promise(r => setTimeout(r, ms));
const PROD_CON_COSTO = 'ANIS ESTRELLA ENTERO GRANEL';   // pv 80 · pc 30 · margen 62.5%

const res = [];
let errTotal = 0;
const b = await chromium.launch();
for (const [W, H, tag] of VPS) {
  const ctx = await b.newContext({ viewport: { width: W, height: H }, hasTouch: W < 800 });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0, 140)));
  await p.addInitScript(seed => { for (const [k, v] of Object.entries(seed)) localStorage.setItem(k, v); }, SEED);
  await p.goto('https://levo19.github.io/MOS/?nc=' + Date.now(), { waitUntil: 'domcontentloaded' });
  await w(21000);
  await p.evaluate(() => { const el = [...document.querySelectorAll('button,a')].find(x => /Entrar a MOS/i.test(x.textContent || '')); if (el) el.click(); });
  await w(1800);
  await p.evaluate(() => { try { MOS.nav('catalogo'); } catch (_) {} });
  await w(7000);

  const boot = await p.evaluate(() => {
    let mos = 'nd'; try { mos = typeof MOS; } catch (_) {}
    const g = (document.body.innerText.match(/([0-9]+) grupos/) || [])[1];
    return { mos, grupos: g || 0, ver: (window.MOS_VER || '') };
  });
  console.log(`[${tag}] boot:`, JSON.stringify(boot), errs.length ? '· ERR: ' + errs.join(' | ') : '· sin pageerrors');
  if (boot.mos !== 'object') { res.push([tag, 'BOOT FAIL', errs.join('|')]); errTotal += 1; await ctx.close(); continue; }

  // ── 1) vista integrada: ideas + activas ──
  await p.evaluate(() => MOS.abrirPromoCentro('mis'));
  await w(6500);
  const vista = await p.evaluate(() => ({
    ideas:   document.querySelectorAll('.pcx-idea').length,
    activas: document.querySelectorAll('#pcxActivas .pcx-card').length,
    deals:   [...document.querySelectorAll('.pcx-deal')].slice(0, 6).map(x => x.textContent.trim()),
    ancla:   [...document.querySelectorAll('.pcx-ancla')].map(x => x.textContent.trim())[0] || null
  }));
  console.log(`[${tag}] integrada:`, JSON.stringify(vista, null, 1));
  await p.screenshot({ path: `${OUT}/1_integrada_${tag}.png`, fullPage: false });
  res.push([tag, 'integrada', `ideas=${vista.ideas} activas=${vista.activas}`]);

  // ── 2) sheet de una idea ──
  const idSug = await p.evaluate(() => {
    const c = document.querySelector('.pcx-idea');
    return c ? c.getAttribute('data-pcsug') : null;
  });
  if (idSug) {
    await p.evaluate(id => MOS._pcSheet(id), idSug);
    await w(900);
    await p.screenshot({ path: `${OUT}/2_sheet_idea_${tag}.png` });
    const sh = await p.evaluate(() => {
      const s = document.getElementById('pcSheet');
      return s ? { tit: s.querySelector('.pcx-sheet-tit')?.textContent, deal: s.querySelector('.pcx-det-deal-big')?.textContent } : null;
    });
    console.log(`[${tag}] sheet:`, JSON.stringify(sh));
    res.push([tag, 'sheet', sh ? 'ok' : 'NO ABRIO']);
    await p.evaluate(() => MOS._pcCerrarSheet());
    await w(500);
  } else { res.push([tag, 'sheet', 'sin ideas']); }

  // ── 3) detalle de una promo activa ──
  const idProm = await p.evaluate(() => {
    const c = document.querySelector('#pcxActivas .pcx-card') || document.querySelector('.pcx-card:not(.pcx-idea)');
    return c ? c.getAttribute('data-pcid') : null;
  });
  if (idProm) {
    await p.evaluate(id => MOS._pcDetalle(id), idProm);
    await w(800);
    await p.screenshot({ path: `${OUT}/3_detalle_${tag}.png` });
    const det = await p.evaluate(() => {
      const d = document.getElementById('promoDetalle');
      if (!d) return null;
      const z = (el) => +getComputedStyle(el).zIndex;
      return { deal: d.querySelector('.pcx-det-deal-big')?.textContent, z: z(d), zCentro: z(document.getElementById('promoCentro')) };
    });
    console.log(`[${tag}] detalle:`, JSON.stringify(det));
    res.push([tag, 'detalle', det ? `z=${det.z} > centro ${det.zCentro}` : 'NO ABRIO']);
    await p.evaluate(() => MOS._pcCerrarDetalle());
    await w(400);
  } else { res.push([tag, 'detalle', 'sin promos']); }

  // ── 4) FORM con panel del piso · z-index sobre el centro ──
  await p.evaluate(() => MOS.promoAbrirNueva());
  await w(900);
  await p.evaluate(() => {
    document.querySelector('input[name="promoTipo"][value="PORCENTAJE"]').checked = true;
    MOS.promoSetTipo('PORCENTAJE');
  });
  await w(300);
  // producto CON costo cargado → el panel muestra piso, % máximo y semáforo reales
  await p.evaluate(q => { const i = document.getElementById('promoBuscar'); i.value = q; MOS.promoBuscarBase(); }, PROD_CON_COSTO);
  await w(700);
  await p.evaluate(() => { const r = document.querySelector('#promoBuscarRes .pn-result'); if (r) r.click(); });
  await w(500);
  await p.evaluate(() => {
    document.getElementById('promoCantMin').value = '2';
    document.getElementById('promoValor').value = '20';
    MOS.promoActualizarEjemplo();
  });
  await w(400);
  const form = await p.evaluate(() => {
    const m = document.getElementById('modalPromoEdit');
    const c = document.getElementById('promoCentro');
    const panel = document.getElementById('promoPisoPanel');
    return {
      zForm: +getComputedStyle(m).zIndex,
      zCentro: c ? +getComputedStyle(c).zIndex : null,
      panelTxt: (panel ? panel.innerText : '').replace(/\s+/g, ' ').slice(0, 260),
      slider: !!document.getElementById('promoPctSlider')
    };
  });
  await p.evaluate(() => document.getElementById('promoPisoPanel').scrollIntoView({ block: 'center' }));
  await w(600);
  console.log(`[${tag}] form:`, JSON.stringify(form, null, 1));
  await p.screenshot({ path: `${OUT}/4_form_piso_${tag}.png` });
  res.push([tag, 'form', `zForm=${form.zForm} zCentro=${form.zCentro} slider=${form.slider}`]);
  if (!(form.zForm > form.zCentro)) { res.push([tag, 'CAPAS', 'FALLA: el form NO queda encima']); errTotal += 1; }
  await p.evaluate(() => MOS.promoVolverLista());
  await w(400);

  if (errs.length) { res.push([tag, '_pageerrors', errs.join(' | ')]); errTotal += errs.length; }
  else res.push([tag, '_pageerrors', '0 ✓']);
  await ctx.close();
}
await b.close();
console.log('\nRESUMEN:');
res.forEach(r => console.log(' ', r.join(' · ')));
fs.writeFileSync(OUT + '/_resumen.json', JSON.stringify(res, null, 1));
console.log(errTotal ? `\n❌ ${errTotal} problemas` : '\n✅ 0 pageerrors y capas OK');
process.exitCode = errTotal ? 1 : 0;
