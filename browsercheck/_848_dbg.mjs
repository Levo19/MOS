import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT=path.resolve(process.argv[2]);
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8799,r));
const b=await chromium.launch(); const p=await (await b.newContext({viewport:{width:1280,height:900}})).newPage();
p.on('pageerror',e=>console.log('  PAGEERROR:',e.message));
await p.addInitScript(d=>localStorage.setItem('mos_device_id',d),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8799/',{waitUntil:'domcontentloaded'}); await p.waitForTimeout(6000);
try{await p.click('text=/Entrar a MOS/i',{timeout:4000});}catch{}
await p.waitForFunction(()=>{try{return !!MOS;}catch{return false;}},{timeout:60000});
await p.evaluate(()=>MOS.nav('cajas')); await p.waitForTimeout(18000);
console.log('  cartas en la mano:', await p.evaluate(()=>document.querySelectorAll('.cj-carta-mano').length));
const raw = await p.evaluate(async()=>{
  const r=await API.post('meGetCreditosPendientes',{diasAtras:365});
  const d=(r&&r.data)?r.data:(r||{});
  const g=(d.grupos||[])[0]||{};
  const t=(g.tickets||[])[0]||{};
  return { grupos:(d.grupos||[]).length, fecha:g.fecha, idVenta:t.idVenta, estadoCobro:t.estadoCobro,
           trabajador:t.trabajador, keys:Object.keys(t).join(',') };
});
console.log('  API:', JSON.stringify(raw));
await p.evaluate(id=>MOS.cjAbrirDetalleCarta(id), raw.idVenta);
await p.waitForTimeout(1200);
console.log('  detalle visible:', await p.evaluate(()=>{const m=document.getElementById('modalDetalleCarta');return m?!m.classList.contains('hidden'):'no existe';}));
console.log('  contenido:', await p.evaluate(()=>{const c=document.getElementById('cjDetalleContenido');return c?c.textContent.replace(/\s+/g,' ').trim().slice(0,220):'(vacio)';}));
console.log('  boton tk:', await p.evaluate(()=>!!document.querySelector('.cj-det-tk-btn')));
await b.close(); srv.close();
