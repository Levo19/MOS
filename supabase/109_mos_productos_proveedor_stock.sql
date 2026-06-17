-- 109_mos_productos_proveedor_stock.sql — [MIGRACIÓN MOS · FASE 2 · LECTURA-ENRIQUECIDA]
-- Replica con PARIDAD la función GAS getProductosProveedorConStock (gas/Proveedores.gs:563) como RPC
-- PostgreSQL SECURITY DEFINER cross-schema (mos + wh + me). Catálogo enriquecido del proveedor:
-- productos del proveedor + stock WH + stock por zona + ventas en rango + rotación + sugerencia de pedido.
--
-- ⚠️ INERTE / NO-APLICAR-AUN: este archivo SOLO define la RPC con su grant. Nadie la llama todavía (el
--    wiring de js/api.js read-path + el flip de flags es tanda posterior). MOS sigue 100% por GAS. Este
--    SQL NO toca flags, NO toca sync, NO cablea frontend. Idéntico patrón inerte que 94/98/105/106/107.
--
-- ── FUENTES CRUZADAS (todas verificadas que existen en Supabase) ────────────────────────────────────────────
--   · mos.proveedores_productos (04_schema_mos.sql:262) — productos activos del proveedor.
--   · mos.productos (01_schema_compartido.sql:43) — resolver sku_base/factor/codigo_barra/descripcion/min/max.
--   · mos.equivalencias (01:88) — ampliar barrasAll (códigos extra que mapean al mismo skuBase).
--   · mos.zonas (01:130) + mos.estaciones (01:141) — zona resolver + set de zonas REGISTRADAS.
--   · wh.stock (03_schema_wh.sql:63) — cod_producto / cantidad_disponible (stock WH por sku).
--   · me.stock_zonas (02_schema_me.sql:254) — cod_barras / zona_id / cantidad (stock por zona). ✅ EXISTE.
--   · me.ventas (02:16) + me.ventas_detalle (02:51) — ventas en rango por sku/zona para rotación. ✅ EXISTE.
--
-- ── GAPS HONESTOS (ver bloque NOTAS al final) ──────────────────────────────────────────────────────────────
--   NINGUNA fuente falta. Todas las tablas que lee el GAS están migradas. Las DIVERGENCIAS son de SEMÁNTICA
--   de frescura de SOMBRA (wh.stock / me.stock_zonas / me.ventas son sombras alimentadas por sync), señalada
--   por _fresh, NO de ausencia de tabla. Detalle en NOTAS.
--
-- ── PARIDAD DE SHAPE (mismas claves camelCase que el objeto que getProductosProveedorConStock push-ea) ───────
--   Por producto: idPP, idProveedor, skuBase, idProducto, descripcion, codigoBarra, precioReferencia,
--   minimoCompra, diasEntrega, notas, unidadesPorBulto, stockWh, stockTienda, stockTotal, zonas[],
--   zonasHuerfanas|null, stockMinimo, stockMaximo, ventasRango, rotacionDia, rangoDias, sugerencia,
--   sugerenciaBultos, razonSugerencia, alerta, countPresentaciones, countEquivalencias.
--   zonas[] = { idZona, nombre, cantidad, ventasRango, rotacionDia } (orden: cantidad desc).
--   zonasHuerfanas = { cantidad, ventasRango, rotacionDia } | null.
--   Orden final: alertas primero (NEGATIVO<BAJO_MINIMO<AGOTAR_PRONTO<CERCA_MINIMO<SIN_ROTACION<OK), luego desc.
--   Envoltorio: { ok:true, data:[...] } || mos._frescura_sombra()  → agrega _heartbeat/_now/_ttl_min/_fresh.
--
-- ── TZ ─────────────────────────────────────────────────────────────────────────────────────────────────────
--   Filtro de ventas por rango usa America/Lima: el GAS computa `desde = hoy - rangoDias días` con Date local
--   del servidor Apps Script (TZ del proyecto = Lima). Aquí: desde = (now() at time zone 'America/Lima')::date
--   - rangoDias, y se compara (v.fecha at time zone 'America/Lima')::date >= desde. Coherente con el resto del
--   ecosistema MOS (mos.hoy_lima, jornadas_lista, etc.).

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.productos_proveedor_stock(p jsonb) — p = { idProveedor (req), rangoDias (opc, default 30) }
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.productos_proveedor_stock(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_prov  text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_dias  int;
  v_desde date;
  v_data  jsonb;
begin
  -- Gate de app (service_role/GAS o claim app='MOS'); cualquier otro → rechazo.
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- Paridad GAS: idProveedor requerido.
  if v_prov is null then
    return jsonb_build_object('ok', false, 'error', 'idProveedor requerido');
  end if;

  -- rangoDias: parseInt || 30 (paridad). Clamp defensivo (1..3650) para no romper divisiones/intervalos.
  v_dias := coalesce(nullif(btrim(coalesce(p->>'rangoDias','')), '')::int, 30);
  if v_dias is null or v_dias <= 0 then v_dias := 30; end if;
  if v_dias > 3650 then v_dias := 3650; end if;

  -- Ventana de ventas: hoy(Lima) - rangoDias. GAS usa milisegundos exactos; aquí usamos límite por DÍA Lima,
  -- equivalente operativo (la sombra ME guarda fecha como timestamptz). Ver NOTA "ventana de ventas".
  v_desde := (now() at time zone 'America/Lima')::date - v_dias;

  with
  -- ── 1) Productos del proveedor (activos). Paridad: activa truthy. ──────────────────────────────────────
  pp as (
    select t.id_pp, t.id_proveedor, t.sku_base, t.codigo_barra, t.descripcion,
           coalesce(t.precio_referencia, 0) as precio_referencia,
           coalesce(t.minimo_compra, 0)     as minimo_compra,
           coalesce(t.dias_entrega, 0)      as dias_entrega,
           t.notas,
           greatest(coalesce(t.unidades_por_bulto, 1), 1)::int as unidades_por_bulto
    from mos.proveedores_productos t
    where t.id_proveedor = v_prov
      and coalesce(t.activa, false) = true
  ),

  -- ── 2) Master por sku_base: base (factor=1 o id=sku), conteo de presentaciones, todos los ids/barras. ──
  --    base = primer producto cuyo id_producto = sku_base, si no el de factor_conversion=1, si no el 1ro.
  prod_grp as (
    select
      coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku,
      count(*) as count_presentaciones,
      -- base elegido con prioridad determinista (igual criterio que GAS, orden estable por id_producto)
      (array_agg(pr.id_producto order by
          (pr.id_producto = coalesce(nullif(pr.sku_base,''), pr.id_producto)) desc,
          (coalesce(pr.factor_conversion,1) = 1) desc,
          pr.id_producto))[1] as base_id
    from mos.productos pr
    group by coalesce(nullif(pr.sku_base,''), pr.id_producto)
  ),
  base_prod as (
    select g.sku, g.count_presentaciones, b.id_producto, b.descripcion, b.codigo_barra,
           coalesce(b.stock_minimo, 0) as stock_minimo,
           coalesce(b.stock_maximo, 0) as stock_maximo
    from prod_grp g
    join mos.productos b on b.id_producto = g.base_id
  ),
  -- mapa codigo_barra → sku (incluye barras del master + equivalencias activas). Para resolver ventas/zonas.
  cb_to_sku as (
    select distinct coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku,
           nullif(btrim(pr.codigo_barra),'') as cb
    from mos.productos pr
    where nullif(btrim(pr.codigo_barra),'') is not null
    union
    select distinct e.sku_base as sku, nullif(btrim(e.codigo_barra),'') as cb
    from mos.equivalencias e
    where coalesce(e.activo, true) = true
      and nullif(btrim(e.sku_base),'') is not null
      and nullif(btrim(e.codigo_barra),'') is not null
  ),
  -- mapa id_producto → sku (para resolver ventas por SKU directo) y codigo_barra → sku via master/prodById.
  id_to_sku as (
    select pr.id_producto as id, coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku
    from mos.productos pr
  ),
  -- conteo de equivalencias por sku (countEquivalencias = equiv.porSku[sku].length)
  equiv_cnt as (
    select e.sku_base as sku, count(*) as n
    from mos.equivalencias e
    where coalesce(e.activo, true) = true
      and nullif(btrim(e.sku_base),'') is not null
    group by e.sku_base
  ),

  -- ── 3) Zonas registradas (tabla ZONAS activa): id_zona UPPER → nombre. ────────────────────────────────
  zonas_reg as (
    select upper(btrim(z.id_zona)) as zid, coalesce(z.nombre, z.id_zona) as nombre
    from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null
      and coalesce(z.estado, true) = true
  ),

  -- ── 3b) Zona resolver: mapea cualquier identificador (id_zona / estacion / id_estacion) → zona canónica. ─
  --    Canon id = UPPER(trim(idZona)). Para estaciones, el padre es su id_zona. Lookup por variantes
  --    (raw upper trim). GAS además normaliza espacios/guiones; aquí cubrimos el caso real (IDs sin espacios)
  --    con UPPER(TRIM(.)). Ver NOTA "resolver de zonas".
  zona_resolver as (
    -- desde ZONAS: el propio id_zona y el nombre apuntan a sí mismo
    select upper(btrim(z.id_zona)) as raw, upper(btrim(z.id_zona)) as canon_id,
           coalesce(z.nombre, z.id_zona) as canon_nombre
    from mos.zonas z where nullif(btrim(z.id_zona),'') is not null
    union
    select upper(btrim(z.nombre)) as raw, upper(btrim(z.id_zona)) as canon_id,
           coalesce(z.nombre, z.id_zona) as canon_nombre
    from mos.zonas z where nullif(btrim(z.nombre),'') is not null
    union
    -- desde ESTACIONES: id_estacion/nombre → id_zona padre (nombre de la zona si existe, si no el id_zona crudo)
    select upper(btrim(es.id_estacion)) as raw, upper(btrim(es.id_zona)) as canon_id,
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) as canon_nombre
    from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.id_estacion),'') is not null
    union
    select upper(btrim(es.nombre)) as raw, upper(btrim(es.id_zona)) as canon_id,
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) as canon_nombre
    from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.nombre),'') is not null
    union
    select upper(btrim(es.id_zona)) as raw, upper(btrim(es.id_zona)) as canon_id,
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) as canon_nombre
    from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null
  ),
  -- de-dup del resolver: una fila por raw (preferir entrada de ZONAS sobre ESTACIONES no es crítico — el
  -- canon_id es igual; el nombre de ZONAS ya gana en la subquery de estaciones). distinct on raw.
  zona_resolver_u as (
    select distinct on (raw) raw, canon_id, canon_nombre
    from zona_resolver
    order by raw, canon_nombre nulls last
  ),

  -- ── 5) Stock WH agregado por sku (resolver cod_producto via id o codigo_barra → sku). ─────────────────
  wh_by_sku as (
    select coalesce(i.sku, c.sku) as sku, sum(coalesce(s.cantidad_disponible, 0)) as q
    from wh.stock s
    left join id_to_sku i on i.id = s.cod_producto
    left join cb_to_sku c on c.cb = s.cod_producto
    where coalesce(i.sku, c.sku) is not null
    group by coalesce(i.sku, c.sku)
  ),

  -- ── 6) Stock por zona (canon-resolved) por sku. Resolver cb → sku, zona → canónica. ───────────────────
  stock_zonas_raw as (
    select c.sku as sku,
           r.canon_id     as zid,
           r.canon_nombre as znombre,
           sum(coalesce(z.cantidad, 0)) as cantidad
    from me.stock_zonas z
    join cb_to_sku c on c.cb = nullif(btrim(z.cod_barras),'')
    cross join lateral (
      select coalesce(zr.canon_id, upper(btrim(z.zona_id)))        as canon_id,
             coalesce(zr.canon_nombre, btrim(z.zona_id))           as canon_nombre
      from (select 1) _ left join zona_resolver_u zr on zr.raw = upper(btrim(z.zona_id))
    ) r
    where nullif(btrim(z.zona_id),'') is not null
    group by c.sku, r.canon_id, r.canon_nombre
  ),

  -- ── 7) Ventas en rango: cabeceras válidas (no anuladas, fecha >= desde Lima) → detalle por sku/zona. ──
  ventas_validas as (
    select v.id_venta, nullif(btrim(v.estacion),'') as estacion
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  ),
  ventas_lineas as (
    select coalesce(i.sku, c.sku) as sku,
           vv.estacion,
           coalesce(d.cantidad, 0) as cant
    from me.ventas_detalle d
    join ventas_validas vv on vv.id_venta = d.id_venta
    left join id_to_sku i on i.id = nullif(btrim(d.sku),'')
    left join cb_to_sku c on c.cb = nullif(btrim(d.cod_barras),'')
    where coalesce(i.sku, c.sku) is not null
  ),
  -- ventas totales por sku
  ventas_by_sku as (
    select sku, sum(cant) as ventas
    from ventas_lineas
    group by sku
  ),
  -- ventas por sku + zona canónica (solo líneas con estacion → resoluble)
  ventas_by_sku_zona as (
    select vl.sku,
           r.canon_id     as zid,
           r.canon_nombre as znombre,
           sum(vl.cant)   as ventas
    from ventas_lineas vl
    cross join lateral (
      select coalesce(zr.canon_id, upper(btrim(vl.estacion)))  as canon_id,
             coalesce(zr.canon_nombre, btrim(vl.estacion))     as canon_nombre
      from (select 1) _ left join zona_resolver_u zr on zr.raw = upper(btrim(vl.estacion))
    ) r
    where vl.estacion is not null
    group by vl.sku, r.canon_id, r.canon_nombre
  ),

  -- ── 8) Por cada (sku, zid) unir stock + ventas; clasificar registrada vs huérfana. ───────────────────
  zona_keys as (
    select sku, zid, znombre from stock_zonas_raw
    union all
    select sku, zid, znombre from ventas_by_sku_zona
  ),
  -- nombre legible por (sku,zid): el más frecuente/cualquiera no nulo (las fuentes coinciden en la práctica)
  zona_nombre as (
    select sku, zid, max(znombre) as znombre
    from zona_keys
    group by sku, zid
  ),
  zona_merged as (
    select
      k.sku,
      k.zid,
      -- nombre: si registrada usa nombre de tabla ZONAS; si no, el que vino de stock/ventas
      coalesce(zr.nombre, zn.znombre, k.zid) as nombre,
      (zr.zid is not null) as registrada,
      coalesce(sz.cantidad, 0)  as cantidad,
      coalesce(vz.ventas, 0)    as ventas_rango
    from (select distinct sku, zid from zona_keys) k
    left join stock_zonas_raw    sz on sz.sku = k.sku and sz.zid = k.zid
    left join ventas_by_sku_zona vz on vz.sku = k.sku and vz.zid = k.zid
    left join zona_nombre        zn on zn.sku = k.sku and zn.zid = k.zid
    left join zonas_reg          zr on zr.zid = k.zid
  ),
  -- chips de zona REGISTRADA por sku (array)
  zonas_chips as (
    select sku,
           jsonb_agg(
             jsonb_build_object(
               'idZona',      zid,
               'nombre',      nombre,
               'cantidad',    cantidad,
               'ventasRango', ventas_rango,
               'rotacionDia', round((ventas_rango / v_dias)::numeric, 1)
             )
             order by cantidad desc
           ) as zonas,
           sum(cantidad)     as zonas_reg_stock,
           sum(ventas_rango) as zonas_reg_ventas
    from zona_merged
    where registrada
    group by sku
  ),
  -- agregados HUÉRFANOS por sku (zonas no registradas)
  huerfanas_agg as (
    select sku,
           sum(cantidad)     as h_cantidad,
           sum(ventas_rango) as h_ventas
    from zona_merged
    where not registrada
    group by sku
  ),

  -- ── 9) Enriquecer cada pp ────────────────────────────────────────────────────────────────────────────
  enriquecido as (
    select
      pp.id_pp, pp.id_proveedor, pp.sku_base as sku,
      bp.id_producto, bp.descripcion as base_desc, bp.codigo_barra as base_cb,
      bp.stock_minimo, bp.stock_maximo, coalesce(bp.count_presentaciones, 1) as count_pres,
      coalesce(ec.n, 0) as count_equiv,
      pp.codigo_barra as pp_cb, pp.descripcion as pp_desc, pp.precio_referencia, pp.minimo_compra,
      pp.dias_entrega, pp.notas, pp.unidades_por_bulto,
      coalesce(wb.q, 0)                            as wh_q,
      coalesce(zc.zonas, '[]'::jsonb)              as zonas,
      coalesce(zc.zonas_reg_stock, 0)              as zonas_reg_stock,
      coalesce(ha.h_cantidad, 0)                   as huer_cant,
      coalesce(ha.h_ventas, 0)                     as huer_ventas,
      coalesce(vbs.ventas, 0)                      as ventas
    from pp
    left join base_prod bp on bp.sku = pp.sku_base
    left join equiv_cnt ec on ec.sku = pp.sku_base
    left join wh_by_sku wb on wb.sku = pp.sku_base
    left join zonas_chips zc on zc.sku = pp.sku_base
    left join huerfanas_agg ha on ha.sku = pp.sku_base
    left join ventas_by_sku vbs on vbs.sku = pp.sku_base
  ),
  calculado as (
    select
      e.*,
      (e.zonas_reg_stock + e.huer_cant)            as zonas_total,
      (e.wh_q + e.zonas_reg_stock + e.huer_cant)   as total,
      case when v_dias > 0 then e.ventas::numeric / v_dias else 0 end as rot_dia
    from enriquecido e
  ),
  final_rows as (
    select
      c.*,
      -- minimo/maximo del MASTER base (paridad: p.stockMinimo / p.stockMaximo)
      c.stock_minimo as minimo,
      c.stock_maximo as maximo,
      -- sugerencia + razón (replica exacta del árbol if/else del GAS)
      sug.sugerencia, sug.razon, sug.sug_bultos,
      -- alerta (refs a stock_minimo/stock_maximo de `calculado`; los alias minimo/maximo de este SELECT no son
      --         visibles en su propia lista — usar las columnas base)
      case
        when c.total < 0 then 'NEGATIVO'
        when c.stock_minimo > 0 and c.total < c.stock_minimo then 'BAJO_MINIMO'
        when c.rot_dia > 0 and c.total > 0 and (c.total / c.rot_dia) < 7 then 'AGOTAR_PRONTO'
        when c.stock_minimo > 0 and c.total < c.stock_minimo * 1.2 then 'CERCA_MINIMO'
        when c.total > 0 and c.ventas = 0 then 'SIN_ROTACION'
        else 'OK'
      end as alerta
    from calculado c
    cross join lateral (
      -- Paso A: sugerencia base + razón (sin bultos). objetivo = max>min ? max : min*2.
      with base as (
        select
          (case when c.stock_maximo > c.stock_minimo then c.stock_maximo else c.stock_minimo * 2 end) as objetivo
      ),
      sug_base as (
        select
          base.objetivo,
          case
            when c.stock_minimo > 0 and c.total < c.stock_minimo
              then greatest(0, ceil(base.objetivo - c.total))
            when c.rot_dia > 0
              then greatest(0, ceil(c.rot_dia * 14) - floor(c.total))
            else 0
          end as sug0,
          case
            when c.stock_minimo > 0 and c.total < c.stock_minimo
              then 'Reponer hasta ' || (case when c.stock_maximo > c.stock_minimo
                     then 'máx (' || trim(to_char(base.objetivo, 'FM999999990.######')) || ')'
                     else '2× mín (' || trim(to_char(base.objetivo, 'FM999999990.######')) || ')' end)
            when c.rot_dia > 0
              then (case when greatest(0, ceil(c.rot_dia * 14) - floor(c.total)) > 0
                     then 'Cobertura 14d (rot ' || to_char(c.rot_dia, 'FM990.0') || '/d)'
                     else 'Stock cubre 14d' end)
            when c.total <= 0 and c.stock_minimo = 0
              then 'Sin rotación · sin mín — define mínimo'
            else ''
          end as razon0
        from base
      ),
      -- Paso B: redondeo a múltiplo de bulto + sufijo de razón
      bultos as (
        select
          case
            when sug_base.sug0 > 0 and c.unidades_por_bulto > 1
              then ceil(sug_base.sug0 / c.unidades_por_bulto) * c.unidades_por_bulto
            else sug_base.sug0
          end as sugerencia,
          case
            when sug_base.sug0 > 0 and c.unidades_por_bulto > 1
              then ceil(sug_base.sug0 / c.unidades_por_bulto)
            when sug_base.sug0 > 0 and c.unidades_por_bulto = 1
              then sug_base.sug0
            else 0
          end as sug_bultos,
          case
            when sug_base.sug0 > 0 and c.unidades_por_bulto > 1
              then sug_base.razon0 || ' · ' || ceil(sug_base.sug0 / c.unidades_por_bulto)
                   || ' bulto' || (case when ceil(sug_base.sug0 / c.unidades_por_bulto) = 1 then '' else 's' end)
            else sug_base.razon0
          end as razon
        from sug_base
      )
      select bultos.sugerencia, bultos.razon, bultos.sug_bultos from bultos
    ) sug
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'idPP',             fr.id_pp,
             'idProveedor',      fr.id_proveedor,
             'skuBase',          fr.sku,
             'idProducto',       coalesce(fr.id_producto, fr.sku),
             'descripcion',      coalesce(nullif(fr.pp_desc,''), fr.base_desc, fr.sku),
             'codigoBarra',      coalesce(nullif(fr.pp_cb,''), fr.base_cb, ''),
             'precioReferencia', fr.precio_referencia,
             'minimoCompra',     fr.minimo_compra,
             'diasEntrega',      fr.dias_entrega,
             'notas',            coalesce(fr.notas, ''),
             'unidadesPorBulto', fr.unidades_por_bulto,
             'stockWh',          fr.wh_q,
             'stockTienda',      fr.zonas_total,
             'stockTotal',       fr.total,
             'zonas',            fr.zonas,
             'zonasHuerfanas',   case when (fr.huer_cant > 0 or fr.huer_ventas > 0)
                                   then jsonb_build_object(
                                          'cantidad',    fr.huer_cant,
                                          'ventasRango', fr.huer_ventas,
                                          'rotacionDia', round((fr.huer_ventas / v_dias)::numeric, 1))
                                   else null end,
             'stockMinimo',      fr.minimo,
             'stockMaximo',      fr.maximo,
             'ventasRango',      fr.ventas,
             'rotacionDia',      round(fr.rot_dia::numeric, 1),
             'rangoDias',        v_dias,
             'sugerencia',       fr.sugerencia,
             'sugerenciaBultos', fr.sug_bultos,
             'razonSugerencia',  fr.razon,
             'alerta',           fr.alerta,
             'countPresentaciones', fr.count_pres,
             'countEquivalencias',  fr.count_equiv
           )
           order by
             case fr.alerta
               when 'NEGATIVO'      then 0
               when 'BAJO_MINIMO'   then 1
               when 'AGOTAR_PRONTO' then 2
               when 'CERCA_MINIMO'  then 3
               when 'SIN_ROTACION'  then 4
               when 'OK'            then 5
               else 9
             end,
             lower(coalesce(nullif(fr.pp_desc,''), fr.base_desc, fr.sku))
         ), '[]'::jsonb)
    into v_data
  from final_rows fr;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.productos_proveedor_stock(jsonb) from public;
