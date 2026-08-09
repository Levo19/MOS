// [WH 2.13.540] Verificación en navegador REAL de la foto del producto en el catálogo.
// Chromium (Android/PC) + WebKit (Safari/iPhone), 390px y 1280px.
//   node _wh540_foto.mjs chromium 390
//   node _wh540_foto.mjs webkit 390
//   node _wh540_foto.mjs chromium 1280
import { chromium, webkit } from 'playwright';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MOTOR = process.argv[2] || 'chromium';
const ANCHO = parseInt(process.argv[3] || '390', 10);
const SUBIR = process.argv.includes('--subir');   // prueba REAL de subida end-to-end
const ID_TEST = process.argv[4] || '';            // idProducto destino de la prueba de subida

const URL = 'https://levo19.github.io/warehouseMos-/';
const DEV = '7e57c1a0-de1c-4a7e-b0de-c47a10906475';   // TEST-CLAUDE-WH
const SESION = JSON.stringify({
  idSesion: 'LOCAL_TESTCLAUDE', idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE',
  apellido: 'CLAUDE', color: '#4f46e5', rol: 'MASTER', fechaDia: '2026-08-09', fechaGuardado: new Date().toISOString()
});

const engine = MOTOR === 'webkit' ? webkit : chromium;
const tactil = ANCHO < 900;

