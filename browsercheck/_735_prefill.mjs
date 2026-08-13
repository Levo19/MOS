// [735] Verifica el caso del lápiz de Liquidaciones: el modal abre con un resumen
// SINTÉTICO en 0 (limpieza 0, checks {}) y el dato real debe completar sliders y
// checks cuando llega. Y el caso opuesto: si el admin YA movió el slider, el
// refresco NO debe pisárselo.
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
await p.evaluate(()=>{try{MOS.nav('finanzas');}catch(_){}} );
for(let i=0;i<50;i++){await w(1500);const n=await p.evaluate(()=>document.querySelectorAll('#finPersonalList button[onclick*="abrirAuditar"]').length);if(n>0)break;}
await w(8000);

// Elegir una persona que SÍ tenga limpieza acumulada > 0 en el dato real.
const caso = await p.evaluate(async () => {
  const btns=[...document.querySelectorAll('#finPersonalList button[onclick*="abrirAuditar"]')];
  const ids=btns.map(b=>(b.getAttribute('onclick').match(/abrirAuditar\('([^']+)'/)||[])[1]).filter(Boolean);
  return { ids };
});
console.log('ids:', caso.ids.slice(0,12).join(' | '));

const r = await p.evaluate(async (ids) => {
  const out=[];
  const $ = id => document.getElementById(id);
  for (const id of ids) {
    // 1) SIMULAR EL LÁPIZ: sustituir el resumen en memoria por uno sintético en 0.
    const real = await MOS.__test_resumenDe ? null : null;
    // acceso indirecto: forzamos que la apertura arranque "en cero" borrando el cache
    // y dejando solo un stub, igual que hace _liqEditarDia.
    const antes = JSON.parse(localStorage.getItem('mos_fin_resum_' + new Date().toISOString().slice(0,10)) || 'null');
    if (!antes || !Array.isArray(antes.data)) continue;
    const realR = antes.data.find(x=>x.idPersonal===id);
    if (!realR) continue;
    const limpReal = Math.round(((realR.manual&&realR.manual.limpiezaPct)||0)/10)*10;
    const nChecksReal = Object.keys((realR.manual&&realR.manual.checksAcum)||{}).length;
    if (limpReal === 0 && nChecksReal === 0) continue;   // no sirve para el test
    out.push({ id, limpReal, nChecksReal });
    if (out.length >= 1) break;
  }
  return out;
}, caso.ids);
console.log('candidato con acumulado real:', JSON.stringify(r));
if (!r.length) { console.log('⚠ nadie con limpieza/checks acumulados hoy — no se puede probar el completado'); }
else {
  const id = r[0].id;
  const res = await p.evaluate(async (info) => {
    const $ = i => document.getElementById(i);
    const hoy = new Date().toISOString().slice(0,10);
    const raw = JSON.parse(localStorage.getItem('mos_fin_resum_'+hoy));
    const realR = raw.data.find(x=>x.idPersonal===info.id);
    // ── CASO A: abrir con sintético en 0 (como el lápiz) → debe completarse solo ──
    const stub = JSON.parse(JSON.stringify(realR));
    stub.manual = { limpiezaPct: 0, limpiezaProfPct: 0, checksAcum: {} };
    localStorage.setItem('mos_fin_resum_'+hoy, JSON.stringify({ts:Date.now(), data: raw.data.map(x=>x.idPersonal===info.id?stub:x)}));
    // vaciar memoria para que lea del cache trucado
    MOS.nav('finanzas');
    await new Promise(r=>setTimeout(r,1500));
    MOS.abrirAuditar(info.id);
    await new Promise(r=>setTimeout(r,300));
    const alAbrir = { limp: $('auditLimpieza').value, checks: document.querySelectorAll('.audit-check-row.checked').length };
    await new Promise(r=>setTimeout(r,9000));   // que aterrice el refresco
    const trasRefresco = { limp: $('auditLimpieza').value, checks: document.querySelectorAll('.audit-check-row.checked').length };
    MOS.cerrarAuditar();
    await new Promise(r=>setTimeout(r,1500));
    // ── CASO B: abrir, MOVER el slider, y comprobar que el refresco NO lo pisa ──
    MOS.abrirAuditar(info.id);
    await new Promise(r=>setTimeout(r,300));
    $('auditLimpieza').value = '70';
    MOS.updateRateSlider('auditLimpieza','auditLimpiezaVal');
    await new Promise(r=>setTimeout(r,9000));
    const tocado = $('auditLimpieza').value;
    MOS.cerrarAuditar();
    return { alAbrir, trasRefresco, esperado: info, tocadoQuedoEn: tocado };
  }, r[0]);
  console.log(JSON.stringify(res, null, 1));
  const okA = String(res.trasRefresco.limp) === String(res.esperado.limpReal);
  const okB = res.tocadoQuedoEn === '70';
  console.log(okA ? '✓ CASO A: el refresco completó el acumulado real ('+res.alAbrir.limp+'% → '+res.trasRefresco.limp+'%)'
                  : '🚨 CASO A: quedó en '+res.trasRefresco.limp+'% y el real es '+res.esperado.limpReal+'%');
  console.log(okB ? '✓ CASO B: lo que el admin movió (70%) sobrevivió al refresco'
                  : '🚨 CASO B: el refresco pisó al admin → '+res.tocadoQuedoEn);
}
console.log('pageerrors:', errs.length?errs.join(' | '):'0');
await b.close();process.exit(0);
