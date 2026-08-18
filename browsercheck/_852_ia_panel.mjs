// [852] Pestaña de gestión de IA: que muestre lo que hay y no invente números.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT=path.resolve(process.argv[2]);
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8801,r));
const ok=[],bad=[]; const T=(n,c,x)=>{(c?ok:bad).push(n);console.log((c?'  ✅ ':'  ❌ ')+n+(x?' — '+x:''));};
const b=await chromium.launch(); const p=await (await b.newContext({viewport:{width:1280,height:950}})).newPage();
const errs=[]; p.on('pageerror',e=>errs.push(String(e.message)));
await p.addInitScript(d=>localStorage.setItem('mos_device_id',d),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8801/',{waitUntil:'domcontentloaded'}); await p.waitForTimeout(5000);
try{await p.click('text=/Entrar a MOS/i',{timeout:4000});}catch{}
await p.waitForFunction(()=>{try{return !!MOS;}catch{return false;}},{timeout:60000});
await p.evaluate(()=>MOS.nav('config')); await p.waitForTimeout(3500);
T('la pestaña 🧠 IA existe en Config', await p.evaluate(()=>!!document.getElementById('cfgTabIa')));
await p.evaluate(()=>MOS.setCfgTab('ia'));
await p.waitForFunction(()=>{const e=document.getElementById('iaBody');return e && !/leyendo el consumo/.test(e.textContent);},{timeout:45000});
await p.waitForTimeout(900);
const v = await p.evaluate(()=>{
  const e=document.getElementById('iaBody');
  return { hero: !!e.querySelector('.ia-hero-usd'), heroTxt: (e.querySelector('.ia-hero-usd')||{}).textContent||'',
           kpis: e.querySelectorAll('.ia-kpi').length, rangos: e.querySelectorAll('.ia-rb').length,
           tarifas: e.querySelectorAll('.ia-tabla tbody tr').length,
           pie: /Dónde se usa IA hoy/.test(e.textContent),
           registro: /registro empieza|ninguna llamada registrada/.test(e.textContent),
           barras: e.querySelectorAll('.ia-bar').length, fns: e.querySelectorAll('.ia-fn').length };
});
console.log('     ' + JSON.stringify(v));
T('muestra el gasto del mes en grande', v.hero && /^\$\d/.test(v.heroTxt), v.heroTxt);
T('trae los KPIs (hoy · promedio · llamadas · tokens)', v.kpis >= 4, v.kpis+' kpis');
T('deja elegir el rango de días', v.rangos === 3);
T('publica el tarifario real de Anthropic', v.tarifas >= 7, v.tarifas+' modelos');
T('dice dónde se usa IA en el ecosistema', v.pie);
T('es honesto sobre desde cuándo hay registro', v.registro);
// [852b] si la IA está fallando, tiene que decirlo con el motivo traducido
const al = await p.evaluate(()=>{const e=document.querySelector('.ia-alerta');
  return e?{txt:e.textContent.replace(/\s+/g,' ').trim().slice(0,120), grave:e.classList.contains('is-grave')}:null;});
console.log('     alerta: '+JSON.stringify(al));
T('avisa el motivo cuando la IA falla', !!al, al?al.txt:'(sin fallas registradas)');
T('sin desborde horizontal', await p.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth<=1));
// el rango cambia sin romper
await p.evaluate(()=>MOS.iaSetRango(7)); await p.waitForTimeout(3500);
T('cambiar el rango vuelve a leer sin romper',
  await p.evaluate(()=>{const e=document.getElementById('iaBody');return !!e.querySelector('.ia-hero-usd') && !!e.querySelector('.ia-rb.is-on');}));
// responsive móvil
await p.setViewportSize({width:390,height:844}); await p.waitForTimeout(700);
T('responsive en móvil sin desborde',
  await p.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth<=1),
  await p.evaluate(()=>(document.documentElement.scrollWidth-document.documentElement.clientWidth)+'px'));
console.log('\n  errores de página: '+(errs.length?errs.slice(0,3).join(' | '):'ninguno'));
T('sin errores de página', errs.length===0);
console.log('\n  '+ok.length+' ✅   '+bad.length+' ❌');
await b.close(); srv.close(); process.exit(bad.length?1:0);
