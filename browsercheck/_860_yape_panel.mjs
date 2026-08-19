// [858/860] Config → Yapes (emparejamiento) y el panel por caja.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT=path.resolve(process.argv[2]);
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8802,r));
const ok=[],bad=[]; const T=(n,c,x)=>{(c?ok:bad).push(n);console.log((c?'  ✅ ':'  ❌ ')+n+(x?' — '+x:''));};
const b=await chromium.launch(); const p=await (await b.newContext({viewport:{width:1280,height:950}})).newPage();
const errs=[]; p.on('pageerror',e=>errs.push(String(e.message)));
await p.addInitScript(d=>localStorage.setItem('mos_device_id',d),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8802/',{waitUntil:'domcontentloaded'}); await p.waitForTimeout(5000);
try{await p.click('text=/Entrar a MOS/i',{timeout:4000});}catch{}
await p.waitForFunction(()=>{try{return !!MOS;}catch{return false;}},{timeout:60000});

// ── Config → Yapes ──
await p.evaluate(()=>MOS.nav('config')); await p.waitForTimeout(3500);
T('la pestaña 💜 Yapes existe', await p.evaluate(()=>!!document.getElementById('cfgTabYape')));
await p.evaluate(()=>MOS.setCfgTab('yape'));
await p.waitForFunction(()=>{const e=document.getElementById('yapeBody');return e && /Emparejar un celular|zonas de venta/.test(e.textContent);},{timeout:30000});
const cfg = await p.evaluate(()=>{
  const e=document.getElementById('yapeBody');
  return { pasos: e.querySelectorAll('.yp-paso').length, zonas: e.querySelectorAll('.yp-zona').length,
           // el enlace va al RELEASE (último APK publicado), no a la página de Actions
           apk: !!e.querySelector('a[href*="releases/latest"]'),
           equipos: e.querySelectorAll('.yp-eq').length, revocar: e.querySelectorAll('.yp-eq-btn').length,
           btn: !!e.querySelector('.yp-btn') };
});
console.log('     config: '+JSON.stringify(cfg));
T('explica los 3 pasos de instalación', cfg.pasos===3);
T('lista los equipos con su estado', cfg.equipos>=1, cfg.equipos+' equipo(s)');
T('da el enlace para descargar el APK', cfg.apk);
T('ofrece emparejar por cada zona de venta', cfg.zonas>=2 && cfg.btn, cfg.zonas+' zonas');
T('sin desborde horizontal', await p.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth<=1));

// ── Panel por caja ──
await p.evaluate(()=>MOS.nav('cajas')); await p.waitForTimeout(15000);
const caja = await p.evaluate(()=>{
  const el=document.querySelector('.cj-caja-yape');
  if(!el) return null;
  const m=String(el.getAttribute('onclick')).match(/yapesCajaAbrir\('([^']+)'\)/);
  return m?m[1]:null;
});
// Solo se puede comprobar con una caja ABIERTA; fuera de horario no hay ninguna y eso no es un fallo.
const hayCajas = await p.evaluate(()=>!!document.querySelector('.cj-caja, [data-caja], .cj-card'));
if (hayCajas) T('cada caja tiene su botón 💜 Yapes', !!caja, caja||'(caja sin botón)');
else console.log('  ·   sin cajas abiertas ahora: el botón 💜 por caja no se puede comprobar (no es fallo)');
if (caja) {
  await p.evaluate(id=>MOS.yapesCajaAbrir(id), caja);
  await p.waitForFunction(()=>{const e=document.getElementById('ypBody');return e && !/leyendo/.test(e.textContent);},{timeout:30000});
  const pan = await p.evaluate(()=>{
    const e=document.getElementById('ypBody');
    return { kpis: e.querySelectorAll('.yp-kpi').length,
             secciones: [...e.querySelectorAll('.yp-sec')].map(x=>x.textContent.trim().slice(0,30)),
             pie: /Sin verificar no significa impago/.test(e.textContent) };
  });
  console.log('     panel: '+JSON.stringify(pan));
  T('el panel trae los 4 contadores', pan.kpis===4);
  T('muestra las dos mitades: Yapes y tickets sin verificar', pan.secciones.length===2, pan.secciones.join(' | '));
  T('aclara que sin verificar no es impago', pan.pie);
  T('sin desborde con el panel abierto',
    await p.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth<=1));
  await p.setViewportSize({width:390,height:844}); await p.waitForTimeout(600);
  T('el panel es responsive en móvil',
    await p.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth<=1));
}
console.log('\n  errores de página: '+(errs.length?errs.slice(0,3).join(' | '):'ninguno'));
T('sin errores de página', errs.length===0);
console.log('\n  '+ok.length+' ✅   '+bad.length+' ❌');
await b.close(); srv.close(); process.exit(bad.length?1:0);
