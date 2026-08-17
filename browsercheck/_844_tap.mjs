import { webkit } from 'playwright';
const b = await webkit.launch();
const ctx = await b.newContext({ viewport: { width: 393, height: 852 }, hasTouch: true, isMobile: true });
const p = await ctx.newPage();
await p.addInitScript(dev => localStorage.setItem('mos_device_id', dev), '7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(7000);
try { await p.click('text=/Entrar a MOS/i', { timeout: 4000 }); } catch {}
await p.waitForFunction(() => { try { return !!MOS; } catch { return false; } }, { timeout: 60000 });
await p.evaluate(() => MOS.nav('finanzas'));
await p.waitForTimeout(15000);
await p.evaluate(() => { try { MOS.finAbrirModalProductos(); } catch(e){} });
await p.waitForTimeout(2500);
await p.evaluate(() => { const r=[...document.querySelectorAll('.fin-prod-row')].find(x=>/LEV024/.test(x.textContent))||document.querySelector('.fin-prod-row'); if(r) r.click(); });
await p.waitForTimeout(6000);
await p.evaluate(() => { const t=document.querySelector('.fpd-tk'); if(t) t.click(); });
await p.waitForTimeout(6000);
const m = await p.evaluate(() => {
  const sel = ['.fin-mg-btn', '.fpd-tk', '.ftk-x', '.fin-prod-row', '.cov-tab', '.cov-ab', '.modal-close-x', '.cvf-x'];
  const out = {};
  sel.forEach(s => {
    const el = document.querySelector(s);
    if (!el) { out[s] = 'ausente'; return; }
    const r = el.getBoundingClientRect();
    out[s] = Math.round(r.width) + 'x' + Math.round(r.height) + (r.height < 34 ? '  ⚠ chico' : '  ok');
  });
  return out;
});
Object.entries(m).forEach(([k, v]) => console.log('  ' + k.padEnd(18) + v));
await b.close();
