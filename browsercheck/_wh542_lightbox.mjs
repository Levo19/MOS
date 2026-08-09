// [WH 2.13.542] Verificación en navegador REAL del LIGHTBOX de foto del producto.
// Chromium (Android/PC) + WebKit (Safari/iPhone), 390 / 768 / 1280.
//   node _wh542_lightbox.mjs chromium 390
//   node _wh542_lightbox.mjs webkit 390
//   node _wh542_lightbox.mjs chromium 1280
import { chromium, webkit } from 'playwright';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MOTOR = process.argv[2] || 'chromium';
const ANCHO = parseInt(process.argv[3] || '390', 10);

const URL = 'https://levo19.github.io/warehouseMos-/';
const DEV = '7e57c1a0-de1c-4a7e-b0de-c47a10906475';   // TEST-CLAUDE-WH
const SESION = JSON.stringify({
  idSesion: 'LOCAL_TESTCLAUDE', idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE',
  apellido: 'CLAUDE', color: '#4f46e5', rol: 'MASTER', fechaDia: '2026-08-09', fechaGuardado: new Date().toISOString()
});

const engine = MOTOR === 'webkit' ? webkit : chromium;
const tactil = ANCHO < 900;
const shot = (page, n) => page.screenshot({ path: path.join(__dirname, `_542_${n}_${MOTOR}_${ANCHO}.png`) });

