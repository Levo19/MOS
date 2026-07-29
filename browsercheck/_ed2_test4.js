const { chromium } = require('playwright');
(async()=>{
  const b = await chromium.launch();
  const p = await b.newPage({ viewport:{width:1280,height:860} });
  const errs=[]; p.on('pageerror', e=>errs.push(e.message));
  await p.goto('file:///C:/Users/ISO/ProyectoMOS/browsercheck/_ed2_harness.html');
  await p.addScriptTag({ url:'https://cdn.jsdelivr.net/npm/jsbarcode@3.11.6/dist/JsBarcode.all.min.js' });
  await p.click('#abrirBtn');
  await p.waitForTimeout(400);
  await p.evaluate(()=>EditorAdhesivos._crearNuevo());
  await p.waitForTimeout(400);
  await p.evaluate(()=>EditorAdhesivos._addBarcode());
  await p.waitForTimeout(500);
  const r = await p.evaluate(()=>{
    const nested = document.querySelector('#ed2Canvas svg[data-codigo]');
    const hit = Array.from(document.querySelectorAll('.ed2-hit')).pop();
    const nb = nested.getBoundingClientRect();
    const hb = hit.getBoundingClientRect();
    // barras dibujadas = rects dentro del nested
    const barras = nested.querySelectorAll('rect, g rect').length;
    const textoResidual = !!document.querySelector('#ed2Canvas g.bc-placeholder text');
    return {
      barras: barras,
      textoResidual: textoResidual,
      // ¿la caja visual de las barras coincide con el hit de la capa? (tolerancia 3px)
      dx: Math.round(Math.abs(nb.x - hb.x)),
      dy: Math.round(Math.abs(nb.y - hb.y)),
      dw: Math.round(Math.abs(nb.width - hb.width)),
      dh: Math.round(Math.abs(nb.height - hb.height)),
      attrs: {
        viewBox: nested.getAttribute('viewBox'),
        w: nested.getAttribute('width'), h: nested.getAttribute('height'),
        par: nested.getAttribute('preserveAspectRatio')
      }
    };
  });
  const alineado = r.dx<=3 && r.dy<=3 && r.dw<=6 && r.dh<=6;
  console.log('BARCODE v1.0.4:', JSON.stringify(r));
  console.log(alineado && r.barras>0 && !r.textoResidual
    ? 'OK barras EXACTAS dentro de la caja, sin texto residual'
    : 'FALLA revisar alineacion/texto');
  // resize del alto por esquina y re-chequear
  const h0 = await p.evaluate(()=>Math.round(document.querySelector('#ed2Canvas svg[data-codigo]').getBoundingClientRect().height));
  const hnd = await p.evaluate(()=>{ const h=document.querySelector('.ed2-hnd.br').getBoundingClientRect(); return {x:h.x+13,y:h.y+13}; });
  await p.mouse.move(hnd.x, hnd.y); await p.mouse.down();
  await p.mouse.move(hnd.x, hnd.y+40, {steps:5}); await p.mouse.up();
  await p.waitForTimeout(400);
  const h1 = await p.evaluate(()=>{
    const n = document.querySelector('#ed2Canvas svg[data-codigo]');
    const hit = Array.from(document.querySelectorAll('.ed2-hit')).pop();
    return { alto: Math.round(n.getBoundingClientRect().height), hitAlto: Math.round(hit.getBoundingClientRect().height) };
  });
  console.log('RESIZE alto barras:', h0, '→', JSON.stringify(h1), (h1.alto>h0 && Math.abs(h1.alto-h1.hitAlto)<=6) ? 'OK crece alineado' : 'revisar');
  console.log(errs.length? ('JS ERRORS: '+errs.join(' | ')) : 'OK sin errores JS');
  await b.close();
})().catch(e=>{console.error('ERR',e.message);process.exit(1)});
