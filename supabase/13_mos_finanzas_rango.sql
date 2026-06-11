-- ============================================================
-- 13_mos_finanzas_rango.sql — FASE 2.A (v2: optimizado para PostgREST statement_timeout)
-- Replica getFinanzasRango (Finanzas.gs:77) byte-a-byte para [desde,hasta] (YYYY-MM-DD).
-- Devuelve {ok, data:{serie,totales,desde,hasta}} con forma camelCase idéntica al GAS.
--
-- v2 cambios de performance (sin cambiar la lógica):
--   · vcobr/liq/gastos FILTRADAS al rango (antes barrían toda la tabla).
--   · COGS: lookups de producto DEDUPLICADOS (m_id/m_cod/m_sku, 1 fila por clave) + canónico
--     por sku_base precomputado → hash-join O(líneas+productos), no escaneo por línea.
--
-- Reglas selladas (idénticas a v1): ventasNetas=Σ(EFE+VIR) cobrados; costoVentas=Σ COGS canónico real/estimado;
-- totalGastos=personal(LIQUIDACIONES_DIA)+gastos; _r2=round(n,2); día=(fecha AT TIME ZONE 'America/Lima')::date.
-- Seguridad: security definer, revoke public, grant solo service_role.
-- ============================================================

create schema if not exists mos;

create or replace function mos._r2(n numeric) returns numeric
  language sql immutable as $fn$ select round(coalesce(n,0)::numeric, 2) $fn$;

