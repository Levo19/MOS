// [735] El OTRO camino al modal: el botón "Auditar" del lápiz de Liquidaciones
// (_liqEditarDia abre con un resumen sintético en 0 y espera que el dato real
// complete sliders/checks). Verifica que sigue llegando completo.
import { chromium } from 'playwright';
const w=ms=>new Promise(r=>setTimeout(r,ms));
const SEED={mos_device_id:'7e57c1a0-de1c-4a7e-b0de-c47a10906477',MOS_SESSION:JSON.stringify({idPersonal:'TEST-CLAUDE',nombre:'PRUEBA CLAUDE',rol:'MASTER',idSesion:'testclaude735'})};
const b=await chromium.launch();const ctx=await b.newContext({viewport:{width:1280,height:1500}});const p=await ctx.newPage();
const errs=[];p.on('pageerror',e=>errs.push(String(e).split('\n')[0].slice(0,150)));
await p.addInitScript(s=>{for(const[k,v]of Object.entries(s))localStorage.setItem(k,v);},SEED);
await p.goto('https://levo19.github.io/MOS/?nc='+Date.now(),{waitUntil:'domcontentloaded',timeout:120000});
await w(20000);
await p.evaluate(()=>{const el=[...document.querySelectorAll('button,a')].find(x=>/Entrar a MOS/i.test(x.textContent||''));if(el)el.click();});
await w(3000);
await p.evaluate(()=>{try{MOS.nav('liquidaciones');}catch(_){}} );
for(let i=0;i<80;i++){await w(2000);const n=await p.evaluate(()=>document.querySelectorAll('button[onclick*="_liqEditarDia"]').length);if(n>0){console.log('personas en Liquidaciones:',n);break;}}
 await p.evaluate(()=>{const el=document.querySelector('[onclick*="_liqTogglePersona"]'); if(el){el.click();el.click();}});
 await w(2500);
 console.log('botones Auditar tras expandir:', await p.evaluate(()=>document.querySelectorAll('button[onclick*="_liqEditarDia"]').length));
const r=await p.evaluate(async()=>{
  let btn=document.querySelector('button[onclick*="_liqEditarDia"]');
  if(!btn){ document.querySelectorAll('[onclick*="_liqTogglePersona"]').forEach(e=>e.click()); await new Promise(r=>setTimeout(r,2500)); btn=document.querySelector('button[onclick*="_liqEditarDia"]'); }
  if(!btn){ return {error:'sin lápiz', diag: (document.getElementById('liqBody')||{}).innerHTML?.replace(/s+/g,' ').slice(0,400) || 'sin liqBody'}; }
  if(!btn) return {error:'sin lápiz'};
  const m=document.getElementById('modalAuditar');const t0=performance.now();
  btn.click();
  let tM=null;for(let i=0;i<200;i++){await new Promise(r=>setTimeout(r,50));if(m&&!m.classList.contains('hidden')){tM=Math.round(performance.now()-t0);break;}}
  await new Promise(r=>setTimeout(r,7000));   // dejar aterrizar el refresco
  return {modalMs:tM, titulo:(document.getElementById('auditTitle')||{}).textContent,
          sub:(document.getElementById('auditSubtitle')||{}).textContent,
          kpis:(document.getElementById('auditKpis')||{}).textContent.replace(/\s+/g,' ').slice(0,220),
          limp:(document.getElementById('auditLimpieza')||{}).value,
          limpP:(document.getElementById('auditLimpiezaProf')||{}).value,
          checks:document.querySelectorAll('#auditChecklist .checked, .audit-check-row.checked').length,
          liq:(document.getElementById('auditLiqBox')||document.getElementById('auditLiquidacion')||{}).textContent?.replace(/\s+/g,' ').slice(0,160)||''};
});
console.log(JSON.stringify(r,null,1));
await p.screenshot({path:'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_735_liq_modal.png'});
console.log('pageerrors:',errs.length?errs.join(' | '):'0');
await b.close();process.exit(0);
