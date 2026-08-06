import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const SUCIO = '7754196000049>', LIMPIO = '7754196000049';
await c.query('begin');
const r1 = await c.query(`update mos.productos set codigo_barra=$2 where codigo_barra=$1`, [SUCIO, LIMPIO]);
const r2 = await c.query(`update wh.stock set cod_producto=$2 where cod_producto=$1`, [SUCIO, LIMPIO]);
const r3 = await c.query(`update wh.stock_movimientos set cod_producto=$2 where cod_producto=$1`, [SUCIO, LIMPIO]);
const r4 = await c.query(`update wh.guia_detalle set cod_producto=$2 where cod_producto=$1`, [SUCIO, LIMPIO]);
console.log(`productos=${r1.rowCount} stock=${r2.rowCount} kardex=${r3.rowCount} guias=${r4.rowCount}`);
// verificación: cero rastros del sucio + el limpio íntegro con su ficha y stock
const v1 = (await c.query(`select
  (select count(*) from mos.productos where codigo_barra=$1) +
  (select count(*) from wh.stock where cod_producto=$1) +
  (select count(*) from wh.stock_movimientos where cod_producto=$1) +
  (select count(*) from wh.guia_detalle where cod_producto=$1) rastros`, [SUCIO])).rows[0];
const v2 = (await c.query(`select p.descripcion, p.descripcion_ia is not null ficha, s.cantidad_disponible stock
  from mos.productos p left join wh.stock s on s.cod_producto=p.codigo_barra where p.codigo_barra=$1`, [LIMPIO])).rows[0];
console.log('rastros del sucio:', v1.rastros, '· limpio:', JSON.stringify(v2));
if (v1.rastros !== '0' || !v2 || !v2.ficha) { await c.query('rollback'); console.log('❌ ROLLBACK'); process.exit(1); }
await c.query('commit');
console.log('✅ código corregido en las 4 tablas (kardex íntegro, ficha conservada)');
await c.end();
