// [848] Cargar un crédito a un TURNO desde MOS (el rescate). La asignación real se intercepta:
// se verifica qué viaja y qué se pinta, sin tocar la deuda de nadie.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = path.resolve(process.argv[2]);
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8798,r));
const ok=[],bad=[]; const T=(n,c,x)=>{(c?ok:bad).push(n);console.log((c?'  ✅ ':'  ❌ ')+n+(x?' — '+x:''));};
const b=await chromium.launch(); const p=await (await b.newContext({viewport:{width:1280,height:900}})).newPage();
const errs=[]; p.on('pageerror',e=>errs.push(String(e.message)));
await p.addInitScript(d=>localStorage.setItem('mos_device_id',d),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8798/',{waitUntil:'domcontentloaded'}); await p.waitForTimeout(4000);
try{await p.click('text=/Entrar a MOS/i',{timeout:4000});}catch{}
await p.waitForFunction(()=>{try{return !!MOS;}catch{return false;}},{timeout:60000});

// blindaje: la asignación NO se escribe · y se espía que se pida CLAVE ADMIN antes
await p.evaluate(()=>{
  window.__asig=[]; const o=API.post.bind(API);
  API.post=function(a,pl){
    if(a==='creditoAsignar'||a==='creditoDesasignar'){
      window.__asig.push({a,pl:JSON.parse(JSON.stringify(pl||{}))});
      return Promise.resolve({ok:true,data:{nombre:'(simulado)',idDia:pl.idDia}});
    }
    // el teclado de autorización valida contra el servidor; en la prueba se acepta la clave
    // ficticia para poder ejercitar el flujo completo SIN una clave real ni escribir nada.
    if(a==='verificarClaveAdmin'){
      window.__asig.push({a,pl:{accion:(pl||{}).accion||''}});
      return Promise.resolve({ autorizado:true, valido:true, ok:true, nombre:'TEST', rol:'ADMIN',
                              tier:2, nivel:3, idAccion:'TEST-1' });
    }
    return o(a,pl);
  };
});

await p.evaluate(()=>MOS.nav('cajas'));
await p.waitForTimeout(12000);
// asegurar que la baraja de créditos esté cargada
await p.evaluate(()=>{ try { MOS._cjCargarCreditosPendientes && MOS._cjCargarCreditosPendientes(); } catch(_){} });
await p.waitForTimeout(4000);
const gr = await p.evaluate(()=>({
  grupos: (MOS.__t||{}).x, n: document.querySelectorAll('.cj-carta-mano').length }));
// buscar un ticket de crédito vivo por la mesa
await p.evaluate(()=>{ try{ MOS.cjRepartirMano(); }catch(_){} });
await p.waitForTimeout(1500);
let tk = await p.evaluate(()=>{
  const el=[...document.querySelectorAll('[onclick*="cjAbrirDetalleCarta"]')][0];
  if(!el) return null;
  const m=String(el.getAttribute('onclick')).match(/cjAbrirDetalleCarta\('([^']+)'\)/);
  return m?m[1]:null;
});
// si el DOM no lo expone (baraja animada), tomarlo del estado interno vía un ticket vivo real
if(!tk){ tk = await p.evaluate(async ()=>{
  const r = await API.post('meGetCreditosPendientes',{diasAtras:365});
  const d = (r&&r.data)?r.data:(r||{});
  for(const g of (d.grupos||[])) for(const t of (g.tickets||[]))
    if(!t.estadoCobro || t.estadoCobro==='VIVO') return t.idVenta;
  return null;
}); }
if(!tk){ console.log('  ⚠ no hay tickets de crédito vivos para probar'); await b.close(); srv.close(); process.exit(0); }
console.log('  ticket de prueba: '+tk);
// [850] el boton tiene que estar en la CARTA de la mesa, sin abrir el detalle
const enMesa = await p.evaluate(()=>{
  const btns=[...document.querySelectorAll('.cj-carta-tk-btn')];
  const sellos=[...document.querySelectorAll('.cj-carta-tk')];
  return { n: btns.length, txt: btns[0]?btns[0].textContent.trim():'', sellos: sellos.length };
});
console.log('     en la mesa: '+enMesa.n+' boton(es) "'+enMesa.txt+'" · '+enMesa.sellos+' ya asignado(s)');
T('la carta de la mesa muestra ASIGNAR sin abrir el detalle', enMesa.n>0 || enMesa.sellos>0, JSON.stringify(enMesa));
// [850] no debe pintarse en dias ya liquidados: seria un boton que el servidor rechaza
const abiertos = await p.evaluate(async ()=>{
  const r=await API.post('meGetCreditosPendientes',{diasAtras:365});
  const d=(r&&r.data)?r.data:(r||{});
  let vivos=0, conTurno=0;
  for(const g of (d.grupos||[])) for(const t of (g.tickets||[]))
    if(!t.estadoCobro || t.estadoCobro==='VIVO'){ vivos++; if(t.turnosAbiertos) conTurno++; }
  return {vivos, conTurno};
});
console.log('     creditos vivos: '+abiertos.vivos+' · con turno abierto ese dia: '+abiertos.conTurno);
T('solo se ofrece donde hay turno abierto (no en dias ya liquidados)',
  enMesa.n === abiertos.conTurno, enMesa.n+' boton(es) vs '+abiertos.conTurno+' dia(s) util(es)');
T('el boton dice ASIGNAR (la palabra del dueno)', /ASIGNAR/i.test(enMesa.txt) || enMesa.n===0, enMesa.txt);

await p.evaluate(id=>MOS.cjAbrirDetalleCarta(id), tk);
await p.waitForTimeout(900);
const hayBtn = await p.evaluate(()=>!!document.querySelector('.cj-det-tk-btn') || !!document.querySelector('.cj-det-tk-quitar'));
T('el detalle ofrece cargar el crédito a un trabajador', hayBtn);

await p.evaluate(id=>MOS.cjTrabajadorAbrir(id), tk);
await p.waitForFunction(()=>{const b=document.querySelector('#cjTkOvl .cjtk-body');return b && !/buscando/.test(b.textContent);},{timeout:30000});
const filas = await p.evaluate(()=>[...document.querySelectorAll('.cjtk-row')].map(e=>e.textContent.replace(/\s+/g,' ').trim()));
console.log('     turnos ofrecidos: '+(filas.length?filas.join(' | '):'(ninguno)'));
T('el selector lista turnos de ESE día', filas.length>0 || /ningún turno abierto/.test(await p.evaluate(()=>document.querySelector('#cjTkOvl .cjtk-body').textContent)));
T('cada fila muestra el turno, no solo el nombre', filas.every(f=>/CAJERO|VENDEDOR|ALMACENERO/.test(f)) || !filas.length,
  filas[0]||'—');
T('sin desborde horizontal con el overlay abierto',
  await p.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth<=1));

