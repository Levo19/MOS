import { chromium } from 'playwright';
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 430, height: 920 } });
await p.addInitScript(dev => localStorage.setItem('mos_device_id', dev), '7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(8000);
try { await p.click('text=/Entrar a MOS/i', { timeout: 4000 }); } catch {}
await p.waitForFunction(() => { try { return !!MOS; } catch { return false; } }, { timeout: 60000 });
console.log('version', await p.evaluate(() => document.querySelector('script[src*="app.js"]').src.split('=').pop()));
await p.evaluate(() => MOS.nav('finanzas'));
await p.waitForTimeout(16000);
await p.evaluate(() => { try { MOS.finAbrirModalProductos(); } catch(e){} });
await p.waitForTimeout(3000);
const hay = await p.evaluate(() => document.querySelectorAll('.fin-prod-row').length);
console.log('filas clickeables:', hay);
if (hay) {
  await p.evaluate(() => { const r=[...document.querySelectorAll('.fin-prod-row')].find(x=>/LEV216/.test(x.textContent)) || document.querySelector('.fin-prod-row'); r.click(); });
  await p.waitForTimeout(5000);
  const r = await p.evaluate(() => {
    const d = document.querySelector('.fin-prod-det'); if (!d) return { abierto:false };
    const css = !!document.getElementById('finProdDesgloseCSS');
    const fila = d.querySelector('.fpd-row');
    const st = fila ? getComputedStyle(fila) : null;
    return { abierto:true, cssCargado:css, filas:d.querySelectorAll('.fpd-row').length,
      display: st ? st.display : '-', celdas: d.querySelectorAll('.fpd-cel').length,
      pista: (d.querySelector('.fpd-pista')||{}).textContent };
  });
  console.log(JSON.stringify(r));
  // capturar la fila abierta junto con su encabezado, sin overlays encima
  const caja = await p.evaluate(() => {
    const tr = document.querySelector('.fin-prod-row.on');
    const det = document.querySelector('.fin-prod-det');
    if (!tr || !det) return null;
    const a = tr.getBoundingClientRect(), b2 = det.getBoundingClientRect();
    return { x: Math.max(0, a.left - 6), y: Math.max(0, a.top - 6),
             width: Math.min(430, Math.max(a.width, b2.width) + 12),
             height: (b2.bottom - a.top) + 12 };
  });
  if (caja && caja.height > 40) await p.screenshot({ path: '_840_desg.png', clip: caja });
  else await p.screenshot({ path: '_840_desg.png' });
}
await b.close();
