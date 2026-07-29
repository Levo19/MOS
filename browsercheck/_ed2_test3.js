const { chromium } = require('playwright');
(async()=>{
  const b = await chromium.launch();
  const p = await b.newPage({ viewport:{width:1280,height:860} });
  const errs=[]; p.on('pageerror', e=>errs.push(e.message));
  await p.goto('file:///C:/Users/ISO/ProyectoMOS/browsercheck/_ed2_harness.html');
  // JsBarcode real (CDN) para probar la posicion de las barras
  await p.addScriptTag({ url:'https://cdn.jsdelivr.net/npm/jsbarcode@3.11.6/dist/JsBarcode.all.min.js' }).catch(()=>console.log('(CDN JsBarcode no disponible — test de barras sera parcial)'));
  await p.click('#abrirBtn');
  await p.waitForTimeout(400);
  await p.evaluate(()=>EditorAdhesivos._crearNuevo());
  await p.waitForTimeout(400);

  // ── TEST 1: BARCODE — barras en la posicion de la capa ──
  await p.evaluate(()=>EditorAdhesivos._addBarcode());
  await p.waitForTimeout(500);
  const bc1 = await p.evaluate(()=>{
    const g = document.querySelector('#ed2Canvas g.bc-placeholder');
    const nested = g ? g.querySelector('svg[data-codigo]') : null;
    return {
      wrapperG: !!g,
      transform: g ? g.getAttribute('transform') : null,
      barsDibujadas: nested ? nested.children.length > 0 : false,
      nestedXY: nested ? (nested.getAttribute('x')+','+nested.getAttribute('y')) : null
    };
  });
  console.log('BARCODE inicial:', JSON.stringify(bc1));
  // mover la capa por modelo y verificar que el transform SIGUE a la capa
  const bc2 = await p.evaluate(()=>{
    const capa = window.EditorAdhesivos; // mover via drag simulada por modelo:
    // accedemos por el hit: no hay API publica → usamos flechas (capa seleccionada)
    return null;
  });
  // mover con flechas (10 x derecha = +5mm)
  for(let i=0;i<10;i++) await p.keyboard.press('ArrowRight');
  await p.waitForTimeout(400);
  const bc3 = await p.evaluate(()=>{
    const g = document.querySelector('#ed2Canvas g.bc-placeholder');
    return { transformDespues: g ? g.getAttribute('transform') : null,
             barsSiguen: g ? (g.querySelector('svg[data-codigo]').children.length>0) : false };
  });
  console.log('BARCODE tras mover +5mm:', JSON.stringify(bc3));

  // ── TEST 2: DRAG continuo con mouse real ──
  await p.evaluate(()=>{ EditorAdhesivos._addTexto(); });
  await p.waitForTimeout(350);
  const antes = await p.evaluate(()=>{
    const hit = document.querySelectorAll('.ed2-hit');
    const h = hit[hit.length-1];
    const r = h.getBoundingClientRect();
    return { cx: r.x+r.width/2, cy: r.y+r.height/2 };
  });
  await p.mouse.move(antes.cx, antes.cy);
  await p.mouse.down();
  await p.mouse.move(antes.cx+90, antes.cy+45, { steps: 8 });   // arrastre largo en pasos
  await p.mouse.up();
  await p.waitForTimeout(300);
  const drag = await p.evaluate(()=>{
    const svg = document.querySelector('#ed2Canvas svg');
    const textos = Array.from(svg.querySelectorAll('text')).map(t=>t.getAttribute('x'));
    return { ultimoTextoX: textos[textos.length-1] };
  });
  console.log('DRAG continuo (texto se movio de x=240):', JSON.stringify(drag));

  // ── TEST 3: RESIZE por esquina (QR) ──
  await p.evaluate(()=>EditorAdhesivos._addQR());
  await p.waitForTimeout(350);
  const q0 = await p.evaluate(()=>{
    const caps = document.querySelectorAll('.ed2-hit');
    // el QR recien agregado esta seleccionado; leer dots via bounds del selbox
    const hnd = document.querySelector('.ed2-hnd.br');
    const r = hnd.getBoundingClientRect();
    return { hx: r.x+r.width/2, hy: r.y+r.height/2 };
  });
  const dots0 = await p.evaluate(()=>{
    // no hay getter → inferir del ancho del selbox (px = dots*1.5*zoom)... mejor via JSON al guardar; leemos el bounds
    const sb = document.querySelector('.ed2-selbox');
    return Math.round(sb.getBoundingClientRect().width);
  });
  await p.mouse.move(q0.hx, q0.hy);
  await p.mouse.down();
  await p.mouse.move(q0.hx+50, q0.hy+50, { steps: 6 });
  await p.mouse.up();
  await p.waitForTimeout(350);
  const dots1 = await p.evaluate(()=>{
    const sb = document.querySelector('.ed2-selbox');
    return sb ? Math.round(sb.getBoundingClientRect().width) : -1;
  });
  console.log('RESIZE esquina QR: ancho selbox', dots0, '→', dots1, dots1>dots0? '✅ crecio' : '❌ no crecio');

  // ── TEST 4: salir sin guardar → dialogo con Guardar / eliminar ──
  await p.evaluate(()=>EditorAdhesivos._volverCatalogo());
  await p.waitForTimeout(300);
  const dlgTxt = await p.evaluate(()=>{
    const d = document.getElementById('ed2Dlg');
    return d ? d.textContent : '(sin dialogo)';
  });
  console.log('SALIDA dice:', JSON.stringify(dlgTxt.slice(0,120)));
  await p.click('#ed2Dlg .ed2-btn-ghost'); // salir sin guardar
  await p.waitForTimeout(350);
  const fin = await p.evaluate(()=>({ catalogo: !!document.querySelector('.ed2-cat'), sinBorradorLS: !localStorage.getItem('eda2_borrador') }));
  console.log('DESCARTE:', JSON.stringify(fin));
  console.log(errs.length? ('JS ERRORS: '+errs.join(' | ')) : 'OK sin errores JS');
  await b.close();
})().catch(e=>{console.error('ERR',e.message);process.exit(1)});
