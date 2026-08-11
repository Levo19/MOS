// [735] ¿Cuánto cuesta el JIT de Tailwind Play CDN en el panel MOS?
// Cuenta recompilaciones (reescrituras del <style> que inyecta el CDN) y el tiempo
// de main thread que consumen, durante boot + nav a finanzas + render de Personal.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS';
const CPU = parseInt(process.env.CPU || '4', 10);
const w = ms => new Promise(r => setTimeout(r, ms));
const MIME = { '.html':'text/html','.js':'text/javascript','.json':'application/json','.css':'text/css','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json' };
const srv = http.createServer((req,res)=>{let rel=decodeURIComponent(req.url.split('?')[0]);if(rel==='/'||rel==='')rel='/index.html';const f=path.join(ROOT,rel);fs.readFile(f,(e,buf)=>{if(e){res.writeHead(404).end('404');return;}res.writeHead(200,{'content-type':MIME[path.extname(f).toLowerCase()]||'application/octet-stream','cache-control':'no-store'});res.end(buf);});});
await new Promise(r=>srv.listen(0,'127.0.0.1',r));
const base='http://127.0.0.1:'+srv.address().port+'/';
const SEED={mos_device_id:'7e57c1a0-de1c-4a7e-b0de-c47a10906477',MOS_SESSION:JSON.stringify({idPersonal:'TEST-CLAUDE',nombre:'PRUEBA CLAUDE',rol:'MASTER',idSesion:'testclaude735'})};
const b=await chromium.launch();
const ctx=await b.newContext({viewport:{width:1280,height:1400}});
const p=await ctx.newPage();
p.on('pageerror',e=>console.log('ERR',String(e).slice(0,150)));
await p.addInitScript(s=>{for(const[k,v]of Object.entries(s))localStorage.setItem(k,v);},SEED);
await p.addInitScript(()=>{
  window.__TW={n:0,ms:0,bytes:0,long:[]};
  // Tailwind Play CDN reescribe el CSS vía CSSStyleSheet/textContent de un <style>.
  // Contamos por dos vías: MutationObserver sobre <head> y parcheo de MutationObserver
  // para saber cuántos observadores globales hay.
  const OMO = window.MutationObserver;
  window.__OBS=[];
  window.MutationObserver = function(cb){
    const wrapped = function(recs, obs){
      const t0=performance.now();
      try { return cb.call(this, recs, obs); }
      finally {
        const d=performance.now()-t0;
        if (d>1) { window.__TW.n++; window.__TW.ms+=d; if(d>50) window.__TW.long.push(Math.round(d)); }
      }
    };
    const m = new OMO(wrapped);
    const oObs = m.observe.bind(m);
    m.observe = function(t,o){ try{ window.__OBS.push({t:(t&&t.nodeName)||'?',o:JSON.stringify(o||{}),stk:(new Error().stack||'').split('\n')[2]||''}); }catch(_){}
      return oObs(t,o); };
    return m;
  };
  window.MutationObserver.prototype = OMO.prototype;
  try { new OMO(l=>{}).observe(document.documentElement,{}); } catch(_){}
  // long tasks
  window.__LT=[];
  try { new OMO(()=>{}); } catch(_){}
  try { new PerformanceObserver(l=>{ for(const e of l.getEntries()) window.__LT.push(Math.round(e.duration)); }).observe({entryTypes:['longtask']}); } catch(_){}
});
const cdp = await ctx.newCDPSession(p);
await cdp.send('Emulation.setCPUThrottlingRate',{rate:CPU});
await p.goto(base+'?nc='+Date.now(),{waitUntil:'domcontentloaded',timeout:120000});
await w(22000);
await p.evaluate(()=>{const el=[...document.querySelectorAll('button,a')].find(x=>/Entrar a MOS/i.test(x.textContent||''));if(el)el.click();});
await w(5000);
const rep = async (t) => {
  const d = await p.evaluate(()=>({tw:{...window.__TW, long:window.__TW.long.slice(-12)}, lt:{n:window.__LT.length,tot:window.__LT.reduce((s,x)=>s+x,0),max:Math.max(0,...window.__LT)},
    styleKB: Math.round([...document.querySelectorAll('style')].reduce((s,e)=>s+(e.textContent||'').length,0)/1024),
    dom: document.getElementsByTagName('*').length,
    obs: window.__OBS.map(o=>o.t+' '+o.o).reduce((a,k)=>{a[k]=(a[k]||0)+1;return a;},{})}));
  console.log(`\n── ${t} ──`);
  console.log(' callbacks de MutationObserver: n=' + d.tw.n + ' · CPU=' + Math.round(d.tw.ms) + 'ms · los >50ms: ' + d.tw.long.join(','));
  console.log(' longtasks: n=' + d.lt.n + ' total=' + d.lt.tot + 'ms max=' + d.lt.max + 'ms');
  console.log(' CSS generado en <style>: ' + d.styleKB + ' KB · nodos DOM: ' + d.dom);
  console.log(' observadores globales:', JSON.stringify(d.obs));
};
await rep('tras BOOT');
await p.evaluate(()=>{try{MOS.nav('finanzas');}catch(_){}} );
for(let i=0;i<45;i++){await w(1500);const n=await p.evaluate(()=>document.querySelectorAll('#finPersonalList .eval-card').length);if(n>0)break;}
await w(12000);
await rep('tras FINANZAS + Personal del día');
await b.close(); srv.close(); process.exit(0);
