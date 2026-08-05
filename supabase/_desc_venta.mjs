import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='me' and p.proname='zona_descontar_venta' limit 1`)).rows[0].d;
fs.writeFileSync('_def_zona_descontar_venta.sql', d);
console.log('líneas:', d.split('\n').length);
d.split('\n').forEach((l,i)=>{ if(/factor|PRESENTACION|canonico|sku_base|tipo_producto/i.test(l)) console.log('  L'+(i+1)+':', l.trim().slice(0,130)); });
await c.end();
