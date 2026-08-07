// FASE 2 del Catálogo Virtual — verificación punta a punta.
//   node _catv_fase2_check.mjs <url> <tag>
// Sin url arranca un servidor estático sobre C:/Users/ISO/ecosistema MOS/MosGo.
//
// Cubre: 0 pageerrors en 5 anchos + WebKit(iPhone), lightbox, carrito con líneas,
// audit responsive (desborde, tipografía de inputs, safe-area, dvh) y el CIERRE REAL
// del pedido contra mos.catv_solicitar (crea un SOL-xxx de verdad) + el test explícito
// de anti-manipulación de precios.
import { chromium, webkit, devices } from 'playwright';
import http from 'http';
import fs from 'fs';
import path from 'path';

const RAIZ = 'C:/Users/ISO/ecosistema MOS/MosGo';
const OUT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/';
const TAG = process.argv[3] || 'local';
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.json': 'application/json',
  '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon' };

let URL_BASE = process.argv[2] || '';
let srv = null;
if (!URL_BASE) {
  const PORT = 8811;
  srv = http.createServer((rq, rs) => {
    const u = decodeURIComponent(rq.url.split('?')[0]);
    const f = path.join(RAIZ, u === '/' ? 'index.html' : u);
    if (!f.startsWith(path.resolve(RAIZ))) { rs.writeHead(403).end(); return; }
    fs.readFile(f, (e, b) => e ? rs.writeHead(404).end()
      : rs.writeHead(200, { 'Content-Type': MIME[path.extname(f)] || 'application/octet-stream' }).end(b));
  });
  await new Promise(r => srv.listen(PORT, '127.0.0.1', r));
  URL_BASE = 'http://127.0.0.1:' + PORT + '/catalogo.html';
}

const T = []; const chk = (n, cond, x) => { T.push([cond ? '✅' : '❌', n, x === undefined ? '' : String(x)]); return cond; };
const tomas = [];
const informe = { url: URL_BASE, tag: TAG, vistas: {} };

