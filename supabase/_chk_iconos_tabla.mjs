import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.log('── columnas:');
console.log((await c.query(`select column_name from information_schema.columns
  where table_schema='mos' and table_name='adhesivo_iconos' order by ordinal_position`)).rows.map(r=>r.column_name).join(', '));
console.log('── resumen por icono:');
console.table((await c.query(`select id_icono, array_agg(tamano_dots order by tamano_dots) tams, max(length(hex)) hexlen_max
  from mos.adhesivo_iconos group by 1 order by 1 limit 30`)).rows);
await c.end();
