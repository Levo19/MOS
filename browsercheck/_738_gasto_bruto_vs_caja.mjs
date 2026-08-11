// [738] El encabezado de cada área de "Personal del día" debe mostrar DOS números:
// el GASTO (lo que la empresa debe por el trabajo) y, solo cuando hubo consumo a
// crédito, el efectivo que sale de caja. Y el KPI de Gasto Personal / Costos Fijos /
// Punto de Equilibrio tiene que estar armado con el BRUTO, no con el neto.
//
// Verdad medida en la base para hoy (mos.personal_dia_lista):
//   Almacén  bruto 144.10 (Jesus 14.10 + Jorgenis 80 + SERGIO 50) · consumo 10.90 → caja 133.20
//   POS      bruto 400.00 · consumo 0 → sin segundo número
import { chromium } from 'playwright';
const w = ms => new Promise(r => setTimeout(r, ms));
const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906477',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude738' })
};
const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 1280, height: 1600 } });
const p = await ctx.newPage();
const errs = [];
p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0, 150)));
await p.addInitScript(s => { for (const [k, v] of Object.entries(s)) localStorage.setItem(k, v); }, SEED);
await p.goto('https://levo19.github.io/MOS/?nc=' + Date.now(), { waitUntil: 'domcontentloaded', timeout: 120000 });
await w(20000);
await p.evaluate(() => { const el = [...document.querySelectorAll('button,a')].find(x => /Entrar a MOS/i.test(x.textContent || '')); if (el) el.click(); });
await w(3000);
console.log('versión viva:', await p.evaluate(() => { try { return V; } catch (_) { return '?'; } }));
await p.evaluate(() => { try { MOS.nav('finanzas'); } catch (_) {} });

// esperar a que pinten los grupos de Personal del día
let grupos = 0;
for (let i = 0; i < 60; i++) {
  await w(2000);
  grupos = await p.evaluate(() => document.querySelectorAll('.fin-pers-group').length);
  if (grupos > 0) break;
}
console.log('grupos pintados:', grupos);
await w(6000); // dejar aterrizar los resúmenes (el header se repinta con ellos)

const r = await p.evaluate(() => {
  const g = [...document.querySelectorAll('.fin-pers-group')].map(el => ({
    area: el.dataset.area,
    titulo: (el.querySelector('.fin-pers-group-tit') || {}).textContent,
    gasto: (el.querySelector('.fin-pers-group-sub') || {}).textContent,
    caja: (el.querySelector('.fin-pers-group-caja') || {}).textContent || null,
    tipGasto: (el.querySelector('.fin-pers-group-sub') || {}).title || '',
    tipCaja: (el.querySelector('.fin-pers-group-caja') || {}).title || ''
  }));
  const pl = (typeof _finPL !== 'undefined' && _finPL) ? _finPL : null;
  return {
    grupos: g,
    pill: (document.getElementById('finPersonalTotal') || {}).textContent,
    sub: (document.getElementById('finPersonalSub') || {}).textContent,
    subTitle: (document.getElementById('finPersonalSub') || {}).title,
    pl: pl ? {
      gastoPersonal: pl.gastoPersonal, consumo: pl._consumoPersonalDia,
      costosFijos: pl.costosFijos, totalGastos: pl.totalGastos,
      utilidadNeta: pl.utilidadNeta, breakEven: pl.breakEvenVentas
    } : null,
    kpiFijos: (document.getElementById('finBECostosFijos') || {}).textContent
  };
});
console.log(JSON.stringify(r, null, 1));

// ── Aserciones ────────────────────────────────────────────────────────────
const num = s => parseFloat(String(s || '').replace(/[^0-9.]/g, '')) || 0;
const alm = r.grupos.find(x => x.area === 'ALMACEN');
const pos = r.grupos.find(x => x.area === 'POS');
const T = [];
const ok = (c, n) => T.push((c ? 'PASS' : 'FAIL') + ' · ' + n);
ok(!!alm, 'existe el grupo ALMACEN');
if (alm) {
  ok(Math.abs(num(alm.gasto) - 144.10) < 0.01, 'Almacén gasto = 144.10 (bruto, no 133.20) — leído ' + alm.gasto);
  ok(!!alm.caja, 'Almacén muestra el segundo número (caja)');
  ok(alm.caja && Math.abs(num(alm.caja) - 133.20) < 0.01, 'Almacén caja = 133.20 — leído ' + alm.caja);
  ok(/gasto/i.test(alm.tipGasto) && /caja/i.test(alm.tipCaja), 'ambos números explicados en el title');
}
if (pos) {
  ok(pos.caja === null, 'POS (sin consumo) NO pinta segundo número — leído ' + pos.caja);
  ok(Math.abs(num(pos.gasto) - 250) < 0.01, 'POS gasto = 250.00 (5 cajeros × 50) — leído ' + pos.gasto);
}
// _finPL es const de módulo (no window) → la prueba se hace contra el DOM, que es
// lo que el dueño mira: el pill del card y el KPI de Costos Fijos del break-even.
ok(Math.abs(num(r.pill) - 394.10) < 0.02, 'pill de Personal = 394.10 BRUTO (250 + 144.10), no 383.20 — leído ' + r.pill);
ok(Math.abs(num(r.kpiFijos) - 394.10) < 0.02, 'Costos Fijos del break-even usa el BRUTO — leído ' + r.kpiFijos);
ok(/sale de caja/.test(r.sub || ''), 'el subtítulo dice cuánto sale de caja — leído "' + r.sub + '"');
ok(/383\.20/.test(r.sub || ''), 'subtítulo con el efectivo real 394.10 − 10.90 = 383.20 — leído "' + r.sub + '"');
ok(/394\.10/.test(r.subTitle || '') && /10\.90/.test(r.subTitle || ''), 'el title del subtítulo explica la resta completa');
ok(errs.length === 0, 'pageerrors: ' + (errs.join(' | ') || '0'));

console.log('\n' + T.join('\n'));
console.log('\nRESULTADO: ' + T.filter(x => x.startsWith('PASS')).length + ' PASS / ' + T.filter(x => x.startsWith('FAIL')).length + ' FAIL');
await p.screenshot({ path: 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_738_personal.png', fullPage: false });
await b.close();
process.exit(T.some(x => x.startsWith('FAIL')) ? 1 : 0);
