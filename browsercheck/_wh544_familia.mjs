// [WH 2.13.544] Verificación en navegador REAL de la DESAMBIGUACIÓN DE CÓDIGOS DUPLICADOS.
// Simula el escaneo de una raíz compartida en DOS flujos distintos (guías + despacho)
// y comprueba que aparezca el selector con TODAS las variantes de la familia.
//   node _wh544_familia.mjs chromium 390
//   node _wh544_familia.mjs chromium 1280
//   node _wh544_familia.mjs webkit  390
import { chromium, webkit } from 'playwright';
import path from 'path';
import fs from 'fs';
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

// Los 2 casos reales medidos en BD por el dueño
const CASO_A = '7758725000036';   // 2 variantes: ...036A wantán azul / ...036B wantán dorado
const CASO_B = '7750464444799';   // 5 en la familia: pelado LA CHINA + ...799A/B/C/D FOCH

const engine = MOTOR === 'webkit' ? webkit : chromium;
const tactil = ANCHO < 900;
const shot = (page, n) => page.screenshot({ path: path.join(__dirname, `_544_${n}_${MOTOR}_${ANCHO}.png`) });

(async () => {
  const browser = await engine.launch({ headless: true });
  const ctx = await browser.newContext({
    viewport: { width: ANCHO, height: ANCHO < 900 ? 844 : 900 },
    hasTouch: tactil, isMobile: tactil && MOTOR !== 'webkit', deviceScaleFactor: 2
  });
  const page = await ctx.newPage();
  const errores = [], consola = [];
  page.on('pageerror', e => errores.push('PAGEERROR: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') consola.push(('[' + m.type() + '] ' + m.text()).slice(0, 220)); });

  await page.addInitScript(([dev, ses]) => {
    localStorage.setItem('wh_device_id', dev);
    localStorage.setItem('wh_sesion', ses);
    localStorage.setItem('wh_last_activity', String(Date.now()));
  }, [DEV, SESION]);

  const out = { motor: MOTOR, ancho: ANCHO };
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 45000 });
  await page.waitForTimeout(26000);   // boot + catálogo (delta)

  out.version = await page.evaluate(async () => {
    try { return (await (await fetch('version.json?b=' + Date.now())).json()).version; } catch (_) { return '?'; }
  });
  await page.evaluate(() => { const o = document.getElementById('whPermsOverlay'); if (o) o.remove(); });

  // ── 0) LA REGLA DE FAMILIA sobre el catálogo REAL ────────────────────────
  out.regla = await page.evaluate(([a, b]) => {
    const r = { hayModulo: !!window.FamiliaCB };
    if (!window.FamiliaCB) return r;
    r.nProds = (OfflineManager.getProductosCache() || []).length;
    const info = (cod) => {
      const raiz = FamiliaCB.raiz(cod);
      const fam  = FamiliaCB.familia(cod);
      const amb  = FamiliaCB.ambigua(cod);
      return {
        cod, raiz, n: fam.length, ambigua: !!amb,
        miembros: fam.map(p => ({
          cb: String(p._scannedCb || p.codigoBarra || ''),
          suf: FamiliaCB.sufijo(p._scannedCb || p.codigoBarra),
          desc: String(p.descripcion || '').slice(0, 46)
        })),
        sufijoLibre: FamiliaCB.sufijoLibre(cod),
        siguiente: FamiliaCB.siguienteCodigo(cod)
      };
    };
    r.casoA = info(a);
    r.casoB = info(b);
    // Con la LETRA explícita NO debe preguntar (el operador ya decidió)
    r.explicitoA = !!FamiliaCB.ambigua(a + 'A');
    // Un código cualquiera de un solo producto no debe volverse ambiguo
    const uno = (OfflineManager.getProductosCache() || []).find(p => {
      const cb = String(p.codigoBarra || '');
      return cb.length === 13 && FamiliaCB.familia(cb).length === 1;
    });
    r.noAmbiguo = uno ? { cb: uno.codigoBarra, ambigua: !!FamiliaCB.ambigua(uno.codigoBarra) } : null;
    // Barrido: cuántas raíces del catálogo tienen más de un miembro
    const vistas = new Set(), raices = [];
    (OfflineManager.getProductosCache() || []).forEach(p => {
      const cb = String(p.codigoBarra || ''); if (!cb) return;
      const rz = FamiliaCB.raiz(cb);
      if (vistas.has(rz)) return;
      vistas.add(rz);
      const n = FamiliaCB.familia(rz).length;
      if (n > 1) raices.push({ raiz: rz, n });
    });
    r.raicesMultiples = raices.sort((x, y) => y.n - x.n);
    return r;
  }, [CASO_A, CASO_B]);

  // ── FLUJO 1 · GUÍAS (barra de captura del detalle = tipeo + lector HID) ──
  // Se llama al núcleo de ruteo con el código, exactamente como lo hace el lector.
  await page.evaluate(() => { try { App.nav('guias'); } catch (_) {} });
  await page.waitForTimeout(3500);

  out.guias = {};
  for (const [nombre, cod] of [['A', CASO_A], ['B', CASO_B]]) {
    const r = await page.evaluate((c) => {
      // Se prepara una guía de INGRESO en memoria para que el ruteo tenga contexto,
      // sin tocar el servidor (no se cierra ni se guarda nada).
      try {
        GuiasView._testSetGuia && GuiasView._testSetGuia();
      } catch (_) {}
      const cand = GuiasView._procesarCodigoEscaneado(c);
      const fam  = cand.filter(x => x._familia);
      return { nCand: cand.length, nFamilia: fam.length, primeroExacto: !!cand[0]?._exacto };
    }, cod);
    // Abrir el sheet real (el mismo que dispara el escaneo)
    await page.evaluate((c) => {
      const amb = FamiliaCB.ambigua(c);
      if (!amb) return;
      FamiliaCB.elegir(amb.raiz, { miembros: amb.miembros, permitirNuevo: true,
        textoNuevo: 'Ninguno · es un producto nuevo' }, () => {});
    }, cod);
    await page.waitForTimeout(600);
    r.sheet = await page.evaluate(() => {
      const ov = document.querySelector('.famcb-ov');
      if (!ov) return null;
      const rows = [...ov.querySelectorAll('.famcb-row')];
      return {
        visible: true,
        titulo: (ov.querySelector('.famcb-ttl') || {}).textContent || '',
        filas: rows.length,
        conFoto: rows.filter(x => x.querySelector('.wh-foto-img')).length,
        conTile: rows.filter(x => x.querySelector('.wh-foto-ini')).length,
        chips: rows.map(x => (x.querySelector('.famcb-chip') || {}).textContent || ''),
        stocks: rows.map(x => (x.querySelector('.famcb-stock') || {}).textContent || ''),
        nombres: rows.map(x => ((x.querySelector('.famcb-name') || {}).textContent || '').slice(0, 44)),
        altoFila: rows[0] ? Math.round(rows[0].getBoundingClientRect().height) : 0,
        nuevo: !!ov.querySelector('[data-famcb-nuevo]'),
        sugerido: (ov.querySelector('.famcb-new-s') || {}).textContent || '',
        desbordaX: document.documentElement.scrollWidth > window.innerWidth + 1
      };
    });
    await shot(page, 'guias' + nombre);
    // Elegir la 2ª variante y comprobar que se recuerda
    r.eleccion = await page.evaluate(() => {
      const rows = [...document.querySelectorAll('.famcb-ov .famcb-row')];
      const el = rows[1] || rows[0];
      if (!el) return null;
      const cb = el.getAttribute('data-famcb-cb');
      el.click();
      return { elegido: cb, sheetCerrado: !document.querySelector('.famcb-ov') };
    });
    await page.waitForTimeout(300);
    // Segundo escaneo del MISMO código → la última elegida arriba y marcada
    await page.evaluate((c) => {
      const amb = FamiliaCB.ambigua(c);
      if (amb) FamiliaCB.elegir(amb.raiz, { miembros: amb.miembros, permitirNuevo: true }, () => {});
    }, cod);
    await page.waitForTimeout(500);
    r.memoria = await page.evaluate(() => {
      const rows = [...document.querySelectorAll('.famcb-ov .famcb-row')];
      if (!rows.length) return null;
      return {
        primeraEsUltima: !!(rows[0] && rows[0].classList.contains('is-ultima')),
        tagArriba: !!(rows[0] && rows[0].querySelector('.famcb-ultima-tag')),
        cbPrimera: rows[0] ? rows[0].getAttribute('data-famcb-cb') : ''
      };
    });
    await shot(page, 'memoria' + nombre);
    await page.evaluate(() => { try { FamiliaCB.cerrar(null); } catch (_) {} });
    await page.waitForTimeout(200);
    out.guias[nombre] = r;
  }

  // ── FLUJO 2 · DESPACHO (salida) ─────────────────────────────────────────
  await page.evaluate(() => { try { App.nav('despacho'); } catch (_) {} });
  await page.waitForTimeout(3000);

  out.despacho = {};
  for (const [nombre, cod] of [['A', CASO_A], ['B', CASO_B]]) {
    const r = await page.evaluate((c) => {
      // El resolvedor de SALIDA es el que usa el escáner de despacho
      const amb = FamiliaCB.ambigua(c, { soloCanonicos: true });
      return { ambigua: !!amb, n: amb ? amb.miembros.length : 0 };
    }, cod);
    // Disparar el flujo REAL de escaneo de despacho
    await page.evaluate((c) => { try { DespachoView.procesarScanGlobal(c); } catch (_) {} }, cod);
    await page.waitForTimeout(400);
    let visible = await page.evaluate(() => !!document.querySelector('.famcb-ov'));
    if (!visible) {
      // Sin despacho activo procesarScanGlobal no hace nada: se abre el sheet igual
      // que lo haría _onDespResult (sin "es nuevo": en salida no se dan de alta códigos).
      await page.evaluate((c) => {
        const amb = FamiliaCB.ambigua(c, { soloCanonicos: true });
        if (amb) FamiliaCB.elegir(amb.raiz, { miembros: amb.miembros, permitirNuevo: false }, () => {});
      }, cod);
      await page.waitForTimeout(500);
      visible = await page.evaluate(() => !!document.querySelector('.famcb-ov'));
      r.viaDirecta = true;
    }
    r.sheet = await page.evaluate(() => {
      const ov = document.querySelector('.famcb-ov');
      if (!ov) return null;
      const rows = [...ov.querySelectorAll('.famcb-row')];
      return {
        filas: rows.length,
        chips: rows.map(x => (x.querySelector('.famcb-chip') || {}).textContent || ''),
        nombres: rows.map(x => ((x.querySelector('.famcb-name') || {}).textContent || '').slice(0, 44)),
        nuevo: !!ov.querySelector('[data-famcb-nuevo]'),   // debe ser false en SALIDA
        desbordaX: document.documentElement.scrollWidth > window.innerWidth + 1
      };
    });
    await shot(page, 'desp' + nombre);
    await page.evaluate(() => { try { FamiliaCB.cerrar(null); } catch (_) {} });
    await page.waitForTimeout(200);
    out.despacho[nombre] = r;
  }

  // ── FLUJO 3 · ALTA DE PRODUCTO NUEVO (sufijo sugerido) ──────────────────
  await page.evaluate(() => { try { App.nav('guias'); } catch (_) {} });
  await page.waitForTimeout(2000);
  await page.evaluate((c) => { try { GuiasView.abrirModalPN(c, ''); } catch (_) {} }, CASO_A);
  await page.waitForTimeout(900);
  out.pn = await page.evaluate(() => {
    const box = document.getElementById('pnFamiliaAviso');
    const items = [...(box ? box.querySelectorAll('[data-famcb-pn-cb]') : [])];
    const btn = box ? box.querySelector('[data-famcb-pn-nuevo]') : null;
    return {
      avisoVisible: !!(box && box.innerHTML.trim()),
      titulo: (box?.querySelector('.famcb-pn-t') || {}).textContent || '',
      variantes: items.length,
      cbs: items.map(x => x.getAttribute('data-famcb-pn-cb')),
      sugerido: btn ? btn.getAttribute('data-famcb-pn-nuevo') : '',
      textoBtn: btn ? btn.textContent.trim() : ''
    };
  });
  await shot(page, 'pn');
  // Tap en "es uno NUEVO" → el input queda con el sufijo propuesto y EDITABLE
  out.pnNuevo = await page.evaluate(() => {
    const btn = document.querySelector('#pnFamiliaAviso [data-famcb-pn-nuevo]');
    if (!btn) return null;
    btn.click();
    const inp = document.getElementById('pnCodigoBarra');
    return { valor: inp ? inp.value : '', editable: inp ? !inp.readOnly : false,
             avisoLimpio: !document.getElementById('pnFamiliaAviso').innerHTML.trim() };
  });
  await page.waitForTimeout(400);
  await shot(page, 'pnSugerido');
  await page.evaluate(() => { try { GuiasView.cerrarModalPN(); } catch (_) {} });

  out.pageerrors = errores;
  out.consolaErrores = consola.slice(0, 12);
  fs.writeFileSync(path.join(__dirname, `_544_${MOTOR}_${ANCHO}.json`), JSON.stringify(out, null, 2));
  console.log(JSON.stringify(out, null, 2));
  await browser.close();
})().catch(e => { console.error('FALLO:', e); process.exit(1); });
