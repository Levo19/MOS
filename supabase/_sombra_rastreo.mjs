// Rastreo indirecto: ¿lo escaneado en LS1785522660160 salió ayer por OTRA guía a ZONA-01?
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.log('— huella de la sombra (items con escaneo > 0):');
const esc = (await c.query(`
  select it->>'skuBase' sku, coalesce(nullif(it->>'nombreMaster',''), it->>'nombre') nombre,
         wh._num(coalesce(it->>'cantidad','0')) pedido,
         wh._num(coalesce(it->>'cantidadEscaneada','0')) escaneado
    from wh.listas_sombra ls, jsonb_array_elements(ls.items) it
   where ls.id_lista = 'LS1785522660160'
     and wh._num(coalesce(it->>'cantidadEscaneada','0')) > 0
   order by 4 desc`)).rows;
console.table(esc.slice(0, 15));
console.log('items escaneados:', esc.length, '· total uds:', esc.reduce((s, r) => s + Number(r.escaneado), 0));
console.log('— guías de salida a ZONA-01 desde ayer 13:00 (posible despacho por otro camino):');
console.table((await c.query(`
  select g.id_guia, g.tipo, g.usuario, g.estado,
         to_char(g.fecha at time zone 'America/Lima','MM-DD HH24:MI') hora,
         (select count(*) from wh.guia_detalle gd where gd.id_guia = g.id_guia) lineas,
         (select round(sum(gd.cant_recibida),1) from wh.guia_detalle gd where gd.id_guia = g.id_guia) uds
    from wh.guias g
   where upper(coalesce(g.id_zona,'')) like '%01%'
     and g.fecha >= (now() at time zone 'America/Lima')::date - 1 + interval '13 hours'
     and g.tipo like 'SALIDA%'
   order by g.fecha`)).rows);
// cruce: ¿cuántos de los skus escaneados aparecen en esas guías con cantidades similares?
console.log('— CRUCE item por item (sku escaneado vs líneas de esas guías):');
console.table((await c.query(`
  with escaneo as (
    select it->>'skuBase' sku, wh._num(coalesce(it->>'cantidadEscaneada','0')) escaneado
      from wh.listas_sombra ls, jsonb_array_elements(ls.items) it
     where ls.id_lista = 'LS1785522660160'
       and wh._num(coalesce(it->>'cantidadEscaneada','0')) > 0),
  lineas as (
    select gd.id_guia, gd.cod_producto, gd.cant_recibida,
           coalesce((select pr.sku_base from mos.productos pr where btrim(pr.codigo_barra)=btrim(gd.cod_producto) limit 1),
                    (select e2.sku_base from mos.equivalencias e2 where btrim(e2.codigo_barra)=btrim(gd.cod_producto) limit 1)) sku
      from wh.guia_detalle gd
      join wh.guias g on g.id_guia = gd.id_guia
     where upper(coalesce(g.id_zona,'')) like '%01%'
       and g.fecha >= (now() at time zone 'America/Lima')::date - 1 + interval '13 hours'
       and g.tipo like 'SALIDA%')
  select e.sku, e.escaneado, l.id_guia, l.cant_recibida en_guia
    from escaneo e
    left join lineas l on l.sku = e.sku
   order by e.escaneado desc limit 20`)).rows);
await c.end();
