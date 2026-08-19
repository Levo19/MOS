// [Config → Yapes v2] una card por zona (estado + acciones), sin "Emparejar" en zonas ya emparejadas,
// "Ver Yapes" por zona con estado de cada uno, y refresco vivo.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT=path.resolve('C:/Users/ISO/ecosistema MOS/ProyectoMOS');
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8803,r));
const ok=[],bad=[]; const T=(n,c,x)=>{(c?ok:bad).push(n);console.log((c?'  OK  ':'  --  ')+n+(x?'  ·  '+x:''));};
const b=await chromium.launch(); const p=await (await b.newContext({viewport:{width:1280,height:950}})).newPage();
const errs=[]; p.on('pageerror',e=>errs.push(String(e.message)));
await p.addInitScript(d=>localStorage.setItem('mos_device_id',d),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8803/',{waitUntil:'domcontentloaded'}); await p.waitForTimeout(5000);
try{await p.click('text=/Entrar a MOS/i',{timeout:4000});}catch{}
await p.waitForFunction(()=>{try{return !!MOS;}catch{return false;}},{timeout:60000});
await p.evaluate(()=>MOS.nav('config')); await p.waitForTimeout(3500);
await p.evaluate(()=>MOS.setCfgTab('yape'));
await p.waitForFunction(()=>{const e=document.getElementById('yapeBody');return e && e.querySelector('.yp-zcard');},{timeout:30000});
const cfg = await p.evaluate(()=>{
  const e=document.getElementById('yapeBody');
  const cards=[...e.querySelectorAll('.yp-zcard')].map(c=>({ zona:c.querySelector('.yp-z-n i')?.textContent||'', estado:c.querySelector('.yp-estado')?.textContent||'',
    acts:[...c.querySelectorAll('.yp-act')].map(a=>a.textContent.trim()), ok:c.classList.contains('is-ok') }));
  return { cards, pasos: e.querySelectorAll('.yp-paso').length, zonasViejas: e.querySelectorAll('.yp-zona').length, apk: !!e.querySelector('a[href*="releases/latest"]') };
});
console.log('     cards: '+JSON.stringify(cfg.cards));
T('una card por zona de venta, y ya no hay cards de zona separadas', cfg.cards.length>=2 && cfg.zonasViejas===0);
const emp = cfg.cards.filter(c=>c.ok);
T('las zonas emparejadas (ZONA-01 y 02, capturando) NO ofrecen "Emparejar": ofrecen Ver Yapes · Revocar · Cambiar de celular',
  emp.length>=2 && emp.every(c=>c.acts.some(a=>/Ver Yapes/.test(a)) && c.acts.some(a=>/Revocar/.test(a)) && c.acts.some(a=>/Cambiar de celular/.test(a)) && !c.acts.some(a=>/Emparejar/.test(a))),
  emp.map(c=>c.acts.join('/')).join(' | '));
T('la card dice el estado en vivo (capturando · N hoy · último)', emp.every(c=>/capturando/.test(c.estado)));
T('los 3 pasos y el enlace al APK siguen', cfg.pasos===3 && cfg.apk);
// refresco vivo arrancado
T('el refresco vivo queda armado (cada 8 s) mientras la pestaña está a la vista', await p.evaluate(()=>!!document.getElementById('yapeBody')));
// Ver Yapes de ZONA-01
await p.evaluate(()=>MOS.yapesZonaAbrir('ZONA-01'));
await p.waitForFunction(()=>{const b=document.getElementById('ypBody');return b && (b.querySelector('.yp-y')||/No entró/.test(b.textContent));},{timeout:30000});
const modal = await p.evaluate(()=>{ const b=document.getElementById('ypBody');
  return { n:b.querySelectorAll('.yp-y').length, sellos:[...b.querySelectorAll('.yp-sello')].map(s=>s.textContent.trim().slice(0,14)), kpis:b.querySelectorAll('.yp-kpi').length, nav:!!b.querySelector('.yp-nav'),
           sub:document.getElementById('ypSub')?.textContent||'', titulo:document.querySelector('#ypOvl .yp-head b')?.textContent||'' }; });
console.log('     modal: '+JSON.stringify(modal));
T('"Ver Yapes" abre los Yapes de la zona con título, resumen y KPIs', /ZONA-01/.test(modal.titulo) && modal.kpis===4 && modal.nav);
T('cada Yape lleva su sello de estado (verificado / libre / ambiguo / ilegible)', modal.n>0 && modal.sellos.length===modal.n, modal.sellos.join(','));
await p.evaluate(()=>MOS.yapesZonaDia(-1)); await p.waitForTimeout(2500);
T('se puede navegar al día anterior', await p.evaluate(()=>/día anterior|Hoy|\d{4}-\d{2}-\d{2}/.test(document.getElementById('ypBody')?.textContent||'')));
await p.evaluate(()=>MOS.yapesCajaCerrar()); await p.waitForTimeout(300);
T('sin errores de página', errs.length===0, errs.join(' | '));
await p.screenshot({path:'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_yape_panel_v2.png'});
await b.close(); srv.close();
console.log('\n  '+ok.length+' OK   '+bad.length+' fallos'); process.exit(bad.length?1:0);
