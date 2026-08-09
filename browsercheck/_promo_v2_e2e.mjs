// [667] E2E del flujo IDEA → toggle → sheet con la explicación → "✓ Activar promo"
// → la card se muda a Activas y la promo QUEDA en Supabase. Al final la borra.
// También captura el form con el panel del piso usando un producto CON costo.
// Uso: node _promo_v2_e2e.mjs
import { chromium } from 'playwright';
import fs from 'fs';

const OUT = process.env.SHOTS_DIR || 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/promoshots';
fs.mkdirSync(OUT, { recursive: true });
const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906474',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' }),
};
const w = ms => new Promise(r => setTimeout(r, ms));
const PROD_CON_COSTO = 'ANIS ESTRELLA ENTERO GRANEL';   // pv 80 · pc 30 · margen 62.5%

const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 1280, height: 900 } });
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

// ── A) FORM con producto CON costo → semáforo y piso reales ──
await p.evaluate(() => MOS.promoAbrirNueva());
await w(900);
await p.evaluate(() => { document.querySelector('input[name="promoTipo"][value="PORCENTAJE"]').checked = true; MOS.promoSetTipo('PORCENTAJE'); });
await p.evaluate(q => { const i = document.getElementById('promoBuscar'); i.value = q; MOS.promoBuscarBase(); }, PROD_CON_COSTO);
await w(700);
await p.evaluate(() => { const r = document.querySelector('#promoBuscarRes .pn-result'); if (r) r.click(); });
await w(500);
await p.evaluate(() => { const c = document.getElementById('promoCantMin'); c.value = '3'; const v = document.getElementById('promoValor'); v.value = '20'; MOS.promoActualizarEjemplo(); });
await w(500);
const pisoOk = await p.evaluate(() => {
  const el = document.getElementById('promoPisoPanel');
  return el ? el.innerText.replace(/\s+/g, ' ') : '';
});
console.log('PISO (verde, con costo):', pisoOk);
await p.screenshot({ path: `${OUT}/4_form_piso_concosto_pc.png` });

// slider a 60→ se topa en 50: probamos que sincroniza
await p.evaluate(() => MOS.promoPctSlider(45));
await w(400);
const pisoRojo = await p.evaluate(() => document.getElementById('promoPisoPanel').innerText.replace(/\s+/g, ' '));
console.log('PISO (slider 45%):', pisoRojo);
await p.screenshot({ path: `${OUT}/4b_form_piso_slider_pc.png` });
await p.evaluate(() => MOS.promoVolverLista());
await w(400);

// ── B) E2E: idea → toggle → sheet → activar ──
await p.evaluate(() => MOS.abrirPromoCentro('mis'));
await w(6500);
const antes = await p.evaluate(() => ({
  ideas: document.querySelectorAll('.pcx-idea').length,
  activas: document.querySelectorAll('#pcxActivas .pcx-card').length
}));
console.log('antes:', JSON.stringify(antes));

// toca el TOGGLE de la idea (no debe activar directo: abre el sheet)
await p.evaluate(() => document.querySelector('.pcx-idea .pcx-tog-idea').click());
await w(900);
const sheetAbierto = await p.evaluate(() => {
  const s = document.getElementById('pcSheet');
  if (!s) return null;
  return {
    tit: s.querySelector('.pcx-sheet-tit')?.textContent,
    deal: s.querySelector('.pcx-det-deal-big')?.textContent,
    porque: (s.querySelector('.pcx-det-txt')?.textContent || '').slice(0, 120),
    botonActivar: !!s.querySelector('.pcx-btn-activar')
  };
});
console.log('TOGGLE → SHEET (no activó directo):', JSON.stringify(sheetAbierto, null, 1));
await p.screenshot({ path: `${OUT}/2b_sheet_desde_toggle_pc.png` });
const yaCreada = await p.evaluate(() => document.querySelectorAll('#pcxActivas .pcx-card').length);
console.log('activas mientras el sheet está abierto (debe seguir igual):', yaCreada);

// ✓ Activar promo
const datosIdea = await p.evaluate(() => {
  const s = document.getElementById('pcSheet');
  return { deal: s.querySelector('.pcx-det-deal-big')?.textContent };
});
await p.evaluate(() => document.querySelector('.pcx-btn-activar').click());
await w(3500);
const despues = await p.evaluate(() => ({
  ideas: document.querySelectorAll('.pcx-idea').length,
  activas: document.querySelectorAll('#pcxActivas .pcx-card').length,
  primeraActiva: document.querySelector('#pcxActivas .pcx-deal')?.textContent,
  idPrimera: document.querySelector('#pcxActivas .pcx-card')?.getAttribute('data-pcid')
}));
console.log('despues:', JSON.stringify(despues, null, 1));
await p.screenshot({ path: `${OUT}/5_activada_pc.png` });

console.log('\nRESULTADO E2E:');
console.log('  idea activada:', datosIdea.deal);
console.log('  ideas', antes.ideas, '→', despues.ideas, '| activas', antes.activas, '→', despues.activas);
console.log('  card en Activas:', despues.primeraActiva);
console.log('  idPromo creado:', despues.idPrimera);
console.log('  pageerrors:', errs.length ? errs.join(' | ') : '0 ✓');

fs.writeFileSync(OUT + '/_e2e.json', JSON.stringify({ antes, despues, sheetAbierto, errs }, null, 1));
await b.close();
process.exitCode = errs.length ? 1 : 0;