if (filas.length) {
  await p.evaluate(()=>document.querySelector('.cjtk-row').click());
  // [851] tiene que aparecer el teclado de AUTORIZACIÓN antes de tocar dinero
  let pidioClave = false;
  try {
    await p.waitForFunction(()=>{ const m=document.getElementById('modalAdminAuth');
      return m && !m.classList.contains('hidden'); }, { timeout: 12000 });
    pidioClave = true;
  } catch(_) {}
  const ctxAuth = await p.evaluate(()=>{ const e=document.getElementById('aamContext');
    return e?e.textContent.replace(/\s+/g,' ').trim():''; });
  T('pide CLAVE ADMIN antes de asignar (queda auditado)', pidioClave, ctxAuth || '(no apareció el teclado)');
  console.log('     contexto auditado: "'+ctxAuth+'"');
  // teclear 8 dígitos y confirmar
  if (pidioClave) {
    await p.evaluate(()=>{ '12345678'.split('').forEach(d=>MOS._aamPress(d)); });
    await p.waitForTimeout(400);
    await p.evaluate(()=>{ try { MOS._aamConfirmar(); } catch(_){} });
    await p.waitForTimeout(1500);
  }
  const env = await p.evaluate(()=>window.__asig.filter(x=>x.a==='creditoAsignar'));
  console.log('     enviado: '+JSON.stringify(env));
  T('al elegir se manda idVenta + idDia (el TURNO, no un nombre)',
    env.length>0 && env[0].pl.idVenta===tk && /^LDIA-/.test(String(env[0].pl.idDia||'')));
  T('la clave viaja al servidor', env.length>0 && env[0].pl.claveAdmin==='12345678',
    env.length?('claveAdmin="'+env[0].pl.claveAdmin+'"'):'(sin envio)');
  // [851] optimista: la carta ya quedó celeste con el chip 👤 y su ✕, sin esperar recarga
  const pintado = await p.evaluate(()=>{
    const el=document.querySelector('.cj-mesa-carta.cj-mesa-carta-tk');
    if(!el) return null;
    const c=el.querySelector('.cj-carta-tk-chip');
    return { celeste:true, chip: c?c.textContent.replace(/\s+/g,' ').trim():'', x: !!el.querySelector('.cj-carta-tk-x'),
             quedaBoton: !!el.querySelector('.cj-carta-tk-btn') };
  });
  console.log('     carta tras asignar: '+JSON.stringify(pintado));
  T('la carta quedó CELESTE al instante (optimista)', !!pintado);
  T('el chip 👤 muestra el nombre arriba a la izquierda', !!(pintado && /👤/.test(pintado.chip) && pintado.chip.length>2), pintado?pintado.chip:'');
  T('el chip trae la ✕ para desasignar', !!(pintado && pintado.x));
  T('el botón ASIGNAR desaparece cuando ya tiene dueño', !!(pintado && !pintado.quedaBoton));

  // desasignar deja la carta limpia
  await p.evaluate(id=>{ MOS.cjTrabajadorQuitar(id); }, tk);   // sin await: la promesa espera al modal
  let pidioClave2 = false;
  try {
    await p.waitForFunction(()=>{ const m=document.getElementById('modalAdminAuth');
      return m && !m.classList.contains('hidden'); }, { timeout: 12000 });
    pidioClave2 = true;
    await p.evaluate(()=>{ '12345678'.split('').forEach(d=>MOS._aamPress(d)); });
    await p.waitForTimeout(400);
    await p.evaluate(()=>{ try { MOS._aamConfirmar(); } catch(_){} });
  } catch(_) {}
  await p.waitForTimeout(2200);
  const limpio = await p.evaluate(()=>{
    const el=document.querySelector('.cj-mesa-carta[data-tk]:not(.cj-mesa-carta-cobrada)');
    const sel=[...document.querySelectorAll('.cj-mesa-carta')].find(e=>e.classList.contains('cj-mesa-carta-tk'));
    return { sigueCeleste: !!sel, hayBoton: !!document.querySelector('.cj-carta-tk-btn') };
  });
  T('al quitar, la carta vuelve a quedar limpia y con ASIGNAR', !limpio.sigueCeleste && limpio.hayBoton,
    JSON.stringify(limpio));
  T('quitar también pide clave (queda auditado)', pidioClave2);
  T('el overlay se cierra tras elegir', await p.evaluate(()=>!document.getElementById('cjTkOvl')));
}
console.log('\n  errores de página: '+(errs.length?errs.slice(0,3).join(' | '):'ninguno'));
T('sin errores de página', errs.length===0);
console.log('\n  '+ok.length+' ✅   '+bad.length+' ❌');
await b.close(); srv.close();
process.exit(bad.length?1:0);
