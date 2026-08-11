// [735] ¿Quién dispara la tormenta de operacion_detalle? Traza el stack de cada RPC
// y resume TODA la red de una sesión de ~4 min en el panel (dashboard → finanzas).
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS';
const w = ms => new Promise(r => setTimeout(r, ms));
const MIME = { '.html':'text/html','.js':'text/javascript','.json':'application/json','.css':'text/css','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json' };
const srv = http.createServer((req,res)=>{let rel=decodeURIComponent(req.url.split('?')[0]);if(rel==='/'||rel==='')rel='/index.html';const f=path.join(ROOT,rel);fs.readFile(f,(e,buf)=>{if(e){res.writeHead(404).end('404');return;}res.writeHead(200,{'content-type':MIME[path.extname(f).toLowerCase()]||'application/octet-stream','cache-control':'no-store'});res.end(buf);});});
await new Promise(r=>srv.listen(0,'127.0.0.1',r));
const base='http://127.0.0.1:'+srv.address().port+'/';
const SEED={mos_device_id:'7e57c1a0-de1c-4a7e-b0de-c47a10906477',MOS_SESSION:JSON.stringify({idPersonal:'TEST-CLAUDE',nombre:'PRUEBA CLAUDE',rol:'MASTER',idSesion:'testclaude735'})};
const b=await chromium.launch({args:['--enable-precise-memory-info']});
const ctx=await b.newContext({viewport:{width:1280,height:1400}});
const p=await ctx.newPage();
p.on('pageerror',e=>console.log('ERR',String(e).slice(0,150)));
await p.addInitScript(s=>{for(const[k,v]of Object.entries(s))localStorage.setItem(k,v);},SEED);
await p.addInitScript(()=>{
  window.__NET=[]; window.__BYTES=0;
  const oF=window.fetch;
  window.fetch=function(u){
    const url=String((u&&u.url)||u||'');
    const t0=performance.now();
    let stk='';
    if(/operacion_detalle|productos_master|resumen_todos_dia/.test(url)){
      stk=(new Error().stack||'').split('\n').slice(2,7).map(s=>s.trim().replace(/https?:\/\/[^/]+\//,'')).join(' < ');
    }
    return oF.apply(window,arguments).then(async r=>{
      let len=0; try{ len=+(r.headers.get('content-length')||0);}catch(_){}
      window.__NET.push({u:url.replace(/^https?:\/\/[^/]+/,'').split('?')[0],ms:Math.round(performance.now()-t0),ts:Math.round(t0),st:r.status,len,stk});
      return r;
    },e=>{window.__NET.push({u:url.replace(/^https?:\/\/[^/]+/,'').split('?')[0],ms:Math.round(performance.now()-t0),ts:Math.round(t0),st:'ERR',stk});throw e;});
  };
});
await p.goto(base+'?nc='+Date.now(),{waitUntil:'domcontentloaded',timeout:120000});
await w(20000);
await p.evaluate(()=>{const el=[...document.querySelectorAll('button,a')].find(x=>/Entrar a MOS/i.test(x.textContent||''));if(el)el.click();});
await w(4000);
const dump = async (tag) => {
  const n = await p.evaluate(()=>{
    const g={}; const stk={};
    window.__NET.forEach(x=>{ g[x.u]=(g[x.u]||0)+1; if(x.stk) stk[x.u]=stk[x.u]||x.stk; });
    const tot=window.__NET.length;
    const lentas=window.__NET.filter(x=>x.ms>1500).length;
    return {tot, lentas, g:Object.entries(g).sort((a,b)=>b[1]-a[1]).slice(0,18), stk};
  });
  console.log(`\n── ${tag} · total requests=${n.tot} · >1.5s=${n.lentas}`);
  n.g.forEach(([u,c])=>console.log('  '+String(c).padStart(4)+'× '+u));
  return n;
};
await dump('tras BOOT (dashboard)');
await p.evaluate(()=>{try{MOS.nav('finanzas');}catch(_){}} );
await w(60000);
await dump('60s en finanzas');
await w(120000);
const fin = await dump('3 min en finanzas');
console.log('\nstacks:');
Object.entries(fin.stk).forEach(([u,s])=>console.log('  '+u+'\n     '+s));
await b.close(); srv.close(); process.exit(0);