/* ── una vista: carga el libro, audita y (si toca) hace el flujo completo ────── */
async function vista(browser, cfg) {
  const ctx = await browser.newContext(cfg.ctx);
  const pg = await ctx.newPage();
  const errs = [], cons = [], red = [];
  pg.on('pageerror', e => errs.push(String(e)));
  pg.on('console', m => { if (m.type() === 'error') cons.push(m.text()); });
  pg.on('requestfailed', r => {
    const u = r.url();
    if (/wa\.me|whatsapp/.test(u)) return;             // el salto a WhatsApp no es un fallo
    red.push(u.slice(0, 110) + ' · ' + ((r.failure() || {}).errorText || ''));
  });

  await pg.goto(URL_BASE, { waitUntil: 'networkidle' });
  await pg.waitForSelector('.p', { timeout: 30000 });
  await pg.waitForTimeout(900);

  const shot = async nombre => {
    const f = OUT + `catv2_${cfg.n}_${nombre}.png`;
    await pg.screenshot({ path: f });
    tomas.push(f); return f;
  };
  const irY = async (sel, i = 0) => {
    await pg.evaluate(([s, k]) => {
      const el = document.querySelectorAll(s)[k];
      if (el) window.scrollTo({ top: el.getBoundingClientRect().top + window.scrollY, behavior: 'instant' });
    }, [sel, i]);
    await pg.waitForTimeout(1100);
  };

  // ── AUDIT RESPONSIVE en la hoja de productos ────────────────────────────────
  await irY('.hoja', 0);
  const aud = await pg.evaluate(() => {
    const W = window.innerWidth;
    const desbordes = [];
    for (const el of document.querySelectorAll('body *')) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      if (r.right > W + 1.5 || r.left < -1.5) {
        const cs = getComputedStyle(el);
        if (cs.position === 'fixed' && +cs.opacity === 0) continue;   // ocultos no cuentan
        if (el.closest('.marq') || el.closest('.amb') || el.className === 'num') continue; // decorados a propósito
        // recortado por un ancestro con overflow oculto ⇒ el usuario no ve nada raro
        let rec = false;
        for (let a = el.parentElement; a && a !== document.body; a = a.parentElement) {
          const ac = getComputedStyle(a);
          if (ac.overflow !== 'visible' && ac.overflowX !== 'visible') {
            const ar = a.getBoundingClientRect();
            if (ar.right <= W + 1.5 && ar.left >= -1.5) { rec = true; break; }
          }
        }
        if (rec) continue;
        desbordes.push((el.tagName + '.' + (el.className || '')).slice(0, 60) +
          ' [' + Math.round(r.left) + '…' + Math.round(r.right) + ']');
      }
    }
    return {
      docDesborde: document.documentElement.scrollWidth > W + 1,
      bodyDesborde: document.body.scrollWidth > W + 1,
      desbordes: desbordes.slice(0, 8),
      fichas: document.querySelectorAll('.p').length,
      lupas: document.querySelectorAll('.p .lupa').length,
      fabBottom: getComputedStyle(document.getElementById('fab')).bottom,
      vh: document.documentElement.style.getPropertyValue('--vh')
    };
  });
  chk(`${cfg.n} · 0 pageerrors`, errs.length === 0, errs.join(' | ').slice(0, 160));
  chk(`${cfg.n} · 0 errores de consola`, cons.length === 0, cons.join(' | ').slice(0, 160));
  chk(`${cfg.n} · 0 requests fallidos`, red.length === 0, red.join(' | ').slice(0, 160));
  chk(`${cfg.n} · sin desborde horizontal`, !aud.docDesborde && !aud.bodyDesborde && aud.desbordes.length === 0,
    aud.desbordes.join(' | ') || 'limpio');
  chk(`${cfg.n} · cada ficha tiene su lupa`, aud.lupas === aud.fichas, `${aud.lupas}/${aud.fichas}`);
  chk(`${cfg.n} · --vh medido (nada de dvh)`, /px$/.test(aud.vh), aud.vh);

  // ── LIGHTBOX ────────────────────────────────────────────────────────────────
  await pg.click('.p');
  await pg.waitForSelector('#lb.on .lbx', { timeout: 6000 });
  await pg.waitForTimeout(650);
  await shot('1lightbox');

  const lb = await pg.evaluate(() => {
    const x = document.querySelector('.lbx');
    const r = x.getBoundingClientRect();
    return {
      nombre: (x.querySelector('.lbn') || {}).textContent,
      meta: (x.querySelector('.lbm') || {}).textContent,
      escalones: x.querySelectorAll('.lbesc button').length,
      elegido: [...x.querySelectorAll('.lbesc button')].filter(b => b.getAttribute('aria-pressed') === 'true').length,
      color: getComputedStyle(x).getPropertyValue('--c').trim(),
      filoColor: getComputedStyle(x, '::before').backgroundColor,
      subtotal: (x.querySelector('.lbstep .sub b') || {}).textContent,
      cantidad: (x.querySelector('.lbstep .q') || {}).textContent,
      cabe: r.right <= window.innerWidth + 1 && r.left >= -1,
      taps: [...x.querySelectorAll('.lbesc button,.lbstep .cj button,.bmax,.cerrar')]
        .map(b => { const q = b.getBoundingClientRect(); return Math.min(q.width, q.height); })
    };
  });
  chk(`${cfg.n} · lightbox con nombre y escalones`, !!lb.nombre && lb.escalones > 0, `${lb.nombre} · ${lb.escalones} esc`);
  chk(`${cfg.n} · lightbox: exactamente 1 escalón elegido`, lb.elegido === 1, lb.elegido);
  chk(`${cfg.n} · lightbox teñido con el color del capítulo`, /^#[0-9a-f]{6}$/i.test(lb.color), lb.color);
  chk(`${cfg.n} · lightbox cabe en el ancho`, lb.cabe);
  chk(`${cfg.n} · objetivos táctiles ≥ 34px`, lb.taps.every(t => t >= 33.5), Math.min(...lb.taps).toFixed(1) + 'px');

  // stepper + escalón: el subtotal debe seguir
  const sub0 = lb.subtotal;
  await pg.click('.lbstep .cj button[data-paso="1"]');
  await pg.waitForTimeout(280);
  const st = await pg.evaluate(() => ({
    c: document.querySelector('.lbstep .q').textContent,
    s: document.querySelector('.lbstep .sub b').textContent
  }));
  chk(`${cfg.n} · stepper sube la cantidad`, st.c === '2', st.c);
  chk(`${cfg.n} · subtotal recalcula con la cantidad`, st.s !== sub0, `${sub0} → ${st.s}`);
  if (lb.escalones > 1) {
    await pg.click('.lbesc button[data-ei="1"]');
    await pg.waitForTimeout(280);
    const e2 = await pg.evaluate(() => [...document.querySelectorAll('.lbesc button')]
      .map(b => b.getAttribute('aria-pressed')).join(','));
    chk(`${cfg.n} · tocar otro escalón lo selecciona`, e2.split(',')[1] === 'true', e2);
    await pg.click('.lbesc button[data-ei="0"]');
    await pg.waitForTimeout(200);
  }

  // ESC cierra
  await pg.keyboard.press('Escape');
  await pg.waitForTimeout(500);
  chk(`${cfg.n} · ESC cierra la lupa`, !(await pg.evaluate(() => document.getElementById('lb').classList.contains('on'))));

  // ── CARRITO: dos productos distintos ────────────────────────────────────────
  const nFichas = await pg.evaluate(() => document.querySelectorAll('.p').length);
  for (const k of [0, Math.min(1, nFichas - 1)]) {
    await pg.evaluate(i => document.querySelectorAll('.p')[i].click(), k);
    await pg.waitForSelector('#lb.on .lbx', { timeout: 6000 });
    await pg.waitForTimeout(420);
    if (k === 0) await pg.click('.lbstep .cj button[data-paso="1"]');   // 2 unidades del primero
    await pg.waitForTimeout(180);
    await pg.click('.bmax[data-add]');
    await pg.waitForTimeout(750);
  }
  const burb = await pg.evaluate(() => ({
    n: document.getElementById('burbN').textContent,
    on: document.getElementById('burb').classList.contains('on'),
    fabArriba: document.getElementById('fab').classList.contains('arriba'),
    guardado: JSON.parse(localStorage.getItem('catv_pedido_v1') || 'null')
  }));
  chk(`${cfg.n} · burbuja visible con contador`, burb.on && burb.n === '3', `n=${burb.n}`);
  chk(`${cfg.n} · el buscador sube al aparecer el carrito`, burb.fabArriba);
  chk(`${cfg.n} · carrito persistido en localStorage`, !!burb.guardado && burb.guardado.items.length === 2,
    JSON.stringify(burb.guardado && burb.guardado.items));
  chk(`${cfg.n} · el localStorage NO guarda precios`, !/precio|total|sub/i.test(JSON.stringify(burb.guardado)),
    JSON.stringify(burb.guardado));

  await pg.click('#burb');
  await pg.waitForSelector('#cesta.on .cx', { timeout: 6000 });
  await pg.waitForTimeout(650);
  await pg.fill('#cnom', 'Bodega La Prueba QA');
  await pg.fill('#ctel', '987 654 321');
  await pg.waitForTimeout(320);
  await shot('2carrito');

  const ce = await pg.evaluate(() => {
    const c = document.querySelector('.cx');
    const r = c.getBoundingClientRect();
    const fs = n => parseFloat(getComputedStyle(document.getElementById(n)).fontSize);
    return {
      lineas: c.querySelectorAll('.cli').length,
      total: (c.querySelector('#ctot') || {}).textContent,
      resumen: (c.querySelector('#cq') || {}).textContent,
      inputs: [fs('cnom'), fs('ctel')],
      cabe: r.right <= window.innerWidth + 1 && r.left >= -1 && r.height <= window.innerHeight + 1,
      pieSafe: getComputedStyle(c.querySelector('.pie')).paddingBottom,
      subtotales: [...c.querySelectorAll('.cli .pz')].map(x => x.textContent.trim())
    };
  });
  chk(`${cfg.n} · cesta con 2 líneas`, ce.lineas === 2, ce.lineas);
  chk(`${cfg.n} · cesta con total grande`, /^S\/ [0-9]/.test(ce.total || ''), ce.total);
  chk(`${cfg.n} · inputs ≥16px (Safari no hace zoom)`, ce.inputs.every(f => f >= 16), ce.inputs.join('/'));
  chk(`${cfg.n} · la cesta cabe en la pantalla`, ce.cabe);

  // stepper de la cesta
  const t0 = ce.total;
  await pg.click('.cli:first-child .cj button[data-d="1"]');
  await pg.waitForTimeout(380);
  const t1 = await pg.evaluate(() => document.getElementById('ctot').textContent);
  chk(`${cfg.n} · stepper de la cesta mueve el total`, t1 !== t0, `${t0} → ${t1}`);
  const nom1 = await pg.inputValue('#cnom');
  chk(`${cfg.n} · el nombre no se pierde al tocar el stepper`, nom1 === 'Bodega La Prueba QA', nom1);
  await pg.click('.cli:first-child .cj button[data-d="-1"]');
  await pg.waitForTimeout(320);

  informe.vistas[cfg.n] = { pageerrors: errs, consoleErrors: cons, requestFailed: red, aud, lb, burb, ce };
  return { pg, ctx };
}

