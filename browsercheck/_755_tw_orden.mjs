// [755] ¿Dónde inyecta su <style> el Tailwind Play CDN dentro del <head>?
// Decide en qué posición va el <link rel=stylesheet href=css/tw.css> del build estático:
// si el CDN inyectaba DESPUÉS de la hoja a mano de index.html, poner el <link> en la
// línea 13 (donde estaba el <script>) invertiría la cascada y cambiaría el aspecto.
// Se corre contra PRODUCCIÓN (que todavía usa el CDN) para medirlo de verdad.
import { createRequire } from 'module';
const require = createRequire('C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/');
const { chromium } = require('playwright');
const w = ms => new Promise(r => setTimeout(r, ms));

const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 1280, height: 900 } });
const p = await ctx.newPage();
await p.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded', timeout: 120000 });
await w(12000);
const d = await p.evaluate(() => {
  const kids = [...document.head.children];
  return kids.map((e, i) => {
    const t = e.tagName.toLowerCase();
    const txt = (e.textContent || '').trim();
    let tag = t;
    if (t === 'script' && e.src) tag += ' src=' + e.src.replace(/^https?:\/\//, '').slice(0, 40);
    if (t === 'link') tag += ' ' + (e.rel || '') + ' ' + (e.href || '').split('/').pop();
    if (t === 'style') tag += ' [' + Math.round(txt.length / 1024) + 'KB] ' + txt.slice(0, 60).replace(/\s+/g, ' ');
    return i + ': ' + tag;
  });
});
d.forEach(l => console.log(l));
await b.close(); process.exit(0);
