-- ============================================================
-- 07_fase1d_cobros.sql — Fase 1.D (canary) · función server-side de getCobrosEnVueloAdmin
-- ============================================================
-- Replica getCobrosEnVueloAdmin() (Creditos.gs:1023-1075 de MosExpress).
-- Devuelve {status, enVuelo[], recientes[]}.
--   · enVuelo   = estado='ASIGNADO', ordenado por fecha_vencimiento asc
--   · recientes = resto, ordenado por fecha_res DESC, top 10
--   · fechas en formato UTC ISO (toISOString → "...T..:..:...000Z")
--   · monto=coalesce(0); horasTTL=coalesce(1); reasignaciones=coalesce(0)
-- Comparar contra Sheets con compararCobrosEnVueloME() (por idCobro, fechas a-segundo).
-- ============================================================

create or replace function me.cobros_en_vuelo()
returns jsonb
language sql
stable
as $$
with base as (
  select
    coalesce(id_cobro,'')        as id_cobro,
    coalesce(id_venta,'')        as id_venta,
    coalesce(caja_destino,'')    as caja_destino,
    coalesce(vendedor_dest,'')   as vendedor_dest,
    coalesce(metodo_sug,'')      as metodo_sug,
    coalesce(estado,'')          as estado,
    coalesce(admin_asignador,'') as admin_asignador,
    fecha_asig, fecha_res, fecha_vencimiento,
    coalesce(razon,'')           as razon,
    coalesce(monto,0)::numeric   as monto,
    coalesce(cliente_nombre,'')  as cliente_nombre,
    coalesce(correlativo,'')     as correlativo,
    coalesce(horas_ttl,1)        as horas_ttl,
    coalesce(mensaje_admin,'')   as mensaje_admin,
    coalesce(reasignaciones,0)   as reasignaciones
  from me.creditos_cobro_asignado
),
item as (
  select estado, fecha_res, fecha_vencimiento,
    jsonb_build_object(
      'idCobro', id_cobro, 'idVenta', id_venta, 'cajaDestino', caja_destino,
      'vendedorDest', vendedor_dest, 'metodoSug', metodo_sug, 'estado', estado,
      'adminAsig', admin_asignador,
      'fechaAsig', case when fecha_asig is not null then to_char(fecha_asig at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end,
      'fechaRes',  case when fecha_res  is not null then to_char(fecha_res  at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end,
      'razon', razon, 'monto', monto, 'cliente', cliente_nombre, 'correlativo', correlativo,
      'fechaVencimiento', case when fecha_vencimiento is not null then to_char(fecha_vencimiento at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end,
      'horasTTL', horas_ttl, 'mensajeAdmin', mensaje_admin, 'reasignaciones', reasignaciones
    ) as obj
  from base
)
select jsonb_build_object(
  'status','success',
  'enVuelo',   coalesce((select jsonb_agg(obj order by fecha_vencimiento asc nulls first) from item where estado='ASIGNADO'),'[]'::jsonb),
  'recientes', coalesce((select jsonb_agg(obj) from (
       select obj from item where estado <> 'ASIGNADO'
       order by fecha_res desc nulls last, (obj->>'idCobro') limit 10
     ) r),'[]'::jsonb)
);
$$;

grant execute on function me.cobros_en_vuelo() to service_role;