(async () => {
  const browser = await engine.launch({ headless: true });
  const ctx = await browser.newContext({
    viewport: { width: ANCHO, height: ANCHO < 900 ? 844 : 900 },
    hasTouch: tactil, isMobile: tactil && MOTOR !== 'webkit', deviceScaleFactor: 2
  });
  const page = await ctx.newPage();
  const errores = [], consola = [], gas = [];
  page.on('pageerror', e => errores.push('PAGEERROR: ' + e.message));
  page.on('console', m => { if (m.type() === 'error' || m.type() === 'warning') consola.push(`[${m.type()}] ${m.text()}`.slice(0, 220)); });
  page.on('request', r => { if (/script\.google(usercontent)?\.com/.test(r.url())) gas.push(r.url().slice(0, 90)); });

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

  // el wizard de permisos tapa la pantalla en un navegador headless (sin permisos concedidos)
  await page.evaluate(() => { const o = document.getElementById('whPermsOverlay'); if (o) o.remove(); });

  // ── 1) Catálogo con miniaturas ─────────────────────────────
  await page.evaluate(() => { try { App.nav('productos'); } catch (_) {} });
  await page.waitForTimeout(4500);
  await page.evaluate(() => {
    const i = document.getElementById('buscarProd') || document.querySelector('#view-productos input[type=search], #view-productos input');
    if (i) { i.value = 'ANIS'; }
    try { ProductosView.buscar('ANIS'); } catch (_) {}
  });
  await page.waitForTimeout(2500);

  salida.cards = await page.evaluate(() => {
    const cs = [...document.querySelectorAll('#listProductos .prod-card')];
    const fotos = [...document.querySelectorAll('#listProductos .wh-foto')];
    const imgs  = [...document.querySelectorAll('#listProductos .wh-foto-img')];
    return {
      nCards: cs.length, nTiles: fotos.length, nImgs: imgs.length,
      lazy: imgs.every(i => i.getAttribute('loading') === 'lazy'),
      cargadas: imgs.filter(i => i.complete && i.naturalWidth > 0).length,
      usaRender: imgs.filter(i => /\/render\/image\//.test(i.src)).length,
      medida: fotos[0] ? Math.round(fotos[0].getBoundingClientRect().width) : 0,
      sinFotoConIniciales: fotos.filter(f => !f.querySelector('.wh-foto-img') && (f.querySelector('.wh-foto-ini') || {}).textContent).length,
      // ninguna card debe desbordar el ancho de la ventana
      desborde: cs.filter(c => c.getBoundingClientRect().right > window.innerWidth + 1).length
    };
  });
  await page.screenshot({ path: path.join(__dirname, `_540_cards_${MOTOR}_${ANCHO}.png`) });

  // ── 2) Detalle con foto grande + botón Editar ──────────────
  // tap REAL sobre la primera card que SÍ tiene foto (para ver la foto grande en el detalle)
  await page.evaluate(() => {
    const cs = [...document.querySelectorAll('#listProductos .prod-card')];
    const c = cs.find(x => x.querySelector('.wh-foto-img')) || cs[0];
    if (!c) return;
    c.scrollIntoView({ block: 'center' });
    c.querySelector('p.font-bold').click();
  });
  await page.waitForTimeout(3500);
  salida.detalle = await page.evaluate(() => {
    const box = document.getElementById('prodDetFotoBox');
    const img = box && box.querySelector('.wh-foto-img');
    const btn = box && box.querySelector('.prod-detail-foto-btn');
    const sh  = document.getElementById('sheetProdDetalle');
    return {
      sheetAbierto: !!sh && sh.classList.contains('open'),
      hayFotoBox: !!box,
      hayImg: !!img, imgCargada: !!(img && img.complete && img.naturalWidth > 0),
      imgSrcRender: !!(img && /\/render\/image\//.test(img.src)),
      textoBoton: btn ? btn.textContent.trim() : null,
      ladoFoto: box && box.querySelector('.wh-foto') ? Math.round(box.querySelector('.wh-foto').getBoundingClientRect().width) : 0,
      titulo: (document.getElementById('prodDetTitulo') || {}).textContent
    };
  });
  await page.screenshot({ path: path.join(__dirname, `_540_detalle_${MOTOR}_${ANCHO}.png`) });

  // ── 3) Selector Cámara / Galería ───────────────────────────
  await page.evaluate(() => { try { ProductosView.detEditarFoto(); } catch (e) { window.__errSel = String(e.message || e); } });
  await page.waitForTimeout(900);
  salida.selector = await page.evaluate(() => {
    const ov = document.getElementById('whFotoChooser');
    const inp = document.getElementById('whFotoProdInput');
    return {
      abierto: !!ov,
      opciones: ov ? [...ov.querySelectorAll('.wh-foto-chooser-op')].map(b => b.textContent.trim()) : [],
      // en desktop no hay selector: se abre el diálogo de archivos nativo (input sin capture)
      inputDesktop: !ov && !!inp ? { existe: true, capture: inp.getAttribute('capture') } : null,
      err: window.__errSel || null
    };
  });
  await page.screenshot({ path: path.join(__dirname, `_540_selector_${MOTOR}_${ANCHO}.png`) });
  await page.evaluate(() => { try { ProductosView.fotoCerrarChooser(); } catch (_) {} });

  // ── 4) Subida REAL end-to-end (compresión + Storage + set_foto_producto) ──
  if (SUBIR) {
    salida.subida = await page.evaluate(async (idProd) => {
      // imagen sintética GRANDE (2600x1900) para probar que la compresión la deja <300KB
      const cv = document.createElement('canvas'); cv.width = 2600; cv.height = 1900;
      const cx = cv.getContext('2d');
      const gr = cx.createLinearGradient(0, 0, 2600, 1900);
      gr.addColorStop(0, '#1e3a8a'); gr.addColorStop(.5, '#f59e0b'); gr.addColorStop(1, '#065f46');
      cx.fillStyle = gr; cx.fillRect(0, 0, 2600, 1900);
      for (let i = 0; i < 900; i++) { cx.fillStyle = `hsl(${(i * 7) % 360},70%,${30 + (i % 50)}%)`; cx.fillRect((i * 137) % 2600, (i * 91) % 1900, 60, 60); }
      cx.fillStyle = '#fff'; cx.font = 'bold 150px sans-serif'; cx.fillText('TEST 540', 200, 1000);
      const original = cv.toDataURL('image/jpeg', 0.98);
      const bytesOrig = Math.round((original.length - original.indexOf(',') - 1) * 3 / 4);
      const blob = await new Promise(r => cv.toBlob(r, 'image/jpeg', 0.98));
      const file = new File([blob], 'test540.jpg', { type: 'image/jpeg' });

      // Usar EXACTAMENTE la compresión de la app (via el flujo interno expuesto no lo está,
      // así que replicamos el contrato: el módulo comprime a <=1200px y <300KB antes de subir).
      const t0 = Date.now();
      let comprimido = null;
      try {
        // pasar por el flujo real: el módulo comprime dentro de _fotoArchivoElegido
        const dt = new DataTransfer(); dt.items.add(file);
        // no podemos disparar el input file por seguridad → llamamos al API con la compresión del módulo
      } catch (_) {}
      // compresión equivalente (misma escalera que app.js)
      const im = await new Promise(r => { const x = new Image(); x.onload = () => r(x); x.src = original; });
      const pintar = (dim) => { const e = Math.min(1, dim / Math.max(im.width, im.height)); const w = Math.round(im.width * e), h = Math.round(im.height * e); const c2 = document.createElement('canvas'); c2.width = w; c2.height = h; const k = c2.getContext('2d'); k.fillStyle = '#fff'; k.fillRect(0, 0, w, h); k.drawImage(im, 0, 0, w, h); return { c2, w, h }; };
      const peso = du => Math.round((du.length - du.indexOf(',') - 1) * 3 / 4);
      let dim = 1200, q = 0.82, p = pintar(dim), du = p.c2.toDataURL('image/jpeg', q), by = peso(du), v = 0;
      while (by > 300 * 1024 && v < 8) { v++; if (q > .5) q = Math.max(.5, q - .1); else { dim = Math.max(500, Math.round(dim * .8)); p = pintar(dim); q = .72; } du = p.c2.toDataURL('image/jpeg', q); by = peso(du); }
      comprimido = { bytes: by, w: p.w, h: p.h, q, ms: Date.now() - t0 };

      let res = null, err = null;
      try { res = await API.subirFotoProducto(idProd, du.split(',')[1], 'image/jpeg'); }
      catch (e) { err = String(e && e.message || e); }
      return { bytesOrig, comprimido, res, err };
    }, ID_TEST || 'TEST-CLAUDE-FOTO');
  }

  salida.pageerrors = errores;
  salida.consolaErr = consola.slice(-12);
  salida.gasHits = gas.length;
  await browser.close();
  console.log(JSON.stringify(salida, null, 1));
})().catch(e => { console.error('FATAL', e); process.exit(1); });
