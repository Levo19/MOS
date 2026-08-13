// [755] Pinta EN ROJO los píxeles que difieren entre local y prod, sobre la captura local
// atenuada. Sirve para ver de un vistazo si el diff es "datos en vivo" o "estilo perdido".
//   node _755_tw_diffimg.mjs config tributario cajas
import { createRequire } from 'module';
const require = createRequire('C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/');
const { chromium } = require('playwright');
import fs from 'fs';
const DIR = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/.claude/worktrees/agent-aa328909aa8900a58/browsercheck';
const nombres = process.argv.slice(2);
const b = await chromium.launch();
const p = await (await b.newContext()).newPage();
await p.goto('about:blank');
for (const n of nombres) {
  const da = 'data:image/png;base64,' + fs.readFileSync(`${DIR}/_755_local_${n}.png`).toString('base64');
  const dc = 'data:image/png;base64,' + fs.readFileSync(`${DIR}/_755_prod_${n}.png`).toString('base64');
  const b64 = await p.evaluate(async ([x, y]) => {
    const load = s => new Promise(r => { const i = new Image(); i.onload = () => r(i); i.src = s; });
    const [ia, ic] = await Promise.all([load(x), load(y)]);
    const cv = document.createElement('canvas'); cv.width = ia.width; cv.height = ia.height;
    const g = cv.getContext('2d', { willReadFrequently: true });
    g.drawImage(ia, 0, 0); const A = g.getImageData(0, 0, cv.width, cv.height);
    g.clearRect(0, 0, cv.width, cv.height); g.drawImage(ic, 0, 0); const C = g.getImageData(0, 0, cv.width, cv.height).data;
    const D = A.data;
    for (let i = 0; i < D.length; i += 4) {
      const dd = Math.max(Math.abs(D[i] - C[i]), Math.abs(D[i+1] - C[i+1]), Math.abs(D[i+2] - C[i+2]));
      if (dd > 12) { D[i] = 255; D[i+1] = 0; D[i+2] = 0; }
      else { D[i] = D[i] * 0.25; D[i+1] = D[i+1] * 0.25; D[i+2] = D[i+2] * 0.25; }
    }
    g.putImageData(A, 0, 0);
    return cv.toDataURL('image/png').split(',')[1];
  }, [da, dc]);
  fs.writeFileSync(`${DIR}/_755_diff_${n}.png`, Buffer.from(b64, 'base64'));
  console.log('_755_diff_' + n + '.png');
}
await b.close(); process.exit(0);
