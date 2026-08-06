import fs from 'fs'; import pkg from 'pg'; const {Client}=pkg;
const c=new Client({connectionString:fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(),ssl:{rejectUnauthorized:false}});
await c.connect();
// forma de catalogo_meta y el bump
const cols=(await c.query(`select column_name from information_schema.columns where table_schema='mos' and table_name='catalogo_meta'`)).rows;
console.log('catalogo_meta:', cols.map(r=>r.column_name).join(','));
const bump=(await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='_bump_catalogo_version'`)).rows[0].d;
console.log(bump.split('\n').filter(l=>/update|insert/i.test(l)).join('\n'));
// grants anon en las 3 señaladas
const g=(await c.query(`select p.proname, has_function_privilege('anon', p.oid, 'execute') anon_ok
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='mos' and p.proname in ('_tax_registrar','_ia_marcar_sust','clasificar_producto')`)).rows;
console.log('anon execute:', JSON.stringify(g));
// evidencia hallazgo 1
const ev=(await c.query(`select count(*) n from mos.productos where sust_intentos>0 and updated_at < now() - interval '1 day'`)).rows[0].n;
console.log('filas tocadas por IA con updated_at viejo:', ev);
await c.end();
