-- ============================================================
-- 06_fase1d_estado_cajas.sql — Fase 1.D (canary) · función server-side de estadoCajas
-- ============================================================
-- Replica EXACTAMENTE la lógica de estadoCajas() (Code.gs:81-230 de MosExpress),
-- pero agregando en Postgres (indexado) en vez de escanear hojas completas en GAS.
-- Devuelve el MISMO JSON {status, kpis, abiertas, cerradas} (sin generadoEn, lo pone GAS).
--
-- Reglas replicadas:
--   · ANULADO → solo cuenta en anulados (no total/tickets/efectivo/otros/byMetodo/byDoc)
--   · POR_COBRAR (no anulado) → sinCobrar++ y tickets++ (no monetario)
--   · resto → total, tickets, efectivo/otros (MIXTO parsea EFE:/VIR:), byMetodo, byDoc
--   · cajas: incluye todas las ABIERTA; CERRADA solo si fecha_cierre dentro de 30 días y no nula
--   · montoFinal = coalesce(.,0); efectivoEsperado = inicial+efectivo+entradas-salidas
--   · diferencia = montoFinal - efectivoEsperado SOLO si estado='CERRADA', si no null
-- Comparar contra Sheets con compararEstadoCajasME() (tolerante a orden y float).
-- ============================================================

