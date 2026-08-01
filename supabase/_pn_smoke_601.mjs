// Smoke 601 en TX con ROLLBACK: PN sin precio, PN con precio (historial REGISTRO_PN),
// costo ignorado, y alta normal sigue exigiendo precio.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const q = async (sql, args) => (await c.query(sql, args)).rows;
let fallos = 0;
const ok = (n, cond, x) => { console.log((cond ? '✓' : '✗ FALLO'), n, x ?? ''); if (!cond) fallos++; };
await c.query('begin');
try {
  // 1) PN SIN precio (y con costo malicioso que debe ignorarse)
  const r1 = (await q(`select mos.lanzar_producto_nuevo(jsonb_build_object(
    'tipo','NUEVO','descripcion','TEST601 SIN PRECIO','codigoFinal','TEST601A',
    'precioCosto','9.99','idCategoria','CAT01','usuario','PRUEBA CLAUDE')) r`))[0].r;
  ok('PN sin precio se aprueba', r1.ok === true, JSON.stringify(r1).slice(0, 120));
  const p1 = (await q(`select precio_venta, precio_costo from mos.productos where codigo_barra='TEST601A'`))[0];
  ok('nace precio 0 + costo 0 (ignoró el 9.99)', Number(p1.precio_venta) === 0 && Number(p1.precio_costo) === 0, JSON.stringify(p1));
  const h1 = await q(`select 1 from mos.historial_precio_costo where id_producto=$1`, [r1.data.idProducto]);
  const hl1 = await q(`select 1 from mos.historial_precios where codigo_barra='TEST601A'`);
  ok('sin precio → SIN historial', h1.length === 0 && hl1.length === 0);

  // 2) PN CON precio → historial REGISTRO_PN
  const r2 = (await q(`select mos.lanzar_producto_nuevo(jsonb_build_object(
    'tipo','NUEVO','descripcion','TEST601 CON PRECIO','codigoFinal','TEST601B',
    'precioVenta','5.50','precioCosto','4.00','idCategoria','CAT01','usuario','PRUEBA CLAUDE')) r`))[0].r;
  const p2 = (await q(`select precio_venta, precio_costo from mos.productos where codigo_barra='TEST601B'`))[0];
  ok('con precio: venta 5.50, costo 0 (ignorado)', Number(p2.precio_venta) === 5.5 && Number(p2.precio_costo) === 0, JSON.stringify(p2));
  const h2 = (await q(`select tipo, valor, source, usuario from mos.historial_precio_costo where id_producto=$1`, [r2.data.idProducto]));
  ok('historial PRECIO source=REGISTRO_PN', h2.length === 1 && h2[0].source === 'REGISTRO_PN' && Number(h2[0].valor) === 5.5, JSON.stringify(h2));

  // 3) alta NORMAL de catálogo sin precio → sigue bloqueada
  const r3 = (await q(`select mos.crear_producto(jsonb_build_object(
    'descripcion','TEST601 NORMAL','codigoBarra','TEST601C','usuario','PRUEBA CLAUDE')) r`))[0].r;
  ok('alta normal sin precio sigue ERROR', r3.ok === false && /precio de venta/i.test(r3.error), r3.error);
} finally {
  await c.query('rollback');
  console.log('ROLLBACK OK — nada persistió · FALLOS:', fallos);
}
const resid = await q(`select count(*) n from mos.productos where codigo_barra like 'TEST601%'`);
console.log('residuos:', resid[0].n);
await c.end();
process.exit(fallos ? 1 : 0);
