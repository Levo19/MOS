// [803] Verificación en navegador real de la curva inmersiva: banda de ingresos sin costo,
// card flotante por punto, guía rica con el producto resaltado y lightbox del comprobante.
const fs = require('fs');

const ev = `(async()=>{
  const r={}, w=ms=>new Promise(s=>setTimeout(s,ms));
  const b=[...document.querySelectorAll('button,a')].find(el=>/Entrar a MOS/i.test(el.textContent||''));
  if(b)b.click();
  await w(5000);
  try{ r.version=(await fetch('https://levo19.github.io/MOS/version.json?b='+Date.now()).then(x=>x.json())).version }catch(_){}
  window._paso2Filas=[{nombre:'GLUTAMATO 1KG',precioActual:14.5,x:{idCanonico:'IDPRO0000035',descripcion:'GLUTAMATO 1KG',costoNuevo:12.1}}];
  try{ await MOS.curvaOverlay(0) }catch(e){ r.err=String(e) }
  await w(7000);
  const ov=document.getElementById('curvaOverlay');
  r.overlay=!!ov;
  if(!ov) return r;

  // leyenda: ¿aparece la tercera serie?
  r.leyenda=[...ov.querySelectorAll('.cov-legend span')].map(e=>e.textContent.trim());
  // tira de ingresos sin costo
  const ti=ov.querySelector('.cov-ing-t');
  r.tiraIngresos = ti ? ti.textContent.trim() : '(NO APARECE)';
  // registros = solo lo del gráfico
  r.registros=[...ov.querySelectorAll('.cov-reg-v')].map(e=>e.textContent.trim());

  // abrir la lista de ingresos y entrar al primero
  if(ti){
    ti.click(); await w(600);
    const filas=[...ov.querySelectorAll('.cov-ing-r')];
    r.ingresosListados=filas.length;
    r.primerIngreso=filas[0]?filas[0].textContent.replace(/[ \\u00a0]+/g,' ').trim():'';
    if(filas[0]){
      filas[0].click();
      await w(5000);
      const card=document.getElementById('curvaCard');
      r.cardAbierto=!!card;
      if(card){
        r.cardTag=(card.querySelector('.cvf-tag')||{}).textContent;
        r.cardVal=(card.querySelector('.cvf-val')||{}).textContent;
        r.cardFilas=[...card.querySelectorAll('.cvf-row')].map(e=>[...e.children].map(c=>c.textContent.trim()).join(': '));
        r.cardAviso=(card.querySelector('.cvf-aviso')||{}).textContent;
        r.guiaProv=(card.querySelector('.cvf-guia-prov')||{}).textContent;
        r.guiaDoc=(card.querySelector('.cvf-guia-doc')||{}).textContent;
        r.guiaCosto=(card.querySelector('.cvf-guia-costo')||{}).textContent;
        r.items=[...card.querySelectorAll('.cvf-it')].map(e=>(e.className.indexOf('is-yo')>=0?'>> ':'   ')+e.textContent.replace(/[ \\u00a0]+/g,' ').trim());
        r.itemsResaltados=card.querySelectorAll('.cvf-it.is-yo').length;
        r.tieneFoto=!!card.querySelector('.cvf-foto');
        // abrir el comprobante en grande y comprobar que quede POR ENCIMA del card
        const fb=card.querySelector('.cvf-foto');
        if(fb){ fb.click(); await w(1200);
          const lb=document.querySelector('.cov-lb');
          r.lightbox=!!lb;
          if(lb){ r.lbZ=getComputedStyle(lb).zIndex; r.cardZ=getComputedStyle(document.getElementById('curvaCard')).zIndex;
                  r.lbEncima = (+r.lbZ > +r.cardZ);
                  r.lbImg=(lb.querySelector('img')||{}).naturalWidth;
                  lb.click(); await w(400); }
        }
        MOS._curvaCardCerrar(); await w(400);
        r.cardCerrado=!document.getElementById('curvaCard');
      }
    }
  }
  // click en un registro del gráfico → mismo card
  const reg=ov.querySelector('.cov-reg');
  if(reg){ reg.click(); await w(3500);
    const c2=document.getElementById('curvaCard');
    r.cardDesdeRegistro=!!c2;
    if(c2){ r.cardRegTag=(c2.querySelector('.cvf-tag')||{}).textContent;
            r.cardRegGuia=(c2.querySelector('.cvf-guia-prov')||{}).textContent;
            r.cardRegResaltados=c2.querySelectorAll('.cvf-it.is-yo').length; }
  }
  return r;
})()`;

fs.writeFileSync('_803_curva.json', JSON.stringify({
  url: 'https://levo19.github.io/MOS/',
  waitMs: 45000,
  viewport: { width: 480, height: 1800 },
  localStorage: { mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906477' },
  evalAfter: ev,
  screenshot: 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_803_curva.png'
}, null, 2));
console.log('escenario listo');
