// _envases_verify.mjs — verifica el seed 597/598 + smoke de las RPCs con los campos nuevos.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();

const q = async (sql, args) => (await c.query(sql, args)).rows;

console.log('— insumos:', (await q(`select count(*) n from mos.productos where es_insumo`))[0].n);
console.log('— derivados por estado de envase:');
console.table(await q(`select case when envase_sku is null then 'PENDIENTE'
                                   when envase_sku='SIN_ENVASE' then 'SIN_ENVASE' else 'CON_ENVASE' end k,
                              count(*) n
                         from mos.productos where coalesce(btrim(codigo_producto_base),'')<>'' group by 1 order by 1`));
console.log('— envases apuntando a sku inexistente o no-insumo (debe ser 0):');
console.table(await q(`select d.codigo_barra, d.descripcion, d.envase_sku
                         from mos.productos d
                        where d.envase_sku is not null and d.envase_sku <> 'SIN_ENVASE'
                          and not exists (select 1 from mos.productos i where i.sku_base = d.envase_sku and i.es_insumo)
                        limit 10`));
console.log('— muestra 5:');
console.table(await q(`select d.descripcion, d.envase_sku, i.descripcion envase
                         from mos.productos d
                         left join mos.productos i on i.sku_base = d.envase_sku and i.es_insumo
                        where d.envase_sku is not null and d.envase_sku <> 'SIN_ENVASE'
                        order by random() limit 5`));

// SMOKE actualizar_producto con campos nuevos (no-op reales: mismo valor) — dentro de una TX con ROLLBACK
await c.query('begin');
try {
  await c.query(`select set_config('request.headers', json_build_object('x-app-claim','MOS')::text, true)`);
  const der = (await q(`select id_producto, envase_sku from mos.productos
                         where envase_sku is not null and envase_sku <> 'SIN_ENVASE' limit 1`))[0];
  const r1 = await q(`select mos.actualizar_producto(jsonb_build_object('idProducto',$1::text,'envaseSku',$2::text)) r`, [der.id_producto, der.envase_sku]);
  console.log('smoke actualizar envaseSku (mismo valor):', JSON.stringify(r1[0].r));
  const r2 = await q(`select mos.actualizar_producto(jsonb_build_object('idProducto',$1::text,'envaseSku','')) r`, [der.id_producto]);
  const chk = await q(`select envase_sku from mos.productos where id_producto=$1`, [der.id_producto]);
  console.log('smoke vaciar envaseSku → null?', chk[0].envase_sku === null, JSON.stringify(r2[0].r));
  const r3 = await q(`select mos.actualizar_producto(jsonb_build_object('idProducto',$1::text,'esInsumo','1')) r`, [der.id_producto]);
  const chk3 = await q(`select es_insumo from mos.productos where id_producto=$1`, [der.id_producto]);
  console.log('smoke esInsumo=1 aplicado?', chk3[0].es_insumo === true, JSON.stringify(r3[0].r));
} finally {
  await c.query('rollback');
  console.log('ROLLBACK OK (smokes no persistieron)');
}
const post = await q(`select envase_sku from mos.productos where envase_sku is null and coalesce(btrim(codigo_producto_base),'')<>''`);
console.log('post-rollback pendientes:', post.length);
await c.end();
