import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const q = async (t,s)=>{ try{ const r=await c.query(s); console.log('###',t); console.dir(r.rows,{depth:3,maxArrayLength:30}); }catch(e){ console.log('###',t,'ERR',e.message); } };
await q('costo0', `select count(*) tot, count(*) filter (where coalesce(precio_costo,0)>0) con_costo from mos.productos where coalesce(estado,false) and tipo_producto::text in ('CANONICO','DERIVADO') and coalesce(es_insumo,false)=false and coalesce(precio_venta,0)>0`);
await q('venc_dist', `
 with v as (select l.cod_producto, min(l.fecha_vencimiento) fv from wh.lotes_vencimiento l where coalesce(l.estado,'ACTIVO')='ACTIVO' and coalesce(l.cantidad_actual,0)>0 and l.fecha_vencimiento is not null group by 1)
 select width_bucket(extract(epoch from (fv-now()))/2629746.0, 0, 12, 12) b, count(*) n, min(extract(epoch from (fv-now()))/2629746.0)::numeric(6,1) mn, max(extract(epoch from (fv-now()))/2629746.0)::numeric(6,1) mx from v group by 1 order by 1`);
await q('venc_lt3_join', `
 with v as (select l.cod_producto, min(l.fecha_vencimiento) fv from wh.lotes_vencimiento l where coalesce(l.estado,'ACTIVO')='ACTIVO' and coalesce(l.cantidad_actual,0)>0 and l.fecha_vencimiento is not null group by 1)
 select p.sku_base, p.descripcion, v.fv, (extract(epoch from (v.fv-now()))/2629746.0)::numeric(6,1) meses, coalesce((select sum(s.cantidad_disponible) from wh.stock s where s.cod_producto=p.codigo_barra),0) stock
 from v join mos.productos p on p.codigo_barra=v.cod_producto
 where extract(epoch from (v.fv-now()))/2629746.0 < 4.6 and coalesce(p.estado,false) and p.tipo_producto::text in ('CANONICO','DERIVADO') and coalesce(p.es_insumo,false)=false and coalesce(p.precio_venta,0)>0
 order by v.fv limit 25`);
await c.end();
