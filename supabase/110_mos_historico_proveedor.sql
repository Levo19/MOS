-- 110_mos_historico_proveedor.sql — [MIGRACIÓN MOS · FASE 2 · LECTURA CROSS-SCHEMA wh + mos]
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- Espeja con PARIDAD la función GAS getHistoricoProveedor (gas/Proveedores.gs:204).
--
-- QUÉ HACE EL GAS (resumen fiel del cuerpo línea-a-línea):
--   1. Lee la HOJA GUIAS de WH (_abrirWhSheet, cross-app) y arma un set guiaIds {idGuia → {fecha, estado}}
--      filtrando: idProveedor == params.idProveedor  ·  tipo COMIENZA con 'INGRESO' (indexOf===0, case-insensitive)
--      ·  fecha (TZ script = America/Lima) >= corte (= hoy - dias).  ⚠️ NO filtra por estado (ver DIVERGENCIA #1).
--   2. Lee la HOJA GUIA_DETALLE de WH; por cada línea cuya idGuia está en el set:
--        cod = codigoProducto (trim, skip vacío)  ·  cant = cantidadRecibida  ·  prec = precioUnitario
--      Acumula:
--        · porCodigo[cod]: veces++, cantidadTotal+=cant, sumaPrecio+=prec*cant (solo si prec>0),
--          sumaCantParaPromedio+=cant (solo si prec>0), ultimaFecha/ultimoPrecio (la compra más reciente con prec>0)
--        · porDia[fecha]: items[cod]{cantidad, sumaMonto, ultimoPrecio}, totalDia, idsGuias(set)
--        · totalGastado += prec*cant   (acumula SIEMPRE, incluso prec<=0 → suma 0, inocuo)
--   3. Enriquece con descripcion/skuBase desde mos.productos (match por codigoBarra). precioPromedio =
--      round(sumaPrecio/sumaCantParaPromedio, 2). variacionPct = round((ultimoPrecio-promedio)/promedio*100, 1).
--      Ordena productos por veces desc.
--   4. Arma guiasPorDia[]: por día {fecha,totalDia(2dec),numGuias,numItems,items[]}, items con
--      {codigoBarra,descripcion,skuBase,cantidad,monto(2dec),precio} ordenados por monto desc; días por fecha desc.
--   5. Lee PAGOS_PROVEEDOR de MOS filtrando idProveedor; totalPagado = Σ monto. porPagar = totalGastado-totalPagado.
--   6. return { ok:true, data:{ idProveedor, rangoDias, totalGuias, totalGastado, totalPagado, porPagar,
--                                productos:[...], guiasPorDia:[...] } }.
--
-- FUENTES CRUZADAS:
--   · wh.guias        (cabecera; filtra id_proveedor + tipo INGRESO* + fecha en rango, TZ Lima)
--   · wh.guia_detalle (montos; cod_producto / cant_recibida / precio_unitario)
--   · mos.productos   (enriquecer descripcion/sku por codigo_barra)
--   · mos.pagos_proveedor (totalPagado)
--
-- ⚠️ MAPEO DE COLUMNAS HOJA→TABLA (verificado contra 03_schema_wh.sql):
--   El GAS lee headers de la HOJA en camelCase (codigoProducto/cantidadRecibida/precioUnitario), pero la SOMBRA
--   Supabase usa snake_case con NOMBRES DISTINTOS: la hoja 'codigoProducto' → columna `cod_producto`,
--   'cantidadRecibida' → `cant_recibida`, 'precioUnitario' → `precio_unitario`. Mapeo confirmado en 03_schema_wh.sql
--   (wh.guia_detalle) y en el sync _WH_SPECS. La RPC usa los nombres REALES de la tabla.
--
-- ── REQUISITOS 40x ──────────────────────────────────────────────────────────────────────────────────────────
--   · PARIDAD DE SHAPE: data.* en camelCase EXACTO + arrays productos/guiasPorDia con sus claves exactas.
--   · GATE: mos._claim_ok() (service_role/GAS o JWT app='MOS'); resto rechazado.
--   · _fresh / _heartbeat: se concatena mos._frescura_sombra() (igual que 94/76). La frescura aquí cubre la
--     SOMBRA wh (guias/guia_detalle) y mos (productos/pagos): si el latido está congelado, el front cae a GAS.
--   · GAPS marcados: data._gaps[] lista qué fuente faltó/quedó vacía (no rompe, informa). Replica el espíritu de
--     los `return {ok:false,'Hoja ... no accesible'}` del GAS, pero sin abortar (en Supabase las tablas existen;
--     un "gap" real es tabla vacía o sombra congelada, no inaccesible).
--   · TZ America/Lima: la fecha de la guía se reduce a YYYY-MM-DD en TZ Lima (espeja Utilities.formatDate(tz)) y
--     el corte = (hoy_lima - dias). Comparación por fecha-de-negocio, coherente con el ecosistema MOS/WH.
--
-- ── DIVERGENCIAS HONESTAS (paridad declarada) ───────────────────────────────────────────────────────────────
--   #1 ESTADO: el GAS NO filtra por estado (captura estado pero acumula todas las guías INGRESO en rango,
--      cerradas o no). El prompt menciona "estado CERRADA"; para NO romper paridad de TOTALES, la RPC replica el
--      GAS (sin filtro de estado por defecto). Se añade un opt-in `soloCerradas:true` (forward-looking) que SÍ
--      filtra estado in ('CERRADA','AUTOCERRADA') — apagado por defecto = paridad exacta. El estado de cada guía
--      se expone igualmente (guiasPorDia[].estados) como metadato.
--   #2 PAGOS: el GAS suma TODOS los pagos del proveedor sin filtrar por rango ni por estado (incluye anulados si
--      los hubiera). La RPC replica: Σ monto de mos.pagos_proveedor where id_proveedor == p, sin filtro de fecha
--      ni estado. (Resultado idéntico a getPagosProveedor→reduce del GAS.)
--   #3 fecha string: el GAS compara/ordena fechas como string 'YYYY-MM-DD' (localeCompare). La RPC produce la
--      misma string (TZ Lima) → ordenamiento idéntico.
--   #4 redondeo: GAS usa Math.round(x*100)/100 y *1000/10. La RPC usa round(numeric,2) y round(numeric,1) →
--      mismo resultado para los valores de dinero esperados (numeric, sin float drift).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create or replace function mos.historico_proveedor(p jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_prov         text    := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_dias         int;
  v_solo_cerr    boolean := (coalesce(p->>'soloCerradas','') in ('true','1','t'));
  v_corte        date;
  v_total_guias  int;
  v_total_gastado numeric;
  v_total_pagado numeric;
  v_productos    jsonb;
  v_dias_arr     jsonb;
  v_gaps         jsonb := '[]'::jsonb;
  v_guia_rows    int;
  v_det_rows     int;
  v_prod_rows    int;
begin
  -- ── Gate de app (paridad con el resto del ecosistema MOS) ──────────────────────────────────────────────────
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- ── Validación de parámetros (paridad GAS: idProveedor requerido; dias default 60) ─────────────────────────
  if v_prov is null then
    return jsonb_build_object('ok', false, 'error', 'idProveedor requerido');
  end if;
  -- parseInt(params.dias) || 60  (basura → 60; <=0 → 60, igual que el GAS donde 0 es falsy)
  begin
    v_dias := nullif(btrim(coalesce(p->>'dias','')), '')::int;
  exception when others then
    v_dias := null;
  end;
  if v_dias is null or v_dias <= 0 then v_dias := 60; end if;

  -- corte = hoy(Lima) - dias  (el GAS hace corte.setDate(getDate()-dias) y compara fDate < corte → descartar)
  v_corte := (now() at time zone 'America/Lima')::date - make_interval(days => v_dias);

  -- ════════════════════════════════════════════════════════════════════════════════════════════════════════
  -- CTE base: guías de INGRESO del proveedor en rango (cross-schema wh.guias ⋈ wh.guia_detalle), enriquecidas.
  -- ════════════════════════════════════════════════════════════════════════════════════════════════════════
  with guias_sel as (
    select
      g.id_guia,
      g.estado,
      to_char((g.fecha at time zone 'America/Lima')::date, 'YYYY-MM-DD') as fecha_dia
    from wh.guias g
    where g.id_proveedor = v_prov
      and position('INGRESO' in upper(coalesce(g.tipo,''))) = 1        -- tipo COMIENZA con INGRESO (indexOf===0)
      and g.fecha is not null
      and (g.fecha at time zone 'America/Lima')::date >= v_corte        -- fecha-de-negocio >= corte (TZ Lima)
      and (not v_solo_cerr or upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA'))  -- opt-in (DIVERG #1)
  ),
  -- líneas de detalle de esas guías, con cantidad/precio numéricos y cod limpio (skip vacíos, igual que GAS)
  det as (
    select
      gs.id_guia,
      gs.fecha_dia,
      btrim(coalesce(d.cod_producto, '')) as cod,
      coalesce(d.cant_recibida, 0)        as cant,
      coalesce(d.precio_unitario, 0)      as prec
    from guias_sel gs
    join wh.guia_detalle d on d.id_guia = gs.id_guia
    where btrim(coalesce(d.cod_producto, '')) <> ''
  ),
  -- catálogo: descripcion/sku por codigo_barra (match exacto trim, primer producto por id_producto = estable)
  prod as (
    select distinct on (btrim(coalesce(pr.codigo_barra,'')))
      btrim(coalesce(pr.codigo_barra,'')) as cb,
      pr.descripcion,
      coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku
    from mos.productos pr
    where coalesce(pr.codigo_barra,'') <> ''
    order by btrim(coalesce(pr.codigo_barra,'')), pr.id_producto
  ),
  -- ── Agregación por CÓDIGO (productos[]) ──────────────────────────────────────────────────────────────────
  por_codigo as (
    select
      d.cod                                                              as codigo_barra,
      count(*)                                                           as veces,
      sum(d.cant)                                                        as cantidad_total,
      -- promedio ponderado solo sobre líneas con prec>0 (paridad: sumaPrecio/sumaCantParaPromedio)
      sum(d.prec * d.cant) filter (where d.prec > 0)                     as suma_precio,
      sum(d.cant)          filter (where d.prec > 0)                     as suma_cant_prom,
      max(d.fecha_dia)                                                   as ultima_fecha
    from det d
    group by d.cod
  ),
  -- último precio = precio (prec>0) de la línea cuya fecha_dia es la más reciente para ese código
  ultimo_precio as (
    select distinct on (d.cod)
      d.cod                                                              as codigo_barra,
      d.prec                                                            as ultimo_precio
    from det d
    where d.prec > 0
    order by d.cod, d.fecha_dia desc
  ),
  productos_calc as (
    select
      pc.codigo_barra,
      pc.veces,
      pc.cantidad_total,
      coalesce(up.ultimo_precio, 0)                                      as ultimo_precio,
      pc.ultima_fecha,
      case when coalesce(pc.suma_cant_prom,0) > 0
           then round(pc.suma_precio / pc.suma_cant_prom, 2)
           else 0 end                                                   as precio_promedio
    from por_codigo pc
    left join ultimo_precio up on up.codigo_barra = pc.codigo_barra
  ),
  productos_final as (
    select jsonb_build_object(
      'codigoBarra',    x.codigo_barra,
      'veces',          x.veces,
      'cantidadTotal',  x.cantidad_total,
      'ultimoPrecio',   x.ultimo_precio,
      'ultimaFecha',    coalesce(x.ultima_fecha, ''),
      'descripcion',    coalesce(pr.descripcion, '—'),
      'skuBase',        coalesce(pr.sku, ''),
      'precioPromedio', x.precio_promedio,
      'variacionPct',   case when x.precio_promedio > 0 and x.ultimo_precio > 0
                             then round(((x.ultimo_precio - x.precio_promedio) / x.precio_promedio) * 100, 1)
                             else 0 end
    ) as row,
    x.veces as ord_veces, x.codigo_barra as ord_cod
    from productos_calc x
    left join prod pr on pr.cb = x.codigo_barra
  ),
  -- ── Agregación por DÍA → ítem (guiasPorDia[].items[]) ────────────────────────────────────────────────────
  dia_item as (
    select
      d.fecha_dia,
      d.cod                                                              as codigo_barra,
      sum(d.cant)                                                        as cantidad,
      sum(d.prec * d.cant)                                               as suma_monto,
      -- ultimoPrecio del ítem-día: último prec>0 según orden de aparición (paridad laxa: el GAS toma el último
      -- prec>0 que recorre; sin orden de fila fiable usamos max(prec) sobre líneas prec>0 — ver RIESGO en informe)
      max(d.prec) filter (where d.prec > 0)                             as ultimo_precio
    from det d
    group by d.fecha_dia, d.cod
  ),
  dia_item_json as (
    select
      di.fecha_dia,
      jsonb_build_object(
        'codigoBarra', di.codigo_barra,
        'descripcion', coalesce(pr.descripcion, '—'),
        'skuBase',     coalesce(pr.sku, ''),
        'cantidad',    di.cantidad,
        'monto',       round(di.suma_monto, 2),
        'precio',      coalesce(di.ultimo_precio, 0)
      ) as item_row,
      round(di.suma_monto, 2) as ord_monto
    from dia_item di
    left join prod pr on pr.cb = di.codigo_barra
  ),
  -- agregados por día (numGuias = guías distintas del día; numItems = códigos distintos del día)
  dia_meta as (
    select
      d.fecha_dia,
      sum(d.prec * d.cant)                                              as total_dia,
      count(distinct d.id_guia)                                          as num_guias
    from det d
    group by d.fecha_dia
  ),
  dia_estados as (
    select gs.fecha_dia,
           jsonb_agg(distinct gs.estado) filter (where gs.estado is not null) as estados
    from guias_sel gs
    where gs.id_guia in (select distinct id_guia from det)               -- solo días que aportan detalle
    group by gs.fecha_dia
  ),
  dia_items_agg as (
    select dij.fecha_dia,
           jsonb_agg(dij.item_row order by dij.ord_monto desc) as items,
           count(*) as num_items
    from dia_item_json dij
    group by dij.fecha_dia
  ),
  dias_final as (
    select jsonb_build_object(
      'fecha',    dm.fecha_dia,
      'totalDia', round(dm.total_dia, 2),
      'numGuias', dm.num_guias,
      'numItems', dia.num_items,
      'estados',  coalesce(de.estados, '[]'::jsonb),
      'items',    coalesce(dia.items, '[]'::jsonb)
    ) as row,
    dm.fecha_dia as ord_fecha
    from dia_meta dm
    join dia_items_agg dia on dia.fecha_dia = dm.fecha_dia
    left join dia_estados de on de.fecha_dia = dm.fecha_dia
  )
  select
    (select count(distinct id_guia) from det)                            as g_count,
    coalesce((select round(sum(prec * cant), 2) from det), 0)            as gastado,
    coalesce((select jsonb_agg(row order by ord_veces desc, ord_cod) from productos_final), '[]'::jsonb),
    coalesce((select jsonb_agg(row order by ord_fecha desc) from dias_final), '[]'::jsonb)
  into v_total_guias, v_total_gastado, v_productos, v_dias_arr;

  -- ── Pagos (DIVERG #2: todos los pagos del proveedor, sin rango ni estado) ──────────────────────────────────
  select coalesce(sum(coalesce(pp.monto, 0)), 0)
    into v_total_pagado
    from mos.pagos_proveedor pp
   where pp.id_proveedor = v_prov;

  -- ── Detección de GAPS (informativo; no aborta) ────────────────────────────────────────────────────────────
  select count(*) into v_guia_rows from wh.guias g
    where g.id_proveedor = v_prov
      and position('INGRESO' in upper(coalesce(g.tipo,''))) = 1
      and g.fecha is not null
      and (g.fecha at time zone 'America/Lima')::date >= v_corte;
  v_det_rows  := v_total_guias;   -- guías que aportaron detalle
  select count(*) into v_prod_rows from mos.productos;

  if v_guia_rows = 0 then
    v_gaps := v_gaps || jsonb_build_array('wh.guias: sin guías INGRESO del proveedor en el rango');
  elsif v_total_guias = 0 then
    v_gaps := v_gaps || jsonb_build_array('wh.guia_detalle: guías halladas pero sin líneas de detalle');
  end if;
  if v_prod_rows = 0 then
    v_gaps := v_gaps || jsonb_build_array('mos.productos: catálogo vacío — descripciones caen a "—"');
  end if;

  return jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'idProveedor',  v_prov,
      'rangoDias',    v_dias,
      'totalGuias',   coalesce(v_total_guias, 0),
      'totalGastado', coalesce(v_total_gastado, 0),
      'totalPagado',  round(coalesce(v_total_pagado, 0), 2),
      'porPagar',     round(coalesce(v_total_gastado, 0) - coalesce(v_total_pagado, 0), 2),
      'productos',    v_productos,
      'guiasPorDia',  v_dias_arr,
      '_gaps',        v_gaps,
      '_soloCerradas', v_solo_cerr
    )
  ) || mos._frescura_sombra();   -- añade _heartbeat / _now / _ttl_min / _fresh
exception
  when others then
    -- Paridad con el catch del GAS (return {ok:false, error:'Error histórico: '+msg}).
    return jsonb_build_object('ok', false, 'error', 'Error histórico: ' || coalesce(sqlerrm, 'desconocido'));
end;
$fn$;

revoke all on function mos.historico_proveedor(jsonb) from public;
grant execute on function mos.historico_proveedor(jsonb) to service_role, authenticated;
