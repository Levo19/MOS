// [735] Perfil de CPU (CDP Profiler) para atribuir los long tasks del panel MOS.
// FASE=boot   → perfila carga + entrada al panel
// FASE=fin    → perfila navegación a finanzas + render de Personal del día
// FASE=clic   → perfila el clic en Auditar
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

function resumir(profile, titulo) {
  const byId = new Map();
  profile.nodes.forEach(n => byId.set(n.id, n));
  const self = new Map();
  const total = (profile.timeDeltas || []).reduce((s, d) => s + Math.max(0, d), 0);
  const samples = profile.samples || [];
  const deltas = profile.timeDeltas || [];
  for (let i = 0; i < samples.length; i++) {
    const n = byId.get(samples[i]); if (!n) continue;
    const cf = n.callFrame;
    const k = (cf.functionName || '(anon)') + ' @' + String(cf.url || '').replace(/^https?:\/\/[^/]+\//, '').split('?')[0] + ':' + (cf.lineNumber + 1);
    self.set(k, (self.get(k) || 0) + Math.max(0, deltas[i] || 0));
  }
  const arr = [...self.entries()].sort((a, b) => b[1] - a[1]).slice(0, 25);
  console.log(`\n═══ PERFIL ${titulo} · CPU ocupada ${Math.round(total / 1000)}ms ═══`);
  arr.forEach(([k, us]) => { if (us > 8000) console.log('  ' + String(Math.round(us / 1000)).padStart(6) + 'ms  ' + k); });
}

const b=await chromium.launch({args:['--enable-precise-memory-info','--js-flags=--expose-gc']});
const ctx=await b.newContext({viewport:{width:1280,height:1400}});
const p=await ctx.newPage();
p.on('pageerror',e=>console.log('ERR',String(e).slice(0,150)));
await p.addInitScript(s=>{for(const[k,v]of Object.entries(s))localStorage.setItem(k,v);},SEED);
const cdp = await ctx.newCDPSession(p);
await cdp.send('Emulation.setCPUThrottlingRate',{rate:CPU});
await cdp.send('Profiler.enable');
await cdp.send('Profiler.setSamplingInterval',{interval:200});

await cdp.send('Profiler.start');
await p.goto(base+'?nc='+Date.now(),{waitUntil:'domcontentloaded',timeout:120000});
await w(22000);
await p.evaluate(()=>{const el=[...document.querySelectorAll('button,a')].find(x=>/Entrar a MOS/i.test(x.textContent||''));if(el)el.click();});
await w(6000);
resumir((await cdp.send('Profiler.stop')).profile, 'BOOT + entrada al panel');

await cdp.send('Profiler.start');
await p.evaluate(()=>{try{MOS.nav('finanzas');}catch(_){}} );
for(let i=0;i<45;i++){await w(1500);const n=await p.evaluate(()=>document.querySelectorAll('#finPersonalList .eval-card').length);if(n>0)break;}
await w(12000);
resumir((await cdp.send('Profiler.stop')).profile, 'NAV finanzas + render Personal del día');

// esperar a que se calme
await w(20000);
await cdp.send('Profiler.start');
const r = await p.evaluate(async ()=>{
  const btn=document.querySelector('#finPersonalList button[onclick*="abrirAuditar"]');
  if(!btn) return 'sin botón';
  const t0=performance.now(); btn.click();
  const m=document.getElementById('modalAuditar');
  for(let i=0;i<200;i++){await new Promise(r=>setTimeout(r,50)); if(m&&!m.classList.contains('hidden'))break;}
  return Math.round(performance.now()-t0);
});
await w(4000);
console.log('\nclic→modal:', r, 'ms');
resumir((await cdp.send('Profiler.stop')).profile, 'CLIC en Auditar');

await b.close(); srv.close(); process.exit(0);
