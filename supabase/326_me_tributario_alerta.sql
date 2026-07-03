-- 326_me_tributario_alerta.sql
-- [Migración Sheet→Supabase · Etapa 4] 3 RPCs read-only que reemplazan lecturas de la Hoja VENTAS:
--   · me.alerta_calcular_efectivo(p_id_caja)     ← _alertaCalcularEfectivo (AlertaEfectivo.gs)
--   · me.tributario_ventas_mes(p_mes,p_anio)     ← tributarioVentasMes (Ventas.gs)
--   · me.tributario_cpe_mes(p_mes,p_anio)        ← tributarioCPEMes (Ventas.gs)
-- Replican EXACTAMENTE la salida del GAS. TZ America/Lima en filtros de fecha/mes (crítico fin-de-mes SUNAT).
-- Redondeo IGV POR FILA (fiscal). Sin gaps de esquema (me.ventas tiene total/estacion/vendedor; MIXTO_EFE:x_VIR:y
-- documentado en 02_schema_me.sql). Verificado: 0 filas con total NULL. Read-only, SECURITY DEFINER, STABLE.

-- ============================================================
-- 1) me.alerta_calcular_efectivo(p_id_caja) → jsonb
--    monto_inicial(me.cajas) + EFE(ventas no ANULADO, parte EFE de MIXTO) + INGRESO - EGRESO (efectivo físico).
-- ============================================================
create or replace function me.alerta_calcular_efectivo(p_id_caja text)
returns jsonb
language sql
stable
security definer
set search_path = me, public
as $$
  with base as (
    select coalesce(c.monto_inicial, 0)::numeric as monto_inicial
    from me.cajas c
    where c.id_caja = p_id_caja
  ),
  ventas_efe as (
    select coalesce(sum(
      case
        when upper(v.forma_pago) = 'EFECTIVO' then coalesce(v.total, 0)
        when upper(v.forma_pago) like 'MIXTO%' then
          coalesce((regexp_match(v.forma_pago, 'EFE:([0-9.]+)', 'i'))[1]::numeric, 0)
        else 0
      end
    ), 0) as efe
    from me.ventas v
    where v.id_caja = p_id_caja
      and coalesce(v.estado_envio, '') <> 'ANULADO'
  ),
  extras as (
    select coalesce(sum(
      case
        when m.tipo = 'INGRESO' then coalesce(m.monto, 0)
        when m.tipo = 'EGRESO'  then -coalesce(m.monto, 0)
        else 0
      end
    ), 0) as neto
    from me.movimientos_extra m
    where m.id_caja = p_id_caja
  )
  select jsonb_build_object(
    'efectivo',      round(coalesce((select monto_inicial from base), 0)
                           + (select efe  from ventas_efe)
                           + (select neto from extras), 2),
    'monto_inicial', round(coalesce((select monto_inicial from base), 0), 2),
    'ventas_efe',    round((select efe  from ventas_efe), 2),
    'extras_neto',   round((select neto from extras), 2)
  );
$$;

grant execute on function me.alerta_calcular_efectivo(text) to service_role;

