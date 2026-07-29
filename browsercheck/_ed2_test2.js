const { chromium } = require('playwright');
(async()=>{
  const b = await chromium.launch();
  const errs=[];
  const p = await b.newPage({ viewport:{width:768,height:1024} }); // TABLET
  p.on('pageerror', e=>errs.push(e.message));
  await p.goto('file:///C:/Users/ISO/ProyectoMOS/browsercheck/_ed2_harness.html');
  await p.click('#abrirBtn');
  await p.waitForTimeout(500);
  // partir de esta (copia al estudio, original intacto)
  await p.click('.ed2-btn-base');
  await p.waitForTimeout(450);
  const pd = await p.evaluate(()=>({
    enEstudio: !!document.getElementById('ed2Canvas'),
    nombreCopia: (document.getElementById('ed2Nombre')||{}).value||'',
    membrete: document.querySelector('#ed2Canvas svg').textContent.indexOf('INVERSIONES MOS')>=0,
    hitsEditables: document.querySelectorAll('.ed2-hit').length
  }));
  console.log('PARTIR-DE-ESTA:', JSON.stringify(pd));
  // picker de iconos
  await p.evaluate(()=>EditorAdhesivos._abrirIconos());
  await p.waitForTimeout(350);
  const ic = await p.evaluate(()=>({
    grid: document.querySelectorAll('.ed2-icb').length,
    cats: document.querySelectorAll('.ed2-catb').length
  }));
  console.log('ICONOS picker:', JSON.stringify(ic));
  await p.click('.ed2-icb');
  await p.waitForTimeout(350);
  const ic2 = await p.evaluate(()=>({
    iconoEnSvg: !!document.querySelector('#ed2Canvas svg image'),
    seleccionado: !!document.querySelector('.ed2-selbox')
  }));
  console.log('ICONO agregado:', JSON.stringify(ic2));
  // salir con cambios → diálogo propio (no confirm nativo)
  await p.evaluate(()=>EditorAdhesivos._volverCatalogo());
  await p.waitForTimeout(300);
  const salida = await p.evaluate(()=>({dlgPropio: !!document.getElementById('ed2Dlg')}));
  console.log('SALIDA con cambios:', JSON.stringify(salida));
  await p.click('#ed2Dlg .ed2-btn-ghost'); // Salir sin guardar (v2.1: se elimina)
  await p.waitForTimeout(400);
  const fin = await p.evaluate(()=>({catalogo: !!document.querySelector('.ed2-cat'), overflowX: document.documentElement.scrollWidth > window.innerWidth}));
  console.log('TABLET final:', JSON.stringify(fin));
  // zoom fit + delta sanity
  console.log(errs.length ? ('JS ERRORS: '+errs.join(' | ')) : 'OK tablet sin errores JS');
  await b.close();
})().catch(e=>{console.error('ERR',e.message);process.exit(1)});
