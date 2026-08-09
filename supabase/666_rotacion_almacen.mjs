// 666 · Corrección dueño: la ROTACIÓN del radar de promos es DE ALMACÉN, no de ventas de zona.
//   q30/q14 = salidas reales de wh.stock_movimientos: CIERRE_GUIA (despachos a zonas)
//   + ENVASADO_SALIDA (granel que se transforma = demanda de la materia prima).
//   Excluidos: AUDITORIA / AJUSTE_MANUAL / ANULACION_* (correcciones, no demanda).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const def = async () => (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='promo_sugerencias'`)).rows[0].d;
let d = await def();
if (d.includes('[666]')) { console.log('ya aplicado'); await c.end(); process.exit(0); }
const P = (a, b, tag) => { const i = d.indexOf(a); if (i < 0) throw new Error('NO: ' + tag); if (d.indexOf(a, i + 1) >= 0) throw new Error('DUP: ' + tag); d = d.slice(0, i) + b + d.slice(i + a.length); };

P(`  ven as (
    select vd.sku, sum(coalesce(vd.cantidad,0))::numeric as q
      from me.ventas_detalle vd join me.ventas v on v.id_venta = vd.id_venta
     where v.fecha >= now() - interval '30 days' and coalesce(v.estado_envio,'') = 'COMPLETADO'
     group by 1
  ),
  ven14 as (
    select vd.sku, sum(coalesce(vd.cantidad,0))::numeric as q
      from me.ventas_detalle vd join me.ventas v on v.id_venta = vd.id_venta
     where v.fecha >= now() - interval '14 days' and coalesce(v.estado_envio,'') = 'COMPLETADO'
     group by 1
  ),`,
`  ven as ( -- [666] rotación de ALMACÉN: despachos a zonas + granel transformado (no ventas de zona)
    select pr.sku_base as sku, sum(-m.delta)::numeric as q
      from wh.stock_movimientos m
      join mos.productos pr on pr.codigo_barra = m.cod_producto
     where m.fecha >= now() - interval '30 days' and m.delta < 0
       and m.tipo_operacion in ('CIERRE_GUIA','ENVASADO_SALIDA')
     group by 1
  ),
  ven14 as (
    select pr.sku_base as sku, sum(-m.delta)::numeric as q
      from wh.stock_movimientos m
      join mos.productos pr on pr.codigo_barra = m.cod_producto
     where m.fecha >= now() - interval '14 days' and m.delta < 0
       and m.tipo_operacion in ('CIERRE_GUIA','ENVASADO_SALIDA')
     group by 1
  ),`,'ven CTEs');

await c.query('begin');
await c.query(d);
const { rows: [{ r }] } = await c.query(`select mos.promo_sugerencias() r`);
const sugs = (r.sugerencias || r.data?.sugerencias || r) ;
const lista = Array.isArray(sugs) ? sugs : (sugs.sugerencias || []);
console.log('sugerencias tras 666:', lista.length);
lista.slice(0,6).forEach(s => console.log(` · ${(s.producto||s.descripcion||'').slice(0,38)} | ${s.jugada||s.tipo||''} | ${s.razon ? String(s.razon).slice(0,60) : ''}`));
await c.query('rollback');
if (!lista.length) { console.log('❌ 0 sugerencias — NO aplico'); process.exit(1); }
await c.query(d);
console.log('✅ 666 APLICADO — rotación = salidas de almacén');
await c.end();
