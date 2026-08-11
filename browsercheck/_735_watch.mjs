// [735] Vigila #finPersonalList durante N minutos: ¿desaparecen los botones Auditar?
// ¿cuántas veces se reescribe el HTML completo? Muestrea cada 500 ms.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS';
const CPU = parseInt(process.env.CPU || '4', 10);
const MIN = parseInt(process.env.MIN || '4', 10);
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
const cdp = await ctx.newCDPSession(p);
await cdp.send('Emulation.setCPUThrottlingRate',{rate:CPU});
await p.goto(base+'?nc='+Date.now(),{waitUntil:'domcontentloaded',timeout:120000});
await w(22000);
const entro = await p.evaluate(()=>{const el=[...document.querySelectorAll('button,a')].find(x=>/Entrar a MOS/i.test(x.textContent||''));if(el){el.click();return 'click';}return 'sin botón Entrar';});
console.log('entrada:', entro);
await w(4000);
console.log('nav:', await p.evaluate(()=>{try{MOS.nav('finanzas');return 'ok view='+((window.MOS&&MOS._debugView&&MOS._debugView())||document.querySelector('.view:not(.hidden)')?.id||'?');}catch(e){return 'ERR '+e.message;}}));
// instalar vigía dentro de la página
await p.evaluate(() => {
  window.__W = [];
  let prev = null;
  const t0 = performance.now();
  setInterval(() => {
    const c = document.getElementById('finPersonalList');
    if (!c) return;
    const n = c.querySelectorAll('button[onclick*="abrirAuditar"]').length;
    const cards = c.querySelectorAll('.eval-card').length;
    const h = c.innerHTML.length;
    const k = n + '|' + cards + '|' + h;
    if (k !== prev) { window.__W.push({ t: Math.round((performance.now() - t0) / 1000), btn: n, cards, kb: Math.round(h / 1024) }); prev = k; }
  }, 500);
});
await w(MIN * 60000);
const hist = await p.evaluate(() => window.__W);
console.log('\n── cambios de #finPersonalList (s | botones Auditar | cards | KB de HTML) ──');
hist.forEach(x => console.log(String(x.t).padStart(4) + 's  btn=' + String(x.btn).padStart(3) + '  cards=' + String(x.cards).padStart(3) + '  ' + x.kb + 'KB' + (x.btn === 0 ? '   ⚠ SIN BOTÓN' : '')));
await p.screenshot({ path: ROOT + '/browsercheck/_735_watch_final.png' });
console.log('diag final:', JSON.stringify(await p.evaluate(() => {
  const c = document.getElementById('finPersonalList');
  return { hayCont: !!c, kb: c ? c.innerHTML.length : -1, fecha: c && c.dataset.fecha,
           vistaVisible: [...document.querySelectorAll('[id^="view"]')].filter(v => !v.classList.contains('hidden')).map(v => v.id),
           total: (document.getElementById('finPersonalTotal') || {}).textContent };
})));
const sinBtn = hist.filter(x => x.btn === 0).length;
console.log('\nestados sin botón Auditar: ' + sinBtn + ' de ' + hist.length + ' cambios · repintes totales: ' + hist.length + ' en ' + MIN + ' min');
await b.close(); srv.close(); process.exit(0);
