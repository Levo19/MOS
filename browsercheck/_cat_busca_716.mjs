// [716] Test del fix del catálogo. Exige 0 pageerrors en 390 y 1280 y prueba
// el caso EXACTO del dueño:
//   A) "alacena personal" SIN filtros → encuentra ALACENA MAYONESA PERSONAL
//   B) con ⚠️ Solo alertas → estado vacío que NOMBRA el filtro y trae botones
//   C) tocar "Quitar ⚠️ Solo alertas" → aparecen los resultados
//   D) "Limpiar todo" deja el catálogo completo y apaga el filtro de alertas
// Uso: node _cat_busca_716.mjs
import { chromium } from 'playwright';
import fs from 'fs';

const OUT = process.env.SHOTS_DIR || 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/cat716';
fs.mkdirSync(OUT, { recursive: true });
const VPS = [[390, 844, 'movil'], [1280, 900, 'pc']];
const Q = 'alacena personal';
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
  await w(1800);
  await p.evaluate(() => { try { MOS.nav('catalogo'); } catch (_) {} });
  await w(8000);

  const ver = await p.evaluate(() => window.APP_VERSION || document.querySelector('#appVersion')?.textContent || '');
  const setAlertas = async (on) => {
    await p.evaluate(o => {
      const btn = document.getElementById('btnAlertasCat');
      if (btn && btn.classList.contains('active') !== o) btn.click();
    }, on);
    await w(700);
  };
  const buscar = async (q) => {
    await p.evaluate(q => { const i = document.getElementById('searchCatalogo'); i.value = q; MOS.filterCatalogo(); }, q);
    await w(1500);
  };
  const leer = () => p.evaluate(() => ({
    stats: document.getElementById('catStats')?.textContent || '',
    txt:   (document.getElementById('listCatalogo')?.innerText || '').replace(/\n+/g, ' | ').slice(0, 300),
    btns:  [...document.querySelectorAll('.cat-vacio-btn')].map(x => x.textContent.trim()),
    alert: !!document.getElementById('btnAlertasCat')?.classList.contains('active'),
    query: document.getElementById('searchCatalogo')?.value || ''
  }));

  // ── A) sin filtros ──
  await setAlertas(false);
  await buscar(Q);
  const A = await leer();
  await p.screenshot({ path: `${OUT}/A_sin_filtros_${tag}.png` });
  const okA = /ALACENA MAYONESA PERSONAL/i.test(A.txt);
  console.log(`[${tag}] A sin filtros:`, A.stats, '| mayonesa =', okA);
  res.push([tag, 'A busca sin filtros', `${A.stats} · mayonesa=${okA}`]);
  if (!okA) { fallas++; res.push([tag, 'FALLA', 'no encontró ALACENA MAYONESA PERSONAL']); }

  // ── B) con Solo alertas → vacío explicado ──
  await setAlertas(true);
  await buscar(Q);
  const B = await leer();
  await p.screenshot({ path: `${OUT}/B_vacio_explicado_${tag}.png` });
  const okB = /Solo alertas/.test(B.txt) && B.btns.length >= 2 && /Limpiar todo/.test(B.btns.join(' '));
  console.log(`[${tag}] B vacío:`, B.stats, '|', B.txt.slice(0, 160), '| btns:', JSON.stringify(B.btns));
  res.push([tag, 'B vacío explicado', `btns=[${B.btns.join(' / ')}]`]);
  if (!okB) { fallas++; res.push([tag, 'FALLA', 'el vacío no nombra el filtro o le faltan botones']); }

  // ── C) tocar "Quitar ⚠️ Solo alertas" → aparecen resultados ──
  await p.evaluate(() => {
    const b = [...document.querySelectorAll('.cat-vacio-btn')].find(x => /Solo alertas/.test(x.textContent));
    if (b) b.click();
  });
  await w(1600);
  const C = await leer();
  await p.screenshot({ path: `${OUT}/C_tras_quitar_filtro_${tag}.png` });
  const okC = /ALACENA MAYONESA PERSONAL/i.test(C.txt) && C.alert === false && C.query === Q;
  console.log(`[${tag}] C tras quitar:`, C.stats, '| alertasOn =', C.alert, '| query =', C.query);
  res.push([tag, 'C quitar filtro', `${C.stats} · alertas=${C.alert} · query="${C.query}"`]);
  if (!okC) { fallas++; res.push([tag, 'FALLA', 'quitar el filtro no devolvió los resultados']); }

  // ── D) "Limpiar todo" desde el vacío ──
  await setAlertas(true);
  await buscar(Q);
  await p.evaluate(() => {
    const b = [...document.querySelectorAll('.cat-vacio-btn')].find(x => /Limpiar todo/.test(x.textContent));
    if (b) b.click();
  });
  await w(1800);
  const D = await leer();
  await p.screenshot({ path: `${OUT}/D_limpiar_todo_${tag}.png` });
  const okD = D.alert === false && D.query === '' && /grupos/.test(D.stats);
  console.log(`[${tag}] D limpiar todo:`, D.stats, '| alertasOn =', D.alert, '| query = "' + D.query + '"');
  res.push([tag, 'D limpiar todo', `${D.stats} · alertas=${D.alert} · query="${D.query}"`]);
  if (!okD) { fallas++; res.push([tag, 'FALLA', 'Limpiar todo no dejó el catálogo limpio']); }

  // ── E) tokenización amplia: marca + nombre ──
  await buscar('niu personal');
  const E = await leer();
  console.log(`[${tag}] E "niu personal":`, E.stats);
  res.push([tag, 'E marca+nombre', E.stats]);

  res.push([tag, 'version', ver || 'n/d']);
  if (errs.length) { res.push([tag, '_pageerrors', errs.join(' | ')]); fallas += errs.length; }
  else res.push([tag, '_pageerrors', '0 ✓']);
  await ctx.close();
}
await b.close();
console.log('\nRESUMEN:');
res.forEach(r => console.log(' ', r.join(' · ')));
fs.writeFileSync(OUT + '/_resumen.json', JSON.stringify(res, null, 1));
console.log(fallas ? `\n❌ ${fallas} fallas` : '\n✅ 0 pageerrors y los 4 casos OK');
process.exitCode = fallas ? 1 : 0;
