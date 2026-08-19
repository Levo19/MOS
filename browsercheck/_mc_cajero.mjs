// [MODO CAJERO v2] Prueba del template REAL de la estación de cobro.
//
// Por qué así: el bloque vive tras un `v-if="modoCajero"`, así que en el arranque normal NUNCA
// se renderiza — un binding mal escrito no aparecería hasta que el cajero abra el modo, en
// producción y frente a un cliente. Y el build de producción de Vue deja `_instance` en null,
// así que no hay forma de forzarlo desde afuera.
//
// Entonces se extrae el template TAL CUAL se despacha, se monta en una app aislada con datos
// de mentira, y se comprueba que compile, que pinte y que las interacciones hagan lo suyo.
// Ningún ticket real se toca. Aparte, se prueba el parser del QR contra las cadenas SUNAT
// reales — que es la parte que decide qué ticket se cobra.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';

const ME = 'C:/Users/ISO/ecosistema MOS/MosExpress/index.html';
const src = fs.readFileSync(ME, 'utf8');

// ── extraer el template tal cual está en el archivo ──
const ini = src.indexOf('<div v-if="modoCajero" id="mcRoot"');
if (ini < 0) { console.log('  --  no encontre el template del modo cajero'); process.exit(1); }
const fin = src.indexOf('\n    <!-- MODAL COBRO (cajero cobra ticket emitido por vendedor) -->', ini);
let TPL = src.slice(ini, fin).trim();
TPL = TPL.replace('v-if="modoCajero"', 'v-if="true"');   // en la prueba siempre visible

// ── extraer el CSS del modo cajero ──
const cini = src.indexOf('#mcRoot{--voz:');
const cfin = src.indexOf('</style>', cini);
const CSS = src.slice(src.lastIndexOf('/*', cini), cfin);

// ── extraer la funcion que decide QUE ticket se cobra ──
const fini = src.indexOf('const mcClaveDeEscaneo = (q) => {');
const ffin = src.indexOf('};', src.indexOf('return t.toUpperCase();', fini)) + 2;
const FN = src.slice(fini, ffin);

// ── los datos compartidos: el mock de acá no puede inventar una forma ──
// `config.estacion` es un objeto y una vez lo traté como texto: el .toUpperCase()
// pasó todas las pruebas y reventó al abrir la caja. Así que cada acceso a un objeto
// compartido (config, venta) que use el template tiene que existir TAMBIÉN fuera de
// este bloque, en el resto de la app, que es donde vive la forma verdadera.
const restoApp = src.slice(0, ini) + src.slice(fin);
const rutas = [...new Set([...TPL.matchAll(/\b(config|venta|cajeroTicketActual)((?:\??\.[A-Za-z_][A-Za-z0-9_]*)+)/g)]
  .map(m => m[1] + m[2]))];
const inventadas = rutas.filter(r => {
  const partes = r.replace(/\?/g, '').split('.');
  const raiz = partes[0], hojas = partes.slice(1);
  // `config` es un objeto único con nombre propio: se exige la misma ruta literal.
  // Un ticket, en cambio, se llama `venta`, `v` o `t` según el rincón de la app, así
  // que del ticket se exige que el campo exista colgado de ALGO — no del mismo nombre.
  const par  = hojas.length >= 2 ? hojas[hojas.length-2] : (raiz === 'config' ? 'config' : null);
  const hoja = hojas[hojas.length-1];
  const re = par ? new RegExp('\\b' + par + '\\??\\.' + hoja + '\\b') : new RegExp('\\??\\.' + hoja + '\\b');
  return !re.test(restoApp);
});

