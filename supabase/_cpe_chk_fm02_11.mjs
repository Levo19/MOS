// Consulta read-only: estado guardado del CPE FM02-11 (soap 0140) y sus vecinos.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const cols = await c.query(`select column_name from information_schema.columns
  where table_schema='me' and table_name='ventas' and column_name like 'nf%' order by 1`);
console.log('cols nf_*:', cols.rows.map(r => r.column_name).join(', '));
const cols2 = await c.query(`select column_name from information_schema.columns
  where table_schema='me' and table_name='ventas' order by ordinal_position`);
console.log('TODAS:', cols2.rows.map(r => r.column_name).join(', '));
const r = await c.query(`
  select correlativo, total, left(cliente_nombre,22) cliente, nf_estado, nf_aceptada_sunat acept,
         nf_sunat_code code, left(coalesce(nf_sunat_desc,''),40) descr,
         to_char(nf_ultima_consulta at time zone 'America/Lima','MM-DD HH24:MI') ult
    from me.ventas
   where correlativo like 'FM02-%' or correlativo like 'BM02-%'
   order by correlativo`);
console.table(r.rows);
const fns = await c.query(`
  select n.nspname||'.'||p.proname f
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('fac','me') and (p.proname ilike '%reconc%' or p.proname ilike '%consult%' or p.proname ilike '%nf%')
   order by 1`);
console.log('funciones reconciler/consulta:', fns.rows.map(x => x.f).join(' · '));
await c.end();
