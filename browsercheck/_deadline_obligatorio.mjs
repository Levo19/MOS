// PRUEBA OBLIGATORIA (regla nueva del dueño):
// "verificando" NUNCA puede ser terminal. Con TODAS las llamadas de red
// colgadas, la app debe llegar a un estado RESUELTO (gracia o bloqueo) en
// MENOS DE 12 SEGUNDOS. Se mide con Playwright, muestreando cada 250ms.
// Además: con red SANA y equipo NO autorizado, debe BLOQUEAR igual que siempre.
// Uso: node _deadline_obligatorio.mjs [carpeta]     (default mos731)
import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';
import http from 'http';

const SP = 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad';
const ARBOL = process.argv[2] || 'mos731';
const APP = (process.argv[3] || 'mos').toLowerCase();
const PERFIL = {
  mos: { dev: '7e57c1a0-de1c-4a7e-b0de-c47a10906474', k: { id: 'mos_device_id',       fecha: 'mos_device_auth_date_lima',        devid: 'mos_device_auth_devid' } },
  wh:  { dev: '7e57c1a0-de1c-4a7e-b0de-c47a10906475', k: { id: 'wh_device_id',        fecha: 'wh_device_auth_date_lima',         devid: 'wh_device_auth_devid' } },
  me:  { dev: '7e57c1a0-de1c-4a7e-b0de-c47a10906476', k: { id: 'mosexpress_deviceId', fecha: 'mosexpress_device_auth_date_lima', devid: 'mosexpress_device_auth_id' } },
  go:  { dev: '7e57c1a0-de00-4c1a-9de0-7e57c1a0de00', k: { id: 'mosgo_deviceId',       fecha: 'mosgo_device_auth_date_lima',      devid: 'mosgo_device_auth_id' } }
}[APP];
// device-auth.js NO vive en el repo de WH/ME: es el asset compartido del repo MOS.
const DA_LOCAL = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/assets/auth/device-auth.js';
const LIVE = path.join(SP, 'mos_live');
const DEV = PERFIL.dev;
const PORT = 4143;
const SB = 'rzbzdeipbtqkzjqdchqk.supabase.co';
const TOPE_MS = 12000;

const MIME = { '.html': 'text/html', '.js': 'application/javascript', '.json': 'application/json' };
function servir() {
  return http.createServer((req, res) => {
    let p = decodeURIComponent(req.url.split('?')[0]);
    if (p === '/' || p.endsWith('/')) p += 'index.html';
    const f = path.join(LIVE, p);
    if (!f.startsWith(LIVE) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); res.end('no'); return; }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(f)] || 'text/plain', 'Cache-Control': 'no-cache' });
    res.end(fs.readFileSync(f));
  }).listen(PORT);
}

async function medir(browser, etiqueta, { colgarRed, cacheHoy, devIdFalso, asentar }) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(String(e.message || e)));
  if (colgarRed) await ctx.route(u => String(u).includes(SB), () => {});
  await ctx.route('**/levo19.github.io/MOS/assets/**', route => {
    const u = route.request().url();
    if (u.includes('/auth/device-auth.js')) {
      route.fulfill({ status: 200, contentType: 'application/javascript', body: fs.readFileSync(DA_LOCAL, 'utf8') });
      return;
    }
    const rel = new URL(u).pathname.replace('/MOS/', '');
    const f = path.join(LIVE, rel);
    route.fulfill({ status: 200, contentType: 'application/javascript', body: fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : '' });
  });
  const id = devIdFalso || DEV;
  await page.addInitScript(([d, cache, k]) => {
    localStorage.setItem(k.id, d);
    if (cache) {
      const ayer = cache === 'ayer';
      const ms = Date.now() - (ayer ? 20 * 3600 * 1000 : 0);
      localStorage.setItem(k.devid, d);
      localStorage.setItem(k.fecha, new Date(ms).toLocaleString('en-CA', { timeZone: 'America/Lima' }).slice(0, 10));
      localStorage.setItem(k.fecha + '_ok_ms', String(ms));
    }
  }, [id, cacheHoy || false, PERFIL.k]);

  const t0 = Date.now();
  await page.goto(`http://localhost:${PORT}/`, { waitUntil: 'domcontentloaded', timeout: 60000 }).catch(() => {});
  let t = null, est = null, gr = false;
  while (Date.now() - t0 < 45000) {
    const r = await page.evaluate(() => {
      const da = window.DeviceAuth; const st = da && da.estado ? da.estado() : null;
      return { e: st ? st.estado : null, g: !!(da && da.enGracia && da.enGracia()) };
    }).catch(() => null);
    if (r && r.e && r.e !== 'VERIFICANDO' && r.e !== 'INIT') { t = Date.now() - t0; est = r.e; gr = r.g; break; }
    await page.waitForTimeout(250);
  }
  // [seguridad] La gracia es PROVISIONAL: si el servidor alcanza a responder, su
  // veredicto llega despues y manda. Para juzgar 'bloquea al no autorizado' hay que
  // mirar el estado ASENTADO, no el primero que aparece.
  // El estado se fija ANTES de repintar (a proposito: asi nunca queda colgado en
  // VERIFICANDO aunque el pintado falle). Damos 1.5s para que el repintado aterrice
  // antes de juzgar lo que VE el usuario.
  await page.waitForTimeout(asentar ? 18000 : 1500);
  const ui = await page.evaluate(() => {
    const ov = document.getElementById('deviceAuthOverlay');
    const da = window.DeviceAuth; const st = da && da.estado ? da.estado() : null;
    return { ov: !!ov, txt: ov ? (ov.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 42) : '',
             pb: document.documentElement.classList.contains('da-pre-block'),
             estFin: st ? st.estado : null, grFin: !!(da && da.enGracia && da.enGracia()),
             aut: !!(da && da.isAuthorized && da.isAuthorized()) };
  }).catch(() => ({}));
  await ctx.close();
  return { etiqueta, t, est, gr, ui, errs, estFin: ui.estFin, grFin: ui.grFin };
}

