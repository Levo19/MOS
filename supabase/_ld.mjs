import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='mos' and p.proname='listar_dispositivos' limit 1`)).rows[0].d;
console.log('campos que emite:', [...d.matchAll(/'([A-Za-z_]+)'\s*,/g)].map(m=>m[1]).join(', ').slice(0,600));
console.log('¿Pendiente_Desde?', d.includes('Pendiente_Desde'), '· ¿Suspendido_Desde?', d.includes('Suspendido_Desde'));
fs.writeFileSync('_def_listar_dispositivos.sql', d);
await c.end();
