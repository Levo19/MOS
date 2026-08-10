import { chromium } from 'playwright';
const URL='https://levo19.github.io/warehouseMos-/';
const DEV='7e57c1a0-de1c-4a7e-b0de-c47a10906475';
const SESION=JSON.stringify({idSesion:'LOCAL_TESTCLAUDE',idPersonal:'TEST-CLAUDE',nombre:'PRUEBA CLAUDE',apellido:'CLAUDE',color:'#4f46e5',rol:'MASTER',fechaDia:'2026-08-09',fechaGuardado:new Date().toISOString()});
(async()=>{const b=await chromium.launch({headless:true});const c=await b.newContext({viewport:{width:1280,height:900}});const p=await c.newPage();
await p.addInitScript(([d,s])=>{localStorage.setItem('wh_device_id',d);localStorage.setItem('wh_sesion',s);localStorage.setItem('wh_last_activity',String(Date.now()));},[DEV,SESION]);
await p.goto(URL,{waitUntil:'domcontentloaded',timeout:45000});await p.waitForTimeout(28000);
console.log(JSON.stringify(await p.evaluate(()=>{
  const o={};
  ['PAS63-001','7752748012052'].forEach(rz=>{
    o[rz]=FamiliaCB.familia(rz).map(x=>({cb:x.codigoBarra,sku:x.skuBase,fc:x.factorConversion,d:String(x.descripcion||'').slice(0,50)}));
  });
  // ¿cuántos productos del catalogo tienen codigo NO numerico?
  const prods=OfflineManager.getProductosCache();
  o.noNumericos = prods.filter(x=>/[A-Za-z]/.test(String(x.codigoBarra||'').replace(/[A-Za-z]+$/,''))).length;
  o.total = prods.length;
  return o;
},[]),null,2));
await b.close();})();