const PAGINA = `<!doctype html><html><head><meta charset="utf-8">
<script src="https://unpkg.com/vue@3.4.21/dist/vue.global.prod.js"><\/script>
<style>body{margin:0;background:#03101a}${CSS}</style></head><body>
<div id="app">${TPL}</div>
<script>
${FN}
window.mcClaveDeEscaneo = mcClaveDeEscaneo;
const { createApp, ref, computed } = Vue;
window.__vm = createApp({
  setup(){
    const tickets = ref([
      { id:'t1', correlativo:'NVM2-000531', tipo:'NOTA_DE_VENTA', total:5.6, timestamp:Date.now(),
        raw_data:{auth:{vendedor:'Mia'}} },
      { id:'t2', correlativo:'FM01-000053', tipo:'FACTURA', total:12.0, timestamp:Date.now(),
        raw_data:{auth:{vendedor:'Shadya'}} },
      { id:'t3', correlativo:'BM01-000335', tipo:'BOLETA', total:3.5, timestamp:Date.now(),
        raw_data:{auth:{vendedor:'Jhoselyn'}} }
    ]);
    const mcYapes = ref([{ id:1, monto:5.6, pagador:'OLIVIA RAMOS', hora:'14:31', min:1,
                           estado:'NUEVO', idVenta:'', ilegible:false }]);
    const cajeroTicketActual = ref(null);
    const mcEstado = ref('espera');
    const mcMixEfe = ref('');
    const mcMoney = v => 'S/ ' + (parseFloat(v)||0).toFixed(2);
    const mcDig = v => String((parseFloat(v)||0).toFixed(2)).split('');
    const par = m => mcYapes.value.find(y => y.estado==='NUEVO' && !y.ilegible &&
        Math.round((+y.monto||0)*10) === Math.round((+m||0)*10));
    const mcMixEfeNum = computed(()=>Math.min(parseFloat(mcMixEfe.value||0)||0, cajeroTicketActual.value?.total||0));
    const mcMixVir = computed(()=>Math.max(0,+(((cajeroTicketActual.value?.total||0)-mcMixEfeNum.value).toFixed(2))));
    return {
      // La forma REAL: config.estacion es el objeto de la estación, no su nombre.
      // Ponerle un texto acá dejaba pasar un .toUpperCase() sobre un objeto — y eso
      // reventaba recién al abrir el modo cajero, en la caja.
      config:{ estacion:{ Estacion_Nombre:'Caja 02 Mercado', PrintNode_ID:'123' },
               vendedor:'Javier Quispe Mamani', zona:'ZONA-02', zonaId:'ZONA-02', esCajero:true },
      cajeroBusqueda: ref(''), cajeroCamara: ref(false),
      cajeroTicketActual, mcEstado, mcYapes, mcMixEfe,
      mcEsperando: ref([{ idVenta:'v9', correlativo:'NVM2-000540', monto:8, hora:'14:10' }]),
      mcSobrio: ref(false), mcLatente: ref(false), mcProcesando: ref(false),
      mcReloj: ref('14:32'), mcHechoMonto: ref(5.6), mcHechoTxt: ref('EFECTIVO'),
      mcReja: ref(null), mcAura: ref(null), mcFlash: ref(null), mcScan: ref(null), mcGlove: ref(null), mcDrag: ref(null),
      // v6: cola, órbita, gestos
      mcSiguientes: computed(()=>tickets.value.filter(v=>v.id!==(cajeroTicketActual.value&&cajeroTicketActual.value.id)).slice(0,2)),
      // v7: órbitas — pendientes + historia, y Yapes; posiciones repartidas por ángulo
      mcEscEl: ref(null),
      mcOrbTk: computed(()=>{ const hist=[{id:'h1',correlativo:'NVM2-000520',tipo:'NOTA_DE_VENTA',total:9,timestamp:Date.now()-3600e3,cobrado:true,raw_data:{auth:{vendedor:'Mia'}}},
                                          {id:'h2',correlativo:'NVM2-000519',tipo:'NOTA_DE_VENTA',total:14.5,timestamp:Date.now()-5400e3,cobrado:true,raw_data:{auth:{vendedor:'Mia'}}}];
        const todos=tickets.value.map(v=>({v,pend:true})).concat(hist.map(v=>({v,pend:false}))); const n=todos.length;
        return todos.map((o,i)=>{ const a=(-90+i*360/n)*Math.PI/180; const x=Math.round(430*Math.cos(a)), y=Math.round(250*Math.sin(a));
          const cur=cajeroTicketActual.value&&cajeroTicketActual.value.id; const sigV=tickets.value.find(v=>v.id!==cur);
          return Object.assign(o,{sig:!!(sigV&&o.v.id===sigV.id&&o.pend),st:{transform:'translate3d(calc(-50% + '+x+'px), calc(-50% + '+y+'px), 0)'}}); }); }),
      mcOrbYp: computed(()=>{ const ys=[...mcYapes.value,{id:2,monto:12,pagador:'JUAN PEREZ',hora:'14:20',min:12,estado:'MATCHEADO',idVenta:'h1',ilegible:false},{id:3,monto:7.5,pagador:'ANA',hora:'14:00',min:32,estado:'NUEVO',idVenta:'',ilegible:false}];
        const n=ys.length; return ys.map((y,i)=>{ const a=(90+180/n - i*360/n)*Math.PI/180; const x=Math.round(560*Math.cos(a)), y2=Math.round(320*Math.sin(a));
          return {y, st:{transform:'translate3d(calc(-50% + '+x+'px), calc(-50% + '+y2+'px), 0)'}}; }); }),
      mcTocarYape: (y) => { window.__tocoYape = y.id; },
      mcLineas: ref([{nombre:'AJI PANCA ENTERO GRANEL',cantidad:0.25,subtotal:3.5,um:'KGM'},{nombre:'AZUCAR RUBIA 1KG',cantidad:2,subtotal:6.6,um:'NIU'},{nombre:'FIDEO SPAGHETTI 500GR',cantidad:1,subtotal:2.4,um:'NIU'}]),
      mcCant: it => { const n=parseFloat(it.cantidad)||0, um=String(it.um||'NIU').toUpperCase(); return (Number.isInteger(n)?n:n.toFixed(3).replace(/0+$/,'').replace(/[.]$/,''))+(um==='KGM'?' kg':um==='NIU'?'×':' '+um.toLowerCase()); },
      mcCorto: n => { const t=String(n||'').trim(); return t.length>26?t.slice(0,25)+'…':t; },
      // en el mock, apoyar el dedo toma el ticket (la app real distingue toque de arrastre por distancia)
      mcDragIni: (e,v) => { window.__drag = { id:v.id, x:e.clientX }; cajeroTicketActual.value=v; mcEstado.value='cobro'; },
      mcFlingIni: (e) => { window.__fling = true; },
      mcPendientes: tickets,
      mcTotalPend: computed(()=>tickets.value.reduce((a,t)=>a+t.total,0)),
      mcYapesLibres: computed(()=>mcYapes.value.filter(y=>y.estado==='NUEVO').length),
      mcYapeDelTicket: computed(()=>cajeroTicketActual.value?par(cajeroTicketActual.value.total):null),
      mcMixEfeNum, mcMixVir,
      mcMixPct: computed(()=>{const t=cajeroTicketActual.value?.total||0;return t?Math.round(mcMixEfeNum.value/t*100):0;}),
      mcMixValido: computed(()=>mcMixEfeNum.value>0 && mcMixEfeNum.value<(cajeroTicketActual.value?.total||0)),
      mcMoney, mcDigitos: mcDig,
      mcPrimerNombre: n => String(n||'').trim().split(/\\s+/)[0]||'',
      mcTipoCorto: t => t==='FACTURA'?'FAC':t==='BOLETA'?'BOL':'N.V.',
      mcHora: v => new Date(v.timestamp).toTimeString().slice(0,5),
      mcCalza: v => !!par(v.total),
      mcYapeCalza: y => y.estado==='NUEVO' && tickets.value.some(v=>Math.round(v.total*10)===Math.round(y.monto*10)),
      mcTomar: v => { cajeroTicketActual.value=v; mcEstado.value='cobro'; },
      mcCobrar: m => { window.__cobro = { metodo:m, virtual:mcMixVir.value }; mcEstado.value='hecho'; },
      mcAbrirMixto: () => { mcMixEfe.value=''; mcEstado.value='mixto'; },
      mcTecla: k => { if(k==='←') mcMixEfe.value=mcMixEfe.value.slice(0,-1);
                      else if(k==='.'){ if(!mcMixEfe.value.includes('.')) mcMixEfe.value=(mcMixEfe.value||'0')+'.'; }
                      else mcMixEfe.value=(mcMixEfe.value+k).replace(/^0(\\d)/,'$1'); },
      mcToggleCamara: () => { window.__toques = (window.__toques||0) + 1; },
      buscarTicketCajero: () => {},
      cerrarModoCajero: () => { window.__cerro = (window.__cerro||0) + 1; }
    };
  }
}).mount('#app');
window.__err = null;
addEventListener('error', e => { window.__err = String(e.message); });
<\/script></body></html>`;

