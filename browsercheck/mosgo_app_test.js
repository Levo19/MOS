// Test de la app REAL MosGo servida en localhost:8189 (modo test local:
// mosgo_test=1 salta DeviceAuth; sesión sembrada). RPCs de LECTURA van a prod;
// NO se confirma ningún pedido (solo se arma el carrito y se abre el sheet).
const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch({ headless: true });
  const page = await b.newPage({ viewport: { width: 430, height: 950 } });
  const errors = [];
  page.on('pageerror', e => errors.push('PAGEERROR: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('CONSOLE: ' + m.text()); });
  await page.addInitScript(() => {
    localStorage.setItem('mosgo_test', '1');
    localStorage.setItem('mosgo_session', JSON.stringify({ nombre: 'PruebaLuis', id_personal: null, rol: 'ADMIN', ts: 1 }));
  });
  const step = async (n, f) => { try { await f(); console.log('✅', n); } catch (e) { console.log('❌', n, '→', e.message.split('\n')[0]); } };

  await page.goto('http://localhost:8189/'); await page.waitForTimeout(4000);

  await step('app visible + boot con catálogo real (6 productos)', async () => {
    const vis = await page.evaluate(() => getComputedStyle(document.getElementById('app')).display);
    if (vis !== 'flex') throw new Error('app display=' + vis);
    const n = await page.locator('.prod').count();
    if (n !== 6) throw new Error('prods=' + n + ' (esperaba 6 del seed)');
  });
  await step('stock real y tramos del seed pintados', async () => {
    const t = await page.locator('.prod', { hasText: 'SIBARITA PALILLO' }).textContent();
    if (!/1260/.test(t)) throw new Error('sin stock real: ' + t.slice(0, 90));
    if (!/pack ×42/.test(t)) throw new Error('sin tramo ×42');
  });
  await step('buscador filtra', async () => {
    await page.fill('.buscar', 'aceite'); await page.waitForTimeout(250);
    const n = await page.locator('#lista .prod').count();
    if (n !== 2) throw new Error('filtrados=' + n + ' (Cocinero + atún en aceite)');
    await page.fill('.buscar', ''); await page.waitForTimeout(300);
  });
  await step('clientes reales cargados en selector', async () => {
    await page.locator('.cli').click(); await page.waitForTimeout(400);
    const n = await page.locator('#cliLista .cit').count();
    if (n < 3) throw new Error('clientes=' + n);
    await page.locator('#cliLista .cit').first().click(); await page.waitForTimeout(300);
  });
  await step('agregar 2 tramos → cartbar con total correcto', async () => {
    await page.locator('.esc button', { hasText: 'caja ×12' }).first().click();
    await page.locator('.esc button', { hasText: 'pack ×60' }).first().click();
    await page.waitForTimeout(250);
    const t = await page.locator('#cb1').textContent();
    if (!/119\.16/.test(t)) throw new Error('total=' + t + ' (esperaba 119.16)');
  });
  await step('sheet confirmar: total + ahorro + fecha + NO confirmamos', async () => {
    await page.locator('#cartbar').click(); await page.waitForTimeout(400);
    const t = await page.locator('.sheet').textContent();
    if (!/119\.16/.test(t) || !/12\.84/.test(t)) throw new Error('totales sheet mal');
    if (!await page.locator('#feCh button', { hasText: 'MAÑANA' }).count()) throw new Error('sin chips fecha');
    await page.screenshot({ path: 'mosgo_app1_confirmar.png' });
    await page.locator('.sheet .x').click();
  });
  await step('tab Pedidos: lista real desde ruta_pedidos_listar', async () => {
    await page.locator('#tb1').click(); await page.waitForTimeout(600);
    await page.screenshot({ path: 'mosgo_app2_pedidos.png' });
  });
  await step('tab Panel: KPIs y chart', async () => {
    await page.locator('#tb2').click(); await page.waitForTimeout(600);
    if (await page.locator('.kpi').count() !== 4) throw new Error('kpis');
    await page.screenshot({ path: 'mosgo_app3_panel.png' });
  });
  await step('login screen (sin sesión): pide clave 8 díg', async () => {
    const p2 = await b.newPage({ viewport: { width: 430, height: 950 } });
    await p2.addInitScript(() => localStorage.setItem('mosgo_test', '1'));
    await p2.goto('http://localhost:8189/'); await p2.waitForTimeout(800);
    const vis = await p2.evaluate(() => getComputedStyle(document.getElementById('login')).display);
    if (vis !== 'flex') throw new Error('login display=' + vis);
    await p2.fill('#clave', '00000000');
    await p2.locator('#loginBtn').click(); await p2.waitForTimeout(2500);
    const err = await p2.locator('#loginErr').textContent();
    if (!err) throw new Error('clave mala no rechazada');
    console.log('   → clave incorrecta rechazada con: "' + err + '"');
    await p2.screenshot({ path: 'mosgo_app4_login.png' });
    await p2.close();
  });
  await step('manifest + sw + version.json servidos', async () => {
    for (const f of ['manifest.json', 'sw.js', 'version.json', 'icons/icon-192.png']) {
      const r = await page.evaluate(u => fetch(u).then(x => x.status), f);
      if (r !== 200) throw new Error(f + ' → ' + r);
    }
  });

  console.log(errors.length ? '🚨 ERRORES JS:\n' + errors.join('\n') : '✨ 0 errores JS de página');
  await b.close();
})();
