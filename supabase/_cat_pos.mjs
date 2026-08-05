import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const fns = (await c.query(`select n.nspname||'.'||p.proname f, pg_get_functiondef(p.oid) d
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where p.prokind='f' and pg_get_functiondef(p.oid) ~* 'PRESENTACIONES' and n.nspname in ('me','mos','public')`)).rows;
console.log('RPCs que arman PRESENTACIONES:', fns.map(x=>x.f).join(', '));
for (const x of fns) {
  const i = x.d.search(/PRESENTACIONES/i);
  console.log('\n== '+x.f+' (contexto):');
  console.log(x.d.slice(Math.max(0,i-500), i+400));
}
await c.end();