/* ═══ 1 · CHROMIUM: 360 / 390 / 768 / 1024 / 1440 ═══ */
const b1 = await chromium.launch();
const ANCHOS = [
  { n: '360', ctx: { viewport: { width: 360, height: 780 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 } },
  { n: '390', ctx: { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 } },
  { n: '768', ctx: { viewport: { width: 768, height: 1024 }, hasTouch: true } },
  { n: '1024', ctx: { viewport: { width: 1024, height: 800 } } },
  { n: '1440', ctx: { viewport: { width: 1440, height: 900 } } }
];
let ultimo = null;
for (const cfg of ANCHOS) {
  const v = await vista(b1, cfg);
  if (cfg.n === '390') ultimo = v; else await v.ctx.close();
}

/* ═══ 2 · CIERRE REAL DEL PEDIDO (una sola vez: el servidor limita 5/hora) ═══ */
let SOL = null;
{
  const { pg, ctx } = ultimo;
  const abiertas = [];
  ctx.on('page', p => abiertas.push(p));
  await pg.click('.bmax[data-enviar]');
  await pg.waitForSelector('.clisto', { timeout: 20000 });
  await pg.waitForTimeout(900);
  const f = OUT + 'catv2_390_3enviado.png';
  await pg.screenshot({ path: f }); tomas.push(f);

  const z = await pg.evaluate(() => ({
    codigo: (document.querySelector('.clisto .cod') || {}).textContent || '',
    texto: (document.querySelector('.clisto p') || {}).textContent || '',
    wa: (document.querySelector('.clisto .wa2') || {}).href || ''
  }));
  SOL = z.codigo;
  chk('cierre · devuelve un código SOL-n', /^SOL-[0-9]+$/.test(z.codigo), z.codigo || '(vacío)');
  chk('cierre · el enlace es wa.me/51967767081', z.wa.indexOf('https://wa.me/51967767081?text=') === 0, z.wa.slice(0, 46));
  const msg = decodeURIComponent((z.wa.split('?text=')[1] || '').replace(/\+/g, ' '));
  chk('cierre · el mensaje lleva el código', msg.indexOf(z.codigo) > 0, msg.split('\n')[2]);
  chk('cierre · el mensaje lleva la lista numerada', /1\) [0-9]+ × /.test(msg));
  chk('cierre · el mensaje lleva el TOTAL', /\*TOTAL: S\/ [0-9]/.test(msg));
  chk('cierre · el mensaje lleva el nombre', msg.indexOf('Bodega La Prueba QA') > 0);
  chk('cierre · se abrió la pestaña de WhatsApp', abiertas.length >= 1, 'pestañas=' + abiertas.length);
  console.log('\n📲 MENSAJE DE WHATSAPP GENERADO:\n' + msg.split('\n').map(l => '   │ ' + l).join('\n'));
  informe.wa = msg; informe.sol = SOL;

  // ── ANTI-MANIPULACIÓN, desde el navegador y como anon ──────────────────────
  const hack = await pg.evaluate(async () => {
    const L = Cesta.vivas();
    const real = Cesta.total();
    const payload = {
      lineas: L.map(l => ({ id: l.it.id, escalon_idx: l.it.ei, cantidad: l.it.c,
        precio: 0.01, precio_unit: 0.01, subtotal: 0.01, label: 'GRATIS' })),
      total: 0.03, nombre: 'QA anti-manipulación', telefono: '900000777',
      ua: 'qa-anti-manipulacion-' + Date.now()
    };
    const r = await fetch(SB_URL + '/rest/v1/rpc/catv_solicitar', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: SB_ANON, Authorization: 'Bearer ' + SB_ANON,
        'Accept-Profile': 'mos', 'Content-Profile': 'mos' },
      body: JSON.stringify({ p: payload })
    });
    return { d: await r.json(), real: real, enviado: 0.03 };
  });
  chk('anti-manipulación · el servidor acepta pero recalcula',
    hack.d && hack.d.ok === true && Math.abs(+hack.d.total - hack.real) < 0.005,
    `enviado=S/ ${hack.enviado} · servidor=S/ ${hack.d && hack.d.total} · real=S/ ${hack.real}`);
  informe.hack = hack;
  await ctx.close();
}
await b1.close();

