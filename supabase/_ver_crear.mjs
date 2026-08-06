import fs from 'fs'; import pkg from 'pg'; const {Client}=pkg;
const c=new Client({connectionString:fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(),ssl:{rejectUnauthorized:false}});
await c.connect();
const d=(await c.query(`select pg_get_functiondef(p.oid) def from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='crear_producto'`)).rows[0].def;
// solo lo relevante: los INSERT y el manejo de tipo
const lineas=d.split('\n');
lineas.forEach((l,i)=>{ if(/insert into|tipo_producto|sku_base|codigo_producto_base|marca|categoria/i.test(l)) console.log(String(i).padStart(4), l.trim().slice(0,150)); });
console.log('--- total líneas:', lineas.length);
await c.end();
