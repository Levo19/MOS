// [735] Confirmación: ¿`pf` (17 s de CPU en el boot) es el JIT de Tailwind Play CDN?
// Se corre el MISMO perfil con el CDN bloqueado y se compara.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT='C:/Users/ISO/ecosistema MOS/ProyectoMOS';
const BLOQ=process.env.BLOQ==='1';
const w=ms=>new Promise(r=>setTimeout(r,ms));
const MIME={'.html':'text/html','.js':'text/javascript','.json':'application/json','.css':'text/css','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json'};
const srv=http.createServer((req,res)=>{let rel=decodeURIComponent(req.url.split('?')[0]);if(rel==='/'||rel==='')rel='/index.html';const f=path.join(ROOT,rel);fs.readFile(f,(e,buf)=>{if(e){res.writeHead(404).end('404');return;}res.writeHead(200,{'content-type':MIME[path.extname(f).toLowerCase()]||'application/octet-stream','cache-control':'no-store'});res.end(buf);});});
await new Promise(r=>srv.listen(0,'127.0.0.1',r));
const base='http://127.0.0.1:'+srv.address().port+'/';
const SEED={mos_device_id:'7e57c1a0-de1c-4a7e-b0de-c47a10906477',MOS_SESSION:JSON.stringify({idPersonal:'TEST-CLAUDE',nombre:'PRUEBA CLAUDE',rol:'MASTER',idSesion:'testclaude735'})};
function top(profile){const byId=new Map();profile.nodes.forEach(n=>byId.set(n.id,n));const self=new Map();
 const s=profile.samples||[],d=profile.timeDeltas||[];
 for(let i=0;i<s.length;i++){const n=byId.get(s[i]);if(!n)continue;const cf=n.callFrame;
  const k=(cf.functionName||'(anon)')+' @'+String(cf.url||'').replace(/^https?:\/\/[^/]+\//,'').split('?')[0]+':'+(cf.lineNumber+1);
  self.set(k,(self.get(k)||0)+Math.max(0,d[i]||0));}
 return [...self.entries()].sort((a,b)=>b[1]-a[1]).slice(0,8).map(([k,us])=>Math.round(us/1000)+'ms '+k);}
const b=await chromium.launch();const ctx=await b.newContext({viewport:{width:1280,height:1400}});const p=await ctx.newPage();
const errs=[];p.on('pageerror',e=>errs.push(String(e).slice(0,120)));
await p.addInitScript(s=>{for(const[k,v]of Object.entries(s))localStorage.setItem(k,v);},SEED);
if(BLOQ) await p.route('**cdn.tailwindcss.com**', r=>r.abort());
const cdp=await ctx.newCDPSession(p);await cdp.send('Emulation.setCPUThrottlingRate',{rate:4});
await cdp.send('Profiler.enable');await cdp.send('Profiler.setSamplingInterval',{interval:200});
await cdp.send('Profiler.start');
await p.goto(base+'?nc='+Date.now(),{waitUntil:'domcontentloaded',timeout:120000});
await w(22000);
await p.evaluate(()=>{const el=[...document.querySelectorAll('button,a')].find(x=>/Entrar a MOS/i.test(x.textContent||''));if(el)el.click();});
await w(6000);
console.log('\n═══ Tailwind CDN ' + (BLOQ?'BLOQUEADO':'presente') + ' ═══');
top((await cdp.send('Profiler.stop')).profile).forEach(l=>console.log('  '+l));
console.log('  errs:'+errs.length);
await b.close();srv.close();process.exit(0);
