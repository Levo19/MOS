import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.table((await c.query(`select p.proname, pg_get_function_identity_arguments(p.oid) args from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='catalogo_version'`)).rows);
await c.end();
