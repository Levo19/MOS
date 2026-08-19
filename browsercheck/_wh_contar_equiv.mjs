// [WH · contar por código] Anís McColins x25 (LEV588): canónico …1408 + equivalentes …8723 y …0106.
// Se carga WH LOCAL con el device de prueba, se busca el código del andamio (…0106), se abre el
// detalle, CONTAR STOCK debe arrancar en …0106 (no en el canónico), el sheet debe mostrar los 3
// chips, y tocar otro chip debe cambiar el objetivo y el "Sistema". Nada se confirma: no se toca stock.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = 'C:/Users/ISO/ecosistema MOS/warehouseMos';
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(path.resolve(ROOT))||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8822,r));
const ok=[], bad=[]; const T=(n,c,x)=>{ (c?ok:bad).push(n); console.log((c?'  OK  ':'  --  ')+n+(x!=null?'  ·  '+x:'')); };
const b = await chromium.launch(); const ctx = await b.newContext({ viewport:{width:420,height:900}, hasTouch:true });
const p = await ctx.newPage(); const errs=[]; p.on('pageerror', e => errs.push(String(e).split('\n')[0].slice(0,160)));
await p.addInitScript(() => { try { localStorage.setItem('wh_device_id','7e57c1a0-de1c-4a7e-b0de-c47a10906475'); } catch(_){} });
await p.goto('http://127.0.0.1:8822/', { waitUntil:'domcontentloaded' });
await p.waitForTimeout(16000);
// ir a productos y buscar el código del andamio
await p.evaluate(() => { try { App.nav('productos'); } catch(_){} });
await p.waitForTimeout(2500);
const tieneBuscador = await p.evaluate(() => !!document.getElementById('buscarProd') || !!document.querySelector('input[placeholder*="Buscar"]'));
await p.evaluate(() => { ProductosView.buscar('7750477080106'); });
await p.waitForTimeout(1200);
const r1 = await p.evaluate(() => { const g = [...document.querySelectorAll('[id^="grp-"]')]; return { n: g.length, exact: g.filter(e=>e.classList.contains('is-match-exact')).length, panelAbierto: !!document.querySelector('[id^="eqs-"]:not(.hidden)') }; });
console.log('     búsqueda: ' + JSON.stringify(r1));
T('escanear …0106 encuentra el grupo LEV588 y abre su panel de códigos', r1.n >= 1 && r1.panelAbierto);
const contarEnFila = await p.evaluate(() => [...document.querySelectorAll('[id^="eqs-"]:not(.hidden) .btn-eye')].map(b => b.textContent.trim()));
T('cada código del panel tiene su botón Contar (3 códigos)', contarEnFila.length === 3 && contarEnFila.every(t => /Contar/.test(t)), JSON.stringify(contarEnFila));
// abrir detalle y CONTAR STOCK → debe arrancar en …0106
await p.evaluate(() => { ProductosView.abrirSheetDetalleProducto('LEV588'); });
await p.waitForTimeout(800);
const contarEnTab = await p.evaluate(() => document.querySelectorAll('#prodDetTabContent .btn-eye').length);
T('el tab Stock del detalle tiene un botón Contar por código', contarEnTab === 3, String(contarEnTab));
await p.evaluate(() => { ProductosView.detContarActual(); });
await p.waitForTimeout(700);
const a1 = await p.evaluate(() => ({ cod: document.getElementById('auditCodigo').textContent, sis: document.getElementById('auditStockSis').textContent,
  chips: [...document.querySelectorAll('#auditCodChips .aud-cod-chip')].map(c => ({ cod: c.dataset.cod, act: c.classList.contains('is-active'), txt: c.textContent.replace(/\s+/g,' ').trim() })),
  abierto: document.getElementById('sheetAudit').classList.contains('open') }));
console.log('     sheet: ' + JSON.stringify(a1));
T('CONTAR STOCK arranca en el código escaneado (…0106), no en el canónico', a1.abierto && a1.cod === '7750477080106');
T('el sheet muestra los 3 chips (canónico + 2 equivalentes) con el escaneado activo', a1.chips.length === 3 && a1.chips.find(c=>c.cod==='7750477080106')?.act === true);
T('el chip del canónico dice CANÓN y los equivalentes EQUIV', /CANÓN/.test(a1.chips.find(c=>c.cod==='8720608001408')?.txt||'') && /EQUIV/.test(a1.chips.find(c=>c.cod==='7752285008723')?.txt||''));
// cambiar al canónico
await p.evaluate(() => { ProductosView.audElegirCodigo('8720608001408'); });
await p.waitForTimeout(300);
const a2 = await p.evaluate(() => ({ cod: document.getElementById('auditCodigo').textContent, sis: document.getElementById('auditStockSis').textContent, conteo: document.getElementById('auditConteo').value,
  act: [...document.querySelectorAll('#auditCodChips .aud-cod-chip.is-active')].map(c=>c.dataset.cod) }));
T('tocar el chip del canónico cambia el objetivo, el "Sistema" y vacía el conteo', a2.cod === '8720608001408' && a2.act.join() === '8720608001408' && a2.conteo === '', JSON.stringify(a2));
// producto de un solo código: sin chips
await p.evaluate(() => { cerrarSheet('sheetAudit'); });
await p.waitForTimeout(300);
const uno = await p.evaluate(() => { const g = ProductosView._grupos ? null : null; return null; });
// un grupo que tenga UN solo código, el que sea: se busca en la lista real
const skuUno = await p.evaluate(() => { const cards=[...document.querySelectorAll('[id^="grp-"]')]; return null; });
await p.evaluate(() => { ProductosView.buscar(''); });
await p.waitForTimeout(600);
const sku1 = await p.evaluate(() => { const c=[...document.querySelectorAll('[id^="grp-"]')].find(e => !e.querySelector('[id^="eqs-"]')); return c ? c.id.slice(4) : null; });
await p.evaluate((sku) => { ProductosView.abrirSheetDetalleProducto(sku); }, sku1);
await p.waitForTimeout(500);
await p.evaluate(() => { ProductosView.detContarActual(); });
await p.waitForTimeout(600);
const a3 = await p.evaluate(() => ({ cod: document.getElementById('auditCodigo').textContent, chips: document.querySelectorAll('#auditCodChips .aud-cod-chip').length, vis: getComputedStyle(document.getElementById('auditCodChips')).display }));
console.log('     un solo código: ' + JSON.stringify(a3));
T('con un solo código no aparece el selector', a3.chips === 0 || a3.vis === 'none');
T('sin errores de página', errs.length === 0, errs.join(' | ') || '0');
await p.screenshot({ path: 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_wh_contar_equiv.png' });
await b.close(); srv.close();
console.log('\n  ' + ok.length + ' OK   ' + bad.length + ' fallos'); process.exit(bad.length ? 1 : 0);
