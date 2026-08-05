import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='wh' and p.proname='cerrar_pickup_con_despacho' limit 1`)).rows[0].d;
fs.writeFileSync('_def_cerrar_pickup_con_despacho.sql', d);
console.log('líneas:', d.split('\n').length);
console.log('\n── qué le hace al pickup:');
d.split('\n').forEach((l,i)=>{ if(/update wh\.pickups|estado\s*=|tomado|lock|bloqueado|operador/i.test(l)) console.log('  L'+(i+1)+': '+l.trim().slice(0,125)); });
await c.end();
