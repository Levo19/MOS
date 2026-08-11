// [735] Mismo test, pero inyectando el acumulado en la RESPUESTA de resumen_todos_dia
// (hoy nadie tiene limpieza acumulada real). Cache = 0, servidor = 60% + 2 checks.
import { chromium } from 'playwright';
const w=ms=>new Promise(r=>setTimeout(r,ms));
const SEED={mos_device_id:'7e57c1a0-de1c-4a7e-b0de-c47a10906477',MOS_SESSION:JSON.stringify({idPersonal:'TEST-CLAUDE',nombre:'PRUEBA CLAUDE',rol:'MASTER',idSesion:'testclaude735'})};
const OBJ='MEX:DIEGO|ZONA-01';
const b=await chromium.launch();const ctx=await b.newContext({viewport:{width:1280,height:1500}});const p=await ctx.newPage();
const errs=[];p.on('pageerror',e=>errs.push(String(e).split('\n')[0].slice(0,150)));
await p.addInitScript(s=>{for(const[k,v]of Object.entries(s))localStorage.setItem(k,v);},SEED);
await p.goto('https://levo19.github.io/MOS/?nc='+Date.now(),{waitUntil:'domcontentloaded',timeout:120000});
await w(20000);
await p.evaluate(()=>{const el=[...document.querySelectorAll('button,a')].find(x=>/Entrar a MOS/i.test(x.textContent||''));if(el)el.click();});
await w(3000);
await p.evaluate(()=>{try{MOS.nav('finanzas');}catch(_){}} );
for(let i=0;i<50;i++){await w(1500);const n=await p.evaluate(()=>document.querySelectorAll('#finPersonalList button[onclick*="abrirAuditar"]').length);if(n>0)break;}
await w(8000);
// A partir de acá el SERVIDOR dice limpieza 60% + 2 checks para OBJ; el cache local sigue en 0.
await p.route('**/rest/v1/rpc/resumen_todos_dia', async route => {
  const r = await route.fetch();
  let j; try { j = await r.json(); } catch(_) { return route.fulfill({response:r}); }
  const arr = (j && j.data) || [];
  arr.forEach(x => { if (x.idPersonal === OBJ) {
    x.manual = Object.assign({}, x.manual, { limpiezaPct: 60, limpiezaProfPct: 30,
      checksAcum: { c0: true, c2: true } });
  }});
  const h = {...r.headers()}; delete h['content-encoding']; delete h['content-length'];
  return route.fulfill({ status: r.status(), headers: h, body: JSON.stringify(j) });
});
const res = await p.evaluate(async (OBJ) => {
  const $ = i => document.getElementById(i);
  const nChecks = () => document.querySelectorAll('.audit-check-row.checked, .audit-check.checked, [class*="check"].checked').length;
  // CASO A — el admin NO toca nada: el refresco debe completar 0% → 60%
  MOS.abrirAuditar(OBJ);
  await new Promise(r=>setTimeout(r,250));
  const alAbrir = { limp: $('auditLimpieza').value, prof: $('auditLimpiezaProf').value, checks: nChecks() };
  await new Promise(r=>setTimeout(r,9000));
  const trasRefresco = { limp: $('auditLimpieza').value, prof: $('auditLimpiezaProf').value, checks: nChecks() };
  MOS.cerrarAuditar(); await new Promise(r=>setTimeout(r,2000));
  // CASO B — el admin mueve el slider antes de que llegue el refresco
  MOS.abrirAuditar(OBJ);
  await new Promise(r=>setTimeout(r,250));
  $('auditLimpieza').value = '90'; MOS.updateRateSlider('auditLimpieza','auditLimpiezaVal');
  const escrito = $('auditComentario'); if (escrito) escrito.value = 'texto del admin';
  await new Promise(r=>setTimeout(r,9000));
  const b = { limp: $('auditLimpieza').value, coment: (escrito||{}).value };
  MOS.cerrarAuditar();
  return { alAbrir, trasRefresco, b };
}, OBJ);
console.log(JSON.stringify(res,null,1));
console.log(res.trasRefresco.limp==='60' && res.trasRefresco.prof==='30'
  ? '✓ CASO A: el refresco completó el acumulado del servidor (0%/0% → 60%/30%), checks '+res.alAbrir.checks+' → '+res.trasRefresco.checks
  : '🚨 CASO A: quedó en '+res.trasRefresco.limp+'%/'+res.trasRefresco.prof+'%');
console.log(res.b.limp==='90' && res.b.coment==='texto del admin'
  ? '✓ CASO B: lo que el admin movió/escribió sobrevivió al refresco'
  : '🚨 CASO B: el refresco pisó al admin → slider '+res.b.limp+' · comentario "'+res.b.coment+'"');
console.log('pageerrors:', errs.length?errs.join(' | '):'0');
await b.close();process.exit(0);
