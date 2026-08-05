import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const fns = (await c.query(`select n.nspname||'.'||p.proname f, pg_get_functiondef(p.oid) d
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in ('wh','mos') and p.prokind='f'
   and pg_get_functiondef(p.oid) ~* 'gemela|guia_gemela|twin'`)).rows;
console.log('funciones que mencionan gemela:', fns.map(x=>x.f).join(', ') || '(ninguna)');
for (const f of fns) { fs.writeFileSync('_def_'+f.f.replace('.','_')+'.sql', f.d); }
await c.end();
