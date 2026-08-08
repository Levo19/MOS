import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
for (const n of ['promociones_lista','crear_promocion']) {
  const r = await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace nn on nn.oid=p.pronamespace where nn.nspname='mos' and p.proname=$1`,[n]);
  console.log('=== '+n+' ===\n'+(r.rows[0]?.d||'NO EXISTE'));
}
const g = await c.query(`select p.proname, r.rolname, has_function_privilege(r.rolname, p.oid,'execute') ex from pg_proc p join pg_namespace nn on nn.oid=p.pronamespace, (values('anon'),('authenticated')) r(rolname) where nn.nspname='mos' and p.proname='promociones_lista'`);
console.dir(g.rows);
await c.end();
