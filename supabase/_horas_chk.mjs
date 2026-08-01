import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.log('cols wh.guia_detalle:');
console.log((await c.query(`select column_name, data_type from information_schema.columns
  where table_schema='wh' and table_name='guia_detalle' order by ordinal_position`)).rows
  .map(r => r.column_name + ':' + r.data_type).join(' · '));
console.log('— muestra de items del acumulador ZONA-02 (claves de un item):');
const r = await c.query(`select items->0 it from wh.pickups where id_pickup='PCK-ACU-ZONA-02-2026-07-26'`);
console.log(Object.keys(r.rows[0]?.it || {}).join(', '));
await c.end();
