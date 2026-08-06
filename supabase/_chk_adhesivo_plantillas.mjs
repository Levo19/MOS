import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.log('── columnas mos.adhesivo_plantillas:');
console.log((await c.query(`select column_name, data_type from information_schema.columns
  where table_schema='mos' and table_name='adhesivo_plantillas' order by ordinal_position`)).rows
  .map(r => r.column_name + ' (' + r.data_type + ')').join(', '));
console.log('\n── plantillas existentes:');
const rows = (await c.query(`select * from mos.adhesivo_plantillas order by fecha_creado desc limit 3`)).rows;
for (const r of rows) {
  const copy = { ...r };
  if (copy.json) copy.json = JSON.stringify(copy.json).slice(0, 2600);
  console.log(JSON.stringify(copy, null, 1).slice(0, 3200), '\n---');
}
await c.end();
