// ¿Las ventas anuladas cuentan como demanda al sugerir compras?
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

console.log('── ¿cómo queda marcada una venta anulada? (columnas de estado)');
console.table((await c.query(`select column_name from information_schema.columns
  where table_schema='me' and table_name='ventas' and column_name ~* 'estado|anul|forma|activ'`)).rows);

console.log('\n── combinaciones reales de estado en los últimos 60 días');
console.table((await c.query(`
  select coalesce(estado_envio,'(null)') estado_envio, coalesce(forma_pago,'(null)') forma_pago,
         count(*) ventas, sum(coalesce(total,0))::numeric(12,2) soles
    from me.ventas where fecha >= now() - interval '60 days'
   group by 1,2 order by 3 desc limit 14`)).rows);

console.log('\n── qué hace me.anular_venta con el estado (¿toca estado_envio?)');
const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='me' and p.proname='anular_venta' and p.prokind='f' limit 1`)).rows[0]?.d || '';
fs.writeFileSync('_def_anular_venta.sql', d);
d.split('\n').forEach(l => { if (/update me\.ventas|estado_envio|forma_pago\s*=|set /i.test(l)) console.log('   ', l.trim().slice(0, 130)); });

console.log('\n── LA PREGUNTA REAL: ¿la demanda de Proveedores excluye las anuladas?');
const dd = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='mos' and p.proname='prov_stock_ubicaciones' and p.prokind='f' limit 1`)).rows[0]?.d || '';
fs.writeFileSync('_def_prov_stock_ubic.sql', dd);
const lineas = dd.split('\n').filter(l => /me\.ventas|estado_envio|forma_pago|ANULAD/i.test(l));
console.log('   filtros de venta que usa:');
lineas.forEach(l => console.log('     ', l.trim().slice(0, 130)));
console.log('   ¿menciona ANULAD?', /ANULAD/i.test(dd) ? 'SÍ' : '❌ NO');

console.log('\n── impacto: demanda de 4 semanas con y sin anuladas');
try {
  console.table((await c.query(`
    with v as (
      select vd.sku_base, sum(vd.cantidad) uds, sum(coalesce(vd.subtotal,0)) soles,
             bool_or(true) x, upper(coalesce(ve.forma_pago,'')) fp, upper(coalesce(ve.estado_envio,'')) ee
        from me.ventas_detalle vd join me.ventas ve on ve.id_venta = vd.id_venta
       where ve.fecha >= date_trunc('week', (now() at time zone 'America/Lima')) - interval '28 days'
         and ve.fecha <  date_trunc('week', (now() at time zone 'America/Lima'))
       group by vd.sku_base, 5, 6)
    select count(distinct sku_base) skus,
           sum(uds) filter (where fp not like '%ANULAD%' and ee not like '%ANULAD%')::numeric(12,2) uds_validas,
           sum(uds) filter (where fp like '%ANULAD%' or ee like '%ANULAD%')::numeric(12,2) uds_anuladas,
           sum(soles) filter (where fp like '%ANULAD%' or ee like '%ANULAD%')::numeric(12,2) soles_anulados
      from v`)).rows);
} catch (e) { console.log('   (no se pudo:', e.message.slice(0, 90), ')'); }
await c.end();
