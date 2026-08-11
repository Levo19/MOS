// probe rápido: ¿qué hay dentro de #finPersonalList?
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS';
const w = ms => new Promise(r => setTimeout(r, ms));
const MIME = { '.html':'text/html','.js':'text/javascript','.json':'application/json','.css':'text/css','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json' };
const srv = http.createServer((req,res)=>{let rel=decodeURIComponent(req.url.split('?')[0]);if(rel==='/'||rel==='')rel='/index.html';const f=path.join(ROOT,rel);fs.readFile(f,(e,buf)=>{if(e){res.writeHead(404).end('404');return;}res.writeHead(200,{'content-type':MIME[path.extname(f).toLowerCase()]||'application/octet-stream','cache-control':'no-store'});res.end(buf);});});
await new Promise(r=>srv.listen(0,'127.0.0.1',r));
const base='http://127.0.0.1:'+srv.address().port+'/';
const SEED={mos_device_id:'7e57c1a0-de1c-4a7e-b0de-c47a10906477',MOS_SESSION:JSON.stringify({idPersonal:'TEST-CLAUDE',nombre:'PRUEBA CLAUDE',rol:'MASTER',idSesion:'testclaude735'})};
const b=await chromium.launch(); const ctx=await b.newContext({viewport:{width:1280,height:1400}}); const p=await ctx.newPage();
p.on('pageerror',e=>console.log('ERR',String(e).slice(0,150)));
await p.addInitScript(s=>{for(const[k,v]of Object.entries(s))localStorage.setItem(k,v);},SEED);
await p.goto(base+'?nc='+Date.now(),{waitUntil:'domcontentloaded'});
await w(20000);
await p.evaluate(()=>{const el=[...document.querySelectorAll('button,a')].find(x=>/Entrar a MOS/i.test(x.textContent||''));if(el)el.click();});
await w(2500);
await p.evaluate(()=>{try{MOS.nav('finanzas');}catch(_){}} );
for(let i=0;i<40;i++){await w(1500);const n=await p.evaluate(()=>document.querySelectorAll('#finPersonalList .eval-card').length);if(n>0){console.log('cards',n);break;}}
await w(6000);
console.log(JSON.stringify(await p.evaluate(()=>{
  const c=document.getElementById('finPersonalList');
  const btns=[...c.querySelectorAll('button')].map(b=>({t:JSON.stringify((b.textContent||'').trim()).slice(0,40),oc:(b.getAttribute('onclick')||'').slice(0,60)}));
  return {cards:c.querySelectorAll('.eval-card').length, nbtn:btns.length, btns:btns.slice(0,20), html:c.innerHTML.slice(0,300)};
}),null,1));
await b.close(); srv.close(); process.exit(0);
