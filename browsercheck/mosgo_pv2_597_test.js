// PV2 v2.43.597 — test READ-ONLY (regla: en este módulo NADA que persista a prod:
// no cycleDia/FP, no agregar productos, no patch). Verifica: buscador no invierte,
// stock-suma, detalle sin re-render total, choosers WA/imprimir, familia en ➕.
const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch({ headless: true });
  const page = await b.newPage({ viewport: { width: 1280, height: 860 } });
  const errors = [];
  page.on('pageerror', e => errors.push('PAGEERROR: ' + e.message));
  await page.addInitScript(() => localStorage.setItem('mos_device_id', '7e57c1a0-de1c-4a7e-b0de-c47a10906474'));
  const step = async (n, f) => { try { await f(); console.log('✅', n); } catch (e) { console.log('❌', n, '→', e.message.split('\n')[0]); } };

  await page.goto('http://127.0.0.1:8124/index.html'); await page.waitForTimeout(9000);
  // solo-UI: quitar overlays de sesión (login PIN / permisos / analítica) que tapan los clicks
  await page.evaluate(() => {
    ['loginOverlay', 'mosPermsOverlay', 'viewAnalitica'].forEach(id => { const el = document.getElementById(id); if (el) el.style.display = 'none'; });
  });

  await step('abrir módulo Proveedores (home v2)', async () => {
    await page.evaluate(() => MOS.nav('proveedores'));
    await page.waitForTimeout(1200);
    if (!await page.locator('#pv2Root .pv2-prov').count()) throw new Error('sin cards');
  });
  await step('BUSCADOR: teclear no invierte (caret estable, input intacto)', async () => {
    const inp = page.locator('#pv2Q');
    await inp.click();
    await page.keyboard.type('adc', { delay: 90 });
    await page.waitForTimeout(300);
    const v = await inp.inputValue();
    if (v !== 'adc') throw new Error('valor="' + v + '" (se invirtió o perdió)');
    const caret = await page.evaluate(() => { const i = document.getElementById('pv2Q'); return i.selectionStart; });
    if (caret !== 3) throw new Error('caret=' + caret);
  });
  await step('buscador filtra la lista sin tocar el input', async () => {
    const n = await page.locator('#pv2HomeBody .pv2-prov').count();
    if (n < 1) throw new Error('sin resultados con "adc"');
    await page.evaluate(() => { document.getElementById('pv2Q').value = ''; MOS.pv2.buscar(''); });
    await page.waitForTimeout(250);
  });
  await step('abrir pedido de un proveedor (overlay)', async () => {
    await page.locator('#pv2HomeBody .pv2-prov .pv2-cta').first().click();
    await page.waitForTimeout(4500);
    if (!await page.locator('#pv2Layout .pv2-laypanel').count()) throw new Error('sin layout');
    await page.screenshot({ path: 'pv2_597_pedido.png' });
  });
  await step('STOCK-SUMA visible (almacén + zonas = familia)', async () => {
    const n = await page.locator('.pv2-stk').count();
    if (!n) throw new Error('sin .pv2-stk');
    const t = await page.locator('.pv2-stk').first().textContent();
    if (!/ALMACÉN/.test(t) || !/ZONAS/.test(t)) throw new Error('estructura: ' + t.slice(0, 60));
  });
  await step('DETALLE: abre repintando SOLO la card (panel no se recrea)', async () => {
    const marca = await page.evaluate(() => { const el = document.querySelector('.pv2-laybody'); el.dataset.marca = 'viva'; return el.dataset.marca; });
    if (marca !== 'viva') throw new Error('no marcó');
    const btn = page.locator('.pv2-prod .pv2-detbtn').first();
    await btn.click(); await page.waitForTimeout(400);
    if (!await page.locator('.pv2-det').count()) throw new Error('detalle no abrió');
    const sigue = await page.evaluate(() => { const el = document.querySelector('.pv2-laybody'); return el && el.dataset.marca === 'viva'; });
    if (!sigue) throw new Error('el panel ENTERO se re-creó (marca perdida) = parpadeo');
    await page.screenshot({ path: 'pv2_597_detalle.png' });
  });
  await step('stepper ＋ también parcial (marca sobrevive) — y lo revierto', async () => {
    const plus = page.locator('.pv2-step button').nth(1);
    await plus.click(); await page.waitForTimeout(350);
    const sigue = await page.evaluate(() => { const el = document.querySelector('.pv2-laybody'); return el && el.dataset.marca === 'viva'; });
    if (!sigue) throw new Error('re-render total en chg()');
    if (!await page.locator('#pv2CartWrap .pv2-cartbar').count()) throw new Error('cartbar no apareció');
    // revertir a 0 (localStorage local, no toca prod)
    await page.locator('.pv2-step button').nth(0).first().click(); await page.waitForTimeout(300);
  });
  await step('chooser WhatsApp: 3 opciones (imagen resumen/stock + texto)', async () => {
    // armar 1 bulto temporal para habilitar la barra (solo carrito localStorage)
    await page.locator('.pv2-step button').nth(1).click(); await page.waitForTimeout(300);
    await page.locator('.pv2-bt.wa').click(); await page.waitForTimeout(400);
    const n = await page.locator('#pv2Modal .pv2-share').count();
    if (n !== 3) throw new Error('opciones=' + n);
    await page.screenshot({ path: 'pv2_597_wachooser.png' });
    await page.evaluate(() => MOS.pv2._mx()); await page.waitForTimeout(200);
  });
  await step('imagen canvas RESUMEN se genera (>10KB, sin errores)', async () => {
    const kb = await page.evaluate(() => new Promise(res => {
      const cv = (function(){ try { return MOS.pv2.__testCanvas ? MOS.pv2.__testCanvas('resumen') : null; } catch(e){ return 'ERR:'+e.message; } })();
      if (typeof cv === 'string' || !cv) { res(cv || 'null'); return; }
      cv.toBlob(b2 => res(Math.round(b2.size / 1024)), 'image/png');
    }));
    if (typeof kb !== 'number' || kb < 10) throw new Error('canvas → ' + kb);
    console.log('   → imagen resumen: ' + kb + ' KB');
  });
  await step('imagen canvas STOCK/PEDIDO se genera', async () => {
    const kb = await page.evaluate(() => new Promise(res => {
      try { const cv = MOS.pv2.__testCanvas('stock'); cv.toBlob(b2 => res(Math.round(b2.size / 1024)), 'image/png'); }
      catch (e) { res('ERR:' + e.message); }
    }));
    if (typeof kb !== 'number' || kb < 10) throw new Error('canvas → ' + kb);
    console.log('   → imagen stock/pedido: ' + kb + ' KB');
  });
  await step('chooser Imprimir: 2 opciones (ticket 80mm + listado)', async () => {
    await page.locator('.pv2-bt.gh').click(); await page.waitForTimeout(400);
    const n = await page.locator('#pv2Modal .pv2-share').count();
    if (n !== 2) throw new Error('opciones=' + n);
    await page.evaluate(() => MOS.pv2._mx()); await page.waitForTimeout(200);
  });
  await step('carrito temporal revertido a 0 (sin rastro)', async () => {
    await page.locator('.pv2-step button').nth(0).click(); await page.waitForTimeout(300);
    const cartN = await page.locator('#pv2CartWrap .pv2-cartbar').count();
    if (cartN) throw new Error('cartbar sigue viva');
  });
  await step('➕ Catálogo maestro: resultados por FAMILIA (padre 👑) — sin agregar', async () => {
    await page.locator('.pv2-ftab.add').click(); await page.waitForTimeout(1800);
    await page.locator('#pv2AtM').click(); await page.waitForTimeout(6000);   // carga lazy del catálogo maestro
    await page.locator('#pv2MQ').click();
    await page.keyboard.type('cocinero', { delay: 40 }); await page.waitForTimeout(800);
    const t = await page.locator('#pv2MRes').textContent();
    if (!/padre canónico/.test(t)) throw new Error('sin etiqueta familia: ' + t.slice(0, 80));
    await page.screenshot({ path: 'pv2_597_familia.png' });
    await page.evaluate(() => MOS.pv2._mx()); await page.waitForTimeout(200);
  });

  console.log(errors.length ? '🚨 ERRORES JS:\n' + errors.join('\n') : '✨ 0 errores JS de página');
  await b.close();
})();
