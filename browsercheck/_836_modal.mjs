import { chromium } from 'playwright';
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 430, height: 900 } });
await p.addInitScript(dev => localStorage.setItem('mos_device_id', dev), '7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(8000);
try { await p.click('text=/Entrar a MOS/i', { timeout: 4000 }); } catch {}
await p.waitForFunction(() => { try { return !!MOS; } catch { return false; } }, { timeout: 60000 });
await p.evaluate(() => MOS.nav('config'));
await p.waitForTimeout(3000);
await p.evaluate(() => MOS.setCfgTab('infra'));
await p.waitForTimeout(12000);
const info = await p.evaluate(() => {
  const lista = (window.cfgData && cfgData.dispositivos) || [];
  const mos = lista.filter(d => ['MOS',''].includes(String(d.App||'').toUpperCase()) && d.Estado === 'ACTIVO');
  return { total: lista.length, mos: mos.length, primero: mos[0] ? { id: mos[0].ID_Dispositivo, nom: mos[0].Nombre_Equipo, manual: mos[0].Nombre_Manual } : null };
});
console.log('dispositivos en memoria:', info.total, '· MOS activos:', info.mos);
console.log('probando con:', JSON.stringify(info.primero));
if (info.primero) {
  const r = await p.evaluate(id => {
    MOS.abrirModalDispositivo(id);
    const g = s => { const e = document.getElementById(s); return e ? (e.value !== undefined ? e.value : e.textContent) : '(no existe)'; };
    const m = document.getElementById('modalDispositivo');
    return {
      visible: !!(m && !m.classList.contains('hidden')),
      titulo: (document.getElementById('modalDispTitle')||{}).textContent,
      dispId: g('dispId'), uuid: g('dispIdVisible'), nombre: g('dispNombre'), app: g('dispApp'), estado: g('dispEstado')
    };
  }, info.primero.id);
  console.log('MODAL →', JSON.stringify(r));
}
await p.screenshot({ path: '_836_modal.png' });
await b.close();
