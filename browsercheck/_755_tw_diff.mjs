// [755] Diff de píxeles local (build estático) vs prod (CDN) de las capturas que dejó
// _755_tw_visual.mjs. Se decodifican en un canvas dentro de Chromium (no hace falta pixelmatch).
// Umbral por píxel: 12/255 en cualquier canal — tolera el antialias del texto, delata
// un color de fondo/borde que cambió.
import { createRequire } from 'module';
const require = createRequire('C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/');
const { chromium } = require('playwright');
import fs from 'fs';

const DIR = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/.claude/worktrees/agent-aa328909aa8900a58/browsercheck';
const pares = fs.readdirSync(DIR).filter(f => f.startsWith('_755_local_') && f.endsWith('.png'))
  .map(f => [f, f.replace('_755_local_', '_755_prod_')])
  .filter(([, b]) => fs.existsSync(DIR + '/' + b));

const b = await chromium.launch();
const p = await (await b.newContext()).newPage();
await p.goto('about:blank');
for (const [a, c] of pares) {
  const d = await p.evaluate(async ([da, dc]) => {
    const load = src => new Promise(r => { const i = new Image(); i.onload = () => r(i); i.onerror = () => r(null); i.src = src; });
    const [ia, ic] = await Promise.all([load(da), load(dc)]);
    if (!ia || !ic) return { err: 'no carga' };
    if (ia.width !== ic.width || ia.height !== ic.height) return { err: `tamaño ${ia.width}x${ia.height} vs ${ic.width}x${ic.height}` };
    const cv = document.createElement('canvas'); cv.width = ia.width; cv.height = ia.height;
    const g = cv.getContext('2d', { willReadFrequently: true });
    g.drawImage(ia, 0, 0); const A = g.getImageData(0, 0, cv.width, cv.height).data;
    g.clearRect(0, 0, cv.width, cv.height); g.drawImage(ic, 0, 0); const C = g.getImageData(0, 0, cv.width, cv.height).data;
    let n = 0, peor = 0, filas = {};
    for (let i = 0; i < A.length; i += 4) {
      const dd = Math.max(Math.abs(A[i] - C[i]), Math.abs(A[i+1] - C[i+1]), Math.abs(A[i+2] - C[i+2]));
      if (dd > 12) { n++; if (dd > peor) peor = dd; const y = Math.floor((i / 4) / cv.width); filas[y - y % 50] = (filas[y - y % 50] || 0) + 1; }
    }
    const zonas = Object.entries(filas).sort((x, y) => y[1] - x[1]).slice(0, 3).map(([y, k]) => `y≈${y}:${k}`);
    return { pct: +(100 * n / (A.length / 4)).toFixed(3), px: n, peor, zonas };
  }, ['data:image/png;base64,' + fs.readFileSync(DIR + '/' + a).toString('base64'),
      'data:image/png;base64,' + fs.readFileSync(DIR + '/' + c).toString('base64')]);
  console.log(a.replace('_755_local_', '').replace('.png', '').padEnd(16) + JSON.stringify(d));
}
await b.close(); process.exit(0);
