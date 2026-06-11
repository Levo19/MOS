-- ============================================================
-- 08_fase1d_creditos.sql — Fase 1.D (canary) · función server-side de getCreditosPendientes
-- ============================================================
-- Replica getCreditosPendientes(diasAtras) (Creditos.gs:489-610 de MosExpress).
-- Lee me.ventas + me.ventas_detalle + me.creditos_cobro_asignado.
--   · solo forma_pago='CREDITO' (case-insensitive), NO cobradas (estado COBRADO), fecha >= now-diasAtras
--   · agrupa por día (Lima), ordena días desc; cada ticket con items (máx 12 por linea) + asignado
--   · fechaISO/dia en Lima; asignado.fechaAsig en UTC (toISOString); subtotal recalcula cant*precio si vacío
-- Comparar con compararCreditosPendientesME() (grupos por fecha, tickets por idVenta, order-independiente).
-- ============================================================

create or replace function me.creditos_pendientes(dias_atras int default 30)
returns jsonb
language sql
stable
as $$
with
cobradas as (
  select distinct id_venta from me.creditos_cobro_asignado where estado='COBRADO' and id_venta is not null and id_venta<>''
),
asignados as (
  select distinct on (id_venta) id_venta,
    jsonb_build_object(
      'idCobro',      coalesce(id_cobro,''),
      'cajaDestino',  coalesce(caja_destino,''),
      'vendedorDest', coalesce(vendedor_dest,''),
      'fechaAsig',    case when fecha_asig is not null then to_char(fecha_asig at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end
    ) as asignado
  from me.creditos_cobro_asignado
  where estado='ASIGNADO' and id_venta is not null and id_venta<>''
  order by id_venta, fecha_asig desc nulls last, id_cobro desc   -- si hay >1 ASIGNADO por venta, gana la más reciente (= última en orden de hoja, como GAS)
),
det_ranked as (
  select id_venta, linea,
    coalesce(nombre,'') as nombre,
    coalesce(cantidad,0)::numeric as cantidad,
    (case when coalesce(subtotal,0)<>0 then subtotal else coalesce(cantidad,0)*coalesce(precio,0) end)::numeric as subtotal,
    row_number() over (partition by id_venta order by linea) as rn
  from me.ventas_detalle where id_venta is not null and id_venta<>''
),
items as (
  select id_venta,
    jsonb_agg(jsonb_build_object('nombre',nombre,'cantidad',cantidad,'subtotal',subtotal) order by linea) as items,
    count(*) as items_count
  from det_ranked where rn<=12 group by id_venta
),
vcred as (
  select v.id_venta, v.fecha, v.correlativo, v.cliente_nombre, v.cliente_doc, v.vendedor, v.total, v.forma_pago, v.obs, v.id_caja
  from me.ventas v
  where upper(coalesce(v.forma_pago,''))='CREDITO'
    and v.id_venta is not null and v.id_venta<>''
    and not exists (select 1 from cobradas c where c.id_venta = v.id_venta)
    and v.fecha is not null
    and v.fecha >= now() - (dias_atras::text || ' days')::interval
),
tickets as (
  select
    to_char(vc.fecha at time zone 'America/Lima','YYYY-MM-DD') as dia,
    vc.fecha,
    coalesce(vc.total,0) as total,
    jsonb_build_object(
      'idVenta',    vc.id_venta,
      'correlativo',coalesce(vc.correlativo,''),
      'cliente',    coalesce(vc.cliente_nombre,''),
      'clienteDoc', coalesce(vc.cliente_doc,''),
      'vendedor',   coalesce(vc.vendedor,''),
      'total',      coalesce(vc.total,0),
      'formaPago',  coalesce(vc.forma_pago,''),
      'obs',        coalesce(vc.obs,''),
      'idCaja',     coalesce(vc.id_caja,''),
      'fechaISO',   to_char(vc.fecha at time zone 'America/Lima','YYYY-MM-DD HH24:MI:SS'),
      'asignado',   a.asignado,
      'items',      coalesce(it.items,'[]'::jsonb),
      'itemsCount', coalesce(it.items_count,0)
    ) as ticket
  from vcred vc
  left join asignados a on a.id_venta = vc.id_venta
  left join items     it on it.id_venta = vc.id_venta
),
grupos as (
  select dia,
    jsonb_agg(ticket order by fecha) as tks,
    sum(total) as total_dia,
    count(*)   as cuenta
  from tickets group by dia
)
select jsonb_build_object(
  'status','success',
  'grupos', coalesce((select jsonb_agg(jsonb_build_object('fecha',dia,'tickets',tks,'total',total_dia,'cuenta',cuenta) order by dia desc) from grupos),'[]'::jsonb),
  'totalAcumulado', coalesce((select sum(total_dia) from grupos),0),
  'totalTickets',   coalesce((select sum(cuenta) from grupos),0)
);
$$;

grant execute on function me.creditos_pendientes(int) to service_role;
