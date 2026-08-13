// Verificación del rediseño del módulo Tributario en navegador real.
// Chromium headless · 3 anchos · vista principal + 3 overlays + lightbox.
// Sonda: pageerrors al abrir/cerrar cada overlay 2 veces + scroll horizontal del body.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import { MOCK } from './_trib_mock.mjs';
const require = createRequire('C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/package.json');
const { chromium } = require('playwright');

const OUT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/.claude/worktrees/agent-a92f86812f5457f83/browsercheck/_trib_shots/';
fs.mkdirSync(OUT, { recursive: true });
const URL_APP = 'http://127.0.0.1:8203/index.html';
const LS = {
  mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906474',
  MOS_SESSION: '{"idPersonal":"TEST-CLAUDE","nombre":"PRUEBA CLAUDE","rol":"MASTER","idSesion":"testclaude1"}'
};
const w = ms => new Promise(r => setTimeout(r, ms));
const anchos = [
  { n: '390',  width: 390,  height: 844,  movil: true },
  { n: '768',  width: 768,  height: 1024, movil: true },
  { n: '1280', width: 1280, height: 900,  movil: false }
];
// PNG 1x1 gris como comprobante de repuesto si el mes no tiene fotos reales.
const FOTO_FAKE = 'data:image/svg+xml;base64,' + Buffer.from(
  '<svg xmlns="http://www.w3.org/2000/svg" width="620" height="880"><rect width="620" height="880" fill="#f4f1ea"/>' +
  '<text x="40" y="80" font-family="monospace" font-size="30" fill="#111">FACTURA ELECTRONICA</text>' +
  '<text x="40" y="130" font-family="monospace" font-size="22" fill="#333">RUC 20100085063</text>' +
  '<text x="40" y="170" font-family="monospace" font-size="22" fill="#333">F001-0001234</text>' +
  '<line x1="40" y1="200" x2="580" y2="200" stroke="#999" stroke-width="2"/>' +
  '<text x="40" y="700" font-family="monospace" font-size="26" fill="#111">OP. GRAVADA   S/ 1316.75</text>' +
  '<text x="40" y="750" font-family="monospace" font-size="26" fill="#111">IGV 18%       S/  237.01</text>' +
  '<text x="40" y="800" font-family="monospace" font-size="30" fill="#000">TOTAL         S/ 1553.76</text></svg>'
).toString('base64');

const informe = { errores: [], consola: [], pasos: [] };