(async () => {
  fs.rmSync(LIVE, { recursive: true, force: true });
  fs.cpSync(path.join(SP, ARBOL), LIVE, { recursive: true });
  const srv = servir();
  const browser = await chromium.launch({ headless: true });
  console.log(`\n### PRUEBA OBLIGATORIA · árbol ${ARBOL} · tope ${TOPE_MS}ms · app=${APP} ###`);
  let ok = true;

  const casos = [
    ['RED COLGADA + verificación previa de hoy ', { colgarRed: true, cacheHoy: true }, 'gracia'],
    ['RED COLGADA + sin verificación previa    ', { colgarRed: true, cacheHoy: false }, 'bloqueo'],
    ['RED COLGADA + equipo desconocido         ', { colgarRed: true, cacheHoy: false, devIdFalso: 'dead0000-0000-4000-8000-' + String(Date.now()).slice(-12) }, 'bloqueo'],
    ['RED COLGADA + verificación de AYER (Lima) ', { colgarRed: true, cacheHoy: 'ayer' }, 'bloqueo']
  ];
  for (const [et, cfg, espera] of casos) {
    const r = await medir(browser, et, cfg);
    const dentro = r.t !== null && r.t < TOPE_MS;
    const correcto = espera === 'gracia'
      ? (r.est === 'ACTIVO' && r.gr === true && r.ui.pb === false)
      : (r.ui.aut === false && r.est !== 'ACTIVO');
    console.log(`  ${et} estado=${String(r.est).padEnd(15)} gracia=${r.gr}`);
    console.log(`     resuelto en ${r.t === null ? 'NUNCA' : r.t + 'ms'} ${dentro ? '✔ <12s' : '✘ FUERA DE PLAZO'} · esperado=${espera} ${correcto ? '✔' : '✘'} · pageerrors=${r.errs.length}`);
    if (r.ui.txt) console.log(`     overlay="${r.ui.txt}"`);
    if (!dentro || !correcto || r.errs.length) ok = false;
  }

  // Caso de seguridad con red SANA: equipo que el servidor NO autoriza → BLOQUEA.
  const rs = await medir(browser, 'RED SANA + equipo NO autorizado', {
    colgarRed: false, cacheHoy: true, asentar: true,
    devIdFalso: 'dead0000-0000-4000-8000-' + String(Date.now() + 7).slice(-12)
  });
  const bloqueaOK = rs.ui.aut === false && rs.estFin !== 'ACTIVO' && rs.grFin === false;
  console.log(`  RED SANA + equipo NO autorizado (cache forjado) primero=${rs.est}/gracia=${rs.gr} → ASENTADO=${rs.estFin}/gracia=${rs.grFin} autorizado=${rs.ui.aut}`);
  console.log(`     >>> BLOQUEA (estado asentado): ${bloqueaOK ? '✔' : '✘'} · pageerrors=${rs.errs.length}`);
  if (!bloqueaOK) ok = false;

  console.log(`\nVEREDICTO: ${ok ? 'CUMPLE la regla (nunca colgado, <12s, y bloquea al no autorizado)' : 'NO CUMPLE'}`);
  await browser.close(); srv.close();
  process.exit(ok ? 0 : 1);
})();
