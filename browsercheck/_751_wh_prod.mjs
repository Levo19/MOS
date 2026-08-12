// [751] Verificación en PRODUCCIÓN de WH 2.13.548: que la app cargue sin errores,
// que la versión viva sea la nueva, que `rev` llegue del servidor y que las funciones
// del ajuste en vivo estén realmente desplegadas.
import { chromium } from 'playwright';
const w = ms => new Promise(r => setTimeout(r, ms));

const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 420, height: 900 } });   // celular del operador
const p = await ctx.newPage();
const errs = [];
p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0, 160)));

await p.goto('https://levo19.github.io/warehouseMos-/?nc=' + Date.now(), { waitUntil: 'domcontentloaded', timeout: 120000 });
await w(18000);

const r = await p.evaluate(() => ({
  version: (typeof WH_CONFIG !== 'undefined' && WH_CONFIG.version) || document.querySelector('[data-version]')?.textContent || '?',
  tieneFusion: /\/\* fusion \*\//.test('') || typeof window._fusionarPickupConServidor === 'function',
  titulo: document.title,
}));

// El código nuevo vive dentro del IIFE, así que se comprueba en el fuente servido.
const src = await (await fetch('https://levo19.github.io/warehouseMos-/js/app.js?v=2.13.548')).text().catch(() => '');
const api = await (await fetch('https://levo19.github.io/warehouseMos-/js/api.js?v=2.13.548')).text().catch(() => '');
const ver = await (await fetch('https://levo19.github.io/warehouseMos-/version.json?nc=' + Date.now())).json().catch(() => ({}));

const T = [];
const ok = (c, n, extra) => T.push((c ? 'PASS' : 'FAIL') + ' · ' + n + (extra !== undefined ? ' — ' + extra : ''));
ok(ver.version === '2.13.548', 'producción sirve 2.13.548', ver.version);
ok(/_fusionarPickupConServidor/.test(src), 'el ajuste en vivo de la lista está desplegado');
ok(/esta lista fue actualizada|Esta lista fue actualizada/i.test(src), 'el aviso al operador está desplegado');
ok(/_pkKey/.test(src), 'la clave de producto (misma regla del backend) está desplegada');
ok(/\['rev','rev','text'\]/.test(api), 'la versión de lista viaja desde el servidor');
ok(errs.length === 0, 'sin errores de página al cargar', errs.join(' | ') || '0');

console.log(T.join('\n'));
const fails = T.filter(x => x.startsWith('FAIL')).length;
console.log('\nRESULTADO: ' + (T.length - fails) + ' PASS / ' + fails + ' FAIL');
await p.screenshot({ path: 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_751_wh.png' });
await b.close();
process.exit(fails ? 1 : 0);
