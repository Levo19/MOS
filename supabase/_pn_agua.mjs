// PN de "agua": estados y tiempos, para entender el aviso fantasma del 7LT.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const t = await c.query(`select table_schema||'.'||table_name t from information_schema.tables
  where table_name ilike '%producto%nuevo%' or table_name ilike '%pn%' order by 1`);
console.log('tablas PN:', t.rows.map(x => x.t).join(' · '));
const cols = await c.query(`select column_name from information_schema.columns
  where table_schema='wh' and table_name='producto_nuevo' order by ordinal_position`);
console.log('cols wh.producto_nuevo:', cols.rows.map(r => r.column_name).join(', '));
const r = await c.query(`select * from wh.producto_nuevo where descripcion ilike '%agua%' limit 12`);
for (const row of r.rows) console.log(JSON.stringify(row));
await c.end();
