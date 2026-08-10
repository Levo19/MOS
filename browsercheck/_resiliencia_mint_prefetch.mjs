// browsercheck · (1) PRIORIDAD AL CAMINO CRÍTICO y (2) PACIENCIA ESCALONADA
//
// A) Orden de arranque: ninguna precarga pesada puede empezar ANTES de que la
//    verificación de dispositivo haya resuelto (antes salían en paralelo y el POST
//    de auth de 200 bytes quedaba enterrado bajo megabytes).
// B) Mint auto-curado: se CUELGA el primer POST de mint (socket muerto tras el
//    sleep) y se deja pasar el resto. Con 1 solo intento la app se quedaba sin
//    token; con 3 intentos escalonados debe conseguirlo sola.
//
// Uso: node _resiliencia_mint_prefetch.mjs mos|me
import { chromium } from 'playwright';

const APPS = {
  mos: {
    url: 'https://levo19.github.io/MOS/', ls: 'mos_device_id', dev: '7e57c1a0-de1c-4a7e-b0de-c47a10906474', mint: 'mint-mos',
    sesion: JSON.stringify({ idSesion: 'LOCAL_TESTCLAUDE', idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', color: '#4f46e5' })
  },
  me:  { url: 'https://levo19.github.io/MosExpress/', ls: 'mosexpress_deviceId', dev: '7e57c1a0-de1c-4a7e-b0de-c47a10906476', mint: 'mint-me' },
  wh:  { url: 'https://levo19.github.io/warehouseMos-/', ls: 'wh_device_id', dev: '7e57c1a0-de1c-4a7e-b0de-c47a10906475', mint: 'mint-wh' }
};
const k = (process.argv[2] || 'mos').toLowerCase();
const A = APPS[k];
const SB = 'rzbzdeipbtqkzjqdchqk.supabase.co';
let ok = true;

// ── A) ORDEN DE ARRANQUE ───────────────────────────────────────────────────
async function ordenArranque() {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(String(e.message || e)));
  const t0 = Date.now();
  const eventos = [];
  // El prefetch loguea "[prefetch] n/m OK · Xms" al terminar, donde X se mide desde
  // que ARRANCÓ → con eso ubicamos su inicio real en la línea de tiempo.
  let prefetchStart = null;
  page.on('console', m => {
    const mm = /\[prefetch\]\s+\d+\/\d+\s+OK\s+·\s+(\d+)ms/.exec(m.text() || '');
    if (mm && prefetchStart === null) prefetchStart = (Date.now() - t0) - parseInt(mm[1], 10);
  });
  page.on('request', r => {
    const u = r.url();
    if (!u.includes(SB)) return;
    eventos.push({ t: Date.now() - t0, tipo: 'req', u });
  });
  page.on('response', r => {
    const u = r.url();
    if (u.includes('verificar_dispositivo')) eventos.push({ t: Date.now() - t0, tipo: 'verify_resp', u });
  });
  // Sesión sembrada: sin ella MOS muestra el login y el prefetch NUNCA corre.
  await page.addInitScript(([d, key, ses]) => {
    localStorage.setItem(key, d);
    if (ses) localStorage.setItem('MOS_SESSION', ses);
    window.__tAuth = 0; window.__tGracia = 0;
    window.addEventListener('deviceauth:authorized', () => { if (!window.__tAuth) window.__tAuth = Date.now(); });
    window.addEventListener('deviceauth:gracia', () => { if (!window.__tGracia) window.__tGracia = Date.now(); });
  }, [A.dev, A.ls, A.sesion || null]);
  await page.goto(A.url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(30000);

  const tAuthAbs = await page.evaluate(() => window.__tAuth || window.__tGracia || 0);
  const tAuth = tAuthAbs ? (tAuthAbs - t0) : null;
  const verifies = eventos.filter(e => e.tipo === 'verify_resp').map(e => e.t);
  // RPC que SOLO dispara el prefetch (el dashboard tiene sus propias cargas, que
  // no son objeto de este cambio): resumen del día, rango 7d e impresoras PrintNode.
  const PESADAS = /resumen_todos_dia|finanzas_rango|listar_impresoras|impresoras_pn|printers/i;
  const pesadas = eventos.filter(e => e.tipo === 'req' && PESADAS.test(e.u));
  console.log(`\n${k.toUpperCase()} · A) ORDEN DE ARRANQUE`);
  console.log(`  respuestas de verificar_dispositivo: ${verifies.join('ms, ')}ms`);
  console.log(`  evento deviceauth:authorized a los ${tAuth === null ? '(no llegó)' : tAuth + 'ms'}`);
  console.log(`  el prefetch ARRANCÓ a los ${prefetchStart === null ? '(no corrió)' : prefetchStart + 'ms'}`);
  if (prefetchStart !== null && tAuth !== null) {
    const dif = prefetchStart - tAuth;
    console.log(`  >>> prefetch ${dif >= 0 ? 'DESPUÉS' : 'ANTES'} del auth (${dif}ms) — esperado DESPUÉS`);
    if (dif < 0) ok = false;
  }
  console.log(`  requests de precarga pesada: ${pesadas.length}` + (pesadas.length ? ` · la 1ª a los ${pesadas[0].t}ms` : ''));
  if (tAuth !== null && pesadas.length) {
    const antes = pesadas.filter(p => p.t < tAuth);
    console.log(`  precargas ANTES de que el auth autorizara: ${antes.length} (esperado 0)`);
    antes.slice(0, 6).forEach(p => console.log(`     ${p.t}ms ${p.u.slice(0, 110)}`));
    if (antes.length) ok = false;
  } else if (!pesadas.length) {
    console.log('  (sin precargas observadas: sesión no sembrada o dashboard sin datos)');
  }
  console.log(`  pageerrors: ${errs.length}`);
  if (errs.length) { ok = false; errs.slice(0, 3).forEach(e => console.log('   ' + e)); }
  await browser.close();
}

// ── B) MINT AUTO-CURADO ────────────────────────────────────────────────────
async function mintAutocurado() {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(String(e.message || e)));
  // VENTANA MUERTA: TODO POST de mint emitido en los primeros 7s queda COLGADO
  // (socket muerto tras el sleep). Con UN solo intento de 6s la app se quedaba sin
  // token para siempre; con 3 intentos escalonados el 2º sale ya fuera de la ventana.
  const VENTANA_MS = 7000;
  const t0 = Date.now();
  const colgados = [], pasados = [], exitos = [];
  await ctx.route(u => String(u).includes(A.mint), (route) => {
    const t = Date.now() - t0;
    if (t < VENTANA_MS) { colgados.push(t); return; }   // sin resolver
    pasados.push(t);
    route.continue().catch(() => {});
  });
  page.on('response', r => { if (r.url().includes(A.mint) && r.status() === 200) exitos.push(Date.now() - t0); });
  await page.addInitScript(([d, key]) => localStorage.setItem(key, d), [A.dev, A.ls]);
  await page.goto(A.url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(40000);
  console.log(`\n${k.toUpperCase()} · B) MINT AUTO-CURADO (todo mint de los primeros ${VENTANA_MS}ms queda COLGADO)`);
  console.log(`  POST de mint colgados: ${colgados.length} en ms ${colgados.join(', ')}`);
  console.log(`  POST de mint dejados pasar: ${pasados.length} en ms ${pasados.join(', ')}`);
  console.log(`  mint con 200: ${exitos.length}` + (exitos.length ? ` (1º a los ${exitos[0]}ms)` : ''));
  console.log(`  pageerrors: ${errs.length}`);
  const curado = colgados.length >= 1 && exitos.length >= 1;
  console.log(`  >>> se auto-curó (consiguió token pese a la ventana muerta): ${curado ? 'OK' : 'FALLA'}`);
  if (!curado || errs.length) ok = false;
  await browser.close();
}

(async () => {
  await ordenArranque();
  await mintAutocurado();
  console.log(`\nVEREDICTO ${k.toUpperCase()}: ${ok ? 'OK' : 'REVISAR'}`);
  process.exit(ok ? 0 : 1);
})();
