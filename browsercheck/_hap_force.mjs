import { chromium } from 'playwright';
import { prepararPagina } from './_hap_seed.mjs';
const b = await chromium.launch();
const ctx = await b.newContext({ viewport:{width:390,height:820}, hasTouch:true, isMobile:true, deviceScaleFactor:2, permissions:['notifications','geolocation'] });
const page = ctx.pages()[0] || await ctx.newPage();
await prepararPagina(page, ctx);
await page.goto('http://127.0.0.1:8126/index.html', { waitUntil:'domcontentloaded', timeout:120000 });
await page.waitForTimeout(30000);
const r = await page.evaluate(() => {
  const app = document.getElementById('app');
  const va = app && app.__vue_app__;
  const inst = va && va._instance;
  const ss = inst && inst.setupState;
  if (!ss) return { sinAcceso:true, tieneApp: !!va, keys: va ? Object.keys(va) : [] };
  const out = { keys: Object.keys(ss).length, tieneConfig: !!ss.config, dbCargada: ss.dbCargada && ss.dbCargada.value };
  try {
    ss.config.value.completado = true;
    ss.config.value.vendedor = 'TEST CLAUDE';
    ss.config.value.zona = 'TIENDA 1';
    ss.config.value.esCajero = true;
    ss.config.value.estacion = { idEstacion:'EST-TEST-1', Zona_ID:'TIENDA 1', Estacion_Nombre:'Caja-01', PrintNode_ID:'0' };
    ss.cajaAbierta.value = true;
    ss.idCajaActual.value = 'CAJA-LOCAL-TESTCLAUDE';
    ss.currentModule.value = 'POS';
    out.forzado = true;
  } catch (e) { out.err = String(e).slice(0,120); }
  return out;
});
console.log(JSON.stringify(r));
await page.waitForTimeout(4000);
console.log('cards:', await page.evaluate(()=>document.querySelectorAll('.pos-card').length));
await page.screenshot({ path:'_hap_force.png' });
await ctx.close(); await b.close();
