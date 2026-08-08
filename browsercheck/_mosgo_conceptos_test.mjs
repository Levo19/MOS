// MosGo 0.5.10 — catálogo por CONCEPTO + LENTE DE MARCA.
//   node _mosgo_conceptos_test.mjs <url> <tag> [whatif]
//     whatif=1 → intercepta la RPC ruta_boot y devuelve el payload REAL de la BD con
//     ZUKO/UMSHA/SIBARITA encendidas en GO (generado en una tx revertida): así se ven
//     los sub-grupos de marca y la sección virtual sin tocar el catálogo de producción.
import { chromium } from 'playwright';
import fs from 'fs';

const URL = process.argv[2] || 'http://127.0.0.1:8791/index.html';
const TAG = process.argv[3] || 'local';
const WHATIF = process.argv[4] === '1';
const OUT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/';

const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
const errs = [], cons = [];
ctx.on('page', p => {
  p.on('pageerror', e => errs.push(String(e)));
  p.on('console', m => { if (m.type() === 'error') cons.push(m.text()); });
});
if (WHATIF) {
  const payload = fs.readFileSync(OUT + '_mosgo_whatif_marcas.json', 'utf8');
  await ctx.route('**/rest/v1/rpc/ruta_boot', r => r.fulfill({ status: 200, contentType: 'application/json', body: payload }));
}
const pg = await ctx.newPage();
await pg.addInitScript(() => {
  localStorage.setItem('mosgo_test', '1');   // hatch oficial del index (solo localhost/file)
  // en producción manda el candado real: TEST-CLAUDE, sembrado ACTIVO en mos.dispositivos
  localStorage.setItem('mosgo_deviceId', '7e57c1a0-de00-4c1a-9de0-7e57c1a0de00');
  localStorage.setItem('mosgo_session', JSON.stringify({ nombre: 'CLAUDE TEST', id_personal: null, rol: 'ADMIN', ts: Date.now() }));
});
await pg.goto(URL, { waitUntil: 'networkidle' });
await pg.waitForSelector('.grp .ghead', { timeout: 25000 }).catch(() => {});
await pg.waitForTimeout(1200);

const lee = () => pg.evaluate(() => {
  const lum = c => { const [r, g, b] = c.match(/[0-9.]+/g).slice(0, 3).map(Number).map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
  const ratio = (a, b) => { const L1 = Math.max(lum(a), lum(b)), L2 = Math.min(lum(a), lum(b)); return +((L1 + 0.05) / (L2 + 0.05)).toFixed(2); };
  return [...document.querySelectorAll('#lista .grp')].map(g => {
    const h = g.querySelector('.ghead'), cs = getComputedStyle(h);
    return {
      titulo: h.querySelector('.gnm').textContent,
      tag: h.querySelector('.gtag')?.textContent || null,
      contador: h.querySelector('.gct')?.textContent || null,
      tono: g.style.getPropertyValue('--gc').trim(),
      contrasteTextoSobreBanda: ratio(cs.color, cs.backgroundColor),
      subgruposMarca: [...g.querySelectorAll('.mhead')].map(m => m.querySelector('.mnm').textContent + ' · ' + m.querySelector('.mct').textContent),
      cards: g.querySelectorAll('.prod').length
    };
  });
});

const R = {
  V: await pg.evaluate(() => window.V),
  browse: await lee(),
  chips: await pg.$$eval('.prod .stkc', n => n.map(x => x.textContent.trim())),
  stkViejo: await pg.$$eval('.prod .stk', n => n.length).catch(() => 0),
  refs: await pg.$$eval('.prod .ref', n => n.map(x => x.textContent.trim())),
  altp: await pg.$$eval('.altp', n => n.length)
};
await pg.screenshot({ path: OUT + `mosgo_0510_browse_${TAG}.png`, fullPage: false });
// browse con SUB-GRUPO de marca a la vista (2 secciones de concepto + el mini-header)
{
  const i = R.browse.findIndex(s => s.subgruposMarca.length);
  if (i > 0) {
    await pg.evaluate(n => { const g = document.querySelectorAll('#lista .grp')[n];
      document.getElementById('body').scrollTop = g.offsetTop - 150; }, i);
    await pg.waitForTimeout(500);
    await pg.screenshot({ path: OUT + `mosgo_0510_submarca_${TAG}.png` });
  }
}

async function buscar(q, shot) {
  await pg.fill('#busca', q); await pg.waitForTimeout(450);
  const r = await lee();
  if (shot) await pg.screenshot({ path: OUT + shot });
  return r;
}
R.busca_glutamato = await buscar('glutamato', `mosgo_0510_glutamato_${TAG}.png`);
R.busca_marca_zuko = await buscar('zuko', `mosgo_0510_zuko_${TAG}.png`);
R.busca_marca_sibarita = await buscar('sibarita', `mosgo_0510_sibarita_${TAG}.png`);

// estabilidad del color: el tono de una sección no cambia al filtrar
await pg.fill('#busca', ''); await pg.waitForTimeout(400);
const base = await lee();
R.colorEstable = base.every(s => {
  const f = [...R.busca_glutamato, ...R.busca_marca_zuko].find(x => x.titulo === s.titulo);
  return !f || f.tono === s.tono;
});

// irAFam sigue haciendo scroll+flash con secciones y sub-grupos
R.irA = await pg.evaluate(async () => {
  const f = D.fams.find(x => D.escalones.some(e => e.fam === x));
  UI.irAFam(f.fsku); await new Promise(r => setTimeout(r, 400));
  const el = document.querySelector(`.prod[data-fsku="${f.fsku}"]`);
  return { fsku: f.fsku, encontrado: !!el, flash: el ? el.classList.contains('flashfam') : false };
});
R.pageerrors = errs; R.consoleErrors = cons; R.url = URL; R.whatif = WHATIF;

fs.writeFileSync(OUT + `mosgo_0510_${TAG}.json`, JSON.stringify(R, null, 2));
console.log(JSON.stringify(R, null, 2));
await b.close();
process.exit(errs.length ? 1 : 0);
