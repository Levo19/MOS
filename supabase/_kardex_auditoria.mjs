// AUDITORÍA DEL KARDEX — lo que Luis dijo que importa de verdad.
// wh.stock_movimientos guarda stock_antes / delta / stock_despues, así que se puede
// auditar la CADENA completa, que es la prueba real de que el kardex no miente:
//   1. cada renglón cuadra solo:        stock_despues = stock_antes + delta
//   2. la cadena no tiene saltos:       stock_antes(n) = stock_despues(n-1)
//   3. el final coincide con la verdad: último stock_despues = wh.stock hoy
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const T = (x) => console.table(x);

console.log('── volumen por tipo de operación (90 días)');
T((await c.query(`
  select tipo_operacion, origen, count(*) movs, round(sum(delta),2) uds_netas,
         min(fecha)::date desde, max(fecha)::date hasta
    from wh.stock_movimientos where fecha >= now() - interval '90 days'
   group by 1,2 order by 3 desc limit 14`)).rows);

console.log('\n── PRUEBA 1 · cada renglón cuadra: stock_despues = stock_antes + delta');
T((await c.query(`
  select count(*) movs, count(*) filter (where abs(stock_despues - (stock_antes + delta)) < 0.0005) cuadran,
         count(*) filter (where abs(stock_despues - (stock_antes + delta)) >= 0.0005) descuadran
    from wh.stock_movimientos where fecha >= now() - interval '90 days'`)).rows);

console.log('\n── PRUEBA 2 · la cadena no tiene saltos (stock_antes = stock_despues del anterior)');
T((await c.query(`
  with s as (
    select cod_producto, fecha, stock_antes, stock_despues,
           lag(stock_despues) over (partition by upper(btrim(cod_producto)) order by fecha, id_mov) prev
      from wh.stock_movimientos where fecha >= now() - interval '90 days')
  select count(*) filter (where prev is not null) enlaces,
         count(*) filter (where prev is not null and abs(stock_antes - prev) < 0.0005) continuos,
         count(*) filter (where prev is not null and abs(stock_antes - prev) >= 0.0005) con_salto,
         round(sum(case when prev is not null and abs(stock_antes-prev) >= 0.0005 then abs(stock_antes-prev) else 0 end),2) uds_saltadas
    from s`)).rows);

console.log('\n── los saltos más grandes (stock que cambió sin dejar movimiento)');
T((await c.query(`
  with s as (
    select cod_producto, fecha, stock_antes, tipo_operacion, origen,
           lag(stock_despues) over (partition by upper(btrim(cod_producto)) order by fecha, id_mov) prev
      from wh.stock_movimientos where fecha >= now() - interval '90 days')
  select left(cod_producto,16) cod, to_char(fecha at time zone 'America/Lima','DD/MM HH24:MI') cuando,
         tipo_operacion, left(coalesce(origen,''),18) origen,
         round(prev,2) venia_de, round(stock_antes,2) dice_tener, round(stock_antes - prev,2) salto
    from s where prev is not null and abs(stock_antes - prev) >= 0.0005
   order by abs(stock_antes - prev) desc limit 10`)).rows);

console.log('\n── PRUEBA 3 · el último movimiento coincide con el stock de hoy');
T((await c.query(`
  with u as (
    select distinct on (upper(btrim(cod_producto))) upper(btrim(cod_producto)) cod, stock_despues, fecha
      from wh.stock_movimientos order by upper(btrim(cod_producto)), fecha desc, id_mov desc)
  select count(*) codigos_con_kardex,
         count(*) filter (where abs(coalesce(s.cantidad_disponible,0) - u.stock_despues) < 0.0005) coinciden,
         count(*) filter (where abs(coalesce(s.cantidad_disponible,0) - u.stock_despues) >= 0.0005) difieren
    from u left join wh.stock s on upper(btrim(s.cod_producto)) = u.cod`)).rows);

console.log('\n── las mayores diferencias entre el kardex y el stock real');
T((await c.query(`
  with u as (
    select distinct on (upper(btrim(cod_producto))) upper(btrim(cod_producto)) cod, stock_despues, fecha
      from wh.stock_movimientos order by upper(btrim(cod_producto)), fecha desc, id_mov desc)
  select left(u.cod,16) cod, left(coalesce(p.descripcion,'?'),30) producto,
         round(u.stock_despues,2) kardex, round(coalesce(s.cantidad_disponible,0),2) stock_real,
         round(coalesce(s.cantidad_disponible,0) - u.stock_despues,2) dif,
         to_char(u.fecha at time zone 'America/Lima','DD/MM') ult_mov
    from u left join wh.stock s on upper(btrim(s.cod_producto)) = u.cod
    left join mos.productos p on upper(btrim(p.codigo_barra)) = u.cod
   where abs(coalesce(s.cantidad_disponible,0) - u.stock_despues) >= 0.0005
   order by abs(coalesce(s.cantidad_disponible,0) - u.stock_despues) desc limit 10`)).rows);

console.log('\n── PRUEBA 4 · movimientos duplicados exactos (huella del doble descuento)');
T((await c.query(`
  select count(*) grupos, sum(n-1) movs_de_mas, round(sum((n-1)*abs(delta)),2) uds_de_mas from (
    select cod_producto, delta, origen, date_trunc('second',fecha) seg, count(*) n
      from wh.stock_movimientos where fecha >= now() - interval '90 days'
     group by 1,2,3,4 having count(*) > 1) x`)).rows);

console.log('\n── PRUEBA 5 · stock SIN ningún movimiento registrado (entró sin kardex)');
T((await c.query(`
  select count(*) codigos, round(sum(s.cantidad_disponible),2) uds
    from wh.stock s
   where s.cantidad_disponible <> 0
     and not exists (select 1 from wh.stock_movimientos m where upper(btrim(m.cod_producto)) = upper(btrim(s.cod_producto)))`)).rows);
await c.end();
