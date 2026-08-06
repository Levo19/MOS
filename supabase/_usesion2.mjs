import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const r = (await c.query(`select n.nspname||'.'||p.proname f from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where p.prokind='f' and pg_get_functiondef(p.oid) ~* 'ultima_sesion'`)).rows;
console.log('mencionan ultima_sesion:', r.map(x=>x.f).join(' · '));
await c.end();
