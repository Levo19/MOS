// ¿Dónde se usa mos.categorias y el margen por categoría? (BD completa)
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const fns = (await c.query(String.raw`
select n.nspname||'.'||p.proname fn, pg_get_functiondef(p.oid) def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('mos','wh','me','ruta','public','fac') and p.prokind='f'
   and pg_get_functiondef(p.oid) ~* 'mos\.categorias'`)).rows;
for (const f of fns) {
  const usaMargen = /margen_pct|modo_venta|precio_tope/i.test(f.def.replace(/--[^\n]*/g,''));
  console.log(`· ${f.fn}  ${usaMargen ? '⚠ USA margen/modo de categoría' : '(solo lista/valida)'}`);
}
// columnas de mos.categorias
const cols=(await c.query(`select column_name from information_schema.columns where table_schema='mos' and table_name='categorias' order by ordinal_position`)).rows;
console.log('\nmos.categorias:', cols.map(r=>r.column_name).join(', '));
await c.end();