grant execute on function mos.productos_proveedor_stock(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTAS DE PARIDAD / DIVERGENCIAS / GAPS (honestidad 40x)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) FUENTES — TODAS migradas. No hay GAP de ausencia de tabla:
--      · wh.stock                 ✅  (cod_producto / cantidad_disponible)
--      · me.stock_zonas           ✅  (cod_barras / zona_id / cantidad)  ← clave: SÍ existe en 02_schema_me.sql
--      · me.ventas / ventas_detalle ✅ (estado_envio / estacion / fecha ; sku / cod_barras / cantidad)
--      · mos.productos / equivalencias / zonas / estaciones / proveedores_productos ✅
--
-- 2) FRESCURA DE SOMBRA (no es GAP de datos, es GAP de actualidad). wh.stock, me.stock_zonas y me.ventas son
--    SOMBRAS alimentadas por el sync GAS→Supabase. Si ese sync se atrasa, los números (stock/ventas/rotación)
--    quedan stale respecto a las hojas que el GAS lee en vivo. _frescura_sombra() expone _fresh para que el
--    front decida caer a GAS si la sombra está congelada. El GAS lee la HOJA en vivo → siempre "fresco".
--    ⇒ Antes del cutover de ESTE getter, el sync de wh.stock + me.stock_zonas + me.ventas DEBE estar vivo.
--
-- 3) ANULACIÓN DE VENTA — el GAS detecta 'ANULADO' por la columna índice 8 de VENTAS_CABECERA, que es
--    Estado_Envio (memoria del proyecto: "FormaPago es la fuente de verdad para anulación"). Aquí usamos
--    me.ventas.estado_envio = 'ANULADO' (= col 8). ⚠️ DIVERGENCIA POTENCIAL DE PARIDAD: hay otra regla del
--    ecosistema que dice que la anulación REAL se decide por forma_pago, no por estado_envio. Replicamos
--    EXACTAMENTE lo que hace getProductosProveedorConStock (que mira col 8 = estado_envio), NO la regla
--    forma_pago. Si en el flip se quisiera endurecer, agregar OR sobre forma_pago — pero eso sería MÁS estricto
--    que el GAS y rompería paridad bit-a-bit. Decisión: paridad fiel con el getter.
--
-- 4) RESOLVER DE ZONAS — el GAS normaliza variantes (mayúsc/minúsc, espacios, guiones) de id_zona/estacion/
--    nombre/id_estacion contra ZONAS+ESTACIONES; sin match devuelve { id: UPPER(raw), nombre: raw }. Aquí se
--    construye zona_resolver_u con las mismas tres fuentes y canon_id=UPPER(TRIM(id_zona)); el fallback sin
--    match = UPPER(TRIM(raw)) / TRIM(raw). ⚠️ DIFERENCIA MENOR: el GAS también prueba variantes SIN espacios/
--    guiones (k.replace(/[\s_-]+/g,'')). Esta RPC solo prueba UPPER+TRIM. En datos reales los IDs de zona/
--    estación no llevan espacios internos (son códigos), así que el impacto es nulo; si apareciera un id con
--    espacios internos que el GAS sí resolvía, aquí caería al fallback (zona "huérfana"). RIESGO BAJO,
--    documentado. Si se detecta, ampliar el resolver con regexp_replace(.,'[\s_-]+','','g').
--
-- 5) VENTANA DE VENTAS — el GAS usa `desde = new Date(hoy - rangoDias*86400000)` (corte por milisegundo
--    exacto, TZ Lima del proyecto Apps Script). Aquí el corte es por DÍA Lima: fecha::date(Lima) >= hoy(Lima)
--    - rangoDias. ⚠️ DIVERGENCIA: en el límite inferior, la RPC incluye TODO el día (rangoDias)-ésimo hacia
--    atrás, mientras el GAS corta a la hora exacta de "ahora" ese día. Diferencia ≤ 1 día parcial de ventas en
--    el borde. Para rotación (promedio sobre rangoDias) el efecto es marginal. Aceptable; si se exige paridad
--    al ms, cambiar a: v.fecha >= (now() - make_interval(days => v_dias)).
--
-- 6) BASE DEL SKU — el GAS elige base = (id == sku) OR (primer factor=1) OR (primera presentación). La RPC usa
--    array_agg con orden (id=sku) desc, (factor=1) desc, id_producto, y toma [1]. Mismo criterio, orden
--    determinista por id_producto como desempate (el GAS depende del orden de las filas de la hoja; aquí es
--    estable por id). Para min/max/descripcion del producto base puede haber diferencia SOLO si hay empate de
--    prioridad y las presentaciones difieren en min/max — caso raro. RIESGO BAJO.
--
-- 7) prodByCB de equivalencias — el GAS, para una equivalencia, mapea cb→base del sku (prodByCB[cb] = base).
--    Aquí cb_to_sku mapea cb→sku y luego se une al base por sku. Equivalente. Si un mismo cb perteneciera a
--    dos skus (no debería: regla del ecosistema = 1 cb → 1 canónico), el DISTINCT/UNION podría duplicar; el
--    sum() por sku lo absorbe sin doble conteo dentro de un sku, pero el cb se contaría en ambos skus. Mismo
--    comportamiento ambiguo que el GAS (que usa el último prodByCB asignado). RIESGO BAJO (dato inválido).
--
-- 8) TIPOS NUMÉRICOS — stock/ventas/cantidades se emiten como número JSON (paridad con _sheetToObjects, que
--    devuelve Number). rotacionDia/rotación huérfana redondeadas a 1 decimal (Math.round(x*10)/10 ≡
--    round(x,1)). sugerencia/sugerenciaBultos son enteros (ceil/floor). El front hace parseFloat() defensivo.
--
-- 9) GATE + ENVOLTORIO — mos._claim_ok() (74) y mos._frescura_sombra() (94) ya existen; este archivo NO los
--    redefine, los consume. Resultado: { ok, data, _heartbeat, _now, _ttl_min, _fresh }.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
