import { chromium } from 'playwright';
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1280, height: 800 } });
await p.addInitScript(() => localStorage.setItem('mos_device_id', '7e57c1a0-de1c-4a7e-b0de-c47a10906477'));
await p.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(8000);
try { await p.click('text=/Entrar a MOS/i', { timeout: 4000 }); } catch {}
await p.waitForFunction(() => { try { return !!MOS && typeof MOS.curvaOverlay === 'function'; } catch { return false; } }, { timeout: 60000 });
await p.evaluate(() => { window._paso2Filas=[{nombre:'G',precioActual:14.5,x:{idCanonico:'IDPRO0000035',descripcion:'G',costoNuevo:13.2}}]; return MOS.curvaOverlay(0); });
await p.waitForTimeout(9000);
console.log('version', await p.evaluate(() => document.querySelector('script[src*="app.js"]').src.split('=').pop()));
const info = await p.evaluate(() => {
  const c = document.getElementById('covCanvas');
  return { existe: !!c, cursor: c && c.style.cursor, tienePM: !!(c && c.onpointermove), tieneCtx: !!(c && c.oncontextmenu) };
});
console.log('canvas:', JSON.stringify(info));
const r = await p.evaluate(() => { const c=document.getElementById('covCanvas'); const b=c.getBoundingClientRect(); return {x:b.left,y:b.top,w:b.width,h:b.height}; });
await p.mouse.move(r.x + r.w*0.55, r.y + r.h*0.45, { steps: 6 });
await p.waitForTimeout(800);
console.log('tras mover el mouse · cursor =', await p.evaluate(() => document.getElementById('covCanvas').style.cursor));
// dispatch manual por si el mouse sintetico no genera pointermove
await p.evaluate(({x,y}) => {
  const c = document.getElementById('covCanvas');
  const b = c.getBoundingClientRect();
  c.dispatchEvent(new PointerEvent('pointermove', { clientX: b.left + x, clientY: b.top + y, bubbles: true, pointerType: 'mouse' }));
}, { x: r.w*0.55, y: r.h*0.45 });
await p.waitForTimeout(600);
console.log('tras dispatch manual · cursor =', await p.evaluate(() => document.getElementById('covCanvas').style.cursor));
await p.screenshot({ path: '_825_dbg.png' });
await b.close();
