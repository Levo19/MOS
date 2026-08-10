import { chromium } from 'playwright';
const URL='https://levo19.github.io/warehouseMos-/';
const DEV='7e57c1a0-de1c-4a7e-b0de-c47a10906475';
const SESION=JSON.stringify({idSesion:'LOCAL_TESTCLAUDE',idPersonal:'TEST-CLAUDE',nombre:'PRUEBA CLAUDE',apellido:'CLAUDE',color:'#4f46e5',rol:'MASTER',fechaDia:'2026-08-09',fechaGuardado:new Date().toISOString()});
(async()=>{const b=await chromium.launch({headless:true});const c=await b.newContext({viewport:{width:1280,height:900}});const p=await c.newPage();
p.on('pageerror',e=>console.log('PAGEERROR',e.message));
await p.addInitScript(([d,s])=>{localStorage.setItem('wh_device_id',d);localStorage.setItem('wh_sesion',s);localStorage.setItem('wh_last_activity',String(Date.now()));},[DEV,SESION]);
await p.goto(URL,{waitUntil:'domcontentloaded',timeout:45000});await p.waitForTimeout(28000);
const r=await p.evaluate(()=>{
  const out={};
  out.hasNormCb = typeof window.normCb;
  out.raiz = FamiliaCB.raiz('7758725000036A');
  out.raizPelado = FamiliaCB.raiz('7758725000036');
  const prods = OfflineManager.getProductosCache();
  const prods2 = OfflineManager.getProductosCache();
  out.mismaRef = prods === prods2;
  // reimplementar el índice inline para comparar
  const m = new Map();
  for (const q of prods) {
    const cb = String(q.codigoBarra||'').trim().toUpperCase();
    if(!cb) continue;
    const rz = FamiliaCB.raiz(cb);
    if(!m.has(rz)) m.set(rz,[]);
    m.get(rz).push(cb);
  }
  out.inlineA = m.get('7758725000036') || null;
  out.inlineB = m.get('7750464444799') || null;
  out.moduloA = FamiliaCB.familia('7758725000036').length;
  // qué devuelve familia con la raíz exacta obtenida del propio módulo
  const uno = prods.find(q=>String(q.codigoBarra||'')==='7758725000036A');
  out.unoExiste = !!uno;
  if(uno){ out.unoRaiz = FamiliaCB.raiz(uno.codigoBarra); out.famDeUno = FamiliaCB.familia(uno.codigoBarra).length; }
  out.ambigua = !!FamiliaCB.ambigua('7758725000036');
  return out;
});
console.log(JSON.stringify(r,null,2));
await b.close();})();
