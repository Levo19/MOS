// [848] Cargar un crédito a un TURNO desde MOS (el rescate). La asignación real se intercepta:
// se verifica qué viaja y qué se pinta, sin tocar la deuda de nadie.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = path.resolve(process.argv[2]);
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8798,r));
const ok=[],bad=[]; const T=(n,c,x)=>{(c?ok:bad).push(n);console.log((c?'  ✅ ':'  ❌ ')+n+(x?' — '+x:''));};
const b=await chromium.launch(); const p=await (await b.newContext({viewport:{width:1280,height:900}})).newPage();
const errs=[]; p.on('pageerror',e=>errs.push(String(e.message)));
await p.addInitScript(d=>localStorage.setItem('mos_device_id',d),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8798/',{waitUntil:'domcontentloaded'}); await p.waitForTimeout(6000);
try{await p.click('text=/Entrar a MOS/i',{timeout:4000});}catch{}
await p.waitForFunction(()=>{try{return !!MOS;}catch{return false;}},{timeout:60000});

// blindaje: la asignación NO se escribe
await p.evaluate(()=>{
  window.__asig=[]; const o=API.post.bind(API);
  API.post=function(a,pl){
    if(a==='creditoAsignar'||a==='creditoDesasignar'){
      window.__asig.push({a,pl:JSON.parse(JSON.stringify(pl||{}))});
      return Promise.resolve({ok:true,data:{nombre:'(simulado)',idDia:pl.idDia}});
    }
    return o(a,pl);
  };
});

await p.evaluate(()=>MOS.nav('cajas'));
await p.waitForTimeout(16000);
// asegurar que la baraja de créditos esté cargada
await p.evaluate(()=>{ try { MOS._cjCargarCreditosPendientes && MOS._cjCargarCreditosPendientes(); } catch(_){} });
await p.waitForTimeout(6000);
const gr = await p.evaluate(()=>({
  grupos: (MOS.__t||{}).x, n: document.querySelectorAll('.cj-carta-mano').length }));
// buscar un ticket de crédito vivo por la mesa
await p.evaluate(()=>{ try{ MOS.cjRepartirMano(); }catch(_){} });
await p.waitForTimeout(2500);
let tk = await p.evaluate(()=>{
  const el=[...document.querySelectorAll('[onclick*="cjAbrirDetalleCarta"]')][0];
  if(!el) return null;
  const m=String(el.getAttribute('onclick')).match(/cjAbrirDetalleCarta\('([^']+)'\)/);
  return m?m[1]:null;
});
// si el DOM no lo expone (baraja animada), tomarlo del estado interno vía un ticket vivo real
if(!tk){ tk = await p.evaluate(async ()=>{
  const r = await API.post('meGetCreditosPendientes',{diasAtras:365});
  const d = (r&&r.data)?r.data:(r||{});
  for(const g of (d.grupos||[])) for(const t of (g.tickets||[]))
    if(!t.estadoCobro || t.estadoCobro==='VIVO') return t.idVenta;
  return null;
}); }
if(!tk){ console.log('  ⚠ no hay tickets de crédito vivos para probar'); await b.close(); srv.close(); process.exit(0); }
console.log('  ticket de prueba: '+tk);
await p.evaluate(id=>MOS.cjAbrirDetalleCarta(id), tk);
await p.waitForTimeout(900);
const hayBtn = await p.evaluate(()=>!!document.querySelector('.cj-det-tk-btn') || !!document.querySelector('.cj-det-tk-quitar'));
T('el detalle ofrece cargar el crédito a un trabajador', hayBtn);

await p.evaluate(id=>MOS.cjTrabajadorAbrir(id), tk);
await p.waitForFunction(()=>{const b=document.querySelector('#cjTkOvl .cjtk-body');return b && !/buscando/.test(b.textContent);},{timeout:30000});
const filas = await p.evaluate(()=>[...document.querySelectorAll('.cjtk-row')].map(e=>e.textContent.replace(/\s+/g,' ').trim()));
console.log('     turnos ofrecidos: '+(filas.length?filas.join(' | '):'(ninguno)'));
T('el selector lista turnos de ESE día', filas.length>0 || /ningún turno abierto/.test(await p.evaluate(()=>document.querySelector('#cjTkOvl .cjtk-body').textContent)));
T('cada fila muestra el turno, no solo el nombre', filas.every(f=>/CAJERO|VENDEDOR|ALMACENERO/.test(f)) || !filas.length,
  filas[0]||'—');
T('sin desborde horizontal con el overlay abierto',
  await p.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth<=1));

if (filas.length) {
  await p.evaluate(()=>document.querySelector('.cjtk-row').click());
  await p.waitForTimeout(1500);
  const env = await p.evaluate(()=>window.__asig);
  console.log('     enviado: '+JSON.stringify(env));
  T('al elegir se manda idVenta + idDia (el TURNO, no un nombre)',
    env.length>0 && env[0].pl.idVenta===tk && /^LDIA-/.test(String(env[0].pl.idDia||'')));
  T('el overlay se cierra tras elegir', await p.evaluate(()=>!document.getElementById('cjTkOvl')));
}
console.log('\n  errores de página: '+(errs.length?errs.slice(0,3).join(' | '):'ninguno'));
T('sin errores de página', errs.length===0);
console.log('\n  '+ok.length+' ✅   '+bad.length+' ❌');
await b.close(); srv.close();
process.exit(bad.length?1:0);
