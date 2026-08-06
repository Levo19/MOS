import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.table((await c.query(`select tgname, pg_get_triggerdef(t.oid) def from pg_trigger t
  join pg_class cl on cl.oid=t.tgrelid join pg_namespace n on n.oid=cl.relnamespace
 where n.nspname='mos' and cl.relname='productos' and not t.tgisinternal`)).rows.map(r=>({tg:r.tgname, def:r.def.slice(0,150)})));
await c.end();
