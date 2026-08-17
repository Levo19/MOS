// [845] Test funcional del camino gráfico → costos, sobre el árbol LOCAL.
//
// IMPORTANTE: las RPC que ESCRIBEN dinero (llenarCostosGuia, aplicarCostosCompra,
// quitarCostoCompra) se interceptan y se responden ok:true SIN salir a la red. El test verifica
// que se disparen y con qué, pero no toca un solo costo real de la base. Las lecturas pasan.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';

const ROOT = path.resolve(process.argv[2]);
const MIME = { '.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json',
               '.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon' };
const srv = http.createServer((req,res)=>{ let u=decodeURIComponent(req.url.split('?')[0]); if(u==='/')u='/index.html';
  const f=path.join(ROOT,u);
  if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){res.writeHead(404);return res.end('no');}
  res.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'}); res.end(fs.readFileSync(f)); });
await new Promise(r=>srv.listen(8794,r));

const ok = [], bad = [];
const T = (n, cond, extra) => { (cond ? ok : bad).push(n + (extra ? ' — ' + extra : '')); console.log((cond?'  ✅ ':'  ❌ ') + n + (extra?' — '+extra:'')); };

const b = await chromium.launch();
const ctx = await b.newContext({ viewport:{width:1280,height:900} });
const p = await ctx.newPage();
const errs = [];
p.on('pageerror', e => errs.push(String(e.message)));
await p.addInitScript(dev=>localStorage.setItem('mos_device_id',dev),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8794/', { waitUntil:'domcontentloaded' });
await p.waitForTimeout(6000);
try { await p.click('text=/Entrar a MOS/i', { timeout:4000 }); } catch {}
await p.waitForFunction(()=>{try{return !!MOS;}catch{return false;}},{timeout:60000});

// ── red de contención: nada de escritura sale a Supabase ──
await p.evaluate(() => {
  window.__esc = [];
  const MUT = ['llenarCostosGuia','aplicarCostosCompra','quitarCostoCompra','guardarCostosGuia'];
  const orig = API.post.bind(API);
  API.post = function (accion, payload) {
    if (MUT.includes(accion)) {
      window.__esc.push({ accion, t: Date.now(), payload: JSON.parse(JSON.stringify(payload || {})) });
      return Promise.resolve({ ok: true, data: { items: [] } });
    }
    return orig(accion, payload);
  };
  localStorage.removeItem('mos_p1_costos_eco_v1');
});

// ── abrir la Mesa y entrar a una compra real ──
await p.evaluate(()=>MOS.abrirMesaCompras());
await p.waitForFunction(()=>document.querySelectorAll('#mesaComprasModal [onclick*="_mesaComprasEntrar"]').length>0,{timeout:60000});
// la Mesa precarga las líneas de cada compra en segundo plano; sin ellas el Paso 1 abre vacío
await p.waitForFunction(() => [...document.querySelectorAll('#mesaComprasModal [onclick*="_mesaComprasEntrar"]')]
  .some(el => { const m = el.textContent.match(/(\d+)\s*ítems/); return m && +m[1] >= 3; }), { timeout: 90000 });
const guia = await p.evaluate(() => {
  for (const el of document.querySelectorAll('#mesaComprasModal [onclick*="_mesaComprasEntrar"]')) {
    const m = String(el.getAttribute('onclick')).match(/_mesaComprasEntrar\('([^']+)','([^']+)'\)/);
    const n = el.textContent.match(/(\d+)\s*ítems/);
    if (m && n && +n[1] >= 3) return { fuente: m[1], idGuia: m[2], n: +n[1] };
  }
  return null;
});
if (!guia) { console.log('  ⚠ no hay compras en la ventana — sin datos para probar'); await b.close(); srv.close(); process.exit(1); }
console.log('  guía de prueba: ' + guia.fuente + '_' + guia.idGuia + ' (' + guia.n + ' líneas)');
await p.evaluate(g=>MOS._mesaComprasEntrar(g.fuente,g.idGuia), guia);
await p.waitForFunction(()=>!!document.getElementById('costoGuiaLinea_0'),{timeout:45000});
await p.waitForTimeout(800);

const escribir = async (idx, val) => p.evaluate(([i,v]) => {
  const inp = document.querySelector('#costoGuiaCi_'+i+' input');
  if (!inp) return false;
  inp.focus(); inp.value = String(v);
  inp.dispatchEvent(new Event('input', { bubbles:true }));
  return true;
}, [idx, val]);

// ═══ (4) el readout se coteja con la boleta ═══
console.log('\n[4] readout cantidad × unitario, con IGV y sin IGV');
await escribir(0, 240);
await p.waitForTimeout(300);
const ro = await p.evaluate(()=>{ const e=document.getElementById('costoGuiaSubtot_0'); return e?e.textContent.replace(/\s+/g,' ').trim():''; });
console.log('     leído: "' + ro + '"');
T('muestra la multiplicación (n × S/ …)', /×\s*S\/\s*[\d.]+/.test(ro), null);
T('muestra el total CON IGV', /con IGV/.test(ro));
T('muestra el total SIN IGV', /sin IGV/.test(ro));

// ═══ (1) la × devuelve los chips sin cerrar el modal ═══
console.log('\n[1] la × del monto devuelve los chips de características');
await p.evaluate(()=>{ const i=document.querySelector('#costoGuiaCi_0 input'); if(i){i.blur();} });
await p.waitForTimeout(700);
const tglTrasCosto = await p.evaluate(()=>!!document.getElementById('costoGuiaTgl_0'));
T('con costo puesto los chips se esconden (comportamiento previo intacto)', !tglTrasCosto);
await p.evaluate(()=>{ const x=document.querySelector('#costoGuiaCi_0 .ci-x'); if(x) x.click(); });
await p.waitForTimeout(1200);
const tglTrasX = await p.evaluate(()=>{
  const t=document.getElementById('costoGuiaTgl_0'); if(!t) return null;
  return [...t.querySelectorAll('button,span')].map(e=>e.textContent.replace(/\s+/g,' ').trim()).filter(Boolean);
});
T('los chips VUELVEN al quitar el monto (sin cerrar el modal)', Array.isArray(tglTrasX) && tglTrasX.length >= 4,
  Array.isArray(tglTrasX) ? tglTrasX.join(' | ') : 'no aparecieron');
const inputVacio = await p.evaluate(()=>{const i=document.querySelector('#costoGuiaCi_0 input'); return i? i.value==='' : false;});
T('el campo quedó vacío', inputVacio);

// ═══ (3) escribir rápido y salir no pierde nada ═══
console.log('\n[3] uso rápido: escribir y cerrar de inmediato');
await p.evaluate(()=>{ window.__esc = []; });
const _ecoN = () => p.evaluate(()=>{ try {
  const o = JSON.parse(localStorage.getItem('mos_p1_costos_eco_v1')||'{}');
  return Object.values(o).reduce((a,g)=>a+Object.keys(g||{}).length,0);
} catch(_) { return -1; } });
await escribir(1, 180);
await p.waitForTimeout(60);                       // MUY por debajo del debounce
// el eco se escribe AL TECLEAR: es el seguro que cubre la ventana hasta que el servidor confirme
T('el eco local guarda lo tecleado al instante', (await _ecoN()) > 0, (await _ecoN()) + ' línea(s) en eco');
await p.evaluate(()=>MOS.opsSalirModoCostos());   // se cierra al toque, como hace el dueño
await p.waitForTimeout(1500);
const esc = await p.evaluate(()=>window.__esc.map(x=>x.accion));
T('cerrar dispara el guardado pendiente (no se pierde el monto)', esc.length > 0, 'RPC disparadas: ' + (esc.join(', ') || 'NINGUNA'));
// y una vez confirmado, el eco se retira: la fuente vuelve a ser el servidor
T('confirmado el guardado, el eco se limpia solo', (await _ecoN()) === 0, (await _ecoN()) + ' línea(s) en eco');

// reabrir y comprobar que el monto sigue ahí
await p.evaluate(g=>MOS._mesaComprasEntrar(g.fuente,g.idGuia), guia);
await p.waitForFunction(()=>!!document.getElementById('costoGuiaLinea_1'),{timeout:45000});
await p.waitForTimeout(1200);
const reabierto = await p.evaluate(()=>{const i=document.querySelector('#costoGuiaCi_1 input'); return i? i.value : '';});
T('al reabrir, el monto recién escrito sigue ahí (no aparece vacío)', String(reabierto) !== '' && parseFloat(reabierto) > 0,
  'campo = "' + reabierto + '"');

// ═══ (2) del gráfico a costos y de vuelta al gráfico ═══
console.log('\n[2] curva → costos → cerrar → vuelve a la curva');
await p.evaluate(()=>MOS.opsSalirModoCostos());
await p.waitForTimeout(900);
await p.evaluate(()=>{
  window._paso2Filas = [{ nombre:'PRUEBA', precioActual:14.5,
    x:{ idCanonico:'IDPRO0000035', descripcion:'PRUEBA', costoNuevo:13.2 } }];
  return MOS.curvaOverlay(0);
});
await p.waitForTimeout(6000);
T('la curva abrió', await p.evaluate(()=>!!document.getElementById('curvaOverlay')));
await p.evaluate(g=>MOS.curvaIrACostos(g.idGuia), guia);
await p.waitForFunction(()=>!!document.getElementById('costoGuiaLinea_0'),{timeout:45000});
await p.waitForTimeout(600);
T('desde la curva se entró al Paso 1', await p.evaluate(()=>{
  const m=document.getElementById('modalCostosGuiaUnif'); return !!m && !m.classList.contains('hidden'); }));
T('la curva se cerró al entrar (no queda encima)', await p.evaluate(()=>!document.getElementById('curvaOverlay')));
await p.evaluate(()=>MOS.opsSalirModoCostos());
await p.waitForTimeout(7000);
T('al cerrar costos REGRESA a la curva (no al catálogo)', await p.evaluate(()=>!!document.getElementById('curvaOverlay')));

// ═══ que la marca de regreso no quede pegada ═══
console.log('\n[extra] la marca de regreso no se queda pegada');
await p.evaluate(()=>MOS._curvaOverlayCerrar());
await p.waitForTimeout(500);
await p.evaluate(g=>MOS._mesaComprasEntrar(g.fuente,g.idGuia), guia);
await p.waitForFunction(()=>!!document.getElementById('costoGuiaLinea_0'),{timeout:45000});
await p.evaluate(()=>MOS.opsSalirModoCostos());
await p.waitForTimeout(3000);
T('entrar por la Mesa y salir NO abre la curva', await p.evaluate(()=>!document.getElementById('curvaOverlay')));

console.log('\n  errores de página: ' + (errs.length ? errs.slice(0,3).join(' | ') : 'ninguno'));
T('sin errores de página', errs.length === 0);
console.log('\n  ' + ok.length + ' ✅   ' + bad.length + ' ❌');
await b.close(); srv.close();
process.exit(bad.length ? 1 : 0);
