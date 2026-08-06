import fs from 'fs'; import pkg from 'pg'; const {Client}=pkg;
const c=new Client({connectionString:fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(),ssl:{rejectUnauthorized:false}});
await c.connect();
const d=(await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='ia_repesca_pendientes'`)).rows[0].d;
const m=/order by\s+[^\n]+/i.exec(d);
if(!m){ console.log('sin order by?'); process.exit(1); }
const nuevo=d.replace(m[0], 'order by pr.ia_intentos asc, pr.descripcion');
if(nuevo===d){ console.log('sin cambio'); process.exit(1); }
await c.query(nuevo);
console.log('repesca ordenada por intentos ✓ (antes:', m[0].slice(0,60), ')');
await c.end();
