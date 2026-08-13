// [755] Antes/después del build estático: mismo perfil que _735_tw.mjs + _735_twconf.mjs,
// pero parametrizado por RAÍZ para poder comparar el repo VIEJO (con CDN) contra el
// worktree NUEVO (con css/tw.css).
//
//   RAIZ=viejo node _755_tw_perfil.mjs   → C:/Users/ISO/ecosistema MOS/ProyectoMOS (CDN)
//   RAIZ=nuevo node _755_tw_perfil.mjs   → el worktree (build estático)
//
// Reporta: top-8 de tiempo propio del perfilador CDP (donde vivía `pf`, el JIT de Tailwind),
// callbacks de MutationObserver, long tasks, KB de <style> y nodos del DOM.
import { createRequire } from 'module';
const require = createRequire('C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/');
const { chromium } = require('playwright');
import http from 'http'; import fs from 'fs'; import path from 'path';

const RAICES = {
  viejo: 'C:/Users/ISO/ecosistema MOS/ProyectoMOS',
  nuevo: 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/.claude/worktrees/agent-aa328909aa8900a58'
};
const CUAL = process.env.RAIZ || 'nuevo';
const ROOT = RAICES[CUAL];
const CPU = parseInt(process.env.CPU || '4', 10);
const w = ms => new Promise(r => setTimeout(r, ms));
const MIME = { '.html':'text/html','.js':'text/javascript','.json':'application/json','.css':'text/css','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json' };
const srv = http.createServer((req,res)=>{let rel=decodeURIComponent(req.url.split('?')[0]);if(rel==='/'||rel==='')rel='/index.html';const f=path.join(ROOT,rel);fs.readFile(f,(e,buf)=>{if(e){res.writeHead(404).end('404');return;}res.writeHead(200,{'content-type':MIME[path.extname(f).toLowerCase()]||'application/octet-stream','cache-control':'no-store'});res.end(buf);});});
await new Promise(r=>srv.listen(0,'127.0.0.1',r));
const base='http://127.0.0.1:'+srv.address().port+'/';
const SEED={mos_device_id:'7e57c1a0-de1c-4a7e-b0de-c47a10906477',MOS_SESSION:JSON.stringify({idPersonal:'TEST-CLAUDE',nombre:'PRUEBA CLAUDE',rol:'MASTER',idSesion:'testclaude755'})};

function top(profile){const byId=new Map();profile.nodes.forEach(n=>byId.set(n.id,n));const self=new Map();
 const s=profile.samples||[],d=profile.timeDeltas||[];
 for(let i=0;i<s.length;i++){const n=byId.get(s[i]);if(!n)continue;const cf=n.callFrame;
  const k=(cf.functionName||'(anon)')+' @'+String(cf.url||'').replace(/^https?:\/\/[^/]+\//,'').split('?')[0]+':'+(cf.lineNumber+1);
  self.set(k,(self.get(k)||0)+Math.max(0,d[i]||0));}
 return [...self.entries()].sort((a,b)=>b[1]-a[1]).slice(0,8).map(([k,us])=>Math.round(us/1000)+'ms '+k);}

const b=await chromium.launch();
const ctx=await b.newContext({viewport:{width:1280,height:1400}});
const p=await ctx.newPage();
const errs=[]; p.on('pageerror',e=>errs.push(String(e).slice(0,120)));
const cdn=[]; p.on('request',r=>{ if(/cdn\.tailwindcss\.com/.test(r.url())) cdn.push(r.url()); });
await p.addInitScript(s=>{for(const[k,v]of Object.entries(s))localStorage.setItem(k,v);},SEED);
await p.addInitScript(()=>{
  window.__TW={n:0,ms:0,long:[]};
  const OMO=window.MutationObserver;
  window.MutationObserver=function(cb){
    const wrapped=function(recs,obs){const t0=performance.now();try{return cb.call(this,recs,obs);}finally{const d=performance.now()-t0;if(d>1){window.__TW.n++;window.__TW.ms+=d;if(d>50)window.__TW.long.push(Math.round(d));}}};
    return new OMO(wrapped);
  };
  window.MutationObserver.prototype=OMO.prototype;
  window.__LT=[];
  try{new PerformanceObserver(l=>{for(const e of l.getEntries())window.__LT.push(Math.round(e.duration));}).observe({entryTypes:['longtask']});}catch(_){}
});
const cdp=await ctx.newCDPSession(p);
await cdp.send('Emulation.setCPUThrottlingRate',{rate:CPU});
await cdp.send('Profiler.enable');await cdp.send('Profiler.setSamplingInterval',{interval:200});
await cdp.send('Profiler.start');
await p.goto(base+'?nc='+Date.now(),{waitUntil:'domcontentloaded',timeout:120000});
await w(22000);
await p.evaluate(()=>{const el=[...document.querySelectorAll('button,a')].find(x=>/Entrar a MOS/i.test(x.textContent||''));if(el)el.click();});
await w(5000);
const d1=await p.evaluate(()=>({tw:{...window.__TW},lt:{n:window.__LT.length,tot:window.__LT.reduce((s,x)=>s+x,0)},styleKB:Math.round([...document.querySelectorAll('style')].reduce((s,e)=>s+(e.textContent||'').length,0)/1024),cssKB:Math.round([...document.styleSheets].reduce((s,sh)=>{try{return s+[...sh.cssRules].reduce((a,r)=>a+r.cssText.length,0);}catch(_){return s;}},0)/1024),dom:document.getElementsByTagName('*').length}));
await p.evaluate(()=>{try{MOS.nav('finanzas');}catch(_){}} );
for(let i=0;i<45;i++){await w(1500);const n=await p.evaluate(()=>document.querySelectorAll('#finPersonalList .eval-card').length);if(n>0)break;}
await w(12000);
const d2=await p.evaluate(()=>({tw:{...window.__TW},lt:{n:window.__LT.length,tot:window.__LT.reduce((s,x)=>s+x,0)},styleKB:Math.round([...document.querySelectorAll('style')].reduce((s,e)=>s+(e.textContent||'').length,0)/1024),dom:document.getElementsByTagName('*').length}));
const prof=(await cdp.send('Profiler.stop')).profile;

console.log('\n═══ RAIZ=' + CUAL + ' (' + ROOT.split('/').pop() + ') · CPU x' + CPU + ' ═══');
console.log('  peticiones a cdn.tailwindcss.com: ' + cdn.length);
console.log('  errores de página: ' + errs.length + (errs.length ? ' → ' + errs.slice(0,3).join(' ; ') : ''));
console.log('  ── tras BOOT ──');
console.log('   MutationObserver: n=' + d1.tw.n + ' · CPU=' + Math.round(d1.tw.ms) + 'ms · >50ms: ' + d1.tw.long.join(','));
console.log('   longtasks: n=' + d1.lt.n + ' total=' + d1.lt.tot + 'ms · <style> ' + d1.styleKB + ' KB · CSSOM ' + d1.cssKB + ' KB · DOM ' + d1.dom);
console.log('  ── tras FINANZAS + Personal del día ──');
console.log('   MutationObserver: n=' + d2.tw.n + ' · CPU=' + Math.round(d2.tw.ms) + 'ms · >50ms: ' + d2.tw.long.slice(-10).join(','));
console.log('   longtasks: n=' + d2.lt.n + ' total=' + d2.lt.tot + 'ms · <style> ' + d2.styleKB + ' KB · DOM ' + d2.dom);
console.log('  ── top-8 de tiempo propio (acá vivía `pf`, el compilador del CDN) ──');
top(prof).forEach(l=>console.log('   ' + l));
await b.close(); srv.close(); process.exit(0);