(async () => {
  const browser = await engine.launch({ headless: true });
  const ctx = await browser.newContext({
    viewport: { width: ANCHO, height: ANCHO < 900 ? 844 : 900 },
    hasTouch: tactil, isMobile: tactil && MOTOR !== 'webkit', deviceScaleFactor: 2
  });
  const page = await ctx.newPage();
  const errores = [], consola = [];
  page.on('pageerror', e => errores.push('PAGEERROR: ' + e.message));
  page.on('console', m => { if (m.type() === 'error' || m.type() === 'warning') consola.push(`[${m.type()}] ${m.text()}`.slice(0, 220)); });

  await page.addInitScript(([dev, ses]) => {
    localStorage.setItem('wh_device_id', dev);
    localStorage.setItem('wh_sesion', ses);
    localStorage.setItem('wh_last_activity', String(Date.now()));
  }, [DEV, SESION]);

  const salida = { motor: MOTOR, ancho: ANCHO };
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 45000 });
  await page.waitForTimeout(26000);   // boot + catálogo (delta)

  salida.version = await page.evaluate(async () => {
    try { return (await (await fetch('version.json?b=' + Date.now())).json()).version; } catch (_) { return '?'; }
  });
  await page.evaluate(() => { const o = document.getElementById('whPermsOverlay'); if (o) o.remove(); });

  await page.evaluate(() => { try { App.nav('productos'); } catch (_) {} });
  await page.waitForTimeout(4500);
  await page.evaluate(() => {
    const i = document.getElementById('buscarProd');
    if (i) i.value = 'ANIS';
    try { ProductosView.buscar('ANIS'); } catch (_) {}
  });
  await page.waitForTimeout(2500);

  // Miniaturas: ¿son tappables?
  salida.cards = await page.evaluate(() => {
    const tiles = [...document.querySelectorAll('#listProductos .wh-foto')];
    return {
      nTiles: tiles.length,
      tappables: tiles.filter(t => t.classList.contains('is-tap') && t.getAttribute('data-sku')).length,
      conFoto: tiles.filter(t => t.querySelector('.wh-foto-img')).length,
      sinFoto: tiles.filter(t => !t.querySelector('.wh-foto-img')).length
    };
  });

  // ── 1) TAP en una miniatura CON foto → lightbox ────────────
  // Se espera a que la miniatura esté decodificada (caso real: el operador la ve
  // en la card antes de tocarla) para medir el escenario "miniatura cacheada".
  await page.evaluate(() => new Promise(res => {
    const t = [...document.querySelectorAll('#listProductos .wh-foto.is-tap')]
      .find(x => { const i = x.querySelector('.wh-foto-img'); return i && i.complete && i.naturalWidth > 0; });
    if (!t) return res(false);
    window.__tile = t;
    t.scrollIntoView({ block: 'center' });
    setTimeout(() => res(true), 300);
  }));

  const caja = await page.evaluate(() => {
    const t = window.__tile;
    if (!t) return null;
    const r = t.getBoundingClientRect();
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
  });

  if (caja) {
    // Cronómetro DENTRO de la página: t0 en el pointerdown físico y parada en el
    // segundo rAF tras insertarse el overlay = primer frame realmente PINTADO.
    // (Medir desde Node incluiría el poll de Playwright y el swap a 800px.)
    await page.evaluate(() => {
      window.__m = {};
      document.addEventListener('pointerdown', () => { window.__m.t0 = performance.now(); }, true);
      new MutationObserver(() => {
        const ov = document.getElementById('whProdLb');
        if (!ov || window.__m.visto) return;
        window.__m.visto = 1;
        const im = ov.querySelector('.wh-lb-img');
        window.__m.srcInicialEsMini = !!(im && /width=128/.test(im.src));
        window.__m.miniYaDecodificada = !!(im && im.complete && im.naturalWidth > 0);
        requestAnimationFrame(() => requestAnimationFrame(() => {
          window.__m.msPintado = Math.round(performance.now() - window.__m.t0);
        }));
      }).observe(document.body, { childList: true });
    });
    const t0 = Date.now();
    if (tactil) await page.touchscreen.tap(caja.x, caja.y);
    else        await page.mouse.click(caja.x, caja.y);
    await page.waitForFunction(() => window.__m && window.__m.msPintado != null, { timeout: 5000 });
    salida.apertura = await page.evaluate(() => ({
      msTapAPrimerFramePintado: window.__m.msPintado,
      msInternoApp: window.__whLbMs || null,
      arrancoConLaMiniaturaCacheada: window.__m.srcInicialEsMini,
      miniaturaYaDecodificadaAlAbrir: window.__m.miniYaDecodificada,
      msDesdeNodeIncluyeSwap800: 0
    }));
    salida.apertura.msDesdeNodeIncluyeSwap800 = Date.now() - t0;
  }

  salida.lightboxFoto = await page.evaluate(() => {
    const ov = document.getElementById('whProdLb');
    if (!ov) return { abierto: false };
    const im = ov.querySelector('.wh-lb-img');
    const r  = im ? im.getBoundingClientRect() : null;
    return {
      abierto: true,
      hayVelo: !!ov.querySelector('.wh-lb-velo'),
      hayCerrar: !!ov.querySelector('.wh-lb-x'),
      boton: (ov.querySelector('#whProdLbBtn') || {}).textContent?.trim(),
      titulo: (ov.querySelector('.wh-lb-tit') || {}).textContent?.trim(),
      imgCargada: !!(im && im.complete && im.naturalWidth > 0),
      imgSrc800: !!(im && /width=800/.test(im.src)),
      lado: r ? Math.round(r.width) + 'x' + Math.round(r.height) : null,
      dentroDeViewport: r ? (r.right <= window.innerWidth + 1 && r.bottom <= window.innerHeight + 1) : null,
      // la card NO debe haber abierto el detalle (stopPropagation)
      detalleAbierto: !!(document.getElementById('sheetProdDetalle') || {}).classList?.contains('open')
    };
  });
  await page.waitForTimeout(700);   // deja que llegue el swap a 800px
  salida.swap800 = await page.evaluate(() => {
    const im = document.querySelector('#whProdLb .wh-lb-img');
    return im ? { src800: /width=800/.test(im.src), cargada: im.complete && im.naturalWidth > 0 } : null;
  });
  await shot(page, 'lb_foto');

  // ── 2) Selector Cámara/Galería DESDE el overlay ────────────
  await page.evaluate(() => { try { ProductosView.lbCambiarFoto(); } catch (e) { window.__errSel = String(e.message || e); } });
  await page.waitForTimeout(900);
  salida.selectorDesdeLb = await page.evaluate(() => {
    const ov = document.getElementById('whFotoChooser');
    const inp = document.getElementById('whFotoProdInput');
    const lb = document.getElementById('whProdLb');
    return {
      abierto: !!ov,
      opciones: ov ? [...ov.querySelectorAll('.wh-foto-chooser-op')].map(b => b.textContent.trim()) : [],
      porEncimaDelLb: !!(ov && lb) ? (parseInt(getComputedStyle(ov).zIndex, 10) > parseInt(getComputedStyle(lb).zIndex, 10)) : null,
      inputDesktop: !ov && inp ? { existe: true, capture: inp.getAttribute('capture') } : null,
      err: window.__errSel || null
    };
  });
  await shot(page, 'selector');
  await page.evaluate(() => { try { ProductosView.fotoCerrarChooser(); } catch (_) {} });

  // ── 3) ESC cierra al instante ──────────────────────────────
  await page.keyboard.press('Escape');
  await page.waitForTimeout(250);
  salida.escCierra = await page.evaluate(() => !document.getElementById('whProdLb'));

  // ── 4) TAP en un tile SIN foto → lightbox con iniciales ────
  const caja2 = await page.evaluate(() => {
    const t = [...document.querySelectorAll('#listProductos .wh-foto.is-tap')].find(x => !x.querySelector('.wh-foto-img'));
    if (!t) return null;
    t.scrollIntoView({ block: 'center' });
    const r = t.getBoundingClientRect();
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
  });
  if (caja2) {
    await page.waitForTimeout(300);
    const t1 = Date.now();
    if (tactil) await page.touchscreen.tap(caja2.x, caja2.y);
    else        await page.mouse.click(caja2.x, caja2.y);
    await page.waitForFunction(() => !!document.querySelector('#whProdLb .wh-foto-xl'), { timeout: 5000 }).catch(() => {});
    salida.msTapTile = Date.now() - t1;
  }
  salida.lightboxTile = await page.evaluate(() => {
    const ov = document.getElementById('whProdLb');
    if (!ov) return { abierto: false };
    const xl = ov.querySelector('.wh-foto-xl');
    const r = xl ? xl.getBoundingClientRect() : null;
    return {
      abierto: true, hayTileGrande: !!xl,
      iniciales: xl ? (xl.querySelector('.wh-foto-ini') || {}).textContent : null,
      boton: (ov.querySelector('#whProdLbBtn') || {}).textContent?.trim(),
      lado: r ? Math.round(r.width) : 0,
      detalleAbierto: !!(document.getElementById('sheetProdDetalle') || {}).classList?.contains('open')
    };
  });
  await shot(page, 'lb_tile');

  // ── 5) Tap en el VELO cierra ───────────────────────────────
  if (tactil) await page.touchscreen.tap(6, 6); else await page.mouse.click(6, 6);
  await page.waitForTimeout(250);
  salida.veloCierra = await page.evaluate(() => !document.getElementById('whProdLb'));

  // ── 6) Desde el DETALLE: tocar la foto grande abre el visor ─
  await page.evaluate(() => {
    const cs = [...document.querySelectorAll('#listProductos .prod-card')];
    const c = cs.find(x => x.querySelector('.wh-foto-img')) || cs[0];
    if (c) { c.scrollIntoView({ block: 'center' }); c.querySelector('p.font-bold').click(); }
  });
  await page.waitForTimeout(2500);
  const caja3 = await page.evaluate(() => {
    const t = document.querySelector('#prodDetFotoBox .wh-foto.is-tap');
    if (!t) return null;
    const r = t.getBoundingClientRect();
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
  });
  if (caja3) {
    const t2 = Date.now();
    if (tactil) await page.touchscreen.tap(caja3.x, caja3.y);
    else        await page.mouse.click(caja3.x, caja3.y);
    await page.waitForFunction(() => !!document.getElementById('whProdLb'), { timeout: 5000 }).catch(() => {});
    salida.msTapDetalle = Date.now() - t2;
  }
  salida.lightboxDesdeDetalle = await page.evaluate(() => {
    const ov = document.getElementById('whProdLb');
    return { abierto: !!ov, boton: ov ? (ov.querySelector('#whProdLbBtn') || {}).textContent?.trim() : null };
  });
  await shot(page, 'lb_detalle');

  salida.pageerrors = errores;
  salida.consolaErr = consola.slice(-12);
  await browser.close();
  console.log(JSON.stringify(salida, null, 1));
})().catch(e => { console.error('FATAL', e); process.exit(1); });