/* ═══ 3 · WEBKIT (Safari/iPhone): los quirks de iOS ═══ */
{
  const bw = await webkit.launch();
  const v = await vista(bw, { n: 'iphone', ctx: { ...devices['iPhone 13'] } });
  const ios = await v.pg.evaluate(() => {
    const g = (el, p) => getComputedStyle(el).getPropertyValue(p);
    const cx = document.querySelector('.cx');
    return {
      fabBottom: g(document.getElementById('fab'), 'bottom'),
      burbBottom: g(document.getElementById('burb'), 'bottom'),
      piePad: cx ? g(cx.querySelector('.pie'), 'padding-bottom') : '',
      wkBlurLb: g(document.getElementById('lb'), '-webkit-backdrop-filter'),
      wkBlurCesta: g(document.getElementById('cesta'), '-webkit-backdrop-filter'),
      maxCesta: cx ? g(cx, 'max-height') : '',
      dvhEnCss: [...document.styleSheets].some(s => { try {
        return [...s.cssRules].some(r => /dvh/.test(r.cssText)); } catch (_) { return false; } })
    };
  });
  chk('iOS · #fab con safe-area', /px$/.test(ios.fabBottom) && parseFloat(ios.fabBottom) >= 18, ios.fabBottom);
  chk('iOS · burbuja con safe-area', parseFloat(ios.burbBottom) >= 18, ios.burbBottom);
  chk('iOS · pie de la cesta con safe-area', parseFloat(ios.piePad) >= 16, ios.piePad);
  chk('iOS · -webkit-backdrop-filter activo en lupa y cesta',
    /blur/.test(ios.wkBlurLb) && /blur/.test(ios.wkBlurCesta), ios.wkBlurLb + ' | ' + ios.wkBlurCesta);
  chk('iOS · max-height de la cesta resuelto en px (--vh, no dvh)', /px$/.test(ios.maxCesta), ios.maxCesta);
  chk('iOS · CERO dvh en todo el CSS', ios.dvhEnCss === false);
  informe.ios = ios;
  await v.ctx.close();
  await bw.close();
}

