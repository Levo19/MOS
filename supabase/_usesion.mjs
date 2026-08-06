import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const r = (await c.query(`select n.nspname||'.'||p.proname f from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where p.prokind='f' and pg_get_functiondef(p.oid) ~* 'set\s+ultima_sesion|ultima_sesion\s*='`)).rows;
console.log('escriben ultima_sesion:', r.map(x=>x.f).join(' · ') || '(nadie)');
console.log('\n── dispositivos MOS/mosGo: ¿tienen ultima_sesion?');
console.table((await c.query(`select app, count(*) n, count(*) filter (where nullif(btrim(ultima_sesion),'') is not null) con_sesion
  from mos.dispositivos where upper(estado)='ACTIVO' group by 1`)).rows);
await c.end();
