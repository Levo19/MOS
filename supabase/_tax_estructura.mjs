import fs from 'fs'; import pkg from 'pg'; const {Client}=pkg;
const c=new Client({connectionString:fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(),ssl:{rejectUnauthorized:false}});
await c.connect();
// columnas relevantes
const cols=(await c.query(`select column_name, data_type from information_schema.columns where table_schema='mos' and table_name='productos' and column_name in ('sku_base','codigo_producto_base','factor_conversion','factor_conversion_base','marca','id_categoria','descripcion_ia','categoria_ia','tipo_producto','codigo_barra','es_insumo') order by 1`)).rows;
console.log(JSON.stringify(cols));
// ¿cómo se vincula un DERIVADO a su padre canónico?
const d=(await c.query(`select codigo_barra, descripcion, sku_base, codigo_producto_base from mos.productos where tipo_producto::text='DERIVADO' and coalesce(estado,true) limit 3`)).rows;
console.log('DERIVADOS:', JSON.stringify(d,null,1));
// ¿y una presentación a su líder?
const p=(await c.query(`select codigo_barra, descripcion, sku_base, codigo_producto_base from mos.productos where tipo_producto::text='PRESENTACION' and coalesce(estado,true) limit 3`)).rows;
console.log('PRESENTACIONES:', JSON.stringify(p,null,1));
// líderes de esas presentaciones
if(p.length){
  const l=(await c.query(`select codigo_barra, descripcion, tipo_producto::text t, sku_base from mos.productos where sku_base=$1 and tipo_producto::text in ('CANONICO','DERIVADO')`,[p[0].sku_base])).rows;
  console.log('LIDER de la 1ª presentación:', JSON.stringify(l));
}
if(d.length){
  const pd=(await c.query(`select codigo_barra, descripcion, tipo_producto::text t from mos.productos where codigo_barra=$1 or sku_base=$1 limit 3`,[d[0].codigo_producto_base])).rows;
  console.log('PADRE del 1er derivado (via codigo_producto_base):', JSON.stringify(pd));
}
// triggers actuales sobre mos.productos
const tg=(await c.query(`select tgname, pg_get_triggerdef(t.oid) def from pg_trigger t join pg_class r on r.oid=t.tgrelid join pg_namespace n on n.oid=r.relnamespace where n.nspname='mos' and r.relname='productos' and not tgisinternal`)).rows;
console.log('TRIGGERS:', JSON.stringify(tg,null,1));
// RPCs de creación (para testear flujos reales)
const fns=(await c.query(`select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname ~* '(crear|nueva).*(produc|present|deriv)' order by 1`)).rows;
console.log('RPCs crear:', JSON.stringify(fns));
await c.end();
