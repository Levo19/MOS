// browsercheck · DESPERTAR CONSCIENTE (wake ping) — device-auth 1.0.30
// El módulo es COMPARTIDO: verificarlo en una app verifica el mecanismo de las 3.
// Comprueba que al volver a 'visible' tras >60s oculto sale un OPTIONS liviano a
// Supabase ANTES de cualquier otro refresco, y que <60s NO lo dispara (sin ruido).
// Uso: node _resiliencia_wakeping.mjs mos|wh|me
import { chromium } from 'playwright';

const APPS = {
  mos: ['https://levo19.github.io/MOS/', 'mos_device_id', '7e57c1a0-de1c-4a7e-b0de-c47a10906474'],
  wh:  ['https://levo19.github.io/warehouseMos-/', 'wh_device_id', '7e57c1a0-de1c-4a7e-b0de-c47a10906475'],
  me:  ['https://levo19.github.io/MosExpress/', 'mosexpress_deviceId', '7e57c1a0-de1c-4a7e-b0de-c47a10906476']
};
const k = (process.argv[2] || 'mos').toLowerCase();
const [URL, LSKEY, DEV] = APPS[k];
const SB = 'rzbzdeipbtqkzjqdchqk.supabase.co';

(async () => {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(String(e.message || e)));
  const opts = [];
  page.on('request', r => { if (r.method() === 'OPTIONS' && r.url().includes(SB)) opts.push({ t: Date.now(), u: r.url() }); });

  // Falsear visibilityState ANTES de que el módulo registre su handler.
  await page.addInitScript(([d, key]) => {
    localStorage.setItem(key, d);
    window.__vis = 'visible';
    Object.defineProperty(Document.prototype, 'visibilityState', { configurable: true, get: () => window.__vis });
    Object.defineProperty(Document.prototype, 'hidden', { configurable: true, get: () => window.__vis === 'hidden' });
    window.__setVis = (v) => { window.__vis = v; document.dispatchEvent(new Event('visibilitychange')); };
  }, [DEV, LSKEY]);

  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(20000);
  const v = await page.evaluate(() => window.DeviceAuth && window.DeviceAuth.VERSION);
  console.log(`${k.toUpperCase()} · DeviceAuth v${v}`);

  // A) oculto CORTO (5s) → NO debe haber wake ping
  opts.length = 0;
  await page.evaluate(() => window.__setVis('hidden'));
  await page.waitForTimeout(5000);
  await page.evaluate(() => window.__setVis('visible'));
  await page.waitForTimeout(4000);
  const cortos = opts.length;
  console.log(`  A) oculto 5s  → OPTIONS a Supabase: ${cortos}  (esperado 0)`);

  // B) oculto LARGO (65s) → SÍ debe salir el wake ping
  opts.length = 0;
  await page.evaluate(() => window.__setVis('hidden'));
  await page.waitForTimeout(65000);
  const antes = opts.length;
  await page.evaluate(() => window.__setVis('visible'));
  await page.waitForTimeout(4000);
  const largos = opts.length - antes;
  console.log(`  B) oculto 65s → OPTIONS a Supabase: ${largos}  (esperado >=1)`);
  if (largos) console.log(`     ping: ${opts[opts.length - 1].u}`);
  console.log(`  pageerrors: ${errs.length} ${errs.slice(0, 3).join(' | ')}`);
  const ok = cortos === 0 && largos >= 1 && errs.length === 0;
  console.log(`  VEREDICTO wake ping: ${ok ? 'OK' : 'REVISAR'}`);
  await browser.close();
  process.exit(ok ? 0 : 1);
})();
