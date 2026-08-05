import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.log('── presentaciones reales: ¿cómo se enlazan? (muestra 8)');
console.table((await c.query(`select codigo_barra, left(descripcion,36) nombre, sku_base,
    codigo_producto_base, factor_conversion, factor_conversion_base, precio_venta, unidad
  from mos.productos where tipo_producto::text='PRESENTACION' order by descripcion limit 8`)).rows);
console.log('\n── un derivado de ejemplo (para ver el patrón de enlace)');
console.table((await c.query(`select codigo_barra, left(descripcion,36) nombre, sku_base, codigo_producto_base,
    factor_conversion, factor_conversion_base, tipo_producto::text tipo, unidad, estado
  from mos.productos where codigo_producto_base is not null and btrim(codigo_producto_base) <> ''
    and tipo_producto::text <> 'PRESENTACION' limit 6`)).rows);
console.log('\n── el padre nakamito y su familia');
console.table((await c.query(`select codigo_barra, left(descripcion,40) nombre, tipo_producto::text tipo,
    sku_base, codigo_producto_base, factor_conversion, precio_venta, unidad, estado, canal_mayoreo
  from mos.productos where descripcion ilike '%nakamito%' order by tipo_producto, descripcion limit 12`)).rows);
await c.end();
