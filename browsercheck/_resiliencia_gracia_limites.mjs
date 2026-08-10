// browsercheck · LÍMITES DE LA GRACIA (device-auth 1.0.30) — lo que SÍ debe bloquear
// Con Supabase COLGADO (sin veredicto del servidor):
//   C1) verificación previa de hace 25h  → DEBE BLOQUEAR (supera el umbral de 24h)
//   C2) sin ninguna verificación previa   → DEBE BLOQUEAR (nunca hubo autorización)
//   C3) verificación previa de otro equipo→ DEBE BLOQUEAR (el cache no es de este id)
// Uso: node _resiliencia_gracia_limites.mjs mos|wh|me
import { chromium } from 'playwright';

const APPS = {
  mos: ['https://levo19.github.io/MOS/', { deviceId: 'mos_device_id', fecha: 'mos_device_auth_date_lima', devid: 'mos_device_auth_devid' }, '7e57c1a0-de1c-4a7e-b0de-c47a10906474'],
  wh:  ['https://levo19.github.io/warehouseMos-/', { deviceId: 'wh_device_id', fecha: 'wh_device_auth_date_lima', devid: 'wh_device_auth_devid' }, '7e57c1a0-de1c-4a7e-b0de-c47a10906475'],
  me:  ['https://levo19.github.io/MosExpress/', { deviceId: 'mosexpress_deviceId', fecha: 'mosexpress_device_auth_date_lima', devid: 'mosexpress_device_auth_id' }, '7e57c1a0-de1c-4a7e-b0de-c47a10906476']
};
const k = (process.argv[2] || 'mos').toLowerCase();
const [URL, LS, DEV] = APPS[k];
const SB = 'rzbzdeipbtqkzjqdchqk.supabase.co';

async function caso(browser, nombre, semilla) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(String(e.message || e)));
  await ctx.route(u => String(u).includes(SB), () => { /* COLGADA: nunca resuelve */ });
  await page.addInitScript(semilla);
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 }).catch(() => {});
  await page.waitForTimeout(30000);
  const r = await page.evaluate(() => {
    const da = window.DeviceAuth;
    const st = da && da.estado ? da.estado() : null;
    return {
      estado: st ? st.estado : null,
      gracia: !!(da && da.enGracia && da.enGracia()),
      autorizado: !!(da && da.isAuthorized && da.isAuthorized()),
      overlay: !!document.getElementById('deviceAuthOverlay'),
      preBlock: document.documentElement.classList.contains('da-pre-block')
    };
  });
  const bloqueado = (r.autorizado === false && r.gracia === false && (r.overlay === true || r.preBlock === true));
  console.log(`  ${nombre}: estado=${r.estado} gracia=${r.gracia} autorizado=${r.autorizado} overlay=${r.overlay} preBlock=${r.preBlock} · pageerrors=${errs.length}`);
  console.log(`     >>> BLOQUEA: ${bloqueado ? 'OK' : 'FALLA'}`);
  errs.slice(0, 3).forEach(e => console.log(`     pageerror: ${e.slice(0, 160)}`));
  await ctx.close();
  return bloqueado && errs.length === 0;
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  console.log(`\n${k.toUpperCase()} · LÍMITES DE LA GRACIA (Supabase colgado en los 3 casos)`);

  const c1 = await caso(browser, 'C1 verificación previa de hace 25h', new Function('return ' + `(() => {
    const LS = ${JSON.stringify(LS)}, DEV = ${JSON.stringify(DEV)};
    localStorage.setItem(LS.deviceId, DEV);
    localStorage.setItem(LS.devid, DEV);
    localStorage.setItem(LS.fecha, new Date(Date.now() - 25*3600*1000).toLocaleString('en-CA',{timeZone:'America/Lima'}).slice(0,10));
    localStorage.setItem(LS.fecha + '_ok_ms', String(Date.now() - 25*3600*1000));
  })`)());

  const c2 = await caso(browser, 'C2 sin verificación previa       ', new Function('return ' + `(() => {
    const LS = ${JSON.stringify(LS)}, DEV = ${JSON.stringify(DEV)};
    localStorage.setItem(LS.deviceId, DEV);
  })`)());

  const c3 = await caso(browser, 'C3 cache de OTRO equipo          ', new Function('return ' + `(() => {
    const LS = ${JSON.stringify(LS)}, DEV = ${JSON.stringify(DEV)};
    localStorage.setItem(LS.deviceId, DEV);
    localStorage.setItem(LS.devid, 'aaaa1111-2222-4333-8444-555566667777');
    localStorage.setItem(LS.fecha, new Date().toLocaleString('en-CA',{timeZone:'America/Lima'}).slice(0,10));
    localStorage.setItem(LS.fecha + '_ok_ms', String(Date.now()));
  })`)());

  await browser.close();
  const ok = c1 && c2 && c3;
  console.log(`\nVEREDICTO límites ${k.toUpperCase()}: ${ok ? 'OK' : 'REVISAR'}`);
  process.exit(ok ? 0 : 1);
})();