create or replace function mos.finanzas_rango(p_desde text, p_hasta text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_margen numeric := 20;
  v_data   jsonb;
begin
  select valor::numeric into v_margen
  from mos.config
  where clave = 'finMargenDefault' and valor ~ '^[0-9]+(\.[0-9]+)?$';
  if v_margen is null or v_margen < 0 or v_margen >= 100 then v_margen := 20; end if;

  with dias as (
    select to_char(d, 'YYYY-MM-DD') as dia
    from generate_series(p_desde::date, p_hasta::date, interval '1 day') as d
  ),
  -- ventas COBRADAS del rango (no ANULADO/POR_COBRAR/CREDITO)
  vcobr as (
    select to_char(v.fecha at time zone 'America/Lima', 'YYYY-MM-DD') as dia,
           v.id_venta, coalesce(v.total,0)::numeric as total,
           upper(coalesce(v.forma_pago,'')) as fp, v.forma_pago
    from me.ventas v
    where upper(coalesce(v.forma_pago,'')) not in ('ANULADO','POR_COBRAR','CREDITO')
      and (v.fecha at time zone 'America/Lima')::date between p_desde::date and p_hasta::date
  ),
  neto as (
    select dia, mos._r2(sum(
      ( case
          when fp='EFECTIVO' then total
          when fp='VIRTUAL'  then 0
          when fp like 'MIXTO%' then
            coalesce( (substring(upper(forma_pago) from 'EFE:([0-9.]+)'))::numeric,
                      round(total - coalesce((substring(upper(forma_pago) from 'VIR:([0-9.]+)'))::numeric,0), 2) )
          else 0 end )
      +
      ( case
          when fp='EFECTIVO' then 0
          when fp='VIRTUAL'  then total
          when fp like 'MIXTO%' then coalesce((substring(upper(forma_pago) from 'VIR:([0-9.]+)'))::numeric,0)
          else total end )
    )) as ventas_netas
    from vcobr group by dia
  ),
  -- ── COGS ──────────────────────────────────────────────────
  det as (
    select v.dia, upper(trim(d.sku)) as nsku_l, upper(trim(coalesce(d.cod_barras,''))) as ncod_l,
           coalesce(d.cantidad,0)::numeric as cantidad, coalesce(d.precio,0)::numeric as precio
    from me.ventas_detalle d
    join vcobr v on v.id_venta = d.id_venta
  ),
  -- lookups deduplicados (1 fila por clave). id/cod = último gana ; sku = primero gana (espeja idx* del GAS).
  m_id as (
    select distinct on (upper(trim(id_producto))) upper(trim(id_producto)) k,
           upper(trim(sku_base)) nsku, coalesce(factor_conversion,1)::numeric factor
    from mos.productos where id_producto is not null and trim(id_producto)<>''
    order by upper(trim(id_producto)), id_producto desc
  ),
  m_cod as (
    select distinct on (upper(trim(codigo_barra))) upper(trim(codigo_barra)) k,
           upper(trim(sku_base)) nsku, coalesce(factor_conversion,1)::numeric factor
    from mos.productos where codigo_barra is not null and trim(codigo_barra)<>''
    order by upper(trim(codigo_barra)), id_producto desc
  ),
  m_sku as (
    select distinct on (upper(trim(sku_base))) upper(trim(sku_base)) k,
           upper(trim(sku_base)) nsku, coalesce(factor_conversion,1)::numeric factor
    from mos.productos where sku_base is not null and trim(sku_base)<>''
    order by upper(trim(sku_base)), id_producto asc
  ),
  -- costo del canónico (factor=1) por sku_base
  canon as (
    select distinct on (upper(trim(sku_base))) upper(trim(sku_base)) nsku,
           coalesce(precio_costo,0)::numeric costo
    from mos.productos where sku_base is not null and trim(sku_base)<>''
    order by upper(trim(sku_base)), case when coalesce(factor_conversion,1)=1 then 0 else 1 end, id_producto
  ),
  det_res as (
    select dt.dia, dt.cantidad, dt.precio,
           coalesce(mi.factor, mc1.factor, mc2.factor, msk.factor, 1) as factor,
           coalesce(mi.nsku, mc1.nsku, mc2.nsku, msk.nsku) as nsku
    from det dt
    left join m_id  mi  on mi.k  = dt.nsku_l
    left join m_cod mc1 on mc1.k = dt.nsku_l
    left join m_cod mc2 on mc2.k = dt.ncod_l
    left join m_sku msk on msk.k = dt.nsku_l
  ),
  cogs as (
    select dr.dia, mos._r2(sum(
      case when coalesce(cn.costo,0) > 0
           then (dr.cantidad * dr.factor) * cn.costo
           else (dr.precio * dr.cantidad) * (1 - v_margen/100)
      end
    )) as costo_ventas
    from det_res dr
    left join canon cn on cn.nsku = dr.nsku
    group by dr.dia
  ),
  -- ── PERSONAL (LIQUIDACIONES_DIA presente, no admin/MOS, dedup nombre, no-VETADA) ──
  liq as (
    select to_char(l.fecha at time zone 'America/Lima','YYYY-MM-DD') as dia,
           lower(trim(l.nombre)) as k,
           upper(coalesce(l.estado,'PENDIENTE')) as estado,
           case when coalesce(l.total_dia,0)>0 then l.total_dia::numeric else coalesce(l.monto_base,0)::numeric end as monto,
           l.id_dia
    from mos.liquidaciones_dia l
    where l.presente = true and l.nombre is not null and trim(l.nombre)<>''
      and (l.fecha at time zone 'America/Lima')::date between p_desde::date and p_hasta::date
      and not exists (
        select 1 from mos.personal p
        where (
            ( (p.apellido is null or trim(p.apellido)='') and lower(trim(p.nombre)) = lower(trim(l.nombre)) )
            or ( p.apellido is not null and trim(p.apellido)<>'' and lower(trim(p.nombre)||' '||trim(p.apellido)) = lower(trim(l.nombre)) )
          )
          and ( upper(coalesce(p.app_origen,''))='MOS'
             or upper(coalesce(p.rol,'')) in ('MASTER','ADMINISTRADOR','ADMIN')
             or ( coalesce(p.rol,'')<>'' and upper(p.rol) not in ('ALMACENERO','ENVASADOR','OPERADOR','CAJERO','VENDEDOR') ) )
      )
  ),
  liq_dedup as (
    select dia, k, estado, monto, row_number() over (partition by dia, k order by id_dia) rn
    from liq
  ),
  personal as (
    select dia, mos._r2(sum(case when estado<>'VETADA' then monto else 0 end)) total_personal
    from liq_dedup where rn=1 group by dia
  ),
  gastos as (
    select to_char(g.fecha at time zone 'America/Lima','YYYY-MM-DD') as dia,
           mos._r2(sum(coalesce(g.monto,0)::numeric)) total_gastos_otros
    from mos.gastos g
    where (g.fecha at time zone 'America/Lima')::date between p_desde::date and p_hasta::date
    group by dia
  ),
  -- ── P&L por día (todos los días del rango) ──
  pl as (
    select d.dia,
           coalesce(n.ventas_netas,0) ventas_netas, coalesce(c.costo_ventas,0) costo_ventas,
           coalesce(pe.total_personal,0) personal, coalesce(ga.total_gastos_otros,0) gastos_otros
    from dias d
    left join neto n on n.dia=d.dia
    left join cogs c on c.dia=d.dia
    left join personal pe on pe.dia=d.dia
    left join gastos ga on ga.dia=d.dia
  ),
  pl2 as (
    select dia, ventas_netas, costo_ventas,
           mos._r2(ventas_netas - costo_ventas) utilidad_bruta,
           mos._r2(personal + gastos_otros) total_gastos
    from pl
  ),
  pl3 as (
    select dia, ventas_netas, costo_ventas, utilidad_bruta, total_gastos,
           mos._r2(utilidad_bruta - total_gastos) utilidad_neta,
           case when ventas_netas>0 then mos._r2(utilidad_bruta/ventas_netas*100) else 0 end margen_bruto_pct
    from pl2
  )
  select jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'serie', coalesce((
        select jsonb_agg(jsonb_build_object(
          'fecha',dia,'utilidadNeta',utilidad_neta,'ventasNetas',ventas_netas,
          'costoVentas',costo_ventas,'totalGastos',total_gastos,
          'utilidadBruta',utilidad_bruta,'margenBrutoPct',margen_bruto_pct
        ) order by dia) from pl3), '[]'::jsonb),
      'totales', (
        select jsonb_build_object(
          'ventasNetas',sum(ventas_netas),'costoVentas',sum(costo_ventas),
          'utilidadBruta',sum(utilidad_bruta),'totalGastos',sum(total_gastos),'utilidadNeta',sum(utilidad_neta),
          'margenBrutoPct', case when sum(ventas_netas)>0 then mos._r2(sum(utilidad_bruta)/sum(ventas_netas)*100) else 0 end,
          'margenNetoPct',  case when sum(ventas_netas)>0 then mos._r2(sum(utilidad_neta)/sum(ventas_netas)*100) else 0 end
        ) from pl3),
      'desde', p_desde, 'hasta', p_hasta
    )
  ) into v_data;

  return v_data;
end;
$fn$;

revoke all on function mos._r2(numeric)             from public;
revoke all on function mos.finanzas_rango(text,text) from public;
grant execute on function mos._r2(numeric)             to service_role;
grant execute on function mos.finanzas_rango(text,text) to service_role;
