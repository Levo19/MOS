import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
for (const n of ['actualizar_promocion','eliminar_promocion']) {
  const r = await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace nn on nn.oid=p.pronamespace where nn.nspname='mos' and p.proname=$1`,[n]);
  console.log('=== '+n+' ===\n'+(r.rows[0]?.d||'NO EXISTE'));
}
const r2 = await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace nn on nn.oid=p.pronamespace where nn.nspname='mos' and p.proname='catalogo_pos_rls'`);
const d = r2.rows[0].d; const i = d.indexOf('[663]');
console.log('=== pos slice ===\n'+d.slice(Math.max(0,i-200), i+1400));
await c.end();
