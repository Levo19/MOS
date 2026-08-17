import { chromium } from 'playwright';
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 460, height: 940 } });
await p.addInitScript(dev => localStorage.setItem('mos_device_id', dev), '7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(8000);
try { await p.click('text=/Entrar a MOS/i', { timeout: 4000 }); } catch {}
await p.waitForFunction(() => { try { return !!MOS; } catch { return false; } }, { timeout: 60000 });
console.log('version', await p.evaluate(() => document.querySelector('script[src*="app.js"]').src.split('=').pop()));
await p.evaluate(() => MOS.nav('finanzas'));
await p.waitForTimeout(16000);
await p.evaluate(() => { try { MOS.finAbrirModalProductos(); } catch(e){} });
await p.waitForTimeout(2500);
// abrir el desglose del aji panca
await p.evaluate(() => { const r=[...document.querySelectorAll('.fin-prod-row')].find(x=>/LEV024/.test(x.textContent)); if(r) r.click(); });
await p.waitForTimeout(6000);
const est = await p.evaluate(() => ({
  botones: document.querySelectorAll('.fpd-tk').length,
  chips: document.querySelectorAll('.fin-mg-btn').length,
  tramos: document.querySelectorAll('.fpd-row.is-tramo').length
}));
console.log('botones de tickets:', est.botones, '· chips de margen navegables:', est.chips, '· tarjetas de tramo:', est.tramos);
// tocar el de un tramo
await p.evaluate(() => { const b2=[...document.querySelectorAll('.fpd-tk-mini')]; if(b2.length) b2[b2.length-1].click(); });
await p.waitForTimeout(6000);
const r = await p.evaluate(() => {
  const o = document.getElementById('finTicketsOvl'); if (!o) return { abierto:false };
  return { abierto:true,
    titulo: (o.querySelector('.ftk-tit')||{}).textContent,
    resumen: [...o.querySelectorAll('.ftk-resumen>div')].map(d=>d.textContent.trim()),
    tickets: o.querySelectorAll('.ftk-t').length,
    resaltadas: o.querySelectorAll('.ftk-l.is-yo').length };
});
console.log('OVERLAY →', JSON.stringify(r));
const el = await p.$('#finTicketsOvl .ftk-card');
if (el) await el.screenshot({ path: '_843_tickets.png' });
await b.close();
