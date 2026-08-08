// E2E del CASO ESTRELLA: se mueve stock en un dispositivo -> se ve SOLO en otro WH y en MOS.
// Mide tiempos reales de punta a punta contra las apps DESPLEGADAS.
// Inventario: se sube 1 unidad y se devuelve al final -> neto CERO, verificado al cierre.
import fs from 'fs';
import { chromium } from 'playwright';
import pkg from 'pg';
const { Client } = pkg;

const WH_URL  = 'https://levo19.github.io/warehouseMos-/';
const DEV_WH  = '7e57c1a0-de1c-4a7e-b0de-c47a10906475'; // TEST-CLAUDE-WH (browsercheck) — ACTIVO

const db = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await db.connect();

const br = await chromium.launch({ headless: true });
const ctx = await br.newContext({ viewport: { width: 1280, height: 900 } });
await ctx.addInitScript(`localStorage.setItem('wh_device_id', ${JSON.stringify(DEV_WH)});
  window.__RT = { stock: [], refresh: [] };
  window.addEventListener('wh:stock-realtime', e => window.__RT.stock.push({ t: Date.now(), v: (e.detail||{}).version }));
  window.addEventListener('wh:data-refresh', e => window.__RT.refresh.push({ t: Date.now(), changed: (e.detail||{}).changed||[] }));`);
const wh = await ctx.newPage();
const log = [];
wh.on('console', m => log.push(m.text()));
await wh.goto(WH_URL, { waitUntil: 'domcontentloaded', timeout: 60000 });

console.log('WH abierto. esperando arranque (device-auth + mint + canal + precarga operacional)...');
await new Promise(r => setTimeout(r, 40000));
console.log('canal: ' + (log.filter(l => /canal catalogo_meta/.test(l)).pop() || 'NO SUBSCRIBED'));

// producto conejillo: el que la app ya tiene en cache
const COD = await wh.evaluate(() => {
  const s = OfflineManager.getStockCache() || [];
  const f = s.find(x => Number(x.cantidadDisponible) > 0) || s[0];
  return f && (f.codigoBarra || f.codigoProducto || f.cod_producto);
});
const leerEnApp = () => wh.evaluate((c) => {
  const s = OfflineManager.getStockCache() || [];
  const f = s.find(x => String(x.codigoBarra || x.codigoProducto || x.cod_producto) === String(c));
  return f ? Number(f.cantidadDisponible) : null;
}, COD);

const { rows: [db0] } = await db.query(`select cantidad_disponible q from wh.stock where cod_producto=$1`, [COD]);
const app0 = await leerEnApp();
console.log(`\nconejillo ${COD}: BD=${db0.q} · app=${app0}`);
if (app0 == null) { console.log('la app no tiene ese producto en cache — abortando'); await br.close(); await db.end(); process.exit(1); }

// ── DISPARO: otro dispositivo sube 1 unidad ──────────────────────────────
console.log('\n>>> OTRO DISPOSITIVO suma 1 unidad en wh.stock');
await wh.evaluate(() => { window.__RT.stock = []; window.__RT.refresh = []; });
const t0 = Date.now();
await db.query(`update wh.stock set cantidad_disponible = cantidad_disponible + 1 where cod_producto=$1`, [COD]);
console.log('    commit en BD: ' + (Date.now() - t0) + 'ms');

// esperar a que la app lo refleje sola (sin tocar nada)
let tVisto = null, valorVisto = null;
for (let i = 0; i < 60; i++) {
  await new Promise(r => setTimeout(r, 250));
  const v = await leerEnApp();
  if (v != null && Math.abs(v - (Number(db0.q) + 1)) < 0.001) { tVisto = Date.now(); valorVisto = v; break; }
}
const rt = await wh.evaluate(() => window.__RT);

console.log('\n────────── CASO ESTRELLA · el otro WH, sin que nadie lo toque ──────────');
console.log('  1. evento realtime wh:stock-realtime : ' + (rt.stock.length ? (rt.stock[0].t - t0) + 'ms (v' + rt.stock[0].v + ')' : 'NO LLEGO'));
console.log('  2. wh:data-refresh (dato ya en cache): ' + (rt.refresh.length ? (rt.refresh[0].t - t0) + 'ms changed=' + JSON.stringify(rt.refresh[0].changed) : 'NO LLEGO'));
console.log('  3. valor nuevo visible en la app     : ' + (tVisto ? (tVisto - t0) + 'ms  (' + app0 + ' -> ' + valorVisto + ')' : 'NO SE REFLEJO en 15s'));

// ── RESTAURAR ────────────────────────────────────────────────────────────
await db.query(`update wh.stock set cantidad_disponible = cantidad_disponible - 1 where cod_producto=$1`, [COD]);
const { rows: [dbF] } = await db.query(`select cantidad_disponible q from wh.stock where cod_producto=$1`, [COD]);
console.log('\n  inventario restaurado: BD=' + dbF.q + ' (inicial ' + db0.q + ') · neto ' + (Number(dbF.q) - Number(db0.q)));

await wh.screenshot({ path: 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_rt_wh.png' }).catch(() => {});
await br.close(); await db.end();
process.exit(0);
