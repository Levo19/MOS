// Verifica el inspector cartesiano: mueve el mouse sobre el area del grafico y comprueba que
// se dibujen las pastillas de ambos ejes (se detecta leyendo pixeles del canvas).
import { chromium } from 'playwright';

const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1280, height: 800 } });
await p.addInitScript(() => localStorage.setItem('mos_device_id', '7e57c1a0-de1c-4a7e-b0de-c47a10906477'));
await p.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(8000);
try { await p.click('text=/Entrar a MOS/i', { timeout: 4000 }); } catch {}
await p.waitForFunction(() => { try { return !!MOS && typeof MOS.curvaOverlay === 'function'; } catch { return false; } }, { timeout: 60000 });
await p.evaluate(() => {
  window._paso2Filas = [{ nombre: 'GLUTAMATO 1KG', precioActual: 14.5,
    x: { idCanonico: 'IDPRO0000035', descripcion: 'GLUTAMATO 1KG', costoNuevo: 13.2 } }];
  return MOS.curvaOverlay(0);
});
await p.waitForTimeout(9000);

const caja = await p.evaluate(() => {
  const c = document.getElementById('covCanvas'); if (!c) return null;
  const r = c.getBoundingClientRect();
  return { x: r.left, y: r.top, w: r.width, h: r.height };
});
console.log('canvas:', JSON.stringify(caja));

// pixeles "encendidos" antes y despues de posar el mouse
const cuenta = () => p.evaluate(() => {
  const c = document.getElementById('covCanvas'), x = c.getContext('2d');
  const d = x.getImageData(0, 0, c.width, c.height).data;
  let n = 0;
  for (let i = 0; i < d.length; i += 4) if (d[i] + d[i+1] + d[i+2] > 260) n++;
  return n;
});
const antes = await cuenta();
await p.mouse.move(caja.x + caja.w * 0.55, caja.y + caja.h * 0.45);
await p.waitForTimeout(700);
const despues = await cuenta();
console.log('pixeles brillantes · sin inspector:', antes, '· con inspector:', despues,
            despues > antes ? '✅ dibuja algo nuevo' : '❌ no cambio');
await p.screenshot({ path: '_825_hover.png' });

// click derecho para clavarlo, y capturar
await p.mouse.move(caja.x + caja.w * 0.62, caja.y + caja.h * 0.62);
await p.click('#covCanvas', { button: 'right', position: { x: caja.w * 0.62, y: caja.h * 0.62 } });
await p.waitForTimeout(600);
await p.mouse.move(caja.x + 20, caja.y + 20);
await p.waitForTimeout(500);
const clavado = await cuenta();
console.log('con click derecho clavado y el mouse lejos:', clavado, clavado > antes ? '✅ sigue dibujado' : '❌ se apago');
await p.screenshot({ path: '_825_clavado.png' });
await b.close();
