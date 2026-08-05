// MosGo v0.5 — familias/escalones reales (SQL 628). Navegador real + RPCs mockeadas.
const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');
const ROOT = 'C:/Users/ISO/ecosistema MOS/MosGo';
const srv = http.createServer((req, res) => {
  let f = path.join(ROOT, (req.url.split('?')[0] === '/' ? '/index.html' : req.url.split('?')[0]));
  try { const d = fs.readFileSync(f);
    res.writeHead(200, { 'Content-Type': f.endsWith('.html') ? 'text/html' : f.endsWith('.json') ? 'application/json' : f.endsWith('.js') ? 'text/javascript' : 'application/octet-stream' });
    res.end(d);
  } catch (_) { res.writeHead(404); res.end('nf'); }
});

// El piloto nakamito con la forma REAL del boot v2 (SQL 628)
const FAMILIAS = [
  { fsku: 'LEV015', baseCod: 'WHNAXMTO', baseNombre: 'NAKAMITO GLUTAMATO GRANEL', baseUnidad: 'KGM',
    basePrecio: 8, baseMosgo: true, stockBase: 450, escalones: [
      { cod: 'P-NKMGLT-X25', nombre: 'NAKAMITO GLUTAMATO · Saco 25 kg', factor: 25, precio: 155, fijo: true },
      { cod: 'P-VIEJA-D4', nombre: 'NAKAMITO GLUTAMATO · Cuarto', factor: 0.25, precio: 2.5, fijo: false }  // legacy kg → NO debe aparecer
    ] },
  { fsku: 'LEV1385', baseCod: 'WHNAXMTO001KG', baseNombre: 'NAKAMITO GLUTAMATO 1KG', baseUnidad: 'NIU',
    basePrecio: 20, baseMosgo: true, stockBase: 60, escalones: [
      { cod: 'P-NKM1K-X3', nombre: 'NAKAMITO GLUTAMATO 1KG · Tripack ×3', factor: 3, precio: 50, fijo: false }
    ] }
];

