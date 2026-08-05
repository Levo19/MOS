// Cuantifica el daño del doble descuento (619) para saber qué hay que ajustar a mano.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

console.log('══ 1. Códigos con stock NEGATIVO en almacén (síntoma principal)');
console.table((await c.query(`select count(*) codigos, round(sum(cantidad_disponible),2) uds
  from wh.stock where cantidad_disponible < 0`)).rows);

console.log('══ 2. Los 12 peores');
console.table((await c.query(`select s.cod_producto, round(s.cantidad_disponible,3) stock,
    left(coalesce(p.descripcion,'?'),38) producto,
    to_char(s.ultima_actualizacion at time zone 'America/Lima','DD/MM HH24:MI') act
  from wh.stock s left join mos.productos p on upper(btrim(p.codigo_barra))=upper(btrim(s.cod_producto))
 where s.cantidad_disponible < 0 order by s.cantidad_disponible limit 12`)).rows);

console.log('══ 3. Items de pickup con la bomba armada (despachado > baseline persistido)');
console.table((await c.query(`
  with it as (
    select p.id_pickup, p.id_zona, p.estado, e.value it
      from wh.pickups p, jsonb_array_elements(coalesce(p.items,'[]'::jsonb)) e
     where p.id_pickup like 'PCK-%')
  select count(*) items_con_baseline,
         count(*) filter (where (it->>'despachado')::numeric > coalesce((it->>'despachadoBaseline')::numeric,0)) armados,
         round(sum(greatest(0,(it->>'despachado')::numeric - coalesce((it->>'despachadoBaseline')::numeric,0))),2) uds_en_riesgo
    from it where it ? 'despachadoBaseline'`)).rows);

console.log('══ 4. Pares de guías GPCK del MISMO acumulador (el patrón del doble descuento)');
console.table((await c.query(`
  select left(g.id_guia, 44) guia, g.id_zona,
         to_char(g.fecha at time zone 'America/Lima','DD/MM HH24:MI') f,
         count(*) lineas, round(sum(gd.cant_recibida),1) uds
    from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia
   where g.id_guia like 'GPCK_%' and g.fecha > now() - interval '12 days'
   group by 1,2,3 order by 3 desc limit 10`)).rows);
await c.end();
