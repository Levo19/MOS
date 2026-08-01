import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.log('— envasados de hoy (con su envase):');
console.table((await c.query(`
  select e.id_envasado, e.cod_producto_envasado, p.descripcion derivado, e.unidades_producidas uds,
         e.envase_cod, i.descripcion envase, e.envase_cant,
         to_char(e.fecha at time zone 'America/Lima','HH24:MI') hora
    from wh.envasados e
    left join mos.productos p on btrim(p.codigo_barra) = e.cod_producto_envasado
    left join mos.productos i on btrim(i.codigo_barra) = e.envase_cod
   where (e.fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
   order by e.fecha`)).rows);
console.log('— líneas de ENVASE en la guía de salida de hoy:');
console.table((await c.query(`
  select gd.id_guia, gd.linea, gd.cod_producto, gd.cant_recibida, gd.observacion
    from wh.guia_detalle gd
   where gd.id_detalle like 'ENVDET_E%'
     and gd.id_guia in (select id_guia from wh.guias where (fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date)`)).rows);
console.log('— kardex ENVASADO_ENVASE de hoy:');
console.table((await c.query(`
  select id_mov, cod_producto, delta, stock_antes, stock_despues
    from wh.stock_movimientos
   where tipo_operacion = 'ENVASADO_ENVASE'
     and (fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date`)).rows);
await c.end();