const srv = http.createServer((q,r)=>{ r.writeHead(200,{'Content-Type':'text/html; charset=utf-8'}); r.end(PAGINA); });
await new Promise(r=>srv.listen(8807,r));

const ok=[], bad=[];
const T=(n,c,x)=>{ (c?ok:bad).push(n); console.log((c?'  OK  ':'  --  ')+n+(x?'  ·  '+x:'')); };

const b = await chromium.launch();
const p = await (await b.newContext({ viewport:{width:1280,height:800} })).newPage();
const errs=[]; p.on('pageerror', e=>errs.push(String(e.message)));
p.on('console', m => { if (m.type()==='error' || /\[Vue warn\]/.test(m.text())) errs.push(m.text().slice(0,180)); });
await p.goto('http://127.0.0.1:8807/', { waitUntil:'domcontentloaded' });
await p.waitForTimeout(1400);

// ── 0. la forma de los datos compartidos ──
console.log('     rutas usadas: ' + rutas.join(', '));
T('no inventa campos de config/venta que la app no tenga',
  inventadas.length === 0, inventadas.join(', '));

// ── 1. el template compila y pinta ──
const v1 = await p.evaluate(`(() => { const r=document.getElementById('mcRoot'); if(!r) return null;
  return { tickets:r.querySelectorAll('.mc-tk.pend').length, hist:r.querySelectorAll('.mc-tk.hist').length,
           calza:r.querySelectorAll('.mc-tk.calza').length,
           yapes:r.querySelectorAll('.mc-yp').length, yUsado:r.querySelectorAll('.mc-yp.usado').length,
           anillos:r.querySelectorAll('.mc-anillo').length, riel:!!r.querySelector('.mc-riel'), rio:!!r.querySelector('.mc-rio'),
           posiciones:[...r.querySelectorAll('.mc-tk')].map(e=>e.style.transform).filter(Boolean).length,
           hud:!!r.querySelector('.mc-hud'),
           camOn:!!r.querySelector('.mc-ic.on'), esperando:!!r.querySelector('.mc-esperando'),
           mustaches:(r.innerHTML.match(/\\{\\{/g)||[]).length,
           caja:(r.querySelector('.mc-caja')||{}).textContent||'',
           total:'' }; })()`);