-- ============================================================
-- 2) me.tributario_ventas_mes(p_mes, p_anio) → jsonb  (agregados IGV/ventas/CPE del mes)
-- ============================================================
create or replace function me.tributario_ventas_mes(p_mes int default null, p_anio int default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = me, public
as $$
declare
  v_mes  int := p_mes;
  v_anio int := p_anio;
  r record;
begin
  if v_mes is null or v_mes = 0 or v_anio is null or v_anio = 0 then
    v_mes  := extract(month from (now() at time zone 'America/Lima'))::int;
    v_anio := extract(year  from (now() at time zone 'America/Lima'))::int;
  end if;

  select
    coalesce(round(sum(
      case
        when v.tipo_doc in ('BOLETA','FACTURA') then coalesce(v.total,0)
        when v.tipo_doc = 'NOTA_DE_VENTA'
             and coalesce(v.forma_pago,'') not in ('POR_COBRAR','CREDITO')
             then coalesce(v.total,0)
        else 0
      end
    ), 2), 0) as total_ventas,
    coalesce(round(sum(
      case when v.tipo_doc in ('BOLETA','FACTURA')
           then round(coalesce(v.total,0) - (coalesce(v.total,0) / 1.18), 2)
           else 0 end
    ), 2), 0) as total_igv,
    count(*) filter (where v.tipo_doc in ('BOLETA','FACTURA'))                                                as cpe_total,
    count(*) filter (where v.tipo_doc in ('BOLETA','FACTURA') and v.nf_estado = 'EMITIDO')                    as cpe_emitidos,
    count(*) filter (where v.tipo_doc in ('BOLETA','FACTURA') and v.nf_estado in ('RECHAZADO_SUNAT','ERROR')) as cpe_errores,
    count(*) filter (where v.tipo_doc in ('BOLETA','FACTURA')
                       and coalesce(v.nf_estado,'') in ('PENDIENTE','','NA'))                                 as cpe_pendientes
  into r
  from me.ventas v
  where (v.fecha at time zone 'America/Lima') >= make_timestamp(v_anio, v_mes, 1, 0, 0, 0)
    and (v.fecha at time zone 'America/Lima') <  (make_timestamp(v_anio, v_mes, 1, 0, 0, 0) + interval '1 month')
    and coalesce(v.estado_envio,'') <> 'HUERFANA_LIMPIADA'
    and coalesce(v.forma_pago,'')   <> 'ANULADO';

  return jsonb_build_object(
    'status',          'success',
    'mes',             v_mes,
    'anio',            v_anio,
    'totalVentas',     coalesce(r.total_ventas, 0),
    'totalIGVEmitido', coalesce(r.total_igv, 0),
    'cpeTotal',        coalesce(r.cpe_total, 0),
    'cpeEmitidos',     coalesce(r.cpe_emitidos, 0),
    'cpePendientes',   coalesce(r.cpe_pendientes, 0),
    'cpeErrores',      coalesce(r.cpe_errores, 0),
    'cpeAnulados',     0
  );
end;
$$;

grant execute on function me.tributario_ventas_mes(int, int) to service_role;

-- ============================================================
-- 3) me.tributario_cpe_mes(p_mes, p_anio) → jsonb  (lista BOLETA/FACTURA del mes, DESC por fecha)
-- ============================================================
create or replace function me.tributario_cpe_mes(p_mes int default null, p_anio int default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = me, public
as $$
declare
  v_mes  int := p_mes;
  v_anio int := p_anio;
  v_cpe  jsonb;
begin
  if v_mes is null or v_mes = 0 or v_anio is null or v_anio = 0 then
    v_mes  := extract(month from (now() at time zone 'America/Lima'))::int;
    v_anio := extract(year  from (now() at time zone 'America/Lima'))::int;
  end if;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'idVenta',     coalesce(v.id_venta, ''),
             'fecha',       to_char(v.fecha at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
             'correlativo', coalesce(v.correlativo, ''),
             'tipo',        v.tipo_doc,
             'cliente',     coalesce(v.cliente_nombre, ''),
             'clienteDoc',  coalesce(v.cliente_doc, ''),
             'total',       coalesce(v.total, 0),
             'formaPago',   coalesce(v.forma_pago, ''),
             'nfEstado',    coalesce(v.nf_estado, ''),
             'nfHash',      coalesce(v.nf_hash, ''),
             'nfEnlace',    coalesce(v.nf_enlace, '')
           )
           order by v.fecha desc
         ), '[]'::jsonb)
  into v_cpe
  from me.ventas v
  where v.tipo_doc in ('BOLETA','FACTURA')
    and coalesce(v.estado_envio,'') <> 'HUERFANA_LIMPIADA'
    and (v.fecha at time zone 'America/Lima') >= make_timestamp(v_anio, v_mes, 1, 0, 0, 0)
    and (v.fecha at time zone 'America/Lima') <  (make_timestamp(v_anio, v_mes, 1, 0, 0, 0) + interval '1 month');

  return jsonb_build_object('status', 'success', 'cpe', v_cpe);
end;
$$;

grant execute on function me.tributario_cpe_mes(int, int) to service_role;
