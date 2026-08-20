// [881] MosGuard: el bloque de resguardo en Config→Yapes (ubicación + marcar robado)
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT=path.resolve('C:/Users/ISO/ecosistema MOS/ProyectoMOS');
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8808,r));
const ok=[],bad=[]; const T=(n,c,x)=>{(c?ok:bad).push(n);console.log((c?'  OK  ':'  --  ')+n+(x?'  ·  '+x:''));};
const b=await chromium.launch(); const p=await (await b.newContext({viewport:{width:1280,height:950}})).newPage();
const errs=[]; p.on('pageerror',e=>errs.push(String(e.message)));
await p.addInitScript(d=>localStorage.setItem('mos_device_id',d),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8808/',{waitUntil:'domcontentloaded'}); await p.waitForTimeout(5000);
try{await p.click('text=/Entrar a MOS/i',{timeout:4000});}catch{}
await p.waitForFunction(()=>{try{return !!MOS;}catch{return false;}},{timeout:60000});
await p.evaluate(()=>MOS.nav('config')); await p.waitForTimeout(3000);
await p.evaluate(()=>MOS.setCfgTab('yape'));
await p.waitForFunction(()=>{const e=document.getElementById('mgResguardo');return e && e.querySelector('.mg-eq');},{timeout:30000});
const r = await p.evaluate(()=>{ const e=document.getElementById('mgResguardo');
  return { sec:!!e.querySelector('.mg-sec'), n:e.querySelectorAll('.mg-eq').length,
    equipos:[...e.querySelectorAll('.mg-eq')].map(c=>({nombre:c.querySelector('.mg-eq-top b')?.textContent, robado:c.classList.contains('is-robado'), tieneMarcar:!!c.querySelector('.mg-btn')})) }; });
console.log('     '+JSON.stringify(r));
T('el bloque MosGuard lista los equipos con su botón de resguardo', r.sec && r.n>=2 && r.equipos.every(x=>x.tieneMarcar));
// marcar robado un equipo → aparece badge ROBADO → marcar recuperado
await p.evaluate(()=>{ window.__conf = window._modalConfirm; });   // por si el confirm bloquea; forzamos ok
await p.evaluate(()=>{ MOS._testForceConfirm = true; });
// llamamos el RPC directo (evita el modal) para no depender del confirm en headless
const marc = await p.evaluate(async ()=>{ const r=await API.post('guardMarcar',{nombre:'Celular Yape ZONA-02',estado:'ROBADO'}); return r; });
T('marcar ROBADO devuelve success', marc && marc.status==='success', JSON.stringify(marc));
await p.evaluate(()=>MOS.mgMarcar && null); await p.evaluate(async ()=>{ const cont=document.getElementById('mgResguardo'); const r=await API.post('guardEstado',{}); }); 
await p.waitForTimeout(500);
const est = await p.evaluate(async ()=>{ const r=await API.post('guardEstado',{}); const e=((r&&(r.data||r))||{}).equipos||[]; return e.find(x=>x.nombre==='Celular Yape ZONA-02'); });
T('el equipo quedó ROBADO en el servidor', est && est.guardEstado==='ROBADO', est&&est.guardEstado);
const rec = await p.evaluate(async ()=>API.post('guardMarcar',{nombre:'Celular Yape ZONA-02',estado:'NORMAL'}));
T('marcar recuperado (NORMAL) vuelve todo a su lugar', rec && rec.status==='success');
// [882] fase 2: botones foto / en vivo
const foto = await p.evaluate(async ()=>API.post('guardFoto',{nombre:'Celular Yape ZONA-01'}));
T('pedir foto responde success', foto && foto.status==='success', JSON.stringify(foto));
const live = await p.evaluate(async ()=>API.post('guardLive',{nombre:'Celular Yape ZONA-01',seg:120}));
T('activar en vivo responde success', live && live.status==='success', JSON.stringify(live));
const est2 = await p.evaluate(async ()=>{ const r=await API.post('guardEstado',{}); const e=((r&&(r.data||r))||{}).equipos||[]; return e.find(x=>x.nombre==='Celular Yape ZONA-01'); });
T('el equipo quedó con foto pedida y ventana en vivo', est2 && est2.fotoPedida===true && est2.liveSeg>0, JSON.stringify({f:est2&&est2.fotoPedida,l:est2&&est2.liveSeg}));
const off = await p.evaluate(async ()=>API.post('guardLive',{nombre:'Celular Yape ZONA-01',seg:0}));
T('cerrar en vivo (seg=0)', off && off.status==='success');
await p.evaluate(async ()=>API.post('guardFoto',{nombre:'Celular Yape ZONA-01'}).then(()=>null));
// dejar limpio: apagar foto pedida no hay RPC directo, pero el equipo la limpia al subir; para el test la reseteo por estado
T('el panel dibuja los botones 📸/🎥 por equipo', await p.evaluate(()=>{const b=[...document.querySelectorAll('#mgResguardo .mg-btn')].map(x=>x.textContent);return b.some(t=>/Pedir foto/.test(t)) && b.some(t=>/en vivo|Ver en vivo/i.test(t));}));
T('sin errores de página', errs.length===0, errs.join(' | '));
await p.screenshot({path:'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_mosguard_panel.png'});
await b.close(); srv.close();
console.log('\n  '+ok.length+' OK   '+bad.length+' fallos'); process.exit(bad.length?1:0);
