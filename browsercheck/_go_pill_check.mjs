// GO pill sin parpadeo: pintado en sitio, sin re-render del catálogo.
import fs from 'fs';
const app = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/js/app.js', 'utf8');
const html = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/index.html', 'utf8');
let ok = 0, fail = 0;
const t = (n, c, x) => { if (c) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, x ?? ''); } };

t('CSS .go-pill/.on definido en index.html', html.includes('.go-pill.on {') && html.includes('.go-pill.sm'));
t('la pill se emite por clases (pintable en sitio)', /class="go-pill\$\{sm \? ' sm' : ''\}\$\{go \? ' on' : ''\}"/.test(app));
t('existe _pintarGo', app.includes('function _pintarGo('));
const bloque = app.slice(app.indexOf('async function toggleMosgo'), app.indexOf('async function toggleMosgo') + 1800);
t('toggleMosgo NO repinta el catálogo (adiós parpadeo)', !bloque.includes('renderCatalogo()'));
t('optimista y revert pintan solo el botón', bloque.includes('_pintarGo(idProducto, on)') && bloque.includes("_pintarGo(idProducto, String(goPrevio) === '1')"));

console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
process.exit(fail === 0 ? 0 : 1);
