import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.log('── ¿cuánto tiempo pasó entre el movimiento previo y el que llega descuadrado?');
console.table((await c.query(`
  with s as (
    select cod_producto, fecha, stock_antes, tipo_operacion,
           lag(stock_despues) over w prev, lag(fecha) over w prev_f
      from wh.stock_movimientos where fecha >= now() - interval '90 days'
      window w as (partition by upper(btrim(cod_producto)) order by fecha, id_mov))
  select case when fecha - prev_f < interval '10 seconds' then 'a) < 10 seg (concurrencia)'
              when fecha - prev_f < interval '1 hour'     then 'b) < 1 hora'
              when fecha - prev_f < interval '1 day'      then 'c) < 1 dia'
              else 'd) mas de 1 dia' end tramo,
         count(*) saltos, round(sum(abs(stock_antes-prev)),1) uds
    from s where prev is not null and abs(stock_antes - prev) >= 0.0005
   group by 1 order by 1`)).rows);

console.log('\n── ¿el salto se ACUMULA o se corrige solo? (comparar kardex final vs stock real)');
console.table((await c.query(`
  with u as (select distinct on (upper(btrim(cod_producto))) upper(btrim(cod_producto)) cod, stock_despues
      from wh.stock_movimientos order by upper(btrim(cod_producto)), fecha desc, id_mov desc)
  select count(*) codigos, count(*) filter (where abs(coalesce(s.cantidad_disponible,0)-u.stock_despues)<0.0005) kardex_final_correcto,
         round(sum(abs(coalesce(s.cantidad_disponible,0)-u.stock_despues)),2) uds_de_diferencia
    from u left join wh.stock s on upper(btrim(s.cod_producto))=u.cod`)).rows);
await c.end();
