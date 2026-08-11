// [735] Bytes y requests reales de una sesión de N minutos en el panel.
// RAIZ=<dir> para servir otra copia (p.ej. un checkout de HEAD = "antes").
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = process.env.RAIZ || 'C:/Users/ISO/ecosistema MOS/ProyectoMOS';
const MIN = parseInt(process.env.MIN || '5', 10);
const TAG = process.env.TAG || 'x';
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
await cdp.send('Network.enable');
let bytes=0, reqs=0, porRpc={};
const urlDe={};
cdp.on('Network.requestWillBeSent', e => { urlDe[e.requestId]=e.request.url; if(!/^data:/.test(e.request.url)) reqs++; });
cdp.on('Network.loadingFinished', e => { bytes += e.encodedDataLength||0;
  const u=(urlDe[e.requestId]||'').replace(/^https?:\/\/[^/]+/,'').split('?')[0];
  porRpc[u]=porRpc[u]||{n:0,b:0}; porRpc[u].n++; porRpc[u].b+=e.encodedDataLength||0; });
await p.goto(base+'?nc='+Date.now(),{waitUntil:'domcontentloaded',timeout:120000});
await w(22000);
await p.evaluate(()=>{const el=[...document.querySelectorAll('button,a')].find(x=>/Entrar a MOS/i.test(x.textContent||''));if(el)el.click();});
await w(4000);
const bootB=bytes, bootR=reqs;
await p.evaluate(()=>{try{MOS.nav('finanzas');}catch(_){}} );
await w(MIN*60000);
console.log(`\n═══ ${TAG} · ${MIN} min ═══`);
console.log(' BOOT      : ' + bootR + ' requests · ' + (bootB/1048576).toFixed(1) + ' MB');
console.log(' TOTAL     : ' + reqs + ' requests · ' + (bytes/1048576).toFixed(1) + ' MB');
console.log(' proyección a 47 min: ' + Math.round(bootR + (reqs-bootR)*47/MIN) + ' requests · '
  + ((bootB + (bytes-bootB)*47/MIN)/1048576).toFixed(0) + ' MB');
console.log(' top por bytes:');
Object.entries(porRpc).sort((a,c)=>c[1].b-a[1].b).slice(0,10)
  .forEach(([u,v])=>console.log('   ' + (v.b/1048576).toFixed(2).padStart(7) + ' MB  ' + String(v.n).padStart(3) + '×  ' + u));
console.log(' pageerrors: ' + (errs.length?errs.join(' | '):'0'));
await b.close(); srv.close(); process.exit(0);
