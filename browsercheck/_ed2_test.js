const { chromium } = require('playwright');
(async()=>{
  const b = await chromium.launch();
  const errsAll = [];
  async function abrir(vp){
    const p = await b.newPage({ viewport: vp });
    p.on('pageerror', e=>errsAll.push(vp.width+'px: '+e.message));
    await p.goto('file:///C:/Users/ISO/ProyectoMOS/browsercheck/_ed2_harness.html');
    await p.click('#abrirBtn');
    await p.waitForTimeout(500);
    return p;
  }
  // DESKTOP
  const p = await abrir({width:1280,height:860});
  const cat = await p.evaluate(()=>({
    cards: document.querySelectorAll('.ed2-card').length,
    thumbs: document.querySelectorAll('.ed2-th-holder svg').length,
    nota: !!document.querySelector('.ed2-cat-nota'),
    botonesBorrar: document.body.innerHTML.indexOf('Eliminar') >= 0
  }));
  console.log('CATALOGO:', JSON.stringify(cat));
  await p.click('.ed2-btn-print');
  await p.waitForTimeout(800);
  const pr = await p.evaluate(()=>({
    modal: !!document.getElementById('ed2Print'),
    png: !!document.querySelector('#ed2Shot img'),
    svgFallback: !!document.querySelector('#ed2Shot svg'),
    qty: document.getElementById('ed2QtyVal') && document.getElementById('ed2QtyVal').textContent
  }));
  console.log('IMPRIMIR modal:', JSON.stringify(pr));
  await p.evaluate(()=>EditorAdhesivos._qty(1));
  await p.evaluate(()=>EditorAdhesivos._imprimir(0));
  await p.waitForTimeout(300);
  const imp = await p.evaluate(()=>window.__llamadas.filter(l=>l.action==='imprimirAdhesivoPlantilla').map(l=>l.params));
  console.log('LLAMADA imprimir:', JSON.stringify(imp));
  await p.evaluate(()=>EditorAdhesivos._crearNuevo());
  await p.waitForTimeout(400);
  const est1 = await p.evaluate(()=>{
    const svg = document.querySelector('#ed2Canvas svg');
    return {
      canvas: !!document.getElementById('ed2Canvas'),
      membrete: svg ? (svg.textContent.indexOf('INVERSIONES MOS')>=0) : false,
      hitsFija: document.querySelectorAll('.ed2-hit').length,
      dock: document.querySelectorAll('.ed2-dtool').length,
      membTag: !!document.querySelector('.ed2-membtag')
    };
  });
  console.log('ESTUDIO base:', JSON.stringify(est1));
  await p.evaluate(()=>EditorAdhesivos._addTexto());
  await p.waitForTimeout(300);
  const est2 = await p.evaluate(()=>({
    hits: document.querySelectorAll('.ed2-hit').length,
    selbox: !!document.querySelector('.ed2-selbox'),
    fltBotones: document.querySelectorAll('.ed2-flt button').length,
    tray: !!document.querySelector('.ed2-tray.abierta'),
    textarea: !!document.getElementById('ed2TxTexto')
  }));
  console.log('ESTUDIO +texto:', JSON.stringify(est2));
  await p.fill('#ed2TxTexto', 'OFERTA 2x1');
  await p.dispatchEvent('#ed2TxTexto','change');
  await p.waitForTimeout(250);
  const antes = await p.evaluate(()=>document.querySelector('#ed2Canvas svg').textContent.indexOf('OFERTA 2x1')>=0);
  await p.evaluate(()=>EditorAdhesivos._undo());
  await p.waitForTimeout(250);
  const despues = await p.evaluate(()=>document.querySelector('#ed2Canvas svg').textContent.indexOf('OFERTA 2x1')>=0);
  console.log('EDICION+UNDO:', JSON.stringify({aplico:antes, undoRevirtio:!despues}));
  await p.evaluate(()=>{EditorAdhesivos._addTexto();EditorAdhesivos._guardarAlCatalogo();});
  await p.waitForTimeout(300);
  const dlgOk = await p.evaluate(()=>({dlg:!!document.getElementById('ed2Dlg'), input:!!document.getElementById('ed2DlgInput')}));
  console.log('GUARDAR dialogo propio:', JSON.stringify(dlgOk));
  await p.fill('#ed2DlgInput','Aviso de prueba');
  await p.click('#ed2Dlg .ed2-btn-go');
  await p.waitForTimeout(450);
  const g = await p.evaluate(()=>{
    const call = window.__llamadas.find(l=>l.action==='guardarAdhesivoPlantilla');
    return {
      guardo: !!call,
      membreteEnJson: call ? call.params.json.capas.some(c=>c.id==='memb-txt'&&c.fija) : false,
      volvioCatalogo: !!document.querySelector('.ed2-cat')
    };
  });
  console.log('GUARDADO:', JSON.stringify(g));
  await p.screenshot({path:'ed2_desk.png'});
  await p.close();

  // MOVIL 390
  const m = await abrir({width:390,height:844});
  const mc = await m.evaluate(()=>({
    cards: document.querySelectorAll('.ed2-card').length,
    overflowX: document.documentElement.scrollWidth > window.innerWidth
  }));
  console.log('MOVIL catalogo:', JSON.stringify(mc));
  await m.evaluate(()=>EditorAdhesivos._crearNuevo());
  await m.waitForTimeout(450);
  await m.evaluate(()=>EditorAdhesivos._addTexto());
  await m.waitForTimeout(350);
  const mm = await m.evaluate(()=>{
    const tray = document.querySelector('.ed2-tray.abierta');
    const r = tray ? tray.getBoundingClientRect() : null;
    const dock = document.querySelector('.ed2-dock');
    return {
      trayBottomSheet: r ? (Math.abs(r.bottom - window.innerHeight) < 3 && r.width > window.innerWidth*0.95) : false,
      dockOcultoConTray: dock ? getComputedStyle(dock).display==='none' : true,
      overflowX: document.documentElement.scrollWidth > window.innerWidth
    };
  });
  console.log('MOVIL estudio:', JSON.stringify(mm));
  await m.screenshot({path:'ed2_mob.png'});
  await m.close();
  console.log(errsAll.length ? ('JS ERRORS: '+errsAll.join(' || ')) : 'OK sin errores JS en ningun viewport');
  await b.close();
})().catch(e=>{console.error('ERR',e.message);process.exit(1)});
