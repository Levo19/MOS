// browsercheck · RESILIENCIA DE ARRANQUE/REANUDACIÓN (MOS · WH · ME)
//
// Reproduce el escenario real del dueño: la app estuvo en segundo plano, el móvil
// durmió, las conexiones TCP/TLS murieron y al volver el POST de auth se cancela.
//
//   FASE 1  carga normal (con red)      → debe quedar ACTIVO y sembrar el cache
//   FASE 2  pestaña OCULTA + red CAÍDA  → los POST a Supabase QUEDAN COLGADOS
//   FASE 3  reload en esas condiciones  → GRACIA: la app opera, chip "Verificando…"
//   FASE 4  red restaurada + a primer plano → se reverifica sola, chip fuera
//   FASE 5  (negativo) equipo NO autorizado en el servidor, incluso con cache
//           FORJADO y red SANA → DEBE bloquear
//
// Uso:  node _resiliencia_wake.mjs mos|wh|me [--headed]
import { chromium } from 'playwright';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
const __dirname = path.dirname(fileURLToPath(import.meta.url));

const APPS = {
  mos: {
    url: 'https://levo19.github.io/MOS/',
    dev: '7e57c1a0-de1c-4a7e-b0de-c47a10906474',
    ls: { deviceId: 'mos_device_id', fecha: 'mos_device_auth_date_lima', devid: 'mos_device_auth_devid' }
  },
  wh: {
    url: 'https://levo19.github.io/warehouseMos-/',
    dev: '7e57c1a0-de1c-4a7e-b0de-c47a10906475',
    ls: { deviceId: 'wh_device_id', fecha: 'wh_device_auth_date_lima', devid: 'wh_device_auth_devid' }
  },
  me: {
    url: 'https://levo19.github.io/MosExpress/',
    dev: '7e57c1a0-de1c-4a7e-b0de-c47a10906476',
    ls: { deviceId: 'mosexpress_deviceId', fecha: 'mosexpress_device_auth_date_lima', devid: 'mosexpress_device_auth_id' }
  }
};

const SB = 'rzbzdeipbtqkzjqdchqk.supabase.co';
const key = (process.argv[2] || 'mos').toLowerCase();
const APP = APPS[key];
if (!APP) { console.error('app inválida: usa mos|wh|me'); process.exit(1); }
const HEADED = process.argv.includes('--headed');

const log = [];
const say = (s) => { console.log(s); log.push(s); };

// Estado del interceptor: 'ok' = pasa todo · 'hang' = los POST a Supabase se cuelgan
let modoRed = 'ok';
const colgadas = [];

async function estado(page) {
  return page.evaluate(() => {
    const da = window.DeviceAuth;
    const st = da && da.estado ? da.estado() : null;
    const ov = document.getElementById('deviceAuthOverlay');
    return {
      version: da ? da.VERSION : null,
      estado: st ? st.estado : null,
      gracia: !!(da && da.enGracia && da.enGracia()),
      autorizado: !!(da && da.isAuthorized && da.isAuthorized()),
      chip: !!document.getElementById('daGraciaChip'),
      overlay: !!ov,
      overlayTxt: ov ? (ov.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 140) : '',
      preBlock: document.documentElement.classList.contains('da-pre-block'),
      blocked: !!(document.body && document.body.classList.contains('da-blocked'))
    };
  });
}

