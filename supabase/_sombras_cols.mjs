import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const r = await c.query(`select column_name from information_schema.columns
  where table_schema='wh' and table_name='listas_sombra' order by ordinal_position`);
console.log(r.rows.map(x => x.column_name).join(', '));
await c.end();
