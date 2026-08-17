import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = path.resolve(process.argv[2]);
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8795,r));
const b=await chromium.launch(); const ctx=await b.newContext({viewport:{width:1280,height:900}}); const p=await ctx.newPage();
p.on('pageerror',e=>console.log('  PAGEERROR:',e.message));
await p.addInitScript(d=>localStorage.setItem('mos_device_id',d),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8795/',{waitUntil:'domcontentloaded'}); await p.waitForTimeout(6000);
try{await p.click('text=/Entrar a MOS/i',{timeout:4000});}catch{}
await p.waitForFunction(()=>{try{return !!MOS;}catch{return false;}},{timeout:60000});
await p.evaluate(()=>MOS.abrirMesaCompras());
await p.waitForFunction(()=>document.querySelectorAll('#mesaComprasModal [onclick*="_mesaComprasEntrar"]').length>0,{timeout:60000});
const lista = await p.evaluate(()=>[...document.querySelectorAll('#mesaComprasModal [onclick*="_mesaComprasEntrar"]')].slice(0,12).map(el=>{
  const m=String(el.getAttribute('onclick')).match(/_mesaComprasEntrar\('([^']+)','([^']+)'\)/);
  return m?{f:m[1],g:m[2],txt:el.textContent.replace(/\s+/g,' ').trim().slice(0,60)}:null;}).filter(Boolean));
console.log('  compras disponibles:'); lista.forEach(x=>console.log('   ',x.f,x.g,'·',x.txt));
await p.waitForTimeout(20000);
const lista2 = await p.evaluate(()=>[...document.querySelectorAll('#mesaComprasModal [onclick*="_mesaComprasEntrar"]')].slice(0,14).map(el=>{
  const m=String(el.getAttribute('onclick')).match(/_mesaComprasEntrar\('([^']+)','([^']+)'\)/);
  const n=(el.textContent.match(/(\d+)\s*ítems/)||[0,0])[1];
  return m?{f:m[1],g:m[2],n:+n}:null;}).filter(Boolean));
console.log('  tras prefetch:', JSON.stringify(lista2));
const wh = lista2.find(x=>x.n>0) || lista[0];
console.log('  entrando a', wh.f, wh.g);
await p.evaluate(g=>MOS._mesaComprasEntrar(g.f,g.g), wh);
await p.waitForTimeout(9000);
console.log('  modal costos:', await p.evaluate(()=>{const m=document.getElementById('modalCostosGuiaUnif');return m?('existe, hidden='+m.classList.contains('hidden')):'NO EXISTE';}));
console.log('  #costoGuiaLinea_0:', await p.evaluate(()=>!!document.getElementById('costoGuiaLinea_0')));
console.log('  nº líneas:', await p.evaluate(()=>document.querySelectorAll('.alm-v-costo-line').length));
console.log('  modales abiertos:', await p.evaluate(()=>[...document.querySelectorAll('[id]')].filter(e=>/modal|Modal|overlay|Overlay/.test(e.id)&&e.offsetParent!==null).map(e=>e.id).join(', ')));
await b.close(); srv.close();
