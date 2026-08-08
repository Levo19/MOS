// 661 · El bump ya no se pierde (660) pero AHORA BLOQUEA: el update de mos.catalogo_meta toma
//   el row lock en el PRIMER statement de la transaccion y lo suelta recien al commit. Medido:
//   con dos writers concurrentes el segundo se quedo esperando hasta "statement timeout".
//   Antes del 660 no bloqueaba porque simplemente PERDIA el bump (peor).
//
//   FIX: CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED -> el trigger corre justo ANTES
//   del commit, asi que el row lock se sostiene microsegundos en vez de toda la transaccion.
//   Los constraint triggers son FOR EACH ROW, pero el dedupe por transaccion del 660 hace que
//   solo la primera fila trabaje: las otras 1556 de un backfill salen por el current_setting.
//
//   Se aplica a: las 10 tablas del catalogo (mos.catalogo_meta) y al dominio 'stock' de WH
//   (wh.stock + wh.stock_movimientos), que es el camino caliente de guias/ajustes/auditorias.
//   Los demas dominios de wh/me quedan como estaban (statement-level): ya estaban probados en
//   produccion y el 660 solo les quito bumps repetidos.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const URL = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const mk = async () => { const x = new Client({ connectionString: URL, ssl: { rejectUnauthorized: false } }); await x.connect(); return x; };
const c = await mk();

const CAT = [
  ['mos.productos', 'tg_bump_catversion_productos'],
  ['mos.precio_tramos', 'tg_bump_catversion_tramos'],
  ['mos.equivalencias', 'tg_bump_catversion_equiv'],
  ['mos.categorias', 'tg_bump_catversion_categorias'],
  ['mos.zonas', 'tg_bump_catversion_zonas'],
  ['mos.estaciones', 'tg_bump_catversion_estaciones'],
  ['mos.proveedores', 'tg_bump_catversion_proveedores'],
  ['mos.proveedores_productos', 'tg_bump_catversion_provprod'],
  ['mos.series_documentales', 'tg_bump_catversion_series'],
  ['mos.promociones', 'tg_bump_catversion_promociones'],
];
const WH = [
  ['wh.stock', 'tg_bump_ops_stock'],
  ['wh.stock_movimientos', 'tg_bump_ops_stock_movimientos'],
];

let sql = '';
for (const [t, g] of CAT) {
  sql += `drop trigger if exists ${g} on ${t};\n`;
  sql += `create constraint trigger ${g} after insert or update or delete on ${t} deferrable initially deferred for each row execute function mos._bump_catalogo_version();\n`;
}
for (const [t, g] of WH) {
  sql += `drop trigger if exists ${g} on ${t};\n`;
  sql += `create constraint trigger ${g} after insert or update or delete on ${t} deferrable initially deferred for each row execute function wh._tg_bump_ops('stock');\n`;
}

const ver = async (cl) => (await cl.query(`select version from mos.catalogo_meta where id=1`)).rows[0].version;
const vwh = async (cl) => (await cl.query(`select version from wh.ops_meta where dominio='stock'`)).rows[0].version;

// ---------- TEST en begin/rollback ----------
console.log('== TEST en begin/rollback ==');
await c.query('begin');
await c.query(sql);
let v0 = await ver(c);
await c.query(`update mos.zonas set nombre = nombre where true`);
let vMid = await ver(c);
console.log('T1 durante la tx (aun sin commit): bumps=' + (Number(vMid) - Number(v0)) + ' (esperado 0 = el bump quedo diferido)');
let w0 = await vwh(c);
const { rows: cods } = await c.query(`select cod_producto from wh.stock order by cod_producto limit 5`);
for (const r of cods) await c.query(`update wh.stock set cantidad_disponible = cantidad_disponible where cod_producto=$1`, [r.cod_producto]);
console.log('T2 5 updates wh.stock: bumps durante tx=' + (Number(await vwh(c)) - Number(w0)) + ' (esperado 0)');
await c.query('rollback');
console.log('rollback ok\n');

// ---------- APLICAR ----------
console.log('== APLICANDO ==');
await c.query('begin');
await c.query(sql);
await c.query('commit');
console.log('aplicado (' + (CAT.length + WH.length) + ' triggers convertidos a diferidos).');

// ---------- VERIFICACION real ----------
const A = await mk(), B = await mk();
await A.query(`set statement_timeout = '8s'`); await B.query(`set statement_timeout = '8s'`);

// V1: NO bloquea con dos writers concurrentes + ambos bumps llegan
let vi = await ver(c);
await A.query('begin'); await B.query('begin');
await A.query(`update mos.zonas set nombre = nombre where true`);
let bloqueo = 'no';
try { await B.query(`update mos.categorias set nombre = nombre where true`); } catch (e) { bloqueo = 'SI (' + e.code + ')'; }
console.log('\nV1 writer B bloqueado por A? -> ' + bloqueo + ' (antes del 661: SI, statement timeout)');
await A.query('commit'); await B.query('commit');
console.log('V1 bumps totales = ' + (Number(await ver(c)) - Number(vi)) + ' (esperado 2: ninguno perdido)');

// V2: throttle — cerrar "una guia de 50 lineas" = 1 solo bump de stock
let wi = await vwh(c);
await A.query('begin');
const { rows: c50 } = await A.query(`select cod_producto from wh.stock order by cod_producto limit 50`);
for (const r of c50) await A.query(`update wh.stock set cantidad_disponible = cantidad_disponible where cod_producto=$1`, [r.cod_producto]);
await A.query('commit');
console.log('V2 guia de 50 lineas -> bumps wh.ops_meta[stock] = ' + (Number(await vwh(c)) - Number(wi)) + ' (esperado 1; antes del 660: 50)');

// V3: replica -> los triggers NO corren (recordatorio, no regresion)
console.log('V3 recordatorio: session_replication_role=replica apaga tambien los constraint triggers.');

await A.end(); await B.end(); await c.end();
process.exit(0);
