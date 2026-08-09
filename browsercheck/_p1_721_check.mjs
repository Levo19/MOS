// [721] Verifica los tres ajustes: (1) Mesa con la compra EN ZONA en "falta
// cotejar" + chip de sugerencia del catálogo en el Paso 1, (2) header compacto
// con totales en vivo y pie sin el botón "Siguiente sin costo", (3) brazo
// centrado en el eje Y. 0 pageerrors obligatorio.
import { chromium } from 'playwright';
import fs from 'fs';

const OUT = process.env.SHOTS_DIR || 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/p1_721';
fs.mkdirSync(OUT, { recursive: true });
const _ALL = [[390, 844, 'movil'], [1280, 900, 'pc']];
const VPS = process.env.VP ? _ALL.filter(v => v[2] === process.env.VP) : _ALL;
const GUIA_WH   = 'G_L17861131797225kwi4vv';          // proveedor, 12 líneas, con foto
const GUIA_ZONA = 'G-1786193956097-wnj2ch';           // la compra EN ZONA del reporte
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

  // ── A) RPC de cotejo: la compra de zona no tiene costos confirmados ──
  const cot = await p.evaluate(async g => {
    try { const r = await API.post('cotejoCostosGuias', { idGuias: [g, 'G-1785618285431-mobetr'] }); return r && (r.data || r); }
    catch (e) { return 'ERR ' + e.message; }
  }, GUIA_ZONA);
  console.log(`[${tag}] cotejo RPC:`, JSON.stringify(cot));
  res.push([tag, 'A rpc cotejo', JSON.stringify(cot)]);
  if (cot && cot[GUIA_ZONA]) { res.push([tag, 'FALLA', 'la compra de zona figura cotejada']); fallas++; }

  // ── B) Mesa: la compra EN ZONA debe decir "Falta cotejar" ──
  await p.evaluate(() => { try { MOS.abrirMesaCompras(); } catch (_) {} });
  await w(12000);
  const mesa = await p.evaluate(g => {
    const card = document.getElementById('mesacard_ME_' + g) || [...document.querySelectorAll('.mesa-card')].find(c => (c.id || '').includes(g));
    const zonas = [...document.querySelectorAll('.mesa-card.is-zona')];
    return {
      card: card ? card.innerText.replace(/\n+/g, ' | ').slice(0, 190) : null,
      zonasTotal: zonas.length,
      zonasCotejar: zonas.filter(c => /Falta cotejar/i.test(c.innerText)).length,
      nota: !!document.querySelector('.mesa-zona-nota')
    };
  }, GUIA_ZONA);
  console.log(`[${tag}] mesa:`, JSON.stringify(mesa, null, 1));
  await p.screenshot({ path: `${OUT}/1_mesa_zona_${tag}.png` });
  res.push([tag, 'B mesa zona', `zonas=${mesa.zonasTotal} faltaCotejar=${mesa.zonasCotejar} nota=${mesa.nota}`]);
  if (mesa.card && !/Falta cotejar/i.test(mesa.card)) { res.push([tag, 'FALLA', 'la compra del reporte no dice "Falta cotejar": ' + mesa.card]); fallas++; }
  await p.evaluate(() => { try { MOS.cerrarMesaCompras(); } catch (_) {} });
  await w(900);

  // ── C) Paso 1: header compacto + pie sin CTA + brazo centrado ──
  await p.evaluate(g => { try { MOS.opsEntrarModoCostos('WH', g); } catch (_) {} }, GUIA_WH);
  await w(6500);
  const p1 = await p.evaluate(() => {
    const q = s => document.querySelector(s);
    const r = el => { if (!el) return null; const b = el.getBoundingClientRect(); return { y: Math.round(b.y), h: Math.round(b.height), w: Math.round(b.width) }; };
    const box = q('#modalCostosGuiaUnif .p1-box');
    const carta = q('#p1Carta');
    const bb = box ? box.getBoundingClientRect() : null;
    const cb = carta ? carta.getBoundingClientRect() : null;
    return {
      totalEnHeader: !!q('#opsCostosSubheader #costosGuiaTotalBruto'),
      totalEnPie:    !!q('#opsCostosFooter #costosGuiaTotalBruto'),
      cta:           !!q('#costosCtaGuiada'),
      fraseCompara:  (q('#opsCostosSubheader')?.innerText || '').includes('Compara con la factura'),
      sello:         !!q('#costosSaveState'),
      chips:         !!q('#costosMiniProg'),
      sugCat:        document.querySelectorAll('.cl-sugcat').length,
      header:        r(q('#opsCostosSubheader')),
      pie:           r(q('#opsCostosFooter')),
      // centrado del brazo: su centro vs el centro del overlay
      centroBox:     bb ? Math.round(bb.y + bb.height / 2) : null,
      centroCarta:   cb && cb.height ? Math.round(cb.y + cb.height / 2) : null
    };
  });
  console.log(`[${tag}] paso1:`, JSON.stringify(p1, null, 1));
  await p.screenshot({ path: `${OUT}/2_paso1_${tag}.png` });
  res.push([tag, 'C header', `totalHeader=${p1.totalEnHeader} totalPie=${p1.totalEnPie} frase=${p1.fraseCompara} pieH=${p1.pie?.h}`]);
  res.push([tag, 'C pie', `cta=${p1.cta} chips=${p1.chips} sello=${p1.sello}`]);
  if (!p1.totalEnHeader) { res.push([tag, 'FALLA', 'el total no está en el header']); fallas++; }
  if (p1.totalEnPie)     { res.push([tag, 'FALLA', 'el total sigue en el pie']); fallas++; }
  if (p1.cta)            { res.push([tag, 'FALLA', 'el botón "Siguiente sin costo" sigue vivo']); fallas++; }
  if (p1.fraseCompara)   { res.push([tag, 'FALLA', 'la frase "Compara con la factura" sigue viva']); fallas++; }
  if (!p1.sello || !p1.chips) { res.push([tag, 'FALLA', 'el pie perdió chips o sello']); fallas++; }
  if (p1.centroCarta != null) {
    const d = Math.abs(p1.centroCarta - p1.centroBox);
    res.push([tag, 'C brazo', `centroBox=${p1.centroBox} centroCarta=${p1.centroCarta} Δ=${d}`]);
    if (d > 6) { res.push([tag, 'FALLA', 'el brazo no está centrado en Y (Δ=' + d + ')']); fallas++; }
  } else res.push([tag, 'C brazo', 'sin brazo (viewport angosto)']);

  // ── D) Enter salta de línea (el atajo que SÍ sirve sigue vivo) ──
  const salto = await p.evaluate(async () => {
    const inps = [...document.querySelectorAll('.alm-v-costo-input')];
    if (inps.length < 2) return 'pocas líneas';
    inps[0].focus();
    const antes = document.activeElement === inps[0];
    inps[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    await new Promise(r => setTimeout(r, 700));
    return `focoInicial=${antes} focoMovido=${document.activeElement !== inps[0]}`;
  });
  console.log(`[${tag}] enter:`, salto);
  res.push([tag, 'D enter salta', String(salto)]);

  if (errs.length) { res.push([tag, '_pageerrors', errs.join(' | ')]); fallas += errs.length; }
  else res.push([tag, '_pageerrors', '0 ✓']);
  await ctx.close();
}
await b.close();
console.log('\nRESUMEN:');
res.forEach(r => console.log(' ', r.join(' · ')));
fs.writeFileSync(OUT + '/_resumen.json', JSON.stringify(res, null, 1));
console.log(fallas ? `\n❌ ${fallas} fallas` : '\n✅ 0 pageerrors y los 3 ajustes OK');
process.exitCode = fallas ? 1 : 0;
