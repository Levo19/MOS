import { chromium } from 'playwright';
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 430, height: 900 } });
await p.addInitScript(() => localStorage.setItem('mos_device_id', '7e57c1a0-de1c-4a7e-b0de-c47a10906477'));
await p.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(8000);
try { await p.click('text=/Entrar a MOS/i', { timeout: 4000 }); } catch {}
await p.waitForFunction(() => { try { return !!MOS && typeof MOS.curvaOverlay === 'function'; } catch { return false; } }, { timeout: 60000 });
console.log('version', await p.evaluate(() => document.querySelector('script[src*="app.js"]').src.split('=').pop()));
await p.evaluate(() => { window._paso2Filas=[{nombre:'GLUTAMATO 1KG',precioActual:14.5,x:{idCanonico:'IDPRO0000035',descripcion:'GLUTAMATO 1KG',costoNuevo:13.2}}]; return MOS.curvaOverlay(0); });
await p.waitForTimeout(9000);
await p.evaluate(() => MOS._curvaTab(1)); await p.waitForTimeout(600);
const i = await p.evaluate(() => [...document.querySelectorAll('.cov-ing-r')].findIndex(e => /30 jul/i.test(e.textContent)));
await p.evaluate(n => MOS._curvaCardIngreso(n), i);
await p.waitForTimeout(5500);
console.log('tarjeta abierta · botón presente:', await p.evaluate(() => !!document.querySelector('.cvf-ir')));
await p.evaluate(() => document.querySelector('.cvf-ir').click());
// puede tardar: amplía ventana + carga detalle
await p.waitForTimeout(22000);
const r = await p.evaluate(() => {
  const m = document.getElementById('modalCostosUnificado') || document.querySelector('[id*="ostos"]');
  const txt = document.body.innerText;
  return {
    modal: !!m,
    titulo: (txt.match(/Compra · \d+ productos/) || [''])[0],
    sinLineas: /Sin líneas registradas/i.test(txt),
    lineasVisibles: document.querySelectorAll('.cl-row, .cl-linea, [class*="cl-"]').length,
    toast: (document.querySelector('.toast, [class*="toast"]') || {}).textContent || ''
  };
});
console.log('RESULTADO:', JSON.stringify(r));
await p.screenshot({ path: '_834_paso1.png' });
await b.close();
