import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='mos' and p.proname='cron_dispositivos_inactivos' limit 1`)).rows[0].d;
console.log(d);
console.log('\n── ¿cuántos ACTIVO llevan >2 días sin conectar? (los que el cron debería suspender)');
console.table((await c.query(`select app, count(*) n, round(max(extract(epoch from (now()-ultima_conexion))/86400)::numeric,1) max_dias
  from mos.dispositivos where upper(estado)='ACTIVO' and ultima_conexion < now() - interval '2 days' group by 1`)).rows);
await c.end();
