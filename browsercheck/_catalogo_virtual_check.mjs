// Catálogo virtual público de INVERSIONES MOS — verificación visual + de consola.
//   node _catalogo_virtual_check.mjs <url> <tag>
// Toma portada / sumario / apertura de capítulo / hoja de marca / contratapa en 390 y 1280.
import { chromium } from 'playwright';
import fs from 'fs';

const URL = process.argv[2] || 'http://127.0.0.1:8799/catalogo.html';
const TAG = process.argv[3] || 'local';
const OUT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/';

const VP = [
  { w: 390, h: 844, n: '390', movil: true },
  { w: 1280, h: 900, n: '1280', movil: false }
];

const b = await chromium.launch();
const informe = { url: URL, tag: TAG, vistas: {} };

for (const v of VP) {
  const ctx = await b.newContext({
    viewport: { width: v.w, height: v.h }, deviceScaleFactor: 2,
    isMobile: v.movil, hasTouch: v.movil
  });
  const errs = [], cons = [], red = [];
  const pg = await ctx.newPage();
  pg.on('pageerror', e => errs.push(String(e)));
  pg.on('console', m => { if (m.type() === 'error') cons.push(m.text()); });
  pg.on('requestfailed', r => red.push(r.url().slice(0, 120) + ' · ' + (r.failure() || {}).errorText));

  await pg.goto(URL, { waitUntil: 'networkidle' });
  await pg.waitForSelector('.cap-ap', { timeout: 25000 });
  await pg.waitForTimeout(1600);

  const shot = async (nombre) => {
    const f = OUT + `cat_${v.n}_${nombre}.png`;
    await pg.screenshot({ path: f });
    return f;
  };
  // scroll INSTANTÁNEO: la página usa scroll-behavior:smooth + scroll-snap, y un
  // scrollTo animado deja la toma a medio viaje (artefacto del harness, no de la página).
  const irY = async (sel, i = 0) => {
    await pg.evaluate(([s, k]) => {
      const el = document.querySelectorAll(s)[k];
      if (el) window.scrollTo({ top: el.getBoundingClientRect().top + window.scrollY, behavior: 'instant' });
    }, [sel, i]);
    await pg.waitForTimeout(1700);
  };

  const tomas = {};
  tomas.portada = await shot('1portada');
  await irY('#sumario'); tomas.sumario = await shot('2sumario');
  await irY('.cap-ap', 3); tomas.capitulo = await shot('3capitulo');   // ZUKO = cap 4
  await irY('.hoja', 0); tomas.hoja0 = await shot('4hoja_surtido');
  const iz = await pg.evaluate(() => {
    const hs = [...document.querySelectorAll('.hoja')];
    return hs.findIndex(h => (h.querySelector('.hcab h3') || {}).textContent === 'ZUKO');
  });
  await irY('.hoja', iz < 0 ? 1 : iz); tomas.hojaMarca = await shot('5hoja_zuko');
  await irY('#contratapa'); tomas.contratapa = await shot('6contratapa');

  // buscador
  await pg.click('#fab'); await pg.waitForTimeout(600);
  await pg.fill('#bq', 'fresa'); await pg.waitForTimeout(500);
  tomas.buscador = await shot('7buscador');
  const nres = await pg.evaluate(() => document.querySelectorAll('#bres .r').length);
  await pg.keyboard.press('Escape'); await pg.waitForTimeout(500);

  // lectura del DOM construido
  const dom = await pg.evaluate(() => {
    const lum = c => { const [r, g, bl] = c.match(/[0-9.]+/g).slice(0, 3).map(Number).map(x => { x /= 255; return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4); }); return 0.2126 * r + 0.7152 * g + 0.0722 * bl; };
    const ratio = (a, bg) => { const L1 = Math.max(lum(a), lum(bg)), L2 = Math.min(lum(a), lum(bg)); return +((L1 + 0.05) / (L2 + 0.05)).toFixed(2); };
    const caps = [...document.querySelectorAll('.cap-ap')].map(c => {
      const cs = getComputedStyle(c);
      return {
        titulo: (c.querySelector('h2') || {}).textContent,
        color: c.style.getPropertyValue('--c').trim(),
        contrasteTintaSobreColor: ratio(cs.color, 'rgb(' + c.style.getPropertyValue('--crgb').trim() + ')'),
        entro: c.classList.contains('in')
      };
    });
    return {
      capitulos: caps,
      hojas: [...document.querySelectorAll('.hoja')].map(h => ({
        titulo: (h.querySelector('.hcab h3') || {}).textContent,
        kicker: (h.querySelector('.hcab .hk') || {}).textContent,
        fichas: h.querySelectorAll('.p').length
      })),
      fichas: document.querySelectorAll('.p').length,
      agotados: document.querySelectorAll('.p.ago').length,
      sellosAgotado: document.querySelectorAll('.tile .sello').length,
      sumario: [...document.querySelectorAll('.sum .t')].map(x => x.textContent),
      escalones: document.querySelectorAll('.esc li').length,
      preciosVacios: [...document.querySelectorAll('.ep')].filter(x => !/[0-9]/.test(x.textContent)).length,
      selloLevo: (document.querySelector('.levo') || {}).textContent,
      selloEsLink: !!document.querySelector('.sello-levo a'),
      wa: (document.querySelector('#contacto a.wa') || {}).href || null,
      desbordeH: document.documentElement.scrollWidth > window.innerWidth + 1,
      alto: document.documentElement.scrollHeight
    };
  });

  informe.vistas[v.n] = { pageerrors: errs, consoleErrors: cons, requestFailed: red,
    resultadosBusca: nres, tomas, dom };
  console.log(`\n── ${v.n}px ── pageerrors:${errs.length} consoleErr:${cons.length} redFail:${red.length}`);
  if (errs.length) console.log('  ERR', errs);
  if (cons.length) console.log('  CONS', cons);
  if (red.length) console.log('  RED', red);
  console.log('  capítulos:', dom.capitulos.map(c => c.titulo + ' ' + c.color + ' (' + c.contrasteTintaSobreColor + ':1)').join(' | '));
  console.log('  hojas:', dom.hojas.map(h => h.titulo + '×' + h.fichas).join(' | '));
  console.log('  fichas:', dom.fichas, '· agotados:', dom.agotados, '· sellos:', dom.sellosAgotado,
    '· escalones:', dom.escalones, '· precios vacíos:', dom.preciosVacios);
  console.log('  sello:', JSON.stringify(dom.selloLevo), '· es link:', dom.selloEsLink, '· wa:', dom.wa);
  console.log('  desborde horizontal:', dom.desbordeH, '· buscador "fresa":', nres);
  await ctx.close();
}

fs.writeFileSync(OUT + `cat_${TAG}.json`, JSON.stringify(informe, null, 1));
await b.close();
const tot = Object.values(informe.vistas).reduce((a, v) => a + v.pageerrors.length + v.consoleErrors.length, 0);
console.log(tot === 0 ? '\n✅ 0 errores de consola / página' : '\n❌ hay errores');
