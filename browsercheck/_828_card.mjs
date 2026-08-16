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
// pestaña "Sin costo" → el ingreso del 30-jul
await p.evaluate(() => MOS._curvaTab(1));
await p.waitForTimeout(700);
const idx = await p.evaluate(() => [...document.querySelectorAll('.cov-ing-r')].findIndex(e => /30 jul/i.test(e.textContent)));
console.log('fila del 30-jul en la lista:', idx);
await p.evaluate(i => MOS._curvaCardIngreso(i), idx);
await p.waitForTimeout(5000);
const r = await p.evaluate(() => {
  const c = document.getElementById('curvaCard'); if (!c) return { card: false };
  return {
    card: true,
    costo: (c.querySelector('.cvf-guia-costo') || {}).textContent,
    botonBorrados: (c.querySelector('.cvf-elim-t') || {}).textContent,
    listaVisible: !!(c.querySelector('.cvf-elim-l') && !c.querySelector('.cvf-elim-l').hasAttribute('hidden'))
  };
});
console.log('costo que muestra la tarjeta:', JSON.stringify(r.costo));
console.log('botón de eliminados       :', JSON.stringify(r.botonBorrados));
console.log('lista oculta por defecto  :', !r.listaVisible ? 'sí ✅' : 'no ❌');
await p.evaluate(() => { const bb = document.querySelector('.cvf-elim-t'); if (bb) bb.click(); });
await p.waitForTimeout(600);
const filas = await p.evaluate(() => [...document.querySelectorAll('.cvf-elim-r')].map(e => e.textContent.replace(/\s+/g,' ').trim())
  .concat([(document.querySelector('.cvf-elim-pie')||{}).textContent || ''].filter(Boolean)));
filas.forEach(f => console.log('   ' + f));
await p.screenshot({ path: '_828_card.png' });
await b.close();