(async () => {
  const browser = await chromium.launch({ headless: true });
  for (const v of anchos) {
    const ctx = await browser.newContext({
      viewport: { width: v.width, height: v.height },
      deviceScaleFactor: 2,
      hasTouch: v.movil, isMobile: false
    });
    await ctx.addInitScript(ls => { for (const [k, val] of Object.entries(ls)) { try { localStorage.setItem(k, val); } catch (_) {} } }, LS);
    const page = await ctx.newPage();
    page.on('pageerror', e => informe.errores.push('[' + v.n + '] PAGEERROR: ' + e.message));
    page.on('console', m => { if (m.type() === 'error') informe.consola.push('[' + v.n + '] ' + m.text().slice(0, 200)); });

    await page.goto(URL_APP, { waitUntil: 'domcontentloaded' });
    await w(9000);
    // El device TEST-CLAUDE está SUSPENDIDO por inactividad (48h) → DeviceAuth
    // pone html.da-pre-block (visibility:hidden a todo el documento). Para
    // poder ver la UI se levanta el bloqueo SOLO en este navegador de prueba;
    // no se toca nada de la app.
    informe.gate = await page.evaluate(() => {
      const tenia = document.documentElement.classList.contains('da-pre-block');
      const limpiar = () => {
        document.documentElement.classList.remove('da-pre-block');
        document.body.classList.remove('da-blocked');
        // También el onboarding de permisos, que en un navegador fresco tapa todo.
        ['deviceAuthOverlay', 'daApproveToast', 'da-fatal-fallback', 'mosPermsOverlay'].forEach(id => document.getElementById(id)?.remove());
        document.querySelectorAll('.da-insitu-overlay').forEach(e => e.remove());
      };
      limpiar();
      setInterval(limpiar, 400);
      return { estabaBloqueado: tenia };
    });
    await w(500);
    // El entorno local no tiene token de Supabase (la app pide PIN al arrancar),
    // así que se interceptan los 4 fetchers del módulo con datos realistas.
    // Es verificación de PIEL: la lógica de datos no se tocó.
    informe.mock = await page.evaluate(MOCK);
    await page.evaluate(() => { try { MOS.nav('tributario'); } catch (_) {} });
    await w(7000);   // el histórico son 12 llamadas secuenciales

    const overflow = () => page.evaluate(() => ({
      scrollW: document.documentElement.scrollWidth, inner: window.innerWidth,
      bodyW: document.body.scrollWidth
    }));

    // ── 1. Vista principal ──────────────────────────────────────────
    await page.evaluate(() => window.scrollTo(0, 0));
    await w(600);
    await page.screenshot({ path: OUT + 'trib_main_' + v.n + '.png', fullPage: false });
    // El contenido del panel vive en un contenedor con scroll propio: el
    // fullPage no lo alcanza, así que el histórico se captura por elemento.
    const panel = await page.$('#tribHistPanel');
    if (panel) {
      await panel.scrollIntoViewIfNeeded(); await w(900);
      await panel.screenshot({ path: OUT + 'trib_hist_' + v.n + '.png' });
      // Gemelo accesible del gráfico: la tabla con los 12 meses.
      await page.evaluate(() => { const d = document.querySelector('#tribHistPanel details'); if (d) d.open = true; });
      await w(500);
      await panel.screenshot({ path: OUT + 'trib_hist_tabla_' + v.n + '.png' });
      await page.evaluate(() => { const d = document.querySelector('#tribHistPanel details'); if (d) d.open = false; });
    }
    await page.screenshot({ path: OUT + 'trib_abajo_' + v.n + '.png' });
    await page.evaluate(() => { const s = document.getElementById('tribHero'); if (s) s.scrollIntoView({ block: 'start' }); });
    await w(700);
    informe.pasos.push({ ancho: v.n, paso: 'principal', overflow: await overflow(),
      estado: await page.evaluate(() => ({
        hero: document.getElementById('tribBalanceNeto')?.textContent,
        veredicto: document.getElementById('tribHeroVeredicto')?.textContent.trim(),
        favor: document.getElementById('tribIGVFavor')?.textContent,
        contra: document.getElementById('tribIGVPagar')?.textContent,
        renta: document.getElementById('tribRenta')?.textContent,
        ventas: document.getElementById('tribVentas')?.textContent,
        mes: document.getElementById('tribMesLabel')?.textContent,
        sparks: [...document.querySelectorAll('.trib-stat-spark svg')].length,
        chartBands: document.querySelectorAll('.trib-chart-band').length,
        histSub: document.getElementById('tribHistSub')?.textContent
      })) });

    // ── 2. Overlays: abrir/cerrar 2 veces cada uno + captura ────────
    const overlays = [
      ['tribAbrirIGVFavor',   'tribOvFavor',   'favor'],
      ['tribAbrirIGVEmitido', 'tribOvEmitido', 'emitido'],
      ['tribAbrirRenta',      'tribOvRenta',   'renta'],
      ['tribAbrirVentas',     'tribOvVentas',  'ventas']
    ];
    for (const [fn, id, nombre] of overlays) {
      for (let ronda = 1; ronda <= 2; ronda++) {
        await page.evaluate(f => { MOS[f](); }, fn);
        await w(ronda === 1 ? 2600 : 1400);
        if (ronda === 1) {
          await page.screenshot({ path: OUT + 'trib_ov_' + nombre + '_' + v.n + '.png' });
          informe.pasos.push({ ancho: v.n, paso: 'overlay ' + nombre, overflow: await overflow(),
            filas: await page.evaluate(i => document.querySelectorAll('#' + i + ' .trib-gcard').length, id),
            chips: await page.evaluate(i => document.querySelectorAll('#' + i + ' .trib-chip').length, id),
            abierto: await page.evaluate(i => !!document.getElementById(i), id) });
        }
        await page.evaluate(i => MOS._tribSheetCerrar(i), id);
        await w(500);
      }
      const quedo = await page.evaluate(i => !!document.getElementById(i), id);
      if (quedo) informe.errores.push('[' + v.n + '] overlay ' + nombre + ' no se cerró');
    }

    // ── 3. Lightbox del comprobante ────────────────────────────────
    await page.evaluate(() => MOS.tribAbrirIGVFavor());
    await w(2600);
    const hayFoto = await page.evaluate(() => !!document.querySelector('#tribOvFavor [data-foto]'));
    if (hayFoto) {
      await page.click('#tribOvFavor [data-foto]');
    } else {
      await page.evaluate(u => MOS.tribAbrirFotoComprobante(u, 'GI-PRUEBA-0001', 237.01), FOTO_FAKE);
    }
    await w(1600);
    // Zoom para probar el control (y que la captura muestre el estado real)
    await page.evaluate(() => { const b = document.querySelector('[data-lb-zoom="1"]'); if (b) { b.click(); b.click(); } });
    await w(700);
    await page.screenshot({ path: OUT + 'trib_lightbox_' + v.n + '.png' });
    informe.pasos.push({ ancho: v.n, paso: 'lightbox', fotoReal: hayFoto, overflow: await overflow(),
      zoom: await page.evaluate(() => document.getElementById('tribLightboxZoom')?.textContent) });
    await page.keyboard.press('Escape');
    await w(600);
    const lbVivo = await page.evaluate(() => !!document.getElementById('tribLightbox'));
    if (lbVivo) informe.errores.push('[' + v.n + '] lightbox no cerró con Escape');
    await page.keyboard.press('Escape');
    await w(600);

    // ── 4. Menús ⋯ y de mes ────────────────────────────────────────
    // El badge flotante de seguridad (global de la app, arrastrable) queda
    // sobre la esquina superior derecha en móvil: se aparta para poder tocar ⋯.
    await page.evaluate(() => { const b = document.getElementById('segBadge'); if (b) b.style.display = 'none'; });
    await page.click('#tribAccionesBtn');
    await w(700);
    await page.screenshot({ path: OUT + 'trib_menu_' + v.n + '.png' });
    informe.pasos.push({ ancho: v.n, paso: 'menu acciones',
      items: await page.evaluate(() => document.querySelectorAll('.trib-pop-item').length), overflow: await overflow() });
    await page.keyboard.press('Escape');
    await w(500);

    // ── 5. Overflow final del body tras todo el ciclo ──────────────
    informe.pasos.push({ ancho: v.n, paso: 'final', overflow: await overflow(),
      bodyOverflowRestaurado: await page.evaluate(() => document.body.style.overflow || '(vacío)') });

    await ctx.close();
  }
  await browser.close();
  fs.writeFileSync(OUT + '_informe.json', JSON.stringify(informe, null, 2), 'utf8');
  console.log(JSON.stringify(informe, null, 2));
})();
