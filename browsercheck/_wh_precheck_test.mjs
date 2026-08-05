// Verifica el fix del cuelgue al generar guía (reclamo de Sergio, 04/08).
import fs from 'fs';
const html = fs.readFileSync('C:/Users/ISO/ecosistema MOS/warehouseMos/index.html', 'utf8');
const app = fs.readFileSync('C:/Users/ISO/ecosistema MOS/warehouseMos/js/app.js', 'utf8');
let ok = 0, fail = 0;
const t = (n, c, x) => { if (c) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, x ?? ''); } };

console.log('── sintaxis');
const scripts = [...html.matchAll(/<script(?![^>]*\ssrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
let err = 0;
scripts.forEach((s, i) => { if (!s.trim()) return; try { new Function(s); } catch (e) {
  if (/Unexpected|Invalid|missing/i.test(e.message)) { err++; console.log(`     script #${i}: ${e.message.slice(0,90)}`); } } });
t(`los ${scripts.length} scripts inline de index.html parsean`, err === 0, err);

console.log('── el chequeo de versión ya no puede colgar el despacho');
t('usa AbortController', html.includes('const _ac = new AbortController()'));
t('se rinde a los 3.5s', /setTimeout\(\(\) => \{ try \{ _ac\.abort\(\); \} catch\(_\)\{\} \}, 3500\)/.test(html));
t('pasa la señal al fetch de version.json', /fetch\('\.\/version\.json\?t=' \+ now, \{ cache: 'no-store', signal: _ac\.signal \}\)/.test(html));
t('limpia el temporizador siempre (finally)', /finally \{ clearTimeout\(_to\); \}/.test(html));
t('el abort cae al catch tolerante que NO bloquea',
  /catch\(_\) \{[\s\S]{0,120}_preCheckCache = \{ ts: now, ok: true \};\s*\n\s*return true;/.test(html));

console.log('── no se rompió el propósito original (evitar despachar con versión vieja)');
t('sigue detectando versión distinta', html.includes("j.version !== _APP_VERSION_BL"));
t('sigue forzando el reload', html.includes('location.reload(true)'));
t('sigue devolviendo false cuando hay versión nueva', /_preCheckCache = \{ ts: now, ok: false \};\s*\n\s*return false;/.test(html));
t('el cierre de pickup sigue llamando al pre-check', app.includes('await window._preCheckVersion()'));

console.log('── lo publicado hoy sigue en su sitio');
t('el tope de granel 10x sigue', app.includes('es más de 10× lo pedido'));
t('la confirmación de sobre-despacho sigue', app.includes('Más de lo pedido'));

console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
process.exit(fail === 0 ? 0 : 1);
