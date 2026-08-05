// Radiografía del estado actual antes de tocar: columnas, seed ficticio, RPCs de MosGo.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

console.log('── columnas de mos.productos que tocan mayoreo/precio/tipo');
console.table((await c.query(`select column_name, data_type, column_default from information_schema.columns
  where table_schema='mos' and table_name='productos'
    and column_name ~* 'mayoreo|tramo|precio|tipo_producto|factor|fijo|activo|sku_base|codigo_producto_base|unidad'
  order by ordinal_position`)).rows);

console.log('\n── el seed ficticio: productos con canal_mayoreo=true hoy');
console.table((await c.query(`select codigo_barra, left(descripcion,38) producto, tipo_producto::text tipo,
    precio_venta, canal_mayoreo, tramos_mayoreo is not null tiene_tramos,
    jsonb_array_length(coalesce(tramos_mayoreo,'[]'::jsonb)) n_tramos
  from mos.productos where canal_mayoreo = true order by descripcion limit 20`)).rows);

console.log('\n── RPCs mos.ruta_* existentes');
console.table((await c.query(`select p.proname, pg_get_function_identity_arguments(p.oid) args,
    length(pg_get_functiondef(p.oid)) largo
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='mos' and p.proname like 'ruta_%' order by 1`)).rows);

// guardar las 2 críticas para leerlas
for (const f of ['ruta_boot', 'ruta_pedido_crear']) {
  const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='mos' and p.proname=$1 limit 1`, [f])).rows[0]?.d;
  if (d) { fs.writeFileSync('_def_' + f + '.sql', d); console.log(`   guardada _def_${f}.sql (${d.split('\n').length} líneas)`); }
}

console.log('\n── ¿existe ya un concepto de precio FIJO en presentaciones?');
console.table((await c.query(`select column_name from information_schema.columns
  where table_schema='mos' and table_name='productos' and column_name ~* 'fijo|manual'`)).rows);
const fns = (await c.query(`select n.nspname||'.'||p.proname f from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where pg_get_functiondef(p.oid) ~* 'precio_fijo|precioFijo' and p.prokind='f' limit 8`)).rows;
console.log('   funciones que mencionan precio_fijo:', fns.map(x => x.f).join(', ') || '(ninguna)');
await c.end();
