-- ═══════════════════════════════════════════════════════════════════════════
-- [796] FINANZAS · detalleProductos: exponer INGRESO y MARGEN REAL por producto
-- ═══════════════════════════════════════════════════════════════════════════
-- ADITIVO PURO. Partido de la definición VIVA (pg_get_functiondef) — NO del archivo
-- del repo, que estaba desactualizado. Lo único que cambia son DOS claves nuevas
-- dentro de cada elemento de `data.detalleProductos`:
--   · ingreso    = cuánto se cobró de ese grupo_sku (el CTE `grp` ya lo calculaba)
--   · margenPct  = margen real de esa línea SOLO si el costo es real; null si es estimado
-- Ningún total, KPI, orden ni clave existente se toca: costoVentas, ventasNetas,
-- margenBrutoPct, break-even, etc. quedan idénticos.
--
-- PORQUÉ: el 14-ago se descubrió AJINOMOTO GLUTAMATO 90GR (LEV1564) con costo S/320
-- y precio S/2.50 en el catálogo. Ese solo SKU hundió el margen del día a −17.4%
-- cuando el real era +16.8%, y nadie podía verlo porque el overlay mostraba el costo
-- sin el ingreso al lado. Con `ingreso` en la mano el front destaca en rojo toda fila
-- cuyo costo supere su venta: la señal que habría ahorrado 4 días de números falsos.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION mos.finanzas_dia(p_fecha text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '30s'
AS $function$
declare
  v_margen numeric := 20;
  v_d      date;
  v_data   jsonb;
  v_hb     timestamptz;
  v_ttl    int;
  v_fresh  boolean;

  v_ventas_brutas      numeric := 0;
  v_total_efectivo     numeric := 0;
  v_total_virtual      numeric := 0;
  v_total_mixto        numeric := 0;
  v_porcobrar_monto    numeric := 0;
  v_credito_monto      numeric := 0;
  v_ventas_netas       numeric := 0;
  v_tickets            int := 0;
  v_tickets_totales    int := 0;
  v_porcobrar_n        int := 0;
  v_creditos_n         int := 0;
  v_anulados_n         int := 0;
  v_ticket_promedio    numeric := 0;
  v_bydoc              jsonb := '{}'::jsonb;
  v_bymetodo           jsonb;
  v_detalle_tickets    jsonb := '[]'::jsonb;

  v_costo_total        numeric := 0;
  v_costo_real         numeric := 0;
  v_costo_estimado     numeric := 0;
  v_items              int := 0;
  v_unidades           numeric := 0;
  v_skus_distintos     int := 0;
  v_sin_costo          jsonb := '[]'::jsonb;
  v_cant_estimados     int := 0;
  v_margen_prom_pct    numeric := 0;
  v_detalle_productos  jsonb := '[]'::jsonb;

  v_gasto_personal     numeric := 0;
  v_personas           int := 0;
  v_personal_detalle   jsonb := '[]'::jsonb;

  v_gasto_otros        numeric := 0;
  v_gastos_fijos       numeric := 0;
  v_gastos_variables   numeric := 0;
  v_gastos_bycat       jsonb := '{}'::jsonb;
  v_gastos_detalle     jsonb := '[]'::jsonb;

  v_utilidad_bruta     numeric := 0;
  v_total_gastos       numeric := 0;
  v_utilidad_neta      numeric := 0;
  v_margen_bruto_pct   numeric := 0;
  v_margen_neto_pct    numeric := 0;
  v_costos_fijos       numeric := 0;
  v_margen_contrib     numeric := 0;
  v_break_even_ventas  numeric;
  v_break_even_pct     numeric := 0;
  v_supera_be          boolean := false;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  if p_fecha is null or btrim(p_fecha) = '' then
    v_d := (now() at time zone 'America/Lima')::date;
  else
    begin
      v_d := p_fecha::date;
    exception when others then
      return jsonb_build_object('ok', false, 'error', 'Fecha inválida (YYYY-MM-DD)');
    end;
  end if;

  select valor::numeric into v_margen
  from mos.config
  where clave = 'finMargenDefault' and valor ~ '^[0-9]+(\.[0-9]+)?$';
  if v_margen is null or v_margen < 0 or v_margen >= 100 then v_margen := 20; end if;

  with del_dia as (
    select v.id_venta,
           coalesce(v.total,0)::numeric as total,
           upper(coalesce(v.forma_pago,'')) as fp,
           v.forma_pago,
           coalesce(nullif(v.tipo_doc,''),'NOTA_DE_VENTA') as tipo_doc,
           coalesce(v.vendedor,'') as vendedor,
           coalesce(v.correlativo,'') as correlativo,
           coalesce(v.cliente_nombre,'') as cliente_nombre,
           coalesce(v.cliente_doc,'') as cliente_doc,
           v.fecha
    from me.ventas v
    where (v.fecha at time zone 'America/Lima')::date = v_d
  ),
  clasif as (
    select d.*,
           (d.fp like 'ANULADO%')                                    as es_anulado,   -- C2: prefijo
           (d.fp not like 'ANULADO%')                                as no_anulado,   -- C2: prefijo
           (d.fp not like 'ANULADO%' and d.fp not in ('POR_COBRAR','CREDITO')) as es_cobrado,  -- C2: prefijo
           (d.fp = 'POR_COBRAR')                                     as es_porcobrar,
           (d.fp = 'CREDITO')                                        as es_credito
    from del_dia d
  ),
  cob as (
    select
      sum( case
             when fp='EFECTIVO' then total
             when fp='VIRTUAL'  then 0
             when fp like 'MIXTO%' then
               coalesce( (substring(upper(forma_pago) from 'EFE:([0-9.]+)'))::numeric,
                         round(total - coalesce((substring(upper(forma_pago) from 'VIR:([0-9.]+)'))::numeric,0), 2) )
             else 0 end ) as tot_efe,
      sum( case
             when fp='EFECTIVO' then 0
             when fp='VIRTUAL'  then total
             when fp like 'MIXTO%' then coalesce((substring(upper(forma_pago) from 'VIR:([0-9.]+)'))::numeric,0)
             else total end ) as tot_vir,
      sum( case when fp like 'MIXTO%' then total else 0 end ) as tot_mixto,
      count(*) as n_cobrados
    from clasif where es_cobrado
  )
  select
    coalesce((select mos._r2(sum(total)) from clasif where no_anulado), 0),
    coalesce((select tot_efe   from cob), 0),
    coalesce((select tot_vir   from cob), 0),
    coalesce((select tot_mixto from cob), 0),
    coalesce((select mos._r2(sum(total)) from clasif where es_porcobrar), 0),
    coalesce((select mos._r2(sum(total)) from clasif where es_credito), 0),
    coalesce((select n_cobrados from cob), 0),
    coalesce((select count(*)::int from clasif where no_anulado), 0),
    coalesce((select count(*)::int from clasif where es_porcobrar), 0),
    coalesce((select count(*)::int from clasif where es_credito), 0),
    coalesce((select count(*)::int from clasif where es_anulado), 0),
    coalesce((select jsonb_object_agg(tipo_doc, monto)
              from (select tipo_doc, mos._r2(sum(total)) as monto
                    from clasif where no_anulado group by tipo_doc) q), '{}'::jsonb),
    coalesce((
      select jsonb_agg(jsonb_build_object(
               'idVenta',     id_venta,
               'total',       total,
               'tipoDoc',     tipo_doc,
               'formaPago',   case when coalesce(forma_pago,'')='' then 'EFECTIVO' else forma_pago end,
               'estado',      case when fp like 'ANULADO%' then 'ANULADO'    -- C2: prefijo
                                   when fp='POR_COBRAR' then 'POR_COBRAR'
                                   when fp='CREDITO' then 'CREDITO'
                                   else 'COBRADO' end,
               'vendedor',    vendedor,
               'correlativo', correlativo,
               'cliente',     cliente_nombre,
               'clienteDoc',  cliente_doc,
               'hora',        to_char(fecha at time zone 'America/Lima', 'HH24:MI')
             ) order by to_char(fecha at time zone 'America/Lima', 'HH24:MI') desc)
      from clasif), '[]'::jsonb)
  into
    v_ventas_brutas, v_total_efectivo, v_total_virtual, v_total_mixto,
    v_porcobrar_monto, v_credito_monto,
    v_tickets, v_tickets_totales, v_porcobrar_n, v_creditos_n, v_anulados_n,
    v_bydoc, v_detalle_tickets;

  v_total_efectivo := mos._r2(v_total_efectivo);
  v_total_virtual  := mos._r2(v_total_virtual);
  v_total_mixto    := mos._r2(v_total_mixto);
  v_ventas_netas   := mos._r2(v_total_efectivo + v_total_virtual);
  v_ticket_promedio := case when v_tickets > 0 then mos._r2(v_ventas_netas / v_tickets) else 0 end;

  v_bymetodo := jsonb_build_object(
    'EFECTIVO',   v_total_efectivo,
    'VIRTUAL',    v_total_virtual,
    'MIXTO',      v_total_mixto,
    'POR_COBRAR', mos._r2(v_porcobrar_monto),
    'CREDITO',    mos._r2(v_credito_monto)
  );

  with vcobr as (
    select v.id_venta
    from me.ventas v
    where (v.fecha at time zone 'America/Lima')::date = v_d
      and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'           -- C2: prefijo
      and upper(coalesce(v.forma_pago,'')) not in ('POR_COBRAR','CREDITO')
  ),
  det as (
    select upper(trim(d.sku)) as nsku_l,
           upper(trim(coalesce(d.cod_barras,''))) as ncod_l,
           coalesce(d.cantidad,0)::numeric as cantidad,
           coalesce(d.precio,0)::numeric as precio,
           d.sku as sku_raw, d.nombre as nombre_raw
    from me.ventas_detalle d
    join vcobr v on v.id_venta = d.id_venta
  ),
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
  canon as (
    select distinct on (upper(trim(sku_base)))
           upper(trim(sku_base)) nsku,
           coalesce(precio_costo,0)::numeric costo,
           coalesce(descripcion,'') descripcion,
           coalesce(codigo_barra,'') codigo_barra,
           coalesce(precio_venta,0)::numeric precio_venta
    from mos.productos where sku_base is not null and trim(sku_base)<>''
    order by upper(trim(sku_base)), case when coalesce(factor_conversion,1)=1 then 0 else 1 end, id_producto
  ),
  det_res as (
    select dt.cantidad, dt.precio, dt.nombre_raw,
           coalesce(mi.factor, mc1.factor, mc2.factor, msk.factor, 1) as factor,
           coalesce(mi.nsku, mc1.nsku, mc2.nsku, msk.nsku) as nsku_match,
           coalesce(
             mi.nsku, mc1.nsku, mc2.nsku, msk.nsku,
             nullif(dt.nsku_l,''), nullif(dt.ncod_l,''),
             upper(left(trim(coalesce(dt.nombre_raw,'')),30))
           ) as grupo_sku
    from det dt
    left join m_id  mi  on mi.k  = dt.nsku_l
    left join m_cod mc1 on mc1.k = dt.nsku_l
    left join m_cod mc2 on mc2.k = dt.ncod_l
    left join m_sku msk on msk.k = dt.nsku_l
  ),
  lineas as (
    select dr.*,
           coalesce(cn.costo,0) as costo_canon_unit,
           (dr.cantidad * dr.factor) as unidades_base,
           (dr.precio * dr.cantidad) as ingreso_linea,
           coalesce(cn.descripcion,'') as canon_desc,
           coalesce(cn.codigo_barra,'') as canon_cod,
           coalesce(cn.precio_venta,0) as canon_precio,
           (cn.nsku is not null) as tiene_canon,
           case when coalesce(cn.costo,0) > 0
                then (dr.cantidad * dr.factor) * cn.costo
                else (dr.precio * dr.cantidad) * (1 - v_margen/100)
           end as costo_linea,
           (coalesce(cn.costo,0) <= 0) as es_estimado
    from det_res dr
    left join canon cn on cn.nsku = dr.nsku_match
  ),
  grp as (
    select grupo_sku,
           sum(unidades_base) as cantidad,
           sum(cantidad)      as cant_present,
           sum(ingreso_linea) as ingreso,
           bool_or(es_estimado) as es_estimado,
           (array_agg(costo_canon_unit) filter (where tiene_canon))[1] as costo_unit_canon,
           (array_agg(canon_desc)       filter (where tiene_canon))[1] as canon_desc,
           (array_agg(nombre_raw))[1] as nombre_fallback,
           (array_agg(canon_cod)        filter (where tiene_canon))[1] as canon_cod,
           (array_agg(canon_precio)     filter (where tiene_canon))[1] as canon_precio
    from lineas
    group by grupo_sku
  )
  select
    coalesce(mos._r2((select sum(costo_linea) from lineas)),0),
    coalesce(mos._r2((select sum(costo_linea) from lineas where not es_estimado)),0),
    coalesce(mos._r2((select sum(costo_linea) from lineas where es_estimado)),0),
    coalesce((select count(*)::int from det),0),
    coalesce((select round(sum(unidades_base))::numeric from lineas),0),
    coalesce((select count(*)::int from grp),0),
    coalesce((select jsonb_agg(grupo_sku) from grp where es_estimado), '[]'::jsonb),
    coalesce((select count(*)::int from grp where es_estimado),0),
    coalesce((
      select case when sum(ingreso_linea) > 0
        then round( ((sum(ingreso_linea)-sum(costo_linea))/sum(ingreso_linea)) * 1000 ) / 10.0
        else 0 end
      from lineas),0),
    coalesce((
      select jsonb_agg(jsonb_build_object(
               'sku',            grupo_sku,
               'nombre',         coalesce(canon_desc, nombre_fallback),
               'cantidad',       round(cantidad*100)/100,
               'cantPresent',    round(cant_present*100)/100,
               'precio',         case when cantidad > 0 then mos._r2(ingreso/cantidad) else 0 end,
               'costoUnit',      mos._r2(coalesce(costo_unit_canon,0)),
               'costoTotal',     mos._r2(coalesce(costo_unit_canon,0) * cantidad),
               'esEstimado',     es_estimado,
               'sinCosto',       es_estimado,
               'codigoCanonico', coalesce(canon_cod,''),
               'precioCanonico', coalesce(canon_precio,0),
               -- [796] INGRESO por producto: cuánto se COBRÓ realmente de ese grupo_sku. El CTE
               -- `grp` ya lo tenía calculado (sum(ingreso_linea)) pero nunca se exponía, así que el
               -- overlay "Productos Vendidos" mostraba costo sin nada contra qué compararlo y no
               -- se podía ver a simple vista un producto cuyo costo supera su propia venta.
               'ingreso',        mos._r2(ingreso),
               -- [796] MARGEN REAL de la línea, solo cuando el costo es REAL. Si es estimado el
               -- margen sería tautológico (= al default) y mentiría: va null y el front pinta el
               -- chip "est. N%". Mismo costoTotal que se muestra arriba → el chip cuadra con la fila.
               'margenPct',      case when not es_estimado and ingreso > 0
                                      then round( ((ingreso - mos._r2(coalesce(costo_unit_canon,0) * cantidad))
                                                   / ingreso * 100)::numeric, 1)
                                      else null end
             ) order by cantidad desc)
      from grp), '[]'::jsonb)
  into
    v_costo_total, v_costo_real, v_costo_estimado, v_items, v_unidades,
    v_skus_distintos, v_sin_costo, v_cant_estimados, v_margen_prom_pct, v_detalle_productos;

  with liq as (
    select lower(trim(l.nombre)) as k,
           l.nombre,
           upper(coalesce(l.estado,'PENDIENTE')) as estado,
           case when coalesce(l.total_dia,0)>0 then l.total_dia::numeric else coalesce(l.monto_base,0)::numeric end as monto,
           coalesce(l.id_personal,'') as id_personal,
           coalesce(l.rol,'') as rol,
           coalesce(l.app_origen,'') as app_origen,
           l.id_dia
    from mos.liquidaciones_dia l
    where l.presente = true and l.nombre is not null and trim(l.nombre)<>''
      and (l.fecha at time zone 'America/Lima')::date = v_d
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
    select *, row_number() over (partition by coalesce(nullif(id_personal,''), k), rol order by id_dia) rn from liq  -- [732] identidad real, no nombre
  ),
  liq1 as (
    select * from liq_dedup where rn = 1
  ),
  resuelto as (
    select l.*,
           coalesce(
             nullif(upper(l.rol), ''),   -- [732] el rol de LA FILA manda sobre el lookup por nombre
             (select upper(p.rol) from mos.personal p
              where p.rol is not null and trim(p.rol)<>''
                and (
                  ( (p.apellido is null or trim(p.apellido)='') and lower(trim(p.nombre)) = l.k )
                  or ( p.apellido is not null and trim(p.apellido)<>'' and lower(trim(p.nombre)||' '||trim(p.apellido)) = l.k )
                )
              limit 1),
             upper(l.rol)
           ) as rol_final,
           (l.estado = 'VETADA') as vetada
    from liq1 l
  )
  select
    coalesce(mos._r2(sum(case when not vetada then monto else 0 end)),0),
    coalesce(count(*) filter (where not vetada)::int, 0),
    coalesce(jsonb_agg(jsonb_build_object(
        'idJornada',  '',
        'idPersonal', id_personal,
        'nombre',     nombre,
        'rol',        rol_final,
        'zona',       '',
        'appOrigen',  app_origen,
        'monto',      case when vetada then 0 else monto end,
        'fuente',     case when vetada then 'ELIMINADA' else 'AUTO_VENTA' end,
        'vetada',     vetada,
        'presente',   true,
        'liqEstado',  estado
      )), '[]'::jsonb)
  into v_gasto_personal, v_personas, v_personal_detalle
  from resuelto;

  with g as (
    select coalesce(g.monto,0)::numeric as monto,
           coalesce(nullif(g.categoria,''),'OTROS') as categoria,
           g.tipo,
           g.id_gasto, g.fecha, g.descripcion, g.comprobante, g.registrado_por
    from mos.gastos g
    where (g.fecha at time zone 'America/Lima')::date = v_d
      -- [735] El sueldo NO puede entrar dos veces. Ya viene por v_gasto_personal (bruto, desde
      -- liquidaciones_dia y asignado al día que se trabajó). La fila JORNALES de mos.gastos es el
      -- COMPROBANTE DE CAJA del pago (neto de consumos, fechado el primer día liquidado): sirve
      -- para tesorería, no para el resultado. Sin este filtro, el día de pago los costos fijos se
      -- duplicaban y el punto de equilibrio salía inflado (5-ago: S/481.60 cuando eran S/240.80).
      and upper(coalesce(g.categoria,'')) <> 'JORNALES'
  )
  select
    coalesce(mos._r2(sum(monto)),0),
    coalesce(mos._r2(sum(monto) filter (where tipo = 'FIJO')),0),
    coalesce((select jsonb_object_agg(categoria, m)
              from (select categoria, mos._r2(sum(monto)) m from g group by categoria) q), '{}'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object(
                'idGasto',       id_gasto,
                'fecha',         fecha,
                'categoria',     categoria,
                'tipo',          tipo,
                'descripcion',   descripcion,
                'monto',         monto,
                'comprobante',   comprobante,
                'registradoPor', registrado_por
              )) from g), '[]'::jsonb)
  into v_gasto_otros, v_gastos_fijos, v_gastos_bycat, v_gastos_detalle
  from g;

  v_gasto_otros      := mos._r2(v_gasto_otros);
  v_gastos_fijos     := mos._r2(v_gastos_fijos);
  v_gastos_variables := mos._r2(v_gasto_otros - v_gastos_fijos);

  v_utilidad_bruta := mos._r2(v_ventas_netas - v_costo_total);
  v_total_gastos   := mos._r2(v_gasto_personal + v_gasto_otros);
  v_utilidad_neta  := mos._r2(v_utilidad_bruta - v_total_gastos);
  v_margen_bruto_pct := case when v_ventas_netas > 0 then mos._r2(v_utilidad_bruta / v_ventas_netas * 100) else 0 end;
  v_margen_neto_pct  := case when v_ventas_netas > 0 then mos._r2(v_utilidad_neta  / v_ventas_netas * 100) else 0 end;

  v_costos_fijos  := mos._r2(v_gasto_personal + v_gastos_fijos);
  v_margen_contrib := case when v_ventas_netas > 0 then (v_ventas_netas - v_costo_total) / v_ventas_netas else 0 end;
  if v_margen_contrib > 0 then
    v_break_even_ventas := mos._r2(v_costos_fijos / v_margen_contrib);
  else
    v_break_even_ventas := null;
  end if;
  v_break_even_pct := case
    when v_break_even_ventas is not null and v_ventas_netas > 0
    then mos._r2(least(v_break_even_ventas / v_ventas_netas * 100, 100))
    else 0 end;
  v_supera_be := (v_break_even_ventas is not null) and (v_ventas_netas >= v_break_even_ventas);

  v_data := jsonb_build_object(
    'fecha',              to_char(v_d, 'YYYY-MM-DD'),
    'ventasBrutas',       v_ventas_brutas,
    'ventasNetas',        v_ventas_netas,
    'tickets',            v_tickets,
    'anulados',           v_anulados_n,
    'creditos',           v_creditos_n,
    'ticketPromedio',     v_ticket_promedio,
    'cobrado',            v_ventas_netas,
    'cobradoEfectivo',    v_total_efectivo,
    'cobradoVirtual',     v_total_virtual,
    'creditoOtorgado',    mos._r2(v_porcobrar_monto + v_credito_monto),
    'byDoc',              v_bydoc,
    'byMetodo',           v_bymetodo,
    'detalleTickets',     v_detalle_tickets,
    'costoVentas',        v_costo_total,
    'costoVentasReal',    v_costo_real,
    'costoVentasEstimado',v_costo_estimado,
    'itemsVendidos',      v_items,
    'unidadesVendidas',   v_unidades,
    'skusDistintos',      v_skus_distintos,
    'productosSinCosto',  v_sin_costo,
    'cantidadEstimados',  v_cant_estimados,
    'margenPromedioPct',  v_margen_prom_pct,
    'defaultMargenUsado', v_margen,
    'detalleProductos',   v_detalle_productos,
    'utilidadBruta',      v_utilidad_bruta,
    'margenBrutoPct',     v_margen_bruto_pct,
    'gastoPersonal',      v_gasto_personal,
    'personalDetalle',    v_personal_detalle,
    'personas',           v_personas,
    'gastoOtros',         v_gasto_otros,
    'gastosFijos',        v_gastos_fijos,
    'gastosVariables',    v_gastos_variables,
    'gastosByCategoria',  v_gastos_bycat,
    'gastosDetalle',      v_gastos_detalle,
    'totalGastos',        v_total_gastos,
    'utilidadNeta',       v_utilidad_neta,
    'margenNetoPct',      v_margen_neto_pct,
    'costosFijos',        v_costos_fijos,
    'margenContribPct',   mos._r2(v_margen_contrib * 100),
    'breakEvenVentas',    v_break_even_ventas,
    'breakEvenPct',       v_break_even_pct,
    'superaBreakEven',    v_supera_be
  );

  begin
    select (valor)::timestamptz into v_hb from mos.config where clave = 'MOS_SYNC_HEARTBEAT' limit 1;
  exception when others then v_hb := null;
  end;
  begin
    select (valor)::int into v_ttl from mos.config where clave = 'MOS_SYNC_TTL_MIN' limit 1;
  exception when others then v_ttl := null;
  end;
  v_ttl := coalesce(v_ttl, 30);
  if v_ttl < 15   then v_ttl := 15;   end if;
  if v_ttl > 1440 then v_ttl := 1440; end if;
  v_fresh := (v_hb is not null) and (now() - v_hb < make_interval(mins => v_ttl));

  return jsonb_build_object('ok', true, 'data', v_data)
         || jsonb_build_object('_fresh', v_fresh, '_heartbeat', v_hb, '_now', now(), '_ttl_min', v_ttl);
end;
$function$

