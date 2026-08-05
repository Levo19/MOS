// ¿Los 213 "saltos" son reales o artefacto de ordenar por una fecha sin hora?
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const T = (x) => console.table(x);

console.log('── ¿cuántos movimientos guardan hora de verdad?');
T((await c.query(`
  select count(*) total,
         count(*) filter (where (fecha at time zone 'America/Lima')::time = '00:00:00') sin_hora_medianoche,
         count(*) filter (where (fecha at time zone 'America/Lima')::time <> '00:00:00') con_hora
    from wh.stock_movimientos where fecha >= now() - interval '90 days'`)).rows);

console.log('\n── saltos ordenando por id_mov (desempate estable) en vez de sólo fecha');
T((await c.query(`
  with s as (
    select cod_producto, stock_antes,
           lag(stock_despues) over (partition by upper(btrim(cod_producto)) order by id_mov) prev
      from wh.stock_movimientos where fecha >= now() - interval '90 days')
  select count(*) filter (where prev is not null) enlaces,
         count(*) filter (where prev is not null and abs(stock_antes - prev) >= 0.0005) con_salto
    from s`)).rows);

console.log('\n── saltos SOLO entre movimientos de días distintos (sin ambigüedad de orden)');
T((await c.query(`
  with s as (
    select cod_producto, fecha, stock_antes, tipo_operacion, origen,
           lag(stock_despues) over (partition by upper(btrim(cod_producto)) order by fecha, id_mov) prev,
           lag((fecha at time zone 'America/Lima')::date) over (partition by upper(btrim(cod_producto)) order by fecha, id_mov) prev_dia
      from wh.stock_movimientos where fecha >= now() - interval '90 days')
  select count(*) filter (where prev is not null and prev_dia <> (fecha at time zone 'America/Lima')::date) enlaces_entre_dias,
         count(*) filter (where prev is not null and prev_dia <> (fecha at time zone 'America/Lima')::date
                            and abs(stock_antes - prev) >= 0.0005) saltos_reales
    from s`)).rows);

console.log('\n── AJUSTES MANUALES absurdos (posible dedazo del operador)');
T((await c.query(`
  select left(m.cod_producto,16) cod, left(coalesce(p.descripcion,'?'),30) producto,
         to_char(m.fecha at time zone 'America/Lima','DD/MM HH24:MI') cuando,
         round(m.stock_antes,2) antes, round(m.delta,2) delta, round(m.stock_despues,2) despues,
         m.usuario, round(coalesce(s.cantidad_disponible,0),2) stock_hoy
    from wh.stock_movimientos m
    left join mos.productos p on upper(btrim(p.codigo_barra)) = upper(btrim(m.cod_producto))
    left join wh.stock s on upper(btrim(s.cod_producto)) = upper(btrim(m.cod_producto))
   where m.tipo_operacion = 'AJUSTE_MANUAL' and abs(m.stock_despues) > 5000
   order by abs(m.stock_despues) desc limit 10`)).rows);

console.log('\n── ¿esos ajustes gigantes siguen inflando el stock de hoy?');
T((await c.query(`
  select count(*) codigos_sobre_5000, round(sum(cantidad_disponible),2) uds
    from wh.stock where cantidad_disponible > 5000`)).rows);
T((await c.query(`
  select left(s.cod_producto,16) cod, left(coalesce(p.descripcion,'?'),34) producto,
         round(s.cantidad_disponible,2) stock_hoy
    from wh.stock s left join mos.productos p on upper(btrim(p.codigo_barra))=upper(btrim(s.cod_producto))
   where s.cantidad_disponible > 5000 order by s.cantidad_disponible desc limit 8`)).rows);
await c.end();
