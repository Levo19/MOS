-- ============================================================
-- 13_mos_finanzas_rango.sql — FASE 2.A (DRAFT v1, sujeto a iteración con compararFinanzasRangoMOS)
-- Replica getFinanzasRango (Finanzas.gs:77) byte-a-byte para un rango [desde,hasta] (YYYY-MM-DD).
-- Por cada día del rango calcula el P&L y devuelve {ok, data:{serie,totales,desde,hasta}}
-- con la MISMA forma camelCase que el GAS (serie: fecha/utilidadNeta/ventasNetas/costoVentas/
-- totalGastos/utilidadBruta/margenBrutoPct; totales: + margenNetoPct).
--
-- Reglas selladas replicadas:
--  ventasNetas = Σ(EFE+VIR) sobre cobrados (forma_pago NOT IN ANULADO/POR_COBRAR/CREDITO).
--               EFECTIVO→(total,0) · VIRTUAL→(0,total) · MIXTO→(EFE:x | total-VIR:y , VIR:y) · otro→(0,total).
--  costoVentas = Σ líneas de VENTAS_DETALLE de ventas cobradas:
--               lookup producto (id_producto→codigo_barra→cod_barras línea→sku_base),
--               costo del CANÓNICO (factor_conversion=1 del grupo sku_base) precio_costo;
--               si >0 → real = (cantidad×factor)×costoCanon ; si =0 → estimado = (precio×cantidad)×(1−finMargenDefault/100, def 20).
--  totalGastos = personal (LIQUIDACIONES_DIA presente, no-admin/MOS, dedup por nombre, no-VETADA: totalDia||montoBase) + gastos (Σ monto del día).
--  utilidadBruta=_r2(ventasNetas−costoVentas) · utilidadNeta=_r2(utilidadBruta−totalGastos) · margenBrutoPct=_r2(uBruta/vNetas*100).
--  _r2 = round(n,2). Día = (fecha AT TIME ZONE 'America/Lima')::date.
--
-- Seguridad (Fase 1; RLS llega en Fase 2 auth): security definer, revoke from public, grant SOLO service_role.
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
  -- margen default global (CONFIG_MOS.finMargenDefault), 0<=x<100, else 20
  select valor::numeric into v_margen
  from mos.config
  where clave = 'finMargenDefault' and valor ~ '^[0-9]+(\.[0-9]+)?$';
  if v_margen is null or v_margen < 0 or v_margen >= 100 then v_margen := 20; end if;

  with dias as (
    select to_char(d, 'YYYY-MM-DD') as dia
    from generate_series(p_desde::date, p_hasta::date, interval '1 day') as d
  ),
  -- Ventas COBRADAS (las que cuentan para neto y COGS)
  vcobr as (
    select to_char(v.fecha at time zone 'America/Lima', 'YYYY-MM-DD') as dia,
           v.id_venta,
           coalesce(v.total, 0)::numeric as total,
           upper(coalesce(v.forma_pago, '')) as fp,
           v.forma_pago
    from me.ventas v
    where upper(coalesce(v.forma_pago, '')) not in ('ANULADO', 'POR_COBRAR', 'CREDITO')
  ),
  -- ventasNetas por día = Σ(efe + vir)
  neto as (
    select dia,
      mos._r2(sum(
        ( case
            when fp = 'EFECTIVO' then total
            when fp = 'VIRTUAL'  then 0
            when fp like 'MIXTO%' then
              coalesce( (substring(upper(forma_pago) from 'EFE:([0-9.]+)'))::numeric,
                        round(total - coalesce((substring(upper(forma_pago) from 'VIR:([0-9.]+)'))::numeric, 0), 2) )
            else 0
          end )
        +
        ( case
            when fp = 'EFECTIVO' then 0
            when fp = 'VIRTUAL'  then total
            when fp like 'MIXTO%' then coalesce((substring(upper(forma_pago) from 'VIR:([0-9.]+)'))::numeric, 0)
            else total
          end )
      )) as ventas_netas
    from vcobr
    group by dia
  ),
  -- COGS: líneas de detalle de ventas cobradas, con costo del canónico
  det as (
    select v.dia, d.sku, d.cod_barras,
           coalesce(d.cantidad,0)::numeric as cantidad,
           coalesce(d.precio,0)::numeric  as precio
    from me.ventas_detalle d
    join vcobr v on v.id_venta = d.id_venta
  ),
  detm as (
    select dt.dia, dt.cantidad, dt.precio,
           coalesce(mp.factor_conversion, 1)::numeric as factor,
           coalesce((
             select p2.precio_costo
             from mos.productos p2
             where upper(trim(p2.sku_base)) = upper(trim(mp.sku_base))
               and mp.sku_base is not null and trim(mp.sku_base) <> ''
             order by case when coalesce(p2.factor_conversion,1) = 1 then 0 else 1 end, p2.id_producto
             limit 1
           ), 0)::numeric as canon_cost
    from det dt
    left join lateral (
      select p.sku_base, p.factor_conversion
      from mos.productos p
      where upper(trim(p.id_producto))  = upper(trim(dt.sku))
         or upper(trim(p.codigo_barra)) = upper(trim(dt.sku))
         or upper(trim(p.codigo_barra)) = upper(trim(dt.cod_barras))
         or upper(trim(p.sku_base))     = upper(trim(dt.sku))
      order by case
        when upper(trim(p.id_producto))  = upper(trim(dt.sku))        then 1
        when upper(trim(p.codigo_barra)) = upper(trim(dt.sku))        then 2
        when upper(trim(p.codigo_barra)) = upper(trim(dt.cod_barras)) then 3
        else 4 end, p.id_producto
      limit 1
    ) mp on true
  ),
  cogs as (
    select dia,
      mos._r2(sum(
        case when canon_cost > 0
             then (cantidad * factor) * canon_cost
             else (precio * cantidad) * (1 - v_margen / 100)
        end
      )) as costo_ventas
    from detm
    group by dia
  ),
  -- PERSONAL: LIQUIDACIONES_DIA presente, no admin/MOS, dedup por nombre, no-VETADA
  liq as (
    select to_char(l.fecha at time zone 'America/Lima', 'YYYY-MM-DD') as dia,
           lower(trim(l.nombre)) as k,
           upper(coalesce(l.estado, 'PENDIENTE')) as estado,
           case when coalesce(l.total_dia, 0) > 0 then l.total_dia::numeric
                else coalesce(l.monto_base, 0)::numeric end as monto,
           l.id_dia
    from mos.liquidaciones_dia l
    where l.presente = true and l.nombre is not null and trim(l.nombre) <> ''
      and not exists (
        select 1 from mos.personal p
        where (
            ( (p.apellido is null or trim(p.apellido) = '') and lower(trim(p.nombre)) = lower(trim(l.nombre)) )
            or
            ( p.apellido is not null and trim(p.apellido) <> '' and lower(trim(p.nombre) || ' ' || trim(p.apellido)) = lower(trim(l.nombre)) )
          )
          and (
               upper(coalesce(p.app_origen, '')) = 'MOS'
            or upper(coalesce(p.rol, '')) in ('MASTER', 'ADMINISTRADOR', 'ADMIN')
            or ( coalesce(p.rol, '') <> '' and upper(p.rol) not in ('ALMACENERO','ENVASADOR','OPERADOR','CAJERO','VENDEDOR') )
          )
      )
  ),
  liq_dedup as (
    select dia, k, estado, monto,
           row_number() over (partition by dia, k order by id_dia) as rn
    from liq
  ),
  personal as (
    select dia, mos._r2(sum( case when estado <> 'VETADA' then monto else 0 end )) as total_personal
    from liq_dedup
    where rn = 1
    group by dia
  ),
  gastos as (
    select to_char(g.fecha at time zone 'America/Lima', 'YYYY-MM-DD') as dia,
           mos._r2(sum(coalesce(g.monto, 0)::numeric)) as total_gastos_otros
    from mos.gastos g
    group by dia
  ),
  -- P&L por día (todos los días del rango, 0 si no hay actividad)
  pl as (
    select d.dia,
           coalesce(n.ventas_netas, 0)        as ventas_netas,
           coalesce(c.costo_ventas, 0)        as costo_ventas,
           coalesce(pe.total_personal, 0)     as personal,
           coalesce(ga.total_gastos_otros, 0) as gastos_otros
    from dias d
    left join neto     n  on n.dia  = d.dia
    left join cogs     c  on c.dia  = d.dia
    left join personal pe on pe.dia = d.dia
    left join gastos   ga on ga.dia = d.dia
  ),
  pl2 as (
    select dia, ventas_netas, costo_ventas,
           mos._r2(ventas_netas - costo_ventas)              as utilidad_bruta,
           mos._r2(personal + gastos_otros)                  as total_gastos
    from pl
  ),
  pl3 as (
    select dia, ventas_netas, costo_ventas, utilidad_bruta, total_gastos,
           mos._r2(utilidad_bruta - total_gastos) as utilidad_neta,
           case when ventas_netas > 0 then mos._r2(utilidad_bruta / ventas_netas * 100) else 0 end as margen_bruto_pct
    from pl2
  )
  select jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'serie', coalesce((
        select jsonb_agg(jsonb_build_object(
          'fecha',          dia,
          'utilidadNeta',   utilidad_neta,
          'ventasNetas',    ventas_netas,
          'costoVentas',    costo_ventas,
          'totalGastos',    total_gastos,
          'utilidadBruta',  utilidad_bruta,
          'margenBrutoPct', margen_bruto_pct
        ) order by dia) from pl3
      ), '[]'::jsonb),
      'totales', (
        select jsonb_build_object(
          'ventasNetas',   sum(ventas_netas),
          'costoVentas',   sum(costo_ventas),
          'utilidadBruta', sum(utilidad_bruta),
          'totalGastos',   sum(total_gastos),
          'utilidadNeta',  sum(utilidad_neta),
          'margenBrutoPct', case when sum(ventas_netas) > 0 then mos._r2(sum(utilidad_bruta) / sum(ventas_netas) * 100) else 0 end,
          'margenNetoPct',  case when sum(ventas_netas) > 0 then mos._r2(sum(utilidad_neta)  / sum(ventas_netas) * 100) else 0 end
        ) from pl3
      ),
      'desde', p_desde,
      'hasta', p_hasta
    )
  ) into v_data;

  return v_data;
end;
$fn$;

-- Seguridad: nunca PUBLIC; solo service_role (GAS lo invoca con service_role en Fase 1).
revoke all on function mos._r2(numeric)             from public;
revoke all on function mos.finanzas_rango(text,text) from public;
grant execute on function mos._r2(numeric)             to service_role;
grant execute on function mos.finanzas_rango(text,text) to service_role;
