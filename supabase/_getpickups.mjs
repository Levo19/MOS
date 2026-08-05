import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const r = (await c.query(`select n.nspname||'.'||p.proname f, pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace where n.nspname='wh' and p.proname ~ '^(get_)?pickups' limit 3`)).rows;
for (const x of r) {
  console.log('==', x.f);
  const i = x.d.indexOf('jsonb_build_object');
  console.log(x.d.slice(i, i+700));
}
await c.end();
