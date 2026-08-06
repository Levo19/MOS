// ¿Dónde vive el código corrupto '7754196000049>' y hay conflicto con el limpio?
import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const SUCIO = '7754196000049>', LIMPIO = '7754196000049';
console.log('── ¿existe ya un producto con el código LIMPIO? (conflicto)');
console.table((await c.query(`select codigo_barra, descripcion, tipo_producto::text t from mos.productos where codigo_barra = any($1)`, [[SUCIO, LIMPIO]])).rows);
const tablas = [
  ['mos.equivalencias','codigo_barra'], ['mos.proveedores_productos','codigo_barra'],
  ['wh.stock','cod_producto'], ['wh.stock_movimientos','cod_producto'], ['wh.guia_detalle','cod_producto'],
  ['me.stock_zonas','cod_barras'], ['me.ventas_detalle','cod_barras']
];
for (const [t, col] of tablas) {
  const r = (await c.query(`select count(*) filter (where ${col}=$1) sucio, count(*) filter (where ${col}=$2) limpio from ${t}`, [SUCIO, LIMPIO])).rows[0];
  if (r.sucio !== '0' || r.limpio !== '0') console.log(`${t}.${col}: sucio=${r.sucio} · limpio=${r.limpio}`);
}
await c.end();
