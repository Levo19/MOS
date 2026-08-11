// [735] El escenario real del dueño: red mala + CPU lenta. Mide clic→feedback y
// clic→modal en el botón Auditar. RAIZ=<dir> para comparar contra un checkout de HEAD.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = process.env.RAIZ || 'C:/Users/ISO/ecosistema MOS/ProyectoMOS';
const TAG  = process.env.TAG || 'x';
const LAT  = parseInt(process.env.LAT || '500', 10);   // ms de latencia por request
const CPU  = parseInt(process.env.CPU || '4', 10);
const w = ms => new Promise(r => setTimeout(r, ms));
const MIME = { '.html':'text/html','.js':'text/javascript','.json':'application/json','.css':'text/css','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json' };
const srv = http.createServer((req,res)=>{let rel=decodeURIComponent(req.url.split('?')[0]);if(rel==='/'||rel==='')rel='/index.html';const f=path.join(ROOT,rel);fs.readFile(f,(e,buf)=>{if(e){res.writeHead(404).end('404');return;}res.writeHead(200,{'content-type':MIME[path.extname(f).toLowerCase()]||'application/octet-stream','cache-control':'no-store'});res.end(buf);});});
await new Promise(r=>srv.listen(0,'127.0.0.1',r));
const base='http://127.0.0.1:'+srv.address().port+'/';
const SEED={mos_device_id:'7e57c1a0-de1c-4a7e-b0de-c47a10906477',MOS_SESSION:JSON.stringify({idPersonal:'TEST-CLAUDE',nombre:'PRUEBA CLAUDE',rol:'MASTER',idSesion:'testclaude735'})};
const b=await chromium.launch();
const ctx=await b.newContext({viewport:{width:1280,height:1400}});
const p=await ctx.newPage();
const errs=[]; p.on('pageerror',e=>errs.push(String(e).split('\n')[0].slice(0,160)));
await p.addInitScript(s=>{for(const[k,v]of Object.entries(s))localStorage.setItem(k,v);},SEED);
const cdp = await ctx.newCDPSession(p);
await cdp.send('Emulation.setCPUThrottlingRate',{rate:CPU});
await p.goto(base+'?nc='+Date.now(),{waitUntil:'domcontentloaded',timeout:180000});
await w(24000);
await p.evaluate(()=>{const el=[...document.querySelectorAll('button,a')].find(x=>/Entrar a MOS/i.test(x.textContent||''));if(el)el.click();});
await w(4000);
await p.evaluate(()=>{try{MOS.nav('finanzas');}catch(_){}} );
for(let i=0;i<50;i++){await w(1500);const n=await p.evaluate(()=>document.querySelectorAll('#finPersonalList button[onclick*="abrirAuditar"]').length);if(n>0)break;}
await w(10000);
// A PARTIR DE ACÁ la red se pone mala: +LAT ms a cada RPC de Supabase.
await p.route('**/rest/v1/rpc/**', async route => { await new Promise(r=>setTimeout(r,LAT)); return route.continue(); });
await w(1500);
const med = async (etq) => {
  const r = await p.evaluate(async () => {
    const btn = document.querySelector('#finPersonalList button[onclick*="abrirAuditar"]');
    if (!btn) return { error: 'sin botón' };
    const modal = document.getElementById('modalAuditar');
    const t0 = performance.now();
    let tFb = null;
    const o = new MutationObserver(()=>{ if(tFb==null) tFb = performance.now()-t0; });
    o.observe(btn,{attributes:true,childList:true,subtree:true,characterData:true});
    btn.click();
    let tM = null;
    for(let i=0;i<300;i++){ await new Promise(r=>setTimeout(r,50));
      if(modal && !modal.classList.contains('hidden')){ tM = performance.now()-t0; break; } }
    o.disconnect();
    // ¿el modal quedó con datos reales o vacío?
    const kpis = (document.getElementById('auditKpis')||{}).textContent||'';
    return { fb: tFb==null?null:Math.round(tFb), modal: tM==null?null:Math.round(tM),
             titulo: (document.getElementById('auditTitle')||{}).textContent||'', kpiLen: kpis.length };
  });
  console.log(` ${etq}: feedback=${r.fb}ms · modal=${r.modal}ms · "${(r.titulo||'').slice(0,50)}" · kpis=${r.kpiLen} chars`);
  await p.evaluate(()=>{try{MOS.cerrarAuditar();}catch(_){}} );
  await w(2500);
  return r;
};
console.log(`\n═══ ${TAG} · red +${LAT}ms por RPC · CPU ${CPU}x ═══`);
await med('clic 1');
await med('clic 2');
await med('clic 3');
console.log(' pageerrors: ' + (errs.length?errs.join(' | '):'0'));
await b.close(); srv.close(); process.exit(0);
