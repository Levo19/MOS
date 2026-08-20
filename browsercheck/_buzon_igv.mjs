import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT=path.resolve('C:/Users/ISO/ecosistema MOS/ProyectoMOS');
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8809,r));
const ok=[],bad=[]; const T=(n,c,x)=>{(c?ok:bad).push(n);console.log((c?'  OK  ':'  --  ')+n+(x?'  ·  '+x:''));};
const b=await chromium.launch(); const p=await (await b.newContext({viewport:{width:1280,height:950}})).newPage();
const errs=[]; p.on('pageerror',e=>errs.push(String(e.message)));
await p.addInitScript(d=>localStorage.setItem('mos_device_id',d),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8809/',{waitUntil:'domcontentloaded'}); await p.waitForTimeout(5000);
try{await p.click('text=/Entrar a MOS/i',{timeout:4000});}catch{}
await p.waitForFunction(()=>{try{return !!MOS;}catch{return false;}},{timeout:60000});
// la API del buzón responde (listar del mes)
const list = await p.evaluate(async ()=>{ try { return await API.post('buzonListar',{mes:8,anio:2026}); } catch(e){ return {err:String(e)}; } });
T('buzonListar responde ok', list && list.ok===true, JSON.stringify(list && list.data ? {items:(list.data.items||[]).length, igv:list.data.igvBuzonValido} : list));
// abrir el detalle IGV a favor y ver el buzón
await p.evaluate(()=>{ try { MOS.tribAbrirIGVFavor && MOS.tribAbrirIGVFavor('TODOS'); } catch(e){} }); await p.waitForTimeout(1500);
const box = await p.evaluate(()=>({ box:!!document.getElementById('tribBuzonBox'), file:!!document.getElementById('tribBuzonFile'), lista:!!document.getElementById('tribBuzonLista') }));
console.log('     '+JSON.stringify(box));
T('el detalle IGV a favor muestra el BUZÓN (botón subir + lista)', box.box && box.file && box.lista);
T('sin errores de página', errs.length===0, errs.join(' | '));
await b.close(); srv.close();
console.log('\n  '+ok.length+' OK   '+bad.length+' fallos'); process.exit(bad.length?1:0);
