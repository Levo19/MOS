import { chromium } from 'playwright';
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 900, height: 1000 } });
await p.addInitScript(dev => localStorage.setItem('mos_device_id', dev), '7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(8000);
try { await p.click('text=/Entrar a MOS/i', { timeout: 4000 }); } catch {}
await p.waitForFunction(() => { try { return !!MOS; } catch { return false; } }, { timeout: 60000 });
console.log('version', await p.evaluate(() => document.querySelector('script[src*="app.js"]').src.split('=').pop()));
await p.evaluate(() => MOS.nav('catalogo'));
await p.waitForTimeout(12000);
await p.evaluate(() => { const i = document.getElementById('buscadorCatalogo') || document.querySelector('input[placeholder*="uscar"]'); if (i) { i.value = 'deliarroz'; i.dispatchEvent(new Event('input', { bubbles: true })); } });
await p.waitForTimeout(4000);
const r = await p.evaluate(() => {
  const cards = [...document.querySelectorAll('[class*="cat-card"], .prod-card, [data-idproducto]')];
  return cards.slice(0, 4).map(c => c.textContent.replace(/\s+/g, ' ').trim().slice(0, 200));
});
console.log('CARDS DE DELIARROZ EN EL CATÁLOGO:');
r.forEach(t => console.log('   ' + t));
await p.screenshot({ path: '_837_marg.png' });
await b.close();