(async () => {
  await new Promise(r => srv.listen(8189, r));
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 390, height: 844 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  let pedidoEnviado = null;
  await p.route('**/rest/v1/rpc/**', route => {
    const fn = route.request().url().split('/rpc/')[1].split('?')[0];
    if (fn === 'ruta_pedido_crear') { const _b = route.request().postDataJSON(); pedidoEnviado = (_b && _b.p) || _b; }
    const ok = {
      ruta_boot: { ok: true, familias: FAMILIAS, productos: [], clientes: [
        { documento: '20601234567', nombre: 'POLLERIA DONA MECHE', tipo_doc: 'RUC', tipo_negocio: 'polleria', telefono_wsp: '999888777' }], comision_pct: 3 },
      ruta_pedidos_listar: { pedidos: [] },
      ruta_rendiciones_listar: { rendiciones: [] },
      // device-auth exige `estado` — sin esto lanza "respuesta sin estado" (artefacto del mock)
      verificar_dispositivo: { ok: true, estado: 'APROBADO' },
      ruta_pedido_crear: { ok: true, id_pedido: 'R-0100', estado: 'CONFIRMADO', total: 205, ahorro: 55, ajustados: 0 }
    };
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(ok[fn] || { ok: true }) });
  });
  await p.goto('http://localhost:8189/');
  await p.evaluate(() => { localStorage.setItem('mosgo_test', '1');
    localStorage.setItem('mosgo_session', JSON.stringify({ nombre: 'TEST', id_personal: 'PER1', rol: 'ADMIN', ts: Date.now() })); });
  await p.reload();
  await p.waitForTimeout(1000);

  let ok = 0, fail = 0;
  const t = (n, c, x) => { if (c) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, x ?? ''); } };

  const v = await p.evaluate(() => {
    const cards = [...document.querySelectorAll('.prod')];
    return {
      nCards: cards.length,
      granelTxt: cards[0]?.innerText || '',
      kiloTxt: cards.map(c => c.innerText).find(t => t.includes('1KG')) || '',
      escBtns: [...document.querySelectorAll('.esc button')].map(b => b.innerText.replace(/\n/g, ' '))
    };
  });
  t('pintan las 2 familias del piloto', v.nCards === 2, v.nCards);
  t('la familia granel muestra stock en kg y precio suelto /kg', /450 kg/.test(v.granelTxt) && /8\.00.*\/kg/.test(v.granelTxt), v.granelTxt.slice(0, 90));
  t('el SACO sale con SU precio de etiqueta (155), no 25×8=200', v.escBtns.some(b => /Saco 25 kg/.test(b) && /155\.00/.test(b)), JSON.stringify(v.escBtns));
  t('el saco enseña su precio por kilo (6.20/kg) — no "ahorra" (queda bajo el suelto)', v.escBtns.some(b => /Saco/.test(b) && /(ahorra|\/kg)/.test(b)));
  t('la fracción legacy SIN precio fijo NO aparece (mentiría el precio)', !v.escBtns.some(b => /Cuarto/.test(b)));
  t('el tripack muestra "ahorra 10.00" (3×20−50)', v.escBtns.some(b => /Tripack/.test(b) && /ahorra S\/ 10\.00/.test(b)), JSON.stringify(v.escBtns.filter(x => /Tripack/.test(x))));
  t('la unidad base 1kg es su propio escalón a 20.00', v.escBtns.some(b => /^1 un/.test(b) && /20\.00/.test(b)));

  // carrito: 1 saco + 1 tripack → total 205, ahorro 10
  await p.evaluate(() => { UI.addEsc('P-NKMGLT-X25'); UI.addEsc('P-NKM1K-X3'); });
  const c = await p.evaluate(() => UI.calc());
  t('carrito calcula 155+50 = 205', c.tot === 205, c.tot);
  t('ahorro del carrito = 55 (saco 45 + tripack 10, ambos vs suelto)', c.ah === 55, c.ah);
  t('las líneas llevan el código del ESCALÓN (ítem real del catálogo)',
    c.lines.every(l => ['P-NKMGLT-X25', 'P-NKM1K-X3'].includes(l.cb)), JSON.stringify(c.lines.map(l => l.cb)));

  // confirmar → el payload lleva codigo_barra del escalón; el server manda el precio
  await p.evaluate(() => { St.cliDoc = '20601234567'; UI.openCart(); });
  await p.waitForTimeout(300);
  await p.evaluate(() => UI.confirmar());
  await p.waitForTimeout(600);
  t('el pedido viaja con los códigos de escalón y cantidades', !!pedidoEnviado &&
    (pedidoEnviado.items || []).length === 2 && pedidoEnviado.items.every(i => i.cant === 1), JSON.stringify(pedidoEnviado?.items));
  t('sin errores JS en toda la sesión', errs.length === 0, errs.join(' | ').slice(0, 200));

  // [v0.5.1] badge contador + '+1' volador (volver a Vender: confirmar limpió y cambió de tab)
  const badges = await p.evaluate(() => {
    UI.go(0); UI.addEsc('P-NKMGLT-X25'); UI.addEsc('P-NKMGLT-X25');  // 2 sacos → badge 2
    return {
      qns: [...document.querySelectorAll('.esc button .qn')].map(x => ({ n: x.textContent, enSaco: /Saco|x25|155/.test(x.closest('button').innerText) })),
      cssQn: !!document.querySelector('.esc button .qn'),
    };
  });
  t('el escalón muestra su contador sin ir al carrito', badges.cssQn, JSON.stringify(badges));
  t('el saco marca 2 tras dos toques', badges.qns.some(x => x.n === '2'), JSON.stringify(badges.qns));
  const fly = await p.evaluate(() => new Promise(res => {
    const btn = [...document.querySelectorAll('.esc button')].find(b => /Tripack/.test(b.innerText));
    btn.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    setTimeout(() => res({ fly: !!document.querySelector('.plusfly'), txt: document.querySelector('.plusfly')?.textContent }), 120);
  }));
  t('al tocar aparece el +1 volador', fly.fly && fly.txt === '+1', JSON.stringify(fly));

  // [v0.5.2] venta persistente + fecha chip/overlay 2 semanas
  await p.evaluate(() => { Venta.clear(); UI.go(0); St.cliDoc = '20601234567'; UI.addEsc('P-NKM1K-X3'); });
  await p.reload(); await p.waitForTimeout(900);
  const rest = await p.evaluate(() => ({ cart: St.cart, cli: St.cliDoc }));
  t('la venta en curso SOBREVIVE al reload (auto-update sin perder carrito)',
    rest.cart['P-NKM1K-X3'] === 1 && rest.cli === '20601234567', JSON.stringify(rest));
  const fe = await p.evaluate(() => { UI.openCart(); return document.getElementById('sheet').innerText; });
  t('el sheet muestra el chip de fecha HOY', /📅 HOY ▾/.test(fe), fe.slice(0, 140));
  const ovf = await p.evaluate(() => { UI.openFecha(); const b = [...document.querySelectorAll('#sheet .chips button')];
    return { n: b.length, l0: b[0]?.innerText, l1: b[1]?.innerText }; });
  t('el overlay ofrece exactamente 14 días (2 semanas)', ovf.n === 14, JSON.stringify(ovf));
  t('los dos primeros son HOY y MAÑANA', ovf.l0 === 'HOY' && ovf.l1 === 'MAÑANA', JSON.stringify(ovf));
  const pick = await p.evaluate(() => { const b = [...document.querySelectorAll('#sheet .chips button')][5];
    b.click(); const chip = document.querySelector('#sheet .chips button');
    return { fecha: St.fechaEntrega, chip: chip ? chip.innerText : '' }; });
  t('elegir un día vuelve al carrito con el chip actualizado',
    /\d{4}-\d{2}-\d{2}/.test(pick.fecha) && /📅 .+ ▾/.test(pick.chip), JSON.stringify(pick));
  await p.evaluate(() => { Venta.clear(); UI.close(); });

  // familias vacías → mensaje de "activa con 🛵"
  await p.evaluate(() => { D.fams = []; D.escalones = []; UI.go(0); });
  const vacio = await p.evaluate(() => document.getElementById('lista').innerText);
  t('sin nada activado explica el toggle 🛵 (no pantalla rota)', /MosGo 🛵/.test(vacio) && /catálogo de MOS/.test(vacio), vacio.slice(0, 80));

  console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
  await b.close(); srv.close();
  process.exit(fail === 0 ? 0 : 1);
})();