create or replace function me.estado_cajas()
returns jsonb
language sql
stable
as $$
with
v as (
  select
    id_caja,
    coalesce(estado_envio,'COMPLETADO') as estado,   -- col-12 de VENTAS_CABECERA migró como estado_envio (NO existe me.ventas.estado)
    coalesce(forma_pago,'EFECTIVO')      as metodo,
    coalesce(tipo_doc,'NOTA_DE_VENTA')   as tipo_doc,
    coalesce(total,0)::numeric           as total
  from me.ventas
  where id_caja is not null and id_caja <> ''
),
vflag as (
  select v.*,
    (estado = 'ANULADO')                                   as is_anulado,
    (estado <> 'ANULADO' and metodo = 'POR_COBRAR')        as is_porcobrar,
    (estado <> 'ANULADO' and metodo <> 'POR_COBRAR')       as is_normal,
    case when estado <> 'ANULADO' and metodo <> 'POR_COBRAR' then
      case when metodo = 'EFECTIVO' then total
           when metodo like 'MIXTO%' then coalesce(substring(metodo from 'EFE:([0-9.]+)')::numeric, 0)
           else 0 end
    else 0 end as efe_part,
    case when estado <> 'ANULADO' and metodo <> 'POR_COBRAR' then
      case when metodo like 'MIXTO%' then
              coalesce(substring(metodo from 'VIR:([0-9.]+)')::numeric,
                       total - coalesce(substring(metodo from 'EFE:([0-9.]+)')::numeric, 0))
           when metodo = 'EFECTIVO' then 0
           else total end
    else 0 end as otros_part
  from v
),
vcaja as (
  select id_caja,
    sum(case when is_normal then total else 0 end) as total,
    sum(case when is_anulado then 0 else 1 end)    as tickets,
    sum(efe_part)                                  as efectivo,
    sum(otros_part)                                as otros,
    sum(case when is_anulado then 1 else 0 end)    as anulados,
    sum(case when is_porcobrar then 1 else 0 end)  as sin_cobrar
  from vflag group by id_caja
),
vmetodo as (
  select id_caja, jsonb_object_agg(metodo, s) as by_metodo
  from (select id_caja, metodo, sum(total) as s from vflag where is_normal group by id_caja, metodo) t
  group by id_caja
),
vdoc as (
  select id_caja, jsonb_object_agg(tipo_doc, s) as by_doc
  from (select id_caja, tipo_doc, sum(total) as s from vflag where is_normal group by id_caja, tipo_doc) t
  group by id_caja
),
ex as (
  select id_caja,
    sum(case when tipo='INGRESO' then monto else 0 end) as entradas,
    sum(case when tipo='EGRESO'  then monto else 0 end) as salidas
  from (
    select coalesce(tipo,'EGRESO') as tipo, coalesce(monto,0)::numeric as monto, id_caja
    from me.movimientos_extra where id_caja is not null and id_caja <> ''
  ) m group by id_caja
),
cajas_filt as (
  select c.id_caja, c.vendedor, c.estacion, c.zona_id, c.estado,
    c.fecha_apertura, c.fecha_cierre,
    coalesce(c.monto_inicial,0)::numeric as monto_inicial,
    coalesce(c.monto_final,0)::numeric   as monto_final,
    coalesce(vc.total,0)        as v_total,
    coalesce(vc.tickets,0)      as v_tickets,
    coalesce(vc.efectivo,0)     as v_efectivo,
    coalesce(vc.otros,0)        as v_otros,
    coalesce(vc.anulados,0)     as v_anulados,
    coalesce(vc.sin_cobrar,0)   as v_sincobrar,
    coalesce(vm.by_metodo,'{}'::jsonb) as v_bymetodo,
    coalesce(vd.by_doc,'{}'::jsonb)    as v_bydoc,
    coalesce(ex.entradas,0)     as e_entradas,
    coalesce(ex.salidas,0)      as e_salidas
  from me.cajas c
  left join vcaja   vc on vc.id_caja = c.id_caja
  left join vmetodo vm on vm.id_caja = c.id_caja
  left join vdoc    vd on vd.id_caja = c.id_caja
  left join ex         on ex.id_caja = c.id_caja
  where not (c.estado = 'CERRADA' and (c.fecha_cierre is null or c.fecha_cierre < now() - interval '30 days'))
),
obj as (
  select estado,
    jsonb_build_object(
      'idCaja',        id_caja,
      'vendedor',      coalesce(vendedor,''),
      'estacion',      coalesce(estacion,''),
      'zona',          coalesce(zona_id,''),
      'estado',        coalesce(estado,''),
      'fechaApertura', case when fecha_apertura is not null then to_char(fecha_apertura at time zone 'America/Lima','YYYY-MM-DD HH24:MI') else '' end,
      'fechaCierre',   case when fecha_cierre   is not null then to_char(fecha_cierre   at time zone 'America/Lima','YYYY-MM-DD HH24:MI') else '' end,
      'montoInicial',  monto_inicial,
      'montoFinal',    monto_final,
      'totalVentas',   round(v_total,2),
      'tickets',       v_tickets,
      'efectivo',      round(v_efectivo,2),
      'otros',         round(v_otros,2),
      'anulados',      v_anulados,
      'sinCobrar',     v_sincobrar,
      'byMetodo',      v_bymetodo,
      'byDoc',         v_bydoc,
      'entradas',      e_entradas,
      'salidas',       e_salidas,
      'efectivoEsperado', round(monto_inicial + v_efectivo + e_entradas - e_salidas, 2),
      'diferencia',    case when estado='CERRADA'
                            then round(monto_final - (monto_inicial + v_efectivo + e_entradas - e_salidas), 2)
                            else null end
    ) as caja
  from cajas_filt
)
select jsonb_build_object(
  'status','success',
  'kpis', jsonb_build_object(
     'cajasAbiertas', (select count(*) from obj where estado='ABIERTA'),
     'cajasCerradas', (select count(*) from obj where estado<>'ABIERTA'),
     'totalDia',      (select coalesce(sum((caja->>'totalVentas')::numeric),0) from obj),
     'ticketsDia',    (select coalesce(sum((caja->>'tickets')::int),0)        from obj),
     'anuladosDia',   (select coalesce(sum((caja->>'anulados')::int),0)       from obj),
     'sinCobrarDia',  (select coalesce(sum((caja->>'sinCobrar')::int),0)      from obj)
  ),
  'abiertas', coalesce((select jsonb_agg(caja) from obj where estado='ABIERTA'),  '[]'::jsonb),
  'cerradas', coalesce((select jsonb_agg(caja) from obj where estado<>'ABIERTA'), '[]'::jsonb)
);
$$;

grant execute on function me.estado_cajas() to service_role;
