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
const r = await p.evaluate(() => ({
  sub: (document.querySelector('.cvf-its-sub') || {}).textContent,
  filas: [...document.querySelectorAll('.cvf-it')].map(e => e.textContent.replace(/\s+/g,' ').trim()),
  boton: (document.querySelector('.cvf-ir') || {}).textContent
}));
console.log('subtítulo :', r.sub);
console.log('botón     :', (r.boton||'').replace(/\s+/g,' ').trim());
console.log('LÍNEAS (30-jul):'); r.filas.forEach(f => console.log('   ' + f));
await p.screenshot({ path: '_832_card.png' });
await b.close();
