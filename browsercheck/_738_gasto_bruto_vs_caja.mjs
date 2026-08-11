// [738/739] "Personal del día" debe mostrar DOS números por área: el GASTO (lo que la
// empresa debe por el trabajo) y, solo cuando hubo consumo a crédito, el efectivo que
// sale de caja. Y el KPI de Gasto Personal / Costos Fijos / Punto de Equilibrio tiene
// que estar armado con el BRUTO, nunca con el neto (el consumo a crédito es una venta
// cobrada por planilla, no un descuento del costo laboral).
//
// Se comprueban INVARIANTES + el consumo real leído de la base, nunca montos escritos
// a mano: el panel muestra el día EN CURSO, así que un test anclado a las cifras de una
// fecha concreta empieza a fallar solo porque cambió el día.
import { chromium } from 'playwright';
import { Client } from 'pg';
import fs from 'fs';

const w = ms => new Promise(r => setTimeout(r, ms));
const SEED = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906477',
  MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude738' })
};

// ── Verdad de la base: consumo a crédito de hoy (mos.personal_dia_lista) ──────
const cli = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim() });
await cli.connect();
const q = await cli.query(`
  with d as (select mos.personal_dia_lista(jsonb_build_object('fecha',
    to_char((now() at time zone 'America/Lima')::date,'YYYY-MM-DD'))) j)
  select round(coalesce(sum(coalesce((e#>>'{creditosDia,total}')::numeric,0)),0),2) consumo
  from d, jsonb_array_elements(coalesce(d.j->'data'->'personal', d.j->'personal', d.j->'data', d.j)) e`);
await cli.end();
const consumoBD = parseFloat(q.rows[0].consumo) || 0;
console.log('consumo a crédito de hoy según la base: S/ ' + consumoBD.toFixed(2));

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
await p.evaluate(() => { try { MOS.nav('finanzas'); } catch (_) {} });

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
    conteo: (el.querySelector('.fin-pers-group-count') || {}).textContent,
    conteoTip: (el.querySelector('.fin-pers-group-count') || {}).title || '',
    gasto: (el.querySelector('.fin-pers-group-sub') || {}).textContent,
    caja: (el.querySelector('.fin-pers-group-caja') || {}).textContent || null,
    tipGasto: (el.querySelector('.fin-pers-group-sub') || {}).title || '',
    tipCaja: (el.querySelector('.fin-pers-group-caja') || {}).title || ''
  }));
  return {
    grupos: g,
    pill: (document.getElementById('finPersonalTotal') || {}).textContent,
    sub: (document.getElementById('finPersonalSub') || {}).textContent,
    subTitle: (document.getElementById('finPersonalSub') || {}).title,
    kpiFijos: (document.getElementById('finBECostosFijos') || {}).textContent
  };
});
console.log(JSON.stringify(r, null, 1));

// ── Aserciones ────────────────────────────────────────────────────────────────
const num = s => parseFloat(String(s || '').replace(/[^0-9.]/g, '')) || 0;
const T = [];
const ok = (c, n) => T.push((c ? 'PASS' : 'FAIL') + ' · ' + n);

ok(r.grupos.length > 0, 'se pintaron los grupos de Personal del día');

const sumaGrupos = r.grupos.reduce((s, g) => s + num(g.gasto), 0);
ok(Math.abs(sumaGrupos - num(r.pill)) < 0.02,
   'el pill (' + r.pill + ') = suma de los gastos por área (' + sumaGrupos.toFixed(2) + ')');

// _finPL es const de módulo (no window) → se prueba contra el DOM, que es lo que se mira.
ok(num(r.kpiFijos) >= num(r.pill) - 0.02,
   'Costos Fijos (' + r.kpiFijos + ') parte del BRUTO del personal (' + r.pill + '), nunca de un neto menor');

r.grupos.forEach(g => {
  ok(/gasto/i.test(g.tipGasto), g.area + ': el gasto se explica en el title');
  if (g.caja) {
    ok(num(g.caja) < num(g.gasto), g.area + ': caja (' + g.caja + ') < gasto (' + g.gasto + ')');
    ok(/caja/i.test(g.tipCaja), g.area + ': el segundo número se explica en el title');
  }
  // [739] el chip de conteo no puede contradecir al dinero
  if (/\//.test(g.conteo || '')) {
    ok(/no cobran/i.test(g.conteoTip), g.area + ': el chip "' + g.conteo + '" explica los vetados');
  }
});

if (consumoBD > 0) {
  ok(r.grupos.some(g => g.caja), 'hay consumo (S/ ' + consumoBD.toFixed(2) + ') → algún área muestra el segundo número');
  ok(/sale de caja/.test(r.sub || ''), 'el subtítulo dice cuánto sale de caja — "' + r.sub + '"');
  const esperado = (num(r.pill) - consumoBD).toFixed(2);
  ok((r.sub || '').includes(esperado), 'subtítulo con el efectivo real ' + esperado + ' — "' + r.sub + '"');
  ok((r.subTitle || '').includes(consumoBD.toFixed(2)), 'el title explica la resta completa');
} else {
  ok(r.grupos.every(g => g.caja === null), 'sin consumo hoy → ningún área pinta el segundo número');
  ok(!/sale de caja/.test(r.sub || ''), 'sin consumo → el subtítulo no habla de caja — "' + r.sub + '"');
}
ok(errs.length === 0, 'pageerrors: ' + (errs.join(' | ') || '0'));

console.log('\n' + T.join('\n'));
const fails = T.filter(x => x.startsWith('FAIL')).length;
console.log('\nRESULTADO: ' + (T.length - fails) + ' PASS / ' + fails + ' FAIL');
await p.screenshot({ path: 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_738_personal.png', fullPage: false });
await b.close();
process.exit(fails ? 1 : 0);
