// Candidatos a ELIMINAR: en los sku_base con VARIOS "CANONICO", todas las filas que NO
// son el líder real (elección: ficha > no-PRE### > nombre más largo) + los canónicos de
// nombre insuficiente. Con impacto: stock WH, movimientos kardex, ventas ME, hijos.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const r = (await c.query(String.raw`
with lideres as (
  select distinct on (sku_base) sku_base, codigo_barra lider_cod, descripcion lider_desc
    from mos.productos where tipo_producto::text in ('CANONICO','DERIVADO')
   order by sku_base, (descripcion_ia is not null) desc, (codigo_barra !~* '^PRE[0-9]') desc, length(descripcion) desc
),
dup as (
  select p.codigo_barra, p.descripcion, p.sku_base, p.id_producto, coalesce(p.estado,true) estado,
         p.precio_venta, p.descripcion_ia is not null con_ficha, l.lider_cod, l.lider_desc,
         'duplicado' motivo
    from mos.productos p
    join lideres l on l.sku_base = p.sku_base
   where p.tipo_producto::text = 'CANONICO' and p.codigo_barra <> l.lider_cod
     and p.sku_base in (select sku_base from mos.productos where tipo_producto::text in ('CANONICO','DERIVADO')
                        group by sku_base having count(*) > 1)
),
insuf as (
  select p.codigo_barra, p.descripcion, p.sku_base, p.id_producto, coalesce(p.estado,true) estado,
         p.precio_venta, p.descripcion_ia is not null con_ficha, null lider_cod, null lider_desc,
         'nombre insuficiente' motivo
    from mos.productos p
   where p.tipo_producto::text='CANONICO'
     and p.descripcion ~* '^(X *[0-9]+ *UNI?D?(ADES)?\.?|MEDIANO|PEQUEÑO|GRANDE|CHICO|[0-9. ]+ *(METROS?|UNIDADES|MIL)?)$'
     and p.codigo_barra not in (select codigo_barra from dup)
     and p.codigo_barra not in (select lider_cod from lideres)
)
select u.*, 
  coalesce((select sum(s.cantidad_disponible) from wh.stock s where s.cod_producto=u.codigo_barra),0) stock_wh,
  (select count(*) from wh.stock_movimientos m where m.cod_producto=u.codigo_barra) movs,
  (select count(*) from me.ventas_detalle v where v.cod_barras=u.codigo_barra or v.sku=u.sku_base and v.cod_barras=u.codigo_barra) ventas,
  (select count(*) from mos.productos h where h.tipo_producto::text='PRESENTACION' and h.sku_base=u.sku_base) pres_sku,
  (select count(*) from mos.equivalencias e where e.codigo_barra=u.codigo_barra) equiv
from (select * from dup union all select * from insuf) u
order by u.motivo, u.sku_base, u.codigo_barra`)).rows;
console.log('candidatos:', r.length, '· con stock:', r.filter(x=>Number(x.stock_wh)!==0).length,
  '· con movs:', r.filter(x=>Number(x.movs)>0).length, '· con ventas:', r.filter(x=>Number(x.ventas)>0).length,
  '· con ficha:', r.filter(x=>x.con_ficha).length, '· activos:', r.filter(x=>x.estado).length);
fs.writeFileSync('_limpieza_candidatos.json', JSON.stringify(r, null, 1));
// muestra
r.slice(0,8).forEach(x=>console.log(' ', x.motivo,'·',x.codigo_barra,'«'+x.descripcion+'»','→ líder:',x.lider_cod||'—','stock',x.stock_wh,'movs',x.movs,'ventas',x.ventas));
await c.end();
