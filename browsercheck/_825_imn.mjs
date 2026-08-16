import { chromium } from 'playwright';
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1280, height: 800 } });
await p.addInitScript(() => localStorage.setItem('mos_device_id', '7e57c1a0-de1c-4a7e-b0de-c47a10906477'));
await p.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(8000);
try { await p.click('text=/Entrar a MOS/i', { timeout: 4000 }); } catch {}
await p.waitForFunction(() => { try { return !!MOS && typeof MOS.curvaOverlay === 'function'; } catch { return false; } }, { timeout: 60000 });
await p.evaluate(() => { window._paso2Filas=[{nombre:'GLUTAMATO 1KG',precioActual:14.5,x:{idCanonico:'IDPRO0000035',descripcion:'GLUTAMATO 1KG',costoNuevo:13.2}}]; return MOS.curvaOverlay(0); });
await p.waitForTimeout(9000);
// imantado al nodo de costo del 12-ago (~765,437) y captura
await p.mouse.move(760, 434, { steps: 8 });
await p.waitForTimeout(700);
await p.screenshot({ path: '_825_imantado.png', clip: { x: 0, y: 330, width: 880, height: 470 } });
console.log('captura del imantado lista');
// ahora un punto violeta (ingreso sin costo) para ver que NO invente pastilla de precio
await p.mouse.move(444, 727, { steps: 6 });
await p.waitForTimeout(700);
await p.screenshot({ path: '_825_ingreso.png', clip: { x: 0, y: 560, width: 880, height: 240 } });
console.log('captura del ingreso lista');
await b.close();
