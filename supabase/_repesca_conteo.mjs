import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const r = (await c.query(String.raw`
  with sf as (select p.*, exists(select 1 from mos.equivalencias e where e.sku_base=p.sku_base and e.activo and e.codigo_barra ~ '^\d{8,13}$') eq_ean
    from mos.productos p where p.descripcion_ia like '%sin ficha web específica%' and p.tipo_producto::text='CANONICO')
  select count(*) total,
         count(*) filter (where codigo_barra ~ '^\d{8,13}$' or eq_ean) con_ean,
         count(*) filter (where not (codigo_barra ~ '^\d{8,13}$' or eq_ean)) sin_ean
  from sf`)).rows[0];
console.log(`798 sin ficha → con EAN buscable (marca comercial): ${r.con_ean} · genéricos/graneles sin EAN: ${r.sin_ean}`);
await c.end();
