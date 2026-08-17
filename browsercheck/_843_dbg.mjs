import { chromium } from 'playwright';
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 460, height: 940 } });
await p.addInitScript(dev => localStorage.setItem('mos_device_id', dev), '7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(8000);
try { await p.click('text=/Entrar a MOS/i', { timeout: 4000 }); } catch {}
await p.waitForFunction(() => { try { return !!MOS; } catch { return false; } }, { timeout: 60000 });
const r = await p.evaluate(async () => {
  const out = {};
  try {
    const a = await API.post('finanzasDiaSkuTickets', { skuBase: 'LEV024', clave: '', segmentoId: '' });
    out.todos = JSON.stringify(a).slice(0, 300);
  } catch (e) { out.todosErr = String(e); }
  try {
    const c = await API.post('finanzasDiaSkuTickets', { skuBase: 'LEV024', clave: '', segmentoId: '__base__' });
    const d = c && (c.data || c);
    out.base = { total: d && d.total, mostrados: d && d.mostrados };
  } catch (e) { out.baseErr = String(e); }
  return out;
});
console.log(JSON.stringify(r, null, 1));
await b.close();
