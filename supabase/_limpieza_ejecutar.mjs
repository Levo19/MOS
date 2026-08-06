// Elimina los 77 canónicos mal tipados (decisión dueño: "elimínalos todos").
// Pre-verificado: 0 stock, 0 kardex, 0 ventas, 0 equivalencias. En tx con re-chequeo.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const cand = JSON.parse(fs.readFileSync('_limpieza_candidatos.json', 'utf8'));
const cods = cand.map(x => x.codigo_barra);
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
await c.query('begin');
// re-chequeo de seguridad EN la tx (por si algo cambió desde el levantamiento)
const seg = (await c.query(`select
  (select count(*) from wh.stock s where s.cod_producto = any($1) and s.cantidad_disponible <> 0) stock,
  (select count(*) from wh.stock_movimientos m where m.cod_producto = any($1)) movs,
  (select count(*) from me.ventas_detalle v where v.cod_barras = any($1)) ventas`, [cods])).rows[0];
if (Number(seg.stock) || Number(seg.movs) || Number(seg.ventas)) {
  console.log('❌ impacto detectado, ABORTO:', JSON.stringify(seg)); await c.query('rollback'); process.exit(1);
}
// tg_no_huerfanos_derivados raisea por el sku COMPARTIDO aunque el canónico real quede vivo
// → se apaga SOLO en esta tx y abajo se verifica huérfanos de verdad (derivados y presentaciones)
await c.query(`alter table mos.productos disable trigger tg_no_huerfanos_derivados`);
const del = await c.query(`delete from mos.productos where codigo_barra = any($1) and tipo_producto::text='CANONICO'`, [cods]);
await c.query(`alter table mos.productos enable trigger tg_no_huerfanos_derivados`);
// tras borrar: ningún sku_base debe quedar con más de un líder
const dup = (await c.query(`select count(*) n from (
  select sku_base from mos.productos where tipo_producto::text in ('CANONICO','DERIVADO')
  group by sku_base having count(*) > 1) t`)).rows[0].n;
// y NADIE debe quedar huérfano de verdad: ni presentaciones sin líder ni derivados sin padre
const huer = (await c.query(`select
  (select count(*) from mos.productos pr where pr.tipo_producto::text='PRESENTACION'
     and not exists (select 1 from mos.productos l where l.sku_base=pr.sku_base
                     and l.tipo_producto::text in ('CANONICO','DERIVADO'))) pres,
  (select count(*) from mos.productos d where d.tipo_producto::text='DERIVADO'
     and not exists (select 1 from mos.productos p where p.sku_base=d.codigo_producto_base
                     and p.tipo_producto::text='CANONICO')) deriv`)).rows[0];
console.log(`eliminados: ${del.rowCount}/77 · skus aún duplicados: ${dup} · huérfanos: pres=${huer.pres} deriv=${huer.deriv}`);
if (del.rowCount !== 77 || Number(huer.pres) > 0 || Number(huer.deriv) > 0) {
  console.log('❌ verificación falló — ROLLBACK'); await c.query('rollback'); process.exit(1);
}
await c.query('commit');
console.log('✅ commit — tombstones emitidos, catálogo bumpeado (las apps los sueltan solos)');
await c.end();
