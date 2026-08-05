import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='mos' and p.proname='productos_master_rls' limit 1`)).rows[0].d;
console.log('menciona canal_mayoreo:', /canal_mayoreo/.test(d), '· precio_fijo:', /precio_fijo/.test(d), '· select *:', /select \*|to_jsonb\(p\)|row_to_json/.test(d));
const i = d.search(/jsonb_agg|to_jsonb/); console.log(d.slice(i-100, i+320));
await c.end();
