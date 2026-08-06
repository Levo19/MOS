const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');
const ROOT = 'C:/Users/ISO/MosGo';
const srv = http.createServer((req, res) => {
  let f = path.join(ROOT, (req.url.split('?')[0] === '/' ? '/index.html' : req.url.split('?')[0]));
  try { const d = fs.readFileSync(f);
    res.writeHead(200, { 'Content-Type': f.endsWith('.html') ? 'text/html' : f.endsWith('.json') ? 'application/json' : f.endsWith('.js') ? 'text/javascript' : 'application/octet-stream' });
    res.end(d);
  } catch (_) { res.writeHead(404); res.end('nf'); }
});
(async()=>{
  await new Promise(r => srv.listen(8189, r));
  const b = await chromium.launch();
  const p = await b.newPage({ viewport:{width:390,height:844} });
  const errs=[]; p.on('pageerror', e=>errs.push(e.message));
  // interceptar RPCs → mocks
  await p.route('**/rest/v1/rpc/**', route => {
    const fn = route.request().url().split('/rpc/')[1].split('?')[0];
    const ok = { ruta_boot: { productos: [
        { codigo_barra:'775001', descripcion:'ACEITE COCINERO 1L', precio_venta:9.0, stock:144, tramos:[{desde:12,precio:8.5,etiqueta:'caja x12'},{desde:24,precio:8.2,etiqueta:'2 cajas x24'}] },
        { codigo_barra:'775002', descripcion:'SIBARITA PALILLO x42', precio_venta:12.5, stock:80, tramos:[{desde:1,precio:12.5,etiqueta:'pack x42'},{desde:5,precio:11.9,etiqueta:'5 packs'}] }
      ], clientes: [{documento:'20601234567',nombre:'POLLERIA DONA MECHE',tipo_doc:'RUC',tipo_negocio:'polleria',telefono_wsp:'999888777'}], comision_pct: 3 },
      ruta_pedidos_listar: { pedidos: [
        { id_pedido:'R-0001', vendedor:'TEST', nombre_cliente:'POLLERIA DONA MECHE', documento_cliente:'20601234567', estado:'COBRADO', total: 204, pagado:204, comision_monto:6.12, created_at:new Date().toISOString(), items:[{codigo_barra:'775001',descripcion:'ACEITE COCINERO 1L',cant:24,precio_unit:8.5,subtotal:204}], cobros:[{metodo:'YAPE',monto:204}] }
      ] },
      ruta_rendiciones_listar: { rendiciones: [] },
      ruta_pedido_crear: { ok:true, id_pedido:'R-0099', estado:'CONFIRMADO', total:102, ahorro:6 } };
    route.fulfill({ status:200, contentType:'application/json', body: JSON.stringify(ok[fn] || { ok:true }) });
  });
  await p.goto('http://localhost:8189/');
  await p.evaluate(()=>{ localStorage.setItem('mosgo_test','1'); localStorage.setItem('mosgo_session', JSON.stringify({nombre:'TEST', id_personal:'PER1', rol:'ADMIN', ts:Date.now()})); });
  await p.reload();
  await p.waitForTimeout(900);
  const v = await p.evaluate(()=>({
    app: document.getElementById('app').style.display,
    fondo: getComputedStyle(document.body).backgroundColor,
    logoAnim: getComputedStyle(document.querySelector('.brand .logo')).animationName,
    precioOro: (function(){ const b=document.querySelector('.esc button b'); return b ? getComputedStyle(b).color : null; })()
  }));
  console.log('VENDER:', JSON.stringify(v));
  await p.screenshot({ path:'mg_vender.png' });
  // agregar tramo → cartbar
  await p.click('.esc button');
  await p.waitForTimeout(400);
  const cart = await p.evaluate(()=>({
    bar: document.getElementById('cartbar').classList.contains('show'),
    oroEnTotal: !!document.querySelector('#cb1 .oro'),
    tramoSel: !!document.querySelector('.esc button.sel')
  }));
  console.log('CARRITO:', JSON.stringify(cart));
  await p.screenshot({ path:'mg_cart.png' });
  // confirmar pedido → confetti
  await p.click('#cartbar');
  await p.waitForTimeout(400);
  await p.click('#btnConfirmar');
  await p.waitForTimeout(500);
  const conf = await p.evaluate(()=>({ confetti: !!document.querySelector('.confe'), sheetWA: (document.getElementById('sheet').textContent||'').includes('WHATSAPP') }));
  console.log('CONFIRMAR:', JSON.stringify(conf));
  await p.screenshot({ path:'mg_confirm.png' });
  await p.evaluate(()=>UI.close());
  // panel: kpis countup + barras
  await p.evaluate(()=>UI.go(2));
  await p.waitForTimeout(900);
  const pan = await p.evaluate(()=>({
    kpi1: document.querySelector('.kpi b').textContent,
    barras: Array.from(document.querySelectorAll('.bars .b')).map(x=>x.style.height).filter(h=>h && h!=='0%').length
  }));
  console.log('PANEL:', JSON.stringify(pan));
  await p.screenshot({ path:'mg_panel.png' });
  console.log(errs.length ? ('JS ERRORS: '+errs.join(' | ')) : 'OK sin errores JS');
  await b.close(); srv.close();
})().catch(e=>{console.error('ERR',e.message);process.exit(1)});
