import fs from 'fs'; import pkg from 'pg'; const {Client}=pkg;
const c=new Client({connectionString:fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(),ssl:{rejectUnauthorized:false}});
await c.connect();
const n=(await c.query(`select count(*) n from mos.productos
  where tipo_producto::text in ('CANONICO','DERIVADO') and coalesce(estado,true)
    and coalesce(es_insumo,false)=false and descripcion_ia is not null and categoria_ia is not null
    and (sust_stale or sustitutos_internos is null)`)).rows[0].n;
console.log(n);
await c.end();
