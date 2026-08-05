import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='mos' and p.proname='catalogo_pos_rls' limit 1`)).rows[0].d;
fs.writeFileSync('_def_catalogo_pos_rls.sql', d);
const i = d.search(/'PRESENTACIONES'/);
console.log(d.slice(Math.max(0,i-900), i+120));
await c.end();
