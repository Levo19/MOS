-- 610 · Mesa de créditos: los tickets SALDADOS no desaparecen — vuelven con sello.
--
-- Pedido de Luis (02/08/2026): "cuando un crédito es pagado (por el cajero o por
-- liquidación) debe seguir en la mesa pero con un sello visible de COBRADO, así
-- el admin sabe que existió y que el cliente cumple".
--
-- me.creditos_pendientes v2:
--   · VIVOS: igual que antes (CREDITO sin cobro COBRADO). Los totales/cuentas de
--     grupo y los acumulados SOLO suman vivos → el KPI "S/ pendientes" no cambia.
--   · PAGADOS (misma ventana dias_atras, agrupados en su fecha ORIGINAL):
--       - estadoCobro='CAJA'     → tuvo cobro asignado COBRADO (me.creditos_cobro_asignado);
--                                  detalle = cajero + fecha de cobro.
--       - estadoCobro='PLANILLA' → forma_pago='PLANILLA' (descuento en liquidación);
--                                  detalle = "Liquidación" + fecha del descuento (del historial).
--   · Cada ticket lleva 'estadoCobro' ('VIVO'|'CAJA'|'PLANILLA') y 'cobradoDetalle'.
--   · Grupo: 'cuentaPagados'; top-level: 'totalPagados' (informativo).
--
-- El front (MOS Cajas) pinta sello ✓ COBRADO en los no-vivos y les bloquea
-- "enviar a cobrar" (el server ya lo bloqueaba: asignar_cobro_cajero exige
-- CREDITO/POR_COBRAR y cobrar_credito_directo devuelve VENTA_NO_PENDIENTE).

create or replace function me.creditos_pendientes(dias_atras integer default 30)
 returns jsonb
 language sql
 stable
as $function$
with
cobradas as (
  select distinct id_venta from me.creditos_cobro_asignado where estado='COBRADO' and id_venta is not null and id_venta<>''
),
cobro_info as (
  select distinct on (id_venta) id_venta,
         coalesce(vendedor_dest,'') as cajero_cobro,
         fecha_res
    from me.creditos_cobro_asignado
   where estado='COBRADO' and id_venta is not null and id_venta<>''
   order by id_venta, fecha_res desc nulls last, id_cobro desc
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
  order by id_venta, fecha_asig desc nulls last, id_cobro desc
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
-- VIVOS: crédito real pendiente (igual que v1)
vcred as (
  select v.id_venta, v.fecha, v.correlativo, v.cliente_nombre, v.cliente_doc, v.vendedor, v.total, v.forma_pago, v.obs, v.id_caja,
         'VIVO'::text as estado_cobro, ''::text as cobrado_detalle
  from me.ventas v
  where upper(coalesce(v.forma_pago,''))='CREDITO'
    and v.id_venta is not null and v.id_venta<>''
    and not exists (select 1 from cobradas c where c.id_venta = v.id_venta)
    and v.fecha is not null
    and v.fecha >= now() - (dias_atras::text || ' days')::interval
),
-- PAGADOS: fueron crédito y ya se saldaron (caja o liquidación). Misma ventana.
vpag as (
  select v.id_venta, v.fecha, v.correlativo, v.cliente_nombre, v.cliente_doc, v.vendedor, v.total, v.forma_pago, v.obs, v.id_caja,
         case when ci.id_venta is not null then 'CAJA' else 'PLANILLA' end as estado_cobro,
         case when ci.id_venta is not null
              then coalesce(nullif(ci.cajero_cobro,''),'caja')
                   || case when ci.fecha_res is not null
                           then ' · ' || to_char(ci.fecha_res at time zone 'America/Lima','DD/MM') else '' end
              else 'Liquidación'
                   || case when hp.ts_liq is not null
                           then ' · ' || to_char(hp.ts_liq at time zone 'America/Lima','DD/MM') else '' end
         end as cobrado_detalle
  from me.ventas v
  left join cobro_info ci on ci.id_venta = v.id_venta
  left join lateral (
    select max(case when (e->>'ts') ~ '^\d{4}-\d{2}-\d{2}' then (e->>'ts')::timestamptz end) as ts_liq
      from jsonb_array_elements(coalesce(v.historial_cambios,'[]'::jsonb)) e
     where e->>'accion' = 'descuento_planilla'
  ) hp on true
  where v.id_venta is not null and v.id_venta<>''
    and v.fecha is not null
    and v.fecha >= now() - (dias_atras::text || ' days')::interval
    and ( upper(coalesce(v.forma_pago,'')) = 'PLANILLA'
          or ci.id_venta is not null )
),
vtodo as (
  select * from vcred
  union all
  select * from vpag
),
tickets as (
  select
    to_char(vt.fecha at time zone 'America/Lima','YYYY-MM-DD') as dia,
    vt.fecha,
    vt.estado_cobro,
    coalesce(vt.total,0) as total,
    jsonb_build_object(
      'idVenta',    vt.id_venta,
      'correlativo',coalesce(vt.correlativo,''),
      'cliente',    coalesce(vt.cliente_nombre,''),
      'clienteDoc', coalesce(vt.cliente_doc,''),
      'vendedor',   coalesce(vt.vendedor,''),
      'total',      coalesce(vt.total,0),
      'formaPago',  coalesce(vt.forma_pago,''),
      'obs',        coalesce(vt.obs,''),
      'idCaja',     coalesce(vt.id_caja,''),
      'fechaISO',   to_char(vt.fecha at time zone 'America/Lima','YYYY-MM-DD HH24:MI:SS'),
      'asignado',   a.asignado,
      'estadoCobro',    vt.estado_cobro,
      'cobradoDetalle', vt.cobrado_detalle,
      'items',      coalesce(it.items,'[]'::jsonb),
      'itemsCount', coalesce(it.items_count,0)
    ) as ticket
  from vtodo vt
  left join asignados a on a.id_venta = vt.id_venta and vt.estado_cobro = 'VIVO'
  left join items     it on it.id_venta = vt.id_venta
),
grupos as (
  select dia,
    jsonb_agg(ticket order by fecha) as tks,
    sum(total)  filter (where estado_cobro = 'VIVO') as total_dia,
    count(*)    filter (where estado_cobro = 'VIVO') as cuenta,
    count(*)    filter (where estado_cobro <> 'VIVO') as cuenta_pagados
  from tickets group by dia
)
select jsonb_build_object(
  'status','success',
  'grupos', coalesce((select jsonb_agg(jsonb_build_object(
              'fecha',dia,'tickets',tks,
              'total',coalesce(total_dia,0),'cuenta',coalesce(cuenta,0),
              'cuentaPagados',coalesce(cuenta_pagados,0)) order by dia desc) from grupos),'[]'::jsonb),
  'totalAcumulado', coalesce((select sum(total_dia) from grupos),0),
  'totalTickets',   coalesce((select sum(cuenta) from grupos),0),
  'totalPagados',   coalesce((select sum(cuenta_pagados) from grupos),0)
);
$function$;