/* ═══ 4 · REDUCED MOTION ═══ */
{
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, reducedMotion: 'reduce', hasTouch: true, isMobile: true });
  const pg = await ctx.newPage();
  const errs = [];
  pg.on('pageerror', e => errs.push(String(e)));
  await pg.goto(URL_BASE, { waitUntil: 'networkidle' });
  await pg.waitForSelector('.p', { timeout: 30000 });
  await pg.waitForTimeout(700);
  await pg.click('.p');
  await pg.waitForTimeout(400);
  const rm = await pg.evaluate(() => {
    const x = document.querySelector('.lbx');
    const cs = getComputedStyle(x);
    return { abierta: !!x, opacidad: cs.opacity, transform: cs.transform,
      trans: cs.transitionDuration, vuelos: document.querySelectorAll('.vuela').length };
  });
  chk('reduced-motion · la lupa abre igual y queda quieta',
    rm.abierta && +rm.opacidad === 1 && (rm.transform === 'none' || rm.transform === 'matrix(1, 0, 0, 1, 0, 0)'),
    `op=${rm.opacidad} tr=${rm.transform} dur=${rm.trans}`);
  chk('reduced-motion · 0 pageerrors', errs.length === 0, errs.join(' | '));
  const f = OUT + 'catv2_reducedmotion_lightbox.png';
  await pg.screenshot({ path: f }); tomas.push(f);
  await ctx.close(); await b.close();
}

if (srv) srv.close();
fs.writeFileSync(OUT + `catv2_${TAG}.json`, JSON.stringify(informe, null, 1));

const ok = T.every(t => t[0] === '✅');
console.log('\n' + T.map(t => `${t[0]} ${t[1]}${t[2] ? '  → ' + t[2] : ''}`).join('\n'));
console.log('\n📸 ' + tomas.length + ' capturas:\n' + tomas.map(t => '   ' + t).join('\n'));
console.log(ok ? `\n✅ TODO VERDE · solicitud creada: ${SOL}` : '\n❌ hay pruebas en rojo');
process.exit(ok ? 0 : 1);
