// [800] Verificación en navegador real: la curva de precio/costo ya no trae la basura anulada.
const fs = require('fs');

const ev = `(async()=>{
  const r={}, w=ms=>new Promise(s=>setTimeout(s,ms));
  const b=[...document.querySelectorAll('button,a')].find(el=>/Entrar a MOS/i.test(el.textContent||''));
  if(b)b.click();
  await w(5000);
  try{ r.version=(await fetch('https://levo19.github.io/MOS/version.json?b='+Date.now()).then(x=>x.json())).version }catch(_){}
  try{ const rr=await API.post('historialPrecioCosto',{idProducto:'IDPRO0000035'}); const d=rr&&(rr.data||rr);
       r.rpc={costos:(d.costos||[]).length, anulados:(d.costosAnulados||[]).length,
              maxCurva:Math.max(0,...(d.costos||[]).map(x=>+x.valor)),
              maxAnulado:Math.max(0,...(d.costosAnulados||[]).map(x=>+x.valor))};
  }catch(e){ r.rpcErr=String(e) }
  window._paso2Filas=[{nombre:'GLUTAMATO 1KG',precioActual:14.5,x:{idCanonico:'IDPRO0000035',descripcion:'GLUTAMATO 1KG',costoNuevo:12.1}}];
  try{ await MOS.curvaOverlay(0) }catch(e){ r.err=String(e) }
  await w(6000);
  const ov=document.getElementById('curvaOverlay');
  r.overlay=!!ov;
  if(ov){
    r.chips=[...ov.querySelectorAll('.cov-chip')].map(e=>e.textContent.trim());
    r.registros=ov.querySelectorAll('.cov-reg').length;
    const vals=[...ov.querySelectorAll('.cov-reg-v')].map(e=>e.textContent.trim());
    r.valores=vals;
    r.basuraEnCurva=vals.filter(v=>parseFloat(v.replace(/[^0-9.]/g,''))>100);
    const t=ov.querySelector('.cov-anul-t');
    r.tira=t?t.textContent.trim():'(NO APARECE)';
    if(t){ t.click(); await w(700);
      r.anulados=[...ov.querySelectorAll('.cov-anul-r')].map(e=>[...e.children].map(c=>c.textContent.trim()).join(' | '));
      r.tiraTrasClick=(ov.querySelector('.cov-anul-cv')||{}).textContent;
    }
  }
  return r;
})()`;

fs.writeFileSync('_800_curva.json', JSON.stringify({
  url: 'https://levo19.github.io/MOS/',
  waitMs: 40000,
  viewport: { width: 480, height: 1700 },
  localStorage: {
    mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906477'
  },
  evalAfter: ev,
  screenshot: 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_800_curva.png'
}, null, 2));
console.log('escenario listo');
