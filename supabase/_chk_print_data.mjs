import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const d = (await c.query(`select pg_get_functiondef(p.oid) def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='mos' and p.proname='adhesivo_print_data' and p.prokind='f'`)).rows;
console.log(d[0] ? d[0].def : 'NO EXISTE');
// tabla de iconos si existe
const t = (await c.query(`select table_name from information_schema.tables
  where table_schema='mos' and table_name ilike '%icono%'`)).rows;
console.log('tablas icono:', t.map(r => r.table_name).join(', ') || '(ninguna)');
await c.end();
