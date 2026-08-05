import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
console.log('── funciones cuyo CUERPO usa `correlativo` como criterio de búsqueda de PDF/XML:');
const q = (await c.query(`
  select n.nspname||'.'||p.proname fn, pg_get_function_identity_arguments(p.oid) args,
         coalesce(pg_catalog.array_to_string(p.proacl,'|'),'(default)') acl
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where p.prokind='f' and n.nspname in ('mos','me','fac')
     and pg_get_functiondef(p.oid) ilike '%correlativo = v_corr%'
   order by 1`)).rows;
console.table(q);
for (const r of q) {
  const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname=$1 and p.proname=$2 and pg_get_function_identity_arguments(p.oid)=$3`,
    [r.fn.split('.')[0], r.fn.split('.')[1], r.args])).rows[0].d;
  console.log('\n══ ' + r.fn + '(' + r.args + ')');
  d.split('\n').forEach((l, i) => { if (/v_corr|v_idv|where|select .*from me\.ventas|limit/i.test(l)) console.log('  ' + (i+1) + ': ' + l.trim().slice(0, 130)); });
}
await c.end();