(async () => {
  const browser = await chromium.launch({ headless: !HEADED });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: false });
  const page = await ctx.newPage();
  const errs = [];
  page.on('pageerror', e => errs.push(String(e && e.message || e)));

  // Interceptor de red hacia Supabase. En modo 'hang' la request NUNCA se resuelve
  // — es el caso REAL (socket muerto tras el sleep), no un ERR_INTERNET_DISCONNECTED.
  await ctx.route(u => String(u).includes(SB), (route) => {
    if (modoRed === 'hang') { colgadas.push(route.request().url()); return; }  // sin resolver = colgada
    route.continue().catch(() => {});
  });

  await page.addInitScript(([d, k]) => { localStorage.setItem(k, d); }, [APP.dev, APP.ls.deviceId]);

  // ── FASE 1 · carga normal ────────────────────────────────────────────────
  say(`\n=== ${key.toUpperCase()} · FASE 1 · carga normal (red OK) ===`);
  const t1 = Date.now();
  await page.goto(APP.url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(18000);
  const f1 = await estado(page);
  say(`  DeviceAuth v${f1.version} · estado=${f1.estado} · autorizado=${f1.autorizado} · overlay=${f1.overlay} · ${Date.now() - t1}ms`);
  const cache1 = await page.evaluate((k) => ({
    fecha: localStorage.getItem(k.fecha),
    devid: localStorage.getItem(k.devid),
    okms: localStorage.getItem(k.fecha + '_ok_ms')
  }), APP.ls);
  say(`  cache: fecha=${cache1.fecha} devid=${(cache1.devid || '').slice(0, 8)} ok_ms=${cache1.okms ? 'SI' : 'NO'}`);

  // ── FASE 2 · pestaña oculta + red caída ──────────────────────────────────
  say(`=== FASE 2 · a segundo plano y se corta la red ===`);
  const otra = await ctx.newPage();
  await otra.goto('about:blank');
  await otra.bringToFront();                      // → la app pasa a visibilityState hidden
  await page.waitForTimeout(1500);
  const oculta = await page.evaluate(() => document.visibilityState);
  say(`  visibilityState de la app = ${oculta}`);
  modoRed = 'hang';
  await page.waitForTimeout(3000);

  // ── FASE 3 · reload con la red colgada (el arranque que fallaba) ─────────
  say(`=== FASE 3 · reload con Supabase COLGADO (arranque tras el sleep) ===`);
  await page.bringToFront();
  const t3 = Date.now();
  await page.reload({ waitUntil: 'domcontentloaded', timeout: 60000 }).catch(e => say('  reload: ' + e.message));
  await page.waitForTimeout(26000);               // > registrar 5s + verificar 8s + margen
  const f3 = await estado(page);
  say(`  estado=${f3.estado} gracia=${f3.gracia} chip=${f3.chip} overlay=${f3.overlay} preBlock=${f3.preBlock} blocked=${f3.blocked} · ${Date.now() - t3}ms`);
  if (f3.overlayTxt) say(`  overlay dice: "${f3.overlayTxt}"`);
  say(`  requests colgadas a Supabase: ${colgadas.length}`);
  const graciaOK = (f3.estado === 'ACTIVO' && f3.gracia === true && f3.overlay === false && f3.preBlock === false);
  say(`  >>> GRACIA (opera sin pantalla de bloqueo): ${graciaOK ? 'OK' : 'FALLA'}`);

  // ── FASE 4 · vuelve la red + vuelve a primer plano ───────────────────────
  say(`=== FASE 4 · vuelve la red y la app vuelve a primer plano ===`);
  await otra.bringToFront();
  await page.waitForTimeout(1200);
  modoRed = 'ok';
  await page.bringToFront();
  await page.waitForTimeout(20000);               // reintentos 3s/8s/20s
  const f4 = await estado(page);
  say(`  estado=${f4.estado} gracia=${f4.gracia} chip=${f4.chip} overlay=${f4.overlay} autorizado=${f4.autorizado}`);
  const recuperoOK = (f4.estado === 'ACTIVO' && f4.gracia === false && f4.chip === false && f4.overlay === false);
  say(`  >>> RECUPERACIÓN SOLA (sin tocar nada): ${recuperoOK ? 'OK' : 'FALLA'}`);
  await page.screenshot({ path: path.join(__dirname, `_res_${key}_recuperado.png`) }).catch(() => {});

  // ── FASE 5 · negativo: equipo NO autorizado + cache FORJADO + red SANA ──
  say(`=== FASE 5 · NEGATIVO · equipo NO autorizado (cache forjado, red sana) ===`);
  const ctx2 = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const p2 = await ctx2.newPage();
  const errs2 = [];
  p2.on('pageerror', e => errs2.push(String(e && e.message || e)));
  const falso = 'dead0000-0000-4000-8000-' + String(Date.now()).slice(-12);
  await p2.addInitScript(([d, k]) => {
    localStorage.setItem(k.deviceId, d);
    // Cache FORJADO a mano: dice "verificado hace un segundo". El veredicto del
    // servidor tiene que ganarle igual.
    localStorage.setItem(k.devid, d);
    localStorage.setItem(k.fecha, new Date().toLocaleString('en-CA', { timeZone: 'America/Lima' }).slice(0, 10));
    localStorage.setItem(k.fecha + '_ok_ms', String(Date.now()));
  }, [falso, APP.ls]);
  await p2.goto(APP.url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await p2.waitForTimeout(20000);
  const f5 = await estado(p2);
  say(`  estado=${f5.estado} gracia=${f5.gracia} autorizado=${f5.autorizado} overlay=${f5.overlay}`);
  if (f5.overlayTxt) say(`  overlay dice: "${f5.overlayTxt}"`);
  const bloqueoOK = (f5.autorizado === false && f5.estado !== 'ACTIVO' && f5.overlay === true);
  say(`  >>> BLOQUEA AL NO AUTORIZADO: ${bloqueoOK ? 'OK' : 'FALLA'}`);
  await p2.screenshot({ path: path.join(__dirname, `_res_${key}_bloqueado.png`) }).catch(() => {});

  say(`\n=== RESUMEN ${key.toUpperCase()} ===`);
  say(`  pageerrors app: ${errs.length} ${errs.slice(0, 5).join(' | ')}`);
  say(`  pageerrors negativo: ${errs2.length} ${errs2.slice(0, 5).join(' | ')}`);
  say(`  F1 activo=${f1.autorizado} · F3 gracia=${graciaOK} · F4 recupero=${recuperoOK} · F5 bloqueo=${bloqueoOK}`);
  const veredicto = (f1.autorizado && graciaOK && recuperoOK && bloqueoOK && errs.length === 0);
  say(`  VEREDICTO: ${veredicto ? 'TODO OK' : 'REVISAR'}`);

  fs.writeFileSync(path.join(__dirname, `_res_${key}.log`), log.join('\n'), 'utf8');
  await browser.close();
  process.exit(veredicto ? 0 : 1);
})();
