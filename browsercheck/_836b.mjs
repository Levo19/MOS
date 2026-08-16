import { chromium } from 'playwright';
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 900, height: 1000 } });
await p.addInitScript(dev => localStorage.setItem('mos_device_id', dev), '7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(8000);
try { await p.click('text=/Entrar a MOS/i', { timeout: 4000 }); } catch {}
await p.waitForFunction(() => { try { return !!MOS; } catch { return false; } }, { timeout: 60000 });
await p.evaluate(() => MOS.nav('config'));
await p.waitForTimeout(3000);
await p.evaluate(() => MOS.setCfgTab('infra'));
await p.waitForTimeout(14000);
const cards = await p.evaluate(() => {
  const out = [];
  document.querySelectorAll('.dev').forEach(d => {
    const edit = d.querySelector('.mbtn.edit');
    const fij  = d.querySelector('.mbtn.fij');
    const m = edit && (edit.getAttribute('onclick')||'').match(/abrirModalDispositivo\('([^']+)'\)/);
    out.push({ id: m ? m[1] : null, nombre: (d.querySelector('.cap .t')||{}).textContent, tieneFijar: !!fij });
  });
  return out;
});
console.log('cards renderizadas:', cards.length, '· con botón fijar:', cards.filter(c => c.tieneFijar).length);
const objetivo = cards.find(c => c.id && c.tieneFijar) || cards.find(c => c.id);
console.log('probando con:', JSON.stringify(objetivo));
if (objetivo) {
  const r = await p.evaluate(id => {
    MOS.abrirModalDispositivo(id);
    const g = s => { const e = document.getElementById(s); return e ? (e.value !== undefined ? e.value : e.textContent) : '(no existe)'; };
    const m = document.getElementById('modalDispositivo');
    return { visible: !!(m && !m.classList.contains('hidden')),
             titulo: (document.getElementById('modalDispTitle')||{}).textContent,
             dispId: g('dispId'), uuid: g('dispIdVisible'), nombre: g('dispNombre') };
  }, objetivo.id);
  console.log('MODAL →', JSON.stringify(r));
}
await p.screenshot({ path: '_836_modal.png' });
await b.close();