console.log('     ' + JSON.stringify(v1));
T('el template compila y pinta', !!v1);
T('sin bindings rotos (cero mustaches sin procesar)', !!v1 && v1.mustaches===0);
T('los 3 pendientes orbitan encendidos y 2 cobrados apagados (historia)', !!v1 && v1.tickets===3 && v1.hist===2, v1.tickets+' pend · '+v1.hist+' hist');
T('marca el ticket que calza con un Yape', !!v1 && v1.calza===1);
T('los Yapes orbitan afuera; el atado va apagado', !!v1 && v1.yapes===3 && v1.yUsado===1, v1.yapes+' yapes · '+v1.yUsado+' atado');
T('hay dos anillos y ya no hay riel ni río', !!v1 && v1.anillos===2 && !v1.riel && !v1.rio);
T('cada satélite tiene su posición en el anillo', !!v1 && v1.posiciones===5, v1.posiciones+' posicionados');
T('arranca en el radar y con la camara APAGADA', !!v1 && v1.hud && !v1.camOn);
T('la franja "esperando su Yape" aparece', !!v1 && v1.esperando);
// (el total pendiente ya no se muestra como cabecera de un riel: vive en el chip "N por cobrar")
T('la barra dice qué caja es y quién la atiende',
  !!v1 && /CAJA 02 MERCADO/.test(v1.caja) && /Javier/.test(v1.caja) && !/\[object/.test(v1.caja),
  v1 ? v1.caja.replace(/\s+/g,' ').trim() : '');

// ── 2. tomar un ticket ──
await p.evaluate(`(() => { const el=document.querySelectorAll('#mcRoot .mc-tk')[0]; const r=el.getBoundingClientRect();
  const op={bubbles:true,cancelable:true,clientX:r.left+r.width/2,clientY:r.top+r.height/2,pointerType:'touch',isPrimary:true,pointerId:7};
  el.dispatchEvent(new PointerEvent('pointerdown',op)); el.dispatchEvent(new PointerEvent('pointerup',op)); })()`);
await p.waitForTimeout(500);
const v2 = await p.evaluate(`(() => { const r=document.getElementById('mcRoot');
  return { monto:(r.querySelector('.mc-monto')||{}).textContent||'', bts:r.querySelectorAll('.mc-bt').length,
           yape:(r.querySelector('.mc-coyape')||{}).textContent||'',
           destaca:!!r.querySelector('.mc-bt.vir.destaca'), digs:r.querySelectorAll('.mc-dig').length }; })()`);
console.log('     ' + JSON.stringify(v2));
T('al tocar el ticket muestra el monto grande', /5\.60/.test(v2.monto.replace(/\s+/g,'')));
T('el monto se materializa digito por digito', v2.digs===4, v2.digs+' digitos');
T('ofrece los tres metodos, sin vuelto', v2.bts===3);
T('avisa que ya llego el Yape de ese monto', /OLIVIA/.test(v2.yape), v2.yape.replace(/\s+/g,' ').trim());
T('resalta VIRTUAL cuando hay Yape esperando', v2.destaca);
// ── v6: cola, órbita, gestos ──
const v6 = await p.evaluate(`(() => { const r=document.getElementById('mcRoot');
  return { sig:r.querySelectorAll('.mc-tk.sig').length,
           sigCorr:(r.querySelector('.mc-tk.sig .mc-tkc')||{}).textContent||'',
           sigNoEsActual:!((r.querySelector('.mc-tk.sig .mc-tkc')||{}).textContent||'').includes('NVM2-000531'),
           orb:r.querySelectorAll('.mc-orbita .mc-orb').length,
           orbTxt:(r.querySelector('.mc-orbita .mc-orb')||{}).textContent||'',
           glove:!!r.querySelector('.mc-glove'), drag:!!r.querySelector('.mc-drag'), scan:!!r.querySelector('.mc-scan'),
           dragRegistrado:!!(window.__drag && window.__drag.id==='t1') }; })()`);
console.log('     v6: ' + JSON.stringify(v6));
T('el próximo pendiente lleva la etiqueta SIGUIENTE en el anillo (y no es el que está en mano)', v6.sig===1 && v6.sigNoEsActual, v6.sigCorr.replace(/\s+/g,' '));
T('los productos del ticket orbitan el monto', v6.orb===3, v6.orb+' anotaciones');
T('la anotación trae cantidad, nombre y monto', /0\.25 kg.*AJI PANCA.*S\/ 3\.50/.test(v6.orbTxt.replace(/\s+/g,' ')), v6.orbTxt.replace(/\s+/g,' ').trim());
T('el guante, la estela de arrastre y el barrido existen', v6.glove && v6.drag && v6.scan);
T('tocar el ticket entra por el gesto (pointerdown), no por click', v6.dragRegistrado);

// ── 3. MIXTO ──
await p.evaluate(`document.querySelector('#mcRoot .mc-bt.mix').click()`);
await p.waitForTimeout(400);
await p.evaluate(`(() => { const t=[...document.querySelectorAll('#mcRoot .mc-te')];
  t.find(x=>x.textContent.trim()==='2').click();
  t.find(x=>x.textContent.trim()===',').click();
  t.find(x=>x.textContent.trim()==='6').click(); })()`);
await p.waitForTimeout(400);
const v3 = await p.evaluate(`(() => { const r=document.getElementById('mcRoot');
  const b=[...r.querySelectorAll('.mc-liq b')].map(x=>x.textContent.trim());
  const w=[...r.querySelectorAll('.mc-liq i')].map(x=>x.style.width);
  return { teclas:r.querySelectorAll('.mc-te').length, barras:b, anchos:w,
           ok:!r.querySelector('.mc-te.ok').disabled }; })()`);
console.log('     mixto: ' + JSON.stringify(v3));
T('el teclado numerico aparece', v3.teclas>=12);
T('reparte efectivo y virtual solo', v3.barras[0]==='S/ 2.60' && v3.barras[1]==='S/ 3.00', v3.barras.join('  +  '));
T('las barras liquidas muestran la proporcion', v3.anchos[0]==='46%' && v3.anchos[1]==='54%', v3.anchos.join(' / '));
T('habilita cobrar con reparto valido', v3.ok);

await p.evaluate(`document.querySelector('#mcRoot .mc-te.ok').click()`);
await p.waitForTimeout(400);
const v4 = await p.evaluate(`(() => ({ cobro:window.__cobro,
  sello:!!document.querySelector('#mcRoot .mc-sello') }))()`);
console.log('     cobro: ' + JSON.stringify(v4));
T('el cobro manda MIXTO con su parte virtual', !!(v4.cobro && v4.cobro.metodo==='MIXTO' && Math.abs(v4.cobro.virtual-3)<0.001),
  v4.cobro?JSON.stringify(v4.cobro):'(no llego)');
T('muestra el sello COBRADO', v4.sello);

// ── 4. el parser del QR: lo que decide QUE ticket se cobra ──
const casos = await p.evaluate(`(() => {
  const f = window.mcClaveDeEscaneo;
  return {
    // la cadena REAL que imprime NubeFact — con espacios alrededor de cada barra
    sunatReal   : f('20610714057 | 01 | FM02 | 000079 | 4.56 | 35.00 | 18/08/2026 | 6 | 10736984836 | pTp8GwBDfWZgKloBwDPrplIZ9iCm270eEPDMMP19ZrQ= |'),
    // el lector en teclado ES-LatAm puede mandar otra cosa por la barra
    barraRara   : f('20610714057 ° 01 ° FM01 ° 000053 ° 1.83 ° 12.00 ° 18/08/2026'),
    numeroCorto : f('20610714057|03|BM01|335|2.13|17.00|18/08/2026|1|22264311|x'),
    sunatFactura: f('20610714057|01|FM01|000053|1.83|12.00|18/08/2026|'),
    sunatBoleta : f('20610714057|03|BM01|000335|0.53|3.50|18/08/2026|'),
    conEspacios : f(' 20610714057 | 01 | FM01 | 000053 | 1.83 '),
    notaVenta   : f('NVM2-000531'),
    minuscula   : f('nvm2-000531'),
    basura      : f('holaquetal')
  }; })()`);
console.log('     parser: ' + JSON.stringify(casos));
T('la cadena REAL de NubeFact (con espacios) da su correlativo', casos.sunatReal==='FM02-000079', casos.sunatReal);
T('con la barra mangleada por el teclado igual resuelve', casos.barraRara==='FM01-000053', casos.barraRara);
T('numero sin ceros a la izquierda se completa a 6', casos.numeroCorto==='BM01-000335', casos.numeroCorto);
T('el QR SUNAT de una FACTURA da su correlativo', casos.sunatFactura==='FM01-000053');
T('el QR SUNAT de una BOLETA da su correlativo', casos.sunatBoleta==='BM01-000335');
T('tolera espacios dentro de la cadena', casos.conEspacios==='FM01-000053');
T('una nota de venta pasa tal cual', casos.notaVenta==='NVM2-000531');
T('normaliza a mayusculas', casos.minuscula==='NVM2-000531');
T('texto que no es codigo no inventa un ticket', casos.basura==='HOLAQUETAL');

// ── 5. responsive ──
for (const [w,h,etq] of [[1280,800,'tablet apaisada'],[900,600,'tablet chica'],[420,880,'celular']]) {
  await p.setViewportSize({ width:w, height:h }); await p.waitForTimeout(500);
  const d = await p.evaluate(`document.documentElement.scrollWidth-document.documentElement.clientWidth`);
  T('sin desborde horizontal en ' + etq, d<=1, d+'px');
}

// ── 5b. la barra de controles: un dedo, una vez ──
// Se simula un dedo de verdad (touch), no un mouse: es donde aparecía el problema.
await p.setViewportSize({ width:1280, height:800 });
await p.evaluate(`(() => { document.getElementById('mcRoot').querySelector('.mc-esc'); window.__toques=0; window.__cerro=0; })()`);
const tapCam = await p.evaluate(`(async () => {
  const b = document.querySelector('#mcRoot .mc-ic');
  const r = b.getBoundingClientRect(), x = r.left+r.width/2, y = r.top+r.height/2;
  const op = { bubbles:true, cancelable:true, clientX:x, clientY:y, pointerType:'touch', isPrimary:true, pointerId:1 };
  const t0 = performance.now();
  b.dispatchEvent(new PointerEvent('pointerdown', op));
  const dt = performance.now() - t0;
  b.dispatchEvent(new PointerEvent('pointerup', op));
  return { toques: window.__toques, ms: Math.round(dt), alto: Math.round(r.height), ancho: Math.round(r.width) };
})()`);
console.log('     barra: ' + JSON.stringify(tapCam));
T('la cámara reacciona al primer toque del dedo', tapCam.toques === 1, tapCam.toques + ' de 1');
T('el botón tiene blanco de dedo (44px o más)', tapCam.alto >= 44 && tapCam.ancho >= 44,
  tapCam.ancho + 'x' + tapCam.alto);

const tapX = await p.evaluate(`(() => {
  const b = document.querySelector('#mcRoot .mc-ic.x');
  const r = b.getBoundingClientRect();
  const op = { bubbles:true, cancelable:true, clientX:r.left+r.width/2, clientY:r.top+r.height/2,
               pointerType:'touch', isPrimary:true, pointerId:2 };
  b.dispatchEvent(new PointerEvent('pointerdown', op));
  return window.__cerro;
})()`);
T('el ✕ cierra al primer toque del dedo', tapX === 1, tapX + ' de 1');

const barra = await p.evaluate(`(() => { const t=document.querySelector('#mcRoot .mc-top'),
  w=document.querySelector('#mcRoot .mc-wtop'), b=document.querySelector('#mcRoot .mc-ic');
  const cs=getComputedStyle(t), cw=getComputedStyle(w), cb=getComputedStyle(b);
  return { anim:cs.animationName, tw:cw.transform, touch:cb.touchAction,
           ics:document.querySelectorAll('#mcRoot .mc-ic').length }; })()`);
console.log('     ' + JSON.stringify(barra));
T('la barra de controles no respira ni sigue al dedo',
  barra.anim === 'none' && (barra.tw === 'none' || barra.tw === 'matrix(1, 0, 0, 1, 0, 0)'), barra.anim + ' / ' + barra.tw);
T('los botones no esperan el doble-tap del navegador', barra.touch === 'manipulation', barra.touch);
T('quedan solo los dos botones que sirven: 📷 y ✕', barra.ics === 2, barra.ics + ' botones');

// ── 6. lo acordado que NO tiene que estar, y lo que SÍ ──
// Estos tres se revisan sobre el archivo, no sobre el render: son decisiones de la app
// entera (la puerta del escaneo, el salvapantallas, la pantalla completa), no del bloque.
const A = (n,c,x) => T(n,c,x);
A('el modo reposo/latente no existe en ninguna forma',
  !/mcLatente|\.latente|mc-latmsg/.test(src));
A('el botón sobrio no existe; el freno de efectos es automático',
  !/mcSobrio/.test(src) && /_mcLluviaOff = true/.test(src));
A('la estación entra en pantalla completa',
  /mcPantallaCompleta\(\)/.test(src) && /requestFullscreen/.test(src));
A('sale de pantalla completa al cerrar la estación',
  /if \(document\.fullscreenElement\) document\.exitFullscreen/.test(src));
A('el salvapantallas de ME no tapa la estación',
  /!config\.value\.completado \|\| modoCajero\.value\) \{/.test(src));
A('escanear un ticket entra a la estación, no al POS',
  /ctx\.ctx === 'venta' && config\.value\.esCajero[\s\S]{0,400}?abrirModoCajero\(\)/.test(src));
A('un código que no es ticket sigue de largo al POS',
  /const tk = mcResolverTicket\(cod\);[\s\S]{0,300}?\}\s*\n\s*if \(ctx\.ctx === 'venta'\) \{/.test(src));
A('ninguna versión nueva recarga la app con la estación abierta',
  /watch\(modoCajero, v => \{ _meBusyEstacion\.value = !!v; \}/.test(src)
  && /watch\(\[_meBusyBase, _meBusyEstacion\]/.test(src)
  && /if \(document\.getElementById\('mcRoot'\)\) \{ b\.remove\(\); return; \}/.test(src));
// La trampa que ya me costó una pantalla blanca: leer un `const` de la estación desde código
// que corre ANTES de su declaración aborta el setup() entero. Se comprueba el orden.
A('nada lee la estación antes de que exista',
  src.indexOf('const modoCajero') < src.indexOf('watch(modoCajero,')
  && src.indexOf('const modoCajero') < src.lastIndexOf('modoCajero.value'),
  'declarada en ' + src.indexOf('const modoCajero'));
A('no queda ni un panel con fondo, marco o sombra de caja',
  !/backdrop-filter:blur\(11px\)/.test(CSS) && !/border:2px solid var\(--voz\);opacity:\.3/.test(CSS)
  && !/border-radius:26px/.test(CSS));
A('los dos captores globales aceptan la cadena de SUNAT con sus espacios (| . / y espacio)',
  (src.match(/\[0-9A-Za-z\\-\|\.\/ \]/g)||[]).length === 2,
  ((src.match(/\[0-9A-Za-z\\-\|\.\/ \]/g)||[]).length) + ' de 2 captores');
// Decisión del dueño (19-ago): el cajero NO ata Yapes. El sistema cuadra; el admin en MOS verifica/suelta.
A('el cajero NO ata el Yape: la caja no llama a ninguna RPC de atado',
  !/yape_atar_cobro/.test(src) && !/mcYapeAtar/.test(src));
A('el texto del cobro dice la verdad: "el sistema lo cuadra solo"', /el sistema lo cuadra solo/.test(src));
A('el río se refresca EN VIVO por el canal de ops_meta (dominio yapes)',
  /rec\.dominio \|\| ''\) === 'yapes'/.test(src) && /mcCargarRio\(\); \} catch/.test(src));
A('el ticket nuevo suena al aterrizar', /watch\(\(\) => mcPendientes\.value\.length/.test(src) && /mcSon\('tick'\)/.test(src));
A('la franja "esperando" se resuelve con efecto', /resueltos\.length\) \{ mcSon\('match'\)/.test(src));
A('la estación dice "Son … soles"', /const mcDecirMonto/.test(src) && /mcDecirMonto\(venta\.total\)/.test(src));

// MC_SHOT=1 deja capturas de los tres momentos, para MIRAR el diseño y no solo medirlo
if (process.env.MC_SHOT) {
  const SH = 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/82e44282-8af6-4daa-b2da-5c5d8354cfcc/scratchpad/';
  await p.setViewportSize({ width:1280, height:800 });
  await p.evaluate(`window.__vm.mcEstado='espera'; window.__vm.cajeroTicketActual=null;`);
  await p.waitForTimeout(900); await p.screenshot({ path: SH+'mc1_espera.png' });
  await p.evaluate(`(() => { const el=document.querySelectorAll('#mcRoot .mc-tk')[0]; const r=el.getBoundingClientRect();
  const op={bubbles:true,cancelable:true,clientX:r.left+r.width/2,clientY:r.top+r.height/2,pointerType:'touch',isPrimary:true,pointerId:7};
  el.dispatchEvent(new PointerEvent('pointerdown',op)); el.dispatchEvent(new PointerEvent('pointerup',op)); })()`);
  await p.waitForTimeout(900); await p.screenshot({ path: SH+'mc2_cobro.png' });
  await p.evaluate(`document.querySelector('#mcRoot .mc-bt.mix').click()`);
  await p.waitForTimeout(700); await p.screenshot({ path: SH+'mc3_mixto.png' });
  console.log('  capturas listas');
}

console.log('\n  errores de pagina: ' + (errs.length ? errs.slice(0,4).join(' | ') : 'ninguno'));
T('sin errores ni avisos de Vue', errs.length===0);
console.log('\n  ' + ok.length + ' OK   ' + bad.length + ' fallos');
await b.close(); srv.close();
process.exit(bad.length ? 1 : 0);
