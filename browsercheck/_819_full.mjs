// Sirve el árbol COMPLETO del 819 y captura el primer error real de la página.
import { chromium } from 'playwright';
import http from 'http';
import fs from 'fs';
import path from 'path';

const ROOT = path.resolve(process.argv[2]);
const MIME = { '.html':'text/html', '.js':'text/javascript', '.css':'text/css', '.json':'application/json',
               '.png':'image/png', '.jpg':'image/jpeg', '.svg':'image/svg+xml', '.ico':'image/x-icon' };
const srv = http.createServer((req, res) => {
  let u = decodeURIComponent(req.url.split('?')[0]);
  if (u === '/') u = '/index.html';
  const f = path.join(ROOT, u);
  if (!path.resolve(f).startsWith(ROOT) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); return res.end('no'); }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(f)] || 'application/octet-stream' });
  res.end(fs.readFileSync(f));
});
await new Promise(r => srv.listen(8792, r));

const b = await chromium.launch();
const p = await b.newPage();
const errs = [];
p.on('pageerror', e => errs.push('PAGEERROR: ' + e.message));
p.on('response', r => { if (r.status() >= 400) errs.push('HTTP ' + r.status() + ' ' + r.url()); });
p.on('console', m => { if (m.type() === 'error') errs.push('CONSOLE: ' + m.text().slice(0, 220)); });
await p.goto('http://127.0.0.1:8792/', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(4000);
const r = await p.evaluate(() => {
  const g = n => { try { return typeof eval(n); } catch (e) { return 'ERR:' + e.message.slice(0, 60); } };
  return { MOS: g('MOS'), API: g('API') };
});
console.log('typeof MOS →', r.MOS, '| API →', r.API);
console.log('errores:', errs.length);
errs.slice(0, 8).forEach((e, i) => console.log('  ' + (i+1) + ') ' + e));
await b.close(); srv.close();
// Sale con codigo 1 si la app no arranca o si hubo un error de pagina: asi una cadena
// `node _819_full.mjs .. && git push` se CORTA sola en vez de publicar algo roto.
const grave = errs.filter(e => e.startsWith('PAGEERROR'));
if (r.MOS !== 'object' || grave.length) {
  console.log('❌ NO PUBLICAR: ' + (r.MOS !== 'object' ? 'MOS no queda definido' : grave.length + ' error(es) de pagina'));
  process.exit(1);
}
console.log('✅ la app arranca y no hay errores de pagina');
