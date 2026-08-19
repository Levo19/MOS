import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT=path.resolve('C:/Users/ISO/ecosistema MOS/ProyectoMOS');
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8806,r));
const b=await chromium.launch(); const p=await (await b.newContext({viewport:{width:1280,height:950}})).newPage();
await p.addInitScript(d=>localStorage.setItem('mos_device_id',d),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8806/',{waitUntil:'domcontentloaded'}); await p.waitForTimeout(5000);
try{await p.click('text=/Entrar a MOS/i',{timeout:4000});}catch{}
await p.waitForFunction(()=>{try{return !!MOS;}catch{return false;}},{timeout:60000});
await p.evaluate(()=>MOS.nav('cajas')); await p.waitForTimeout(15000);
const r = await p.evaluate(()=>[...document.querySelectorAll('.cj-caja-actions')].slice(0,3).map(a=>{const cs=getComputedStyle(a);return {w:a.getBoundingClientRect().width, cols:cs.gridTemplateColumns, n:a.children.length, labels:[...a.children].map(b=>b.textContent.trim()), bw:[...a.children].map(b=>Math.round(b.getBoundingClientRect().width)), visible:!!a.offsetParent };}));
console.log(JSON.stringify(r,null,1));
const card=await p.$('.cj-caja-card'); if(card) await card.screenshot({path:'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_btn_probe.png'});
await b.close(); srv.close();
