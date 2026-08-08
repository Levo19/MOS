import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const q = async (t,s)=>{ try{ const r=await c.query(s); console.log('###',t); console.dir(r.rows,{depth:3,maxArrayLength:30}); }catch(e){ console.log('###',t,'ERR',e.message); } };
await q('lev182', `
 with ven as (select vd.sku, sum(vd.cantidad) q from me.ventas_detalle vd join me.ventas v on v.id_venta=vd.id_venta where v.fecha>=now()-interval '30 days' and coalesce(v.estado_envio,'')='COMPLETADO' group by 1),
 b as (select p.sku_base, coalesce(vn.q,0) q30 from mos.productos p left join ven vn on vn.sku=p.sku_base where coalesce(p.estado,false) and p.tipo_producto::text in ('CANONICO','DERIVADO') and coalesce(p.es_insumo,false)=false and coalesce(p.precio_venta,0)>0),
 rk as (select sku_base, percent_rank() over (order by q30) pr30 from b where q30>0)
 select b.sku_base, b.q30, rk.pr30 from b left join rk on rk.sku_base=b.sku_base where b.sku_base in ('LEV182','LEV019','LEV0002366','LEV0002367')`);
await q('margen_pct', `select count(*) filter (where coalesce(margen_pct,0)>0) con_mg, count(*) tot from mos.productos where coalesce(estado,false) and tipo_producto::text in ('CANONICO','DERIVADO')`);
await q('costo_y_venta', `
 with ven as (select vd.sku, sum(vd.cantidad) q from me.ventas_detalle vd join me.ventas v on v.id_venta=vd.id_venta where v.fecha>=now()-interval '30 days' and coalesce(v.estado_envio,'')='COMPLETADO' group by 1)
 select count(*) n from mos.productos p join ven vn on vn.sku=p.sku_base where coalesce(p.precio_costo,0)>0`);
await c.end();
