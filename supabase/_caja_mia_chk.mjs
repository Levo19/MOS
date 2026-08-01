// Forense: cierre de caja ZONA-02 de ayer (31/07) + pickups de zona02.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const tabs = await c.query(`select table_schema||'.'||table_name t from information_schema.tables
  where table_schema in ('me','wh') and (table_name ilike '%caja%' or table_name ilike '%pickup%') order by 1`);
console.log('tablas caja/pickup:', tabs.rows.map(x => x.t).join(' · '));
// cajas de zona02 últimas 48h
const cols = await c.query(`select column_name from information_schema.columns
  where table_schema='me' and table_name='cajas' order by ordinal_position`);
console.log('cols me.cajas:', cols.rows.map(r => r.column_name).join(', '));
await c.end();
