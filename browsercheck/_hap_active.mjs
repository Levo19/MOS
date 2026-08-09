// Verificación RUNTIME de la base háptica: ¿todo botón visible tiene touch-action y
// una regla :active que lo alcance?
import { chromium, webkit } from 'playwright';
const URL = process.argv[2] || 'http://127.0.0.1:8126/index.html';
for (const [nm, bt] of [['chromium', chromium], ['webkit', webkit]]) {
  const b = await bt.launch();
  const ctx = await b.newContext({ viewport: { width: 390, height: 820 }, hasTouch: true });
  const page = await ctx.newPage();
  await page.addInitScript(() => localStorage.setItem('mosexpress_deviceId', '7e57c1a0-de1c-4a7e-b0de-c47a10906476'));
  await page.goto(URL, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(22000);
  const r = await page.evaluate(() => {
    const vis = el => { const q = el.getBoundingClientRect(); const s = getComputedStyle(el);
      return q.width > 0 && q.height > 0 && s.display !== 'none' && s.visibility !== 'hidden'; };
    const btns = [...document.querySelectorAll('button,[role=button]')];
    const visibles = btns.filter(vis);
    const sinTA = visibles.filter(e => getComputedStyle(e).touchAction !== 'manipulation');
    // ¿existe la regla global :active?
    let reglaGlobal = false, reglaHit = false;
    for (const sh of document.styleSheets) {
      let rr; try { rr = sh.cssRules } catch (_) { continue }
      for (const r of rr || []) {
        const t = r.selectorText || '';
        if (/button:not\(:disabled\).*:active/.test(t)) reglaGlobal = true;
        if (/\.me-hit::after/.test(t)) reglaHit = true;
      }
    }
    return { botones: btns.length, visibles: visibles.length, sinTouchAction: sinTA.length,
      ejemploSinTA: sinTA.slice(0, 3).map(e => (e.className || '').toString().slice(0, 50)),
      reglaGlobalActive: reglaGlobal, reglaMeHit: reglaHit,
      tapHighlight: getComputedStyle(visibles[0] || document.body).webkitTapHighlightColor };
  });
  console.log(nm.padEnd(9) + JSON.stringify(r));
  await ctx.close(); await b.close();
}
