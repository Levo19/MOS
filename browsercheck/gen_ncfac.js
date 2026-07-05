// Genera los 3 escenarios de verificación del historial NC + PDF legal.
const fs = require('fs');

const comps = `
var fac = {id:'F1',tipo:1,serie:'FFF1',numero:13,estado:'anulada',cliente_nombre:'Comercial El Sol S.A.C.',cliente_doc:'20123456789',cliente_doc_tipo:'6',total:118,moneda:'PEN',creado:'2026-07-01 10:30',enlace_pdf:'',items:[{descripcion:'Tour Islas Ballestas',cantidad:2,precio:50}]};
var nc = {id:'NC1',tipo:3,serie:'FFF1',numero:2,estado:'aceptada',cliente_nombre:'Comercial El Sol S.A.C.',cliente_doc:'20123456789',cliente_doc_tipo:'6',total:118,moneda:'PEN',creado:'2026-07-01 11:00',enlace_pdf:'',doc_modifica_tipo:1,doc_modifica_serie:'FFF1',doc_modifica_numero:13,nc_motivo:'Anulación de la operación',items:[{descripcion:'Tour Islas Ballestas',cantidad:2,precio:50}]};
var bol = {id:'B1',tipo:2,serie:'BBB1',numero:45,estado:'aceptada',cliente_nombre:'Juan Pérez Rojas',cliente_doc:'44556677',cliente_doc_tipo:'1',total:60,moneda:'PEN',creado:'2026-07-02 09:15',enlace_pdf:'',items:[{descripcion:'Paseo en lancha',cantidad:1,precio:60}]};
`;

function evalBody(mode) {
  return `(async()=>{try{
var app=document.getElementById('app');var vn=app.__vnode||app._vnode;var ss=vn&&vn.component&&vn.component.setupState;
if(!ss)return{err:'NO_SS'};
try{_facLoadHist=async function(){if(typeof _facState!=='undefined'&&_facState){_facState.cargandoHist=false;}try{_facRenderSlot&&_facRenderSlot();}catch(e){}};}catch(e){}
localStorage.setItem('ps_session',JSON.stringify({id:'P-1',nombre:'Admin',rol:'Administrador',loginAt:Date.now()}));
try{ss.session={id:'P-1',nombre:'Admin',rol:'Administrador',loginAt:Date.now()};}catch(e){}
try{ss.goModule('facturacion');}catch(e){}
var t=0;while(!_facState&&t<160){await new Promise(function(r){setTimeout(r,100);});t++;}
if(!_facState){var md=document.querySelector('.fac-module');return{err:'NO_FACSTATE',curMod:ss.currentModule,modExists:!!md,modHTML:md?md.innerHTML.replace(/\\s+/g,' ').slice(0,300):'(no .fac-module)'};}
${comps}
var S=_facState;
S.comprobantes=[fac,nc,bol];S.histMeses=[];S.cargandoHist=false;S.tab='historial';
S._histOpen=${mode==='open'?"{F1:true}":"{}"};
try{_facRenderSlot();}catch(e){return{err:'RENDER:'+e.message};}
await new Promise(function(r){setTimeout(r,400);});
var slot=document.querySelector('#fac-slot');if(slot){slot.scrollIntoView({block:'start'});}
${mode==='pdf'?"try{_facAbrirPDF(nc);}catch(e){return{err:'PDF:'+e.message};}await new Promise(function(r){setTimeout(r,900);});":""}
await new Promise(function(r){setTimeout(r,300);});
var out={ver:window.APP_VERSION,mode:_facMode,tab:S.tab,
 cards:document.querySelectorAll('.fac-hist-head').length,
 badges:document.querySelectorAll('.fac-tp').length,
 tris:document.querySelectorAll('.fac-hist-tri').length,
 openTri:document.querySelectorAll('.fac-hist-tri.open').length,
 nestedNC:document.querySelectorAll('.fac-hist-nc').length,
 accOpen:document.querySelectorAll('.fac-hist-acc.open').length};
${mode==='pdf'?"var pv=document.querySelector('#fac-pdf-modal');out.pdfOpen=!!(pv&&pv.style.display!=='none');out.modificaTxt=pv?(pv.innerHTML.indexOf('MODIFICA A: FACTURA FFF1-00000013')>=0):false;out.motivoTxt=pv?(pv.innerHTML.indexOf('Anulación de la operación')>=0):false;":""}
var bx=document.body.scrollWidth,vw=window.innerWidth;out.overflowX=bx>vw+2;
out.balanza=!!document.querySelector('#fac-balanza-panel');
return out;
}catch(e){return{crash:e.message,stack:(e.stack||'').slice(0,300)};}})()`;
}

const base = { url: 'http://127.0.0.1:8137/', waitMs: 3500, viewport: { width: 1280, height: 900 } };
const scen = [
  { name: 'ncfac_hist', mode: 'hist', shot: 'h-hist.png' },
  { name: 'ncfac_open', mode: 'open', shot: 'h-hist-open.png' },
  { name: 'ncfac_pdf', mode: 'pdf', shot: 'h-nc-pdf.png' },
];
scen.forEach(s => {
  fs.writeFileSync(s.name + '.json', JSON.stringify(Object.assign({}, base, { evalAfter: evalBody(s.mode), screenshot: s.shot }), null, 2));
  console.log('wrote ' + s.name + '.json');
});
