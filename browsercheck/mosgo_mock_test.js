// Test E2E del mockup MosGo (archivo local): vender → confirmar → estados → cobrar → rendir → verificar.
const { chromium } = require('playwright');
(async () => {
  const FILE = 'file:///C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/87ed8f2a-b74c-4519-8180-f245e8ec2132/scratchpad/mosgo_mockup.html';
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 430, height: 950 } });
  const errors = [];
  page.on('pageerror', e => errors.push('PAGEERROR: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('CONSOLE: ' + m.text()); });
  await page.goto(FILE); await page.waitForTimeout(600);

  const step = async (name, fn) => { try { await fn(); console.log('✅', name); } catch (e) { console.log('❌', name, '→', e.message.split('\n')[0]); } };

  await step('carga + 6 productos + sugerido visible', async () => {
    const n = await page.locator('.prod').count(); if (n !== 6) throw new Error('prods=' + n);
    if (!await page.locator('.sug').count()) throw new Error('sin sugerido');
  });
  await step('tocar tramo caja Cocinero → cartbar aparece', async () => {
    await page.locator('.esc button', { hasText: 'caja ×12' }).first().click();
    await page.waitForTimeout(200);
    if (!await page.locator('#cartbar.show').count()) throw new Error('cartbar oculto');
  });
  await step('re-pedir habitual (3 items más)', async () => {
    await page.locator('.sp .btn').click(); await page.waitForTimeout(200);
    const t = await page.locator('#cb1').textContent(); if (!/4 items/.test(t)) throw new Error(t);
  });
  await step('sugerido → agregar pack ×42', async () => {
    await page.locator('.sug .btn').click(); await page.waitForTimeout(200);
  });
  await step('abrir carrito → confirmar con fecha MAÑANA + factura', async () => {
    await page.locator('#cartbar').click(); await page.waitForTimeout(300);
    await page.locator('#feCh button', { hasText: 'MAÑANA' }).click();
    await page.screenshot({ path: 'mosgo_m1_carrito.png' });
    await page.locator('.sheet .btn.full').click(); await page.waitForTimeout(400);
  });
  await step('pedido R-0042 CONFIRMADO en lista (tab Pedidos)', async () => {
    if (!await page.locator('.ped', { hasText: 'R-0042' }).count()) throw new Error('no está');
    await page.screenshot({ path: 'mosgo_m2_pedidos.png' });
  });
  await step('realtime simulado: EN_PREPARACION → DESPACHADO', async () => {
    await page.waitForTimeout(9200);
    const card = page.locator('.ped', { hasText: 'R-0042' });
    const txt = await card.textContent(); if (!/DESPACHADO/.test(txt)) throw new Error(txt.slice(0, 80));
  });
  await step('cobrar R-0042 completo (YAPE) → COBRADO', async () => {
    await page.locator('.ped', { hasText: 'R-0042' }).click(); await page.waitForTimeout(300);
    await page.locator('.sheet .btn.full').click(); await page.waitForTimeout(300);
    await page.locator('#metCh button', { hasText: 'YAPE' }).click();
    await page.locator('.sheet .btn.ok').click(); await page.waitForTimeout(300);
    const txt = await page.locator('.ped', { hasText: 'R-0042' }).textContent();
    if (!/COBRADO/.test(txt)) throw new Error(txt.slice(0, 80));
  });
  await step('cobro PARCIAL: R-0038 saldo a cuenta 50', async () => {
    await page.locator('.ped', { hasText: 'R-0038' }).click(); await page.waitForTimeout(300);
    await page.locator('.sheet .btn.full').click(); await page.waitForTimeout(300);
    await page.fill('#cobM', '50');
    await page.locator('.sheet .btn.ok').click(); await page.waitForTimeout(300);
    const txt = await page.locator('.ped', { hasText: 'R-0038' }).textContent();
    if (!/A CUENTA/.test(txt)) throw new Error(txt.slice(0, 80));
  });
  await step('filtro Míos oculta los de Javier', async () => {
    await page.locator('.filtro button', { hasText: 'Míos' }).click(); await page.waitForTimeout(200);
    if (await page.locator('.ped', { hasText: 'R-0041' }).count()) throw new Error('R-0041 (Javier) visible');
  });
  await step('Panel: KPIs + por rendir ≥3 tickets', async () => {
    await page.locator('#tb2').click(); await page.waitForTimeout(300);
    if (await page.locator('.kpi').count() !== 4) throw new Error('kpis');
    const n = await page.locator('.rend-it').count(); if (n < 3) throw new Error('rend-it=' + n);
    await page.screenshot({ path: 'mosgo_m3_panel.png' });
  });
  await step('seleccionar 2 tickets → rendir → ticket contaduría', async () => {
    await page.locator('.rend-it').nth(0).click();
    await page.locator('.rend-it').nth(1).click(); await page.waitForTimeout(200);
    await page.locator('.btn.full', { hasText: 'RENDIR' }).click(); await page.waitForTimeout(300);
    if (!await page.locator('.tk').count()) throw new Error('sin ticket preview');
    await page.screenshot({ path: 'mosgo_m4_rendir.png' });
    await page.locator('.sheet .btn.full').click(); await page.waitForTimeout(300);
  });
  await step('rendición ENVIADA → jefa verifica → VERIFICADA', async () => {
    if (!await page.locator('.ped', { hasText: 'RD-' }).count()) throw new Error('sin rendición');
    await page.locator('.btn.ghost', { hasText: 'jefa verifica' }).click(); await page.waitForTimeout(300);
    const txt = await page.locator('.ped', { hasText: 'RD-' }).first().textContent();
    if (!/VERIFICADA/.test(txt)) throw new Error(txt.slice(0, 80));
    await page.screenshot({ path: 'mosgo_m5_verificada.png' });
  });

  console.log(errors.length ? '🚨 ERRORES JS:\n' + errors.join('\n') : '✨ 0 errores JS de página');
  await browser.close();
})();
