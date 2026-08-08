// Verifica en navegador REAL que las dos señales nuevas llegan:
//   ME   ← me.ops_meta['stock_zonas']  → _patchStockZonasRapido (parche quirúrgico)
//   MosGo← mos.eco_version()           → el poller ve wh_stock, no solo el catálogo
// No altera datos: los bumps se provocan con updates no-op.
import fs from 'fs';
import { chromium } from 'playwright';
import pkg from 'pg';
const { Client } = pkg;
const DEV_ME = '7e57c1a0-de1c-4a7e-b0de-c47a10906476';
const DEV_GO = '7e57c1a0-de00-4c1a-9de0-7e57c1a0de00';

const db = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await db.connect();
const br = await chromium.launch({ headless: true });

// ── ME ───────────────────────────────────────────────────────────────────
const ctxMe = await br.newContext({ viewport: { width: 420, height: 900 } });
await ctxMe.addInitScript(`localStorage.setItem('mosexpress_deviceId', ${JSON.stringify(DEV_ME)});`);
const me = await ctxMe.newPage();
const meLog = [];
me.on('console', m => meLog.push({ t: Date.now(), s: m.text() }));
await me.goto('https://levo19.github.io/MosExpress/', { waitUntil: 'domcontentloaded', timeout: 60000 });

// ── MosGo ────────────────────────────────────────────────────────────────
const ctxGo = await br.newContext({ viewport: { width: 420, height: 900 } });
await ctxGo.addInitScript(`localStorage.setItem('mosgo_deviceId', ${JSON.stringify(DEV_GO)});`);
const go = await ctxGo.newPage();
const goReq = [];
go.on('request', r => { const u = r.url(); if (/rpc\/(eco_version|catalogo_version|ruta_boot)/.test(u)) goReq.push({ t: Date.now(), fn: u.split('/rpc/')[1] }); });
await go.goto('https://mosgo.vercel.app/', { waitUntil: 'domcontentloaded', timeout: 60000 });

console.log('ambas abiertas; esperando arranque 40s...');
await new Promise(r => setTimeout(r, 40000));
console.log('canal ME: ' + (meLog.map(x => x.s).filter(s => /canal catalogo_meta/.test(s)).pop() || 'NO SUBSCRIBED'));

// ── DISPARO ME: bump de me.ops_meta['stock_zonas'] ───────────────────────
const { rows: [z] } = await db.query(`select cod_barras, zona_id from me.stock_zonas limit 1`);
console.log('\n>>> bump de me.stock_zonas (no-op) ' + z.cod_barras + ' / ' + z.zona_id);
const t0 = Date.now();
await db.query(`update me.stock_zonas set cantidad = cantidad where cod_barras=$1 and zona_id=$2`, [z.cod_barras, z.zona_id]);
await new Promise(r => setTimeout(r, 15000));
const hit = meLog.find(x => x.t > t0 && /stock zona express/.test(x.s));
console.log('  ME parche quirúrgico -> ' + (hit ? (hit.t - t0) + 'ms · "' + hit.s + '"' : 'NO SE DISPARO'));

// ── MosGo: qué RPC pollea ────────────────────────────────────────────────
console.log('\n>>> MosGo · RPCs de versión observadas:');
const cnt = {};
goReq.forEach(r => { cnt[r.fn.split('?')[0]] = (cnt[r.fn.split('?')[0]] || 0) + 1; });
console.log('  ' + (Object.keys(cnt).length ? JSON.stringify(cnt) : 'ninguna todavía (poller de 20s / login pendiente)'));
console.log('  usa eco_version (catalogo+wh_stock): ' + (goReq.some(r => /eco_version/.test(r.fn)) ? 'SI' : 'no observado en esta ventana'));

await br.close(); await db.end();
process.exit(0);
