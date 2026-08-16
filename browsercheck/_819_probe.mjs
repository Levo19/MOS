// Carga SOLO el app.js del 819 en un navegador real y reporta el primer error de ejecución.
import { chromium } from 'playwright';
import http from 'http';
import fs from 'fs';

const js = fs.readFileSync('_app819.js', 'utf8');
const srv = http.createServer((req, res) => {
  if (req.url.startsWith('/app.js')) { res.writeHead(200, {'Content-Type':'text/javascript'}); res.end(js); }
  else { res.writeHead(200, {'Content-Type':'text/html'}); res.end('<!doctype html><meta charset="utf-8"><body><script src="/app.js"></script>'); }
});
await new Promise(r => srv.listen(8791, r));

const b = await chromium.launch();
const p = await b.newPage();
await p.addInitScript(dev => localStorage.setItem('mos_device_id', dev), '7e57c1a0-de1c-4a7e-b0de-c47a10906477');  // identidad fija: no genera solicitudes de acceso
const errores = [];
p.on('pageerror', e => errores.push(e.message + '\n     ' + String(e.stack||'').split('\n').slice(1,4).join('\n     ')));
p.on('console', m => { if (m.type() === 'error') errores.push('[console] ' + m.text()); });
await p.goto('http://127.0.0.1:8791/', { waitUntil: 'load' });
await p.waitForTimeout(1500);
const tipo = await p.evaluate(() => { try { return typeof MOS; } catch (e) { return 'ERR:' + e.message; } });
console.log('typeof MOS →', tipo);
console.log('errores capturados:', errores.length);
errores.slice(0, 5).forEach((e, i) => console.log('  ' + (i+1) + ') ' + e));
await b.close(); srv.close();
