import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = 'C:/Users/ISO/ecosistema MOS/warehouseMos';
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(path.resolve(ROOT))||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8822,r));
const b = await chromium.launch(); const ctx = await b.newContext({ viewport:{width:420,height:900}, hasTouch:true });
const p = await ctx.newPage(); const errs=[]; p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0,200)));
const logs=[]; p.on('console', m => { if (/error|warn/i.test(m.type())) logs.push(m.text().slice(0,160)); });
await p.addInitScript(() => { try { localStorage.setItem('wh_device_id','7e57c1a0-de1c-4a7e-b0de-c47a10906475'); } catch(_){} });
await p.goto('http://127.0.0.1:8822/', { waitUntil:'domcontentloaded' });
await p.waitForTimeout(20000);
const st = await p.evaluate(() => ({ pv: typeof ProductosView, nav: typeof App !== 'undefined' && typeof App.nav, buscar: typeof ProductosView !== 'undefined' && typeof ProductosView.buscar,
  prods: (typeof OfflineManager !== 'undefined' && OfflineManager.getProductosCache) ? OfflineManager.getProductosCache().length : -1,
  title: document.title, vista: document.querySelector('.view.active, [data-view].active')?.id || '', body: document.body.innerText.slice(0,300).replace(/\s+/g,' ') }));
console.log(JSON.stringify(st, null, 1)); console.log('errs', errs); console.log('logs', logs.slice(0,8));
await p.screenshot({ path: 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_wh_probe.png' });
await b.close(); srv.close();
