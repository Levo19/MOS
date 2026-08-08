// Borra de mos.purgante_log las filas que dejó el harness de pruebas.
//   node _purgante_limpiar.mjs <token>      (o sin token: borra las de los TEST-CLAUDE)
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const tok = process.argv[2] || null;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const r = await c.query(
  tok ? `delete from mos.purgante_log where token = $1` : `delete from mos.purgante_log where device_id like '7e57c1a0%'`,
  tok ? [tok] : []);
const q = (await c.query(`select count(*)::int n from mos.purgante_log`)).rows[0].n;
console.log(`borradas ${r.rowCount} · quedan ${q} filas en mos.purgante_log`);
if (q === 0) await c.query(`alter sequence mos.purgante_log_id_seq restart with 1`);
await c.end();
