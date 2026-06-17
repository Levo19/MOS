-- 133_fix_factor_ventas.sql — [MIGRACIÓN MOS · FASE 2 · FIX FACTOR EN VENTAS DE ANALÍTICA]
-- Corrige el GAP CRÍTICO #1 (documentado en 126_riz_fundacion_ventas_base.sql, §"REEMPLAZA el conteo crudo"):
-- las RPCs de analítica de almacén que están en PROD SUMAN me.ventas_detalle.cantidad SIN multiplicar por
-- mos.productos.factor_conversion. ME registra el CONTEO DE LA PRESENTACIÓN (ej. 4 tripacks → cantidad=4),
-- de modo que las "unidades vendidas" reales = cantidad × factor (4 tripacks × factor 3 = 12 unidades base).
--
-- ── REGLA DEL DUEÑO (en piedra) ────────────────────────────────────────────────────────────────────────────
--   "En almacén NO se mueven por presentación; las presentaciones SOLO aplican a las VENTAS, no al despacho de
--    almacén a zona." ⇒ Este fix toca SOLO la agregación de VENTAS (vendidasMes / ventasRango / ventas N días).
--    El STOCK (wh.stock, me.stock_zonas) NO se toca: se sigue sumando la cantidad tal cual (es física, ya en
--    unidades de almacén). Tampoco se toca el dinero (mos.ranking_zonas suma `total` S/, no conteo de unidades).
--
-- ── QUÉ SE CORRIGE (4 RPCs · solo el subtotal de ventas) ─────────────────────────────────────────────────────
--   · mos.rotacion_productos       (113) — CTE ventas_mes  → vendidasMes (afecta diasCobertura).
--   · mos.catalogo_stock_resumen   (113) — CTE ventas_by_sku → ventasRango (afecta rotacionDia / diasParaAcabar /
--                                          alerta SIN_ROTACION|AGOTAR_PRONTO).
--   · mos.stock_unificado          (117) — CTE ventas_zona  → ventasRango por zona (afecta rotacionDia /
--                                          diasParaAcabar / insights REPONER_ZONA · SIN_ROTACION).
--   · mos.insights_stock           (117) — CTE ventas_canon_zona → rot_dia (afecta DESPACHAR_DESDE_WH ·
--                                          TRASLADAR · SIN_ROTACION; las cantidadSugerida = rot×14/×factor reales).
--
-- ── QUÉ NO SE TOCA (con razón) ───────────────────────────────────────────────────────────────────────────────
--   · mos.productos_sin_venta (117): solo evalúa EXISTENCIA de venta (canon_vendidos = distinct canónico con
--     ≥1 línea). El factor no cambia "¿hubo venta sí/no?" → multiplicar no altera el resultado. NO se toca.
--   · mos.ranking_zonas (117): agrega DINERO (me.ventas.total), no conteo de unidades. El factor no aplica a
--     un monto en soles. NO se toca.
--   · mos.dashboard_almacen (113): no agrega ventas (solo stock/mermas/envasados/preingresos). NO se toca.
--   · TODOS los agregados de STOCK (wh.stock / me.stock_zonas) en CUALQUIER RPC: regla del dueño. NO se tocan.
--
-- ── BACKWARD-COMPATIBLE ──────────────────────────────────────────────────────────────────────────────────────
--   Mismo NOMBRE de función, misma FIRMA (jsonb), mismo SHAPE de salida (mismas claves, mismos tipos JSON),
--   mismo gate mos._claim_ok(), mismo search_path='', mismos grants, mismo _frescura_sombra(). SOLO cambian los
--   NÚMEROS de ventas (suben al multiplicar por factor). Idempotente (create or replace). NO toca flags / sync /
--   api.js / GAS / version / sw. Las 4 RPCs ya están cableadas como LECTURA en prod; este replace es seguro
--   porque no cambia contrato, solo corrige el valor.
--
-- ── MECÁNICA DEL FACTOR (idéntica a la fundación 126) ───────────────────────────────────────────────────────
--   El detalle de venta se empareja al producto por cod_barras (idx6) o por sku (idx1 = id_producto/sku).
--   Para CADA línea se busca el factor del producto que matchea ese código y se multiplica cantidad × factor.
--   factor null/0 → 1 (paridad con 126: una unidad suelta o equivalente). Los equivalentes (mos.equivalencias)
--   son factor 1 por definición. Se conserva EXACTAMENTE el mismo criterio de match que ya usaba cada RPC para
--   no cambiar QUÉ líneas entran (anulación por estado_envio, ventana de fecha, resolución de sku/cb/canónico);
--   lo único nuevo es el ×factor sobre la cantidad de cada línea ya seleccionada.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) mos.rotacion_productos — FIX en ventas_mes (× factor). Resto IDÉNTICO a 113.
--    El GAS/RPC actual indexa ventas por la clave SKU cruda del detalle. Aquí seguimos indexando por esa misma
--    clave (sku_base resuelto, fallback codigoProducto), pero la cantidad se normaliza a unidades base ANTES de
--    agregar: cada línea × factor del producto que matchea (por cod_barras, si no por sku/id, si no 1).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.rotacion_productos(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_mes        text := nullif(btrim(coalesce(p->>'mes','')), '');
  v_solo_aler  boolean := (coalesce(p->>'soloAlertas','') = 'true');
  v_mes_pref   text;
  v_data       jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  v_mes_pref := coalesce(v_mes, to_char((now() at time zone 'America/Lima'), 'YYYY-MM'));

  with
  prod_by_id as (
    select pr.id_producto as k, pr.id_producto, pr.sku_base, pr.codigo_barra, pr.descripcion, pr.stock_minimo
    from mos.productos pr
  ),
  prod_by_sku as (
    select distinct on (pr.sku_base) pr.sku_base as k, pr.id_producto, pr.sku_base, pr.codigo_barra, pr.descripcion, pr.stock_minimo
    from mos.productos pr where nullif(btrim(pr.sku_base),'') is not null
    order by pr.sku_base, pr.id_producto
  ),
  prod_by_cb as (
    select distinct on (pr.codigo_barra) pr.codigo_barra as k, pr.id_producto, pr.sku_base, pr.codigo_barra, pr.descripcion, pr.stock_minimo
    from mos.productos pr where nullif(btrim(pr.codigo_barra),'') is not null
    order by pr.codigo_barra, pr.id_producto
  ),
  -- ⭐ FIX FACTOR: lookups de factor por código (cb) y por sku/id, para normalizar cada línea a unidades base.
  --    factor null/0 → 1. Equivalentes → factor 1 (no aumentan presentación).
  fac_by_cb as (
    select distinct on (cb) cb, factor from (
      select upper(btrim(pr.codigo_barra)) as cb,
             case when coalesce(pr.factor_conversion,0)=0 then 1 else pr.factor_conversion end as factor, 0 as ord
      from mos.productos pr where nullif(btrim(pr.codigo_barra),'') is not null
      union all
      select upper(btrim(e.codigo_barra)) as cb, 1::numeric as factor, 1 as ord
      from mos.equivalencias e
      where coalesce(e.activo,true)=true and nullif(btrim(e.codigo_barra),'') is not null
    ) t order by cb, ord
  ),
  fac_by_id as (
    select upper(btrim(pr.id_producto)) as idk,
           case when coalesce(pr.factor_conversion,0)=0 then 1 else pr.factor_conversion end as factor
    from mos.productos pr where nullif(btrim(pr.id_producto),'') is not null
  ),
  -- Ventas del MES por la clave SKU cruda del detalle (idéntico criterio de filtro que 113), pero la cantidad
  -- ya viene multiplicada por el factor del producto que matchea la línea (cb gana sobre id/sku).
  ventas_mes as (
    select nullif(btrim(d.sku),'') as sku,
           sum(coalesce(d.cantidad,0) * coalesce(fc.factor, fi.factor, 1)) as q
    from me.ventas_detalle d
    join me.ventas v on v.id_venta = d.id_venta
    left join fac_by_cb fc on fc.cb  = upper(btrim(nullif(btrim(d.cod_barras),'')))
    left join fac_by_id fi on fi.idk = upper(btrim(nullif(btrim(d.sku),'')))
    where v.fecha is not null
      and to_char((v.fecha at time zone 'America/Lima'), 'YYYY-MM') = v_mes_pref
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
      and nullif(btrim(d.sku),'') is not null
    group by nullif(btrim(d.sku),'')
  ),
  stock_rows as (
    select
      s.id_stock,
      s.cod_producto                                            as codigo_producto,
      coalesce(s.cantidad_disponible, 0)                        as cant,
      coalesce(pid.id_producto, psk.id_producto, pcb.id_producto) is not null as en_catalogo,
      coalesce(
        nullif(coalesce(pid.descripcion, psk.descripcion, pcb.descripcion), ''),
        case when coalesce(pid.id_producto, psk.id_producto, pcb.id_producto) is null
             then '⚠ Sin nombre · ' || s.cod_producto
             else s.cod_producto end
      )                                                         as descripcion,
      coalesce(nullif(coalesce(pid.sku_base, psk.sku_base, pcb.sku_base), ''), '') as sku_base,
      coalesce(pid.stock_minimo, psk.stock_minimo, pcb.stock_minimo, 0)            as stock_minimo
    from wh.stock s
    left join prod_by_id  pid on pid.k = s.cod_producto
    left join prod_by_sku psk on psk.k = s.cod_producto
    left join prod_by_cb  pcb on pcb.k = s.cod_producto
  ),
  con_ventas as (
    select
      sr.*,
      coalesce(
        (select vm.q from ventas_mes vm where vm.sku = sr.sku_base and nullif(sr.sku_base,'') is not null),
        (select vm.q from ventas_mes vm where vm.sku = sr.codigo_producto),
        0
      )                                                         as vendidas_mes,
      (sr.cant < sr.stock_minimo)                               as alerta_minimo
    from stock_rows sr
  ),
  calc as (
    select
      cv.*,
      case when cv.vendidas_mes > 0
           then round((cv.cant / cv.vendidas_mes) * 30)::int
           else null end                                        as dias_cobertura
    from con_ventas cv
    where (not v_solo_aler) or cv.alerta_minimo
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'codigoProducto', c.codigo_producto,
             'descripcion',    c.descripcion,
             'skuBase',        c.sku_base,
             'stockActual',    c.cant,
             'vendidasMes',    c.vendidas_mes,
             'diasCobertura',  c.dias_cobertura,
             'alertaMinimo',   c.alerta_minimo
           )
           order by coalesce(c.dias_cobertura, 9999), c.codigo_producto
         ), '[]'::jsonb)
    into v_data
  from calc c;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.rotacion_productos(jsonb) from public;
grant execute on function mos.rotacion_productos(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) mos.catalogo_stock_resumen — FIX en ventas_by_sku (× factor). Resto IDÉNTICO a 113.
--    El detalle se resuelve a sku por id_to_sku (idx1) o cb_to_sku (idx6). Aquí, además de resolver el sku,
--    se multiplica cantidad × factor del producto que matchea la línea (cb gana sobre id/sku; equiv → 1).
--    STOCK (wh_by_sku / zonas_by_sku) NO se toca.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.catalogo_stock_resumen(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_dias  int;
  v_desde date;
  v_prods jsonb;
  v_total int;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  v_dias := coalesce(nullif(btrim(coalesce(p->>'dias','')), '')::int, 7);
  if v_dias is null or v_dias <= 0 then v_dias := 7; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  v_desde := (now() at time zone 'America/Lima')::date - v_dias;

  with
  prods as (
    select pr.* from mos.productos pr
    where coalesce(pr.estado, true) = true
  ),
  grp as (
    select
      coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku,
      count(*) as count_pres,
      (array_agg(pr.id_producto order by
          (pr.id_producto = coalesce(nullif(pr.sku_base,''), pr.id_producto)) desc,
          (coalesce(pr.factor_conversion,1) = 1) desc,
          pr.id_producto))[1] as base_id
    from prods pr
    group by coalesce(nullif(pr.sku_base,''), pr.id_producto)
  ),
  base_prod as (
    select g.sku, g.count_pres,
           b.id_producto, b.descripcion, b.codigo_barra, b.marca, b.id_categoria,
           coalesce(b.precio_venta,0) as precio_venta, coalesce(b.precio_costo,0) as precio_costo,
           coalesce(b.stock_minimo,0) as minimo, coalesce(b.stock_maximo,0) as maximo
    from grp g
    join mos.productos b on b.id_producto = g.base_id
  ),
  id_to_sku as (
    select pr.id_producto as id, coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku
    from prods pr
  ),
  cb_to_sku as (
    select distinct nullif(btrim(pr.codigo_barra),'') as cb, coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku
    from prods pr where nullif(btrim(pr.codigo_barra),'') is not null
    union
    select distinct nullif(btrim(e.codigo_barra),'') as cb, e.sku_base as sku
    from mos.equivalencias e
    where coalesce(e.activo, true) = true
      and nullif(btrim(e.sku_base),'') is not null
      and nullif(btrim(e.codigo_barra),'') is not null
      and exists (select 1 from grp g where g.sku = e.sku_base)
  ),
  -- ⭐ FIX FACTOR: factor por código de barra (cb) y por id de producto (sku idx1). Equivalentes → 1.
  fac_by_cb as (
    select distinct on (cb) cb, factor from (
      select nullif(btrim(pr.codigo_barra),'') as cb,
             case when coalesce(pr.factor_conversion,0)=0 then 1 else pr.factor_conversion end as factor, 0 as ord
      from prods pr where nullif(btrim(pr.codigo_barra),'') is not null
      union all
      select nullif(btrim(e.codigo_barra),'') as cb, 1::numeric as factor, 1 as ord
      from mos.equivalencias e
      where coalesce(e.activo,true)=true and nullif(btrim(e.codigo_barra),'') is not null
    ) t order by cb, ord
  ),
  fac_by_id as (
    select pr.id_producto as idk,
           case when coalesce(pr.factor_conversion,0)=0 then 1 else pr.factor_conversion end as factor
    from prods pr
  ),
  equiv_cnt as (
    select e.sku_base as sku, count(*) as n
    from (
      select distinct e.sku_base, nullif(btrim(e.codigo_barra),'') as cb
      from mos.equivalencias e
      where coalesce(e.activo, true) = true
        and nullif(btrim(e.sku_base),'') is not null
        and nullif(btrim(e.codigo_barra),'') is not null
        and exists (select 1 from grp g where g.sku = e.sku_base)
        and not exists (
          select 1 from prods pr
          where coalesce(nullif(pr.sku_base,''), pr.id_producto) = e.sku_base
            and nullif(btrim(pr.codigo_barra),'') = nullif(btrim(e.codigo_barra),'')
        )
    ) e
    group by e.sku_base
  ),
  wh_by_sku as (
    select coalesce(i.sku, c.sku) as sku, sum(coalesce(s.cantidad_disponible,0)) as q
    from wh.stock s
    left join id_to_sku i on i.id = s.cod_producto
    left join cb_to_sku c on c.cb = s.cod_producto
    where coalesce(i.sku, c.sku) is not null
    group by coalesce(i.sku, c.sku)
  ),
  zonas_by_sku as (
    select c.sku, sum(coalesce(z.cantidad,0)) as q
    from me.stock_zonas z
    join cb_to_sku c on c.cb = nullif(btrim(z.cod_barras),'')
    group by c.sku
  ),
  ventas_validas as (
    select v.id_venta
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  ),
  -- ⭐ FIX FACTOR: ventasRango por sku con cantidad × factor (mismo match id/cb que 113).
  ventas_by_sku as (
    select coalesce(i.sku, c.sku) as sku,
           sum(coalesce(d.cantidad,0) * coalesce(fcb.factor, fid.factor, 1)) as q
    from me.ventas_detalle d
    join ventas_validas vv on vv.id_venta = d.id_venta
    left join id_to_sku i on i.id = nullif(btrim(d.sku),'')
    left join cb_to_sku c on c.cb = nullif(btrim(d.cod_barras),'')
    left join fac_by_cb fcb on fcb.cb  = nullif(btrim(d.cod_barras),'')
    left join fac_by_id fid on fid.idk = nullif(btrim(d.sku),'')
    where coalesce(i.sku, c.sku) is not null
    group by coalesce(i.sku, c.sku)
  ),
  filas as (
    select
      bp.sku, bp.id_producto, bp.descripcion, bp.codigo_barra, bp.marca, bp.id_categoria,
      bp.precio_venta, bp.precio_costo, bp.minimo, bp.maximo, bp.count_pres,
      coalesce(ec.n, 0)              as count_equiv,
      coalesce(wb.q, 0)              as wh_q,
      coalesce(zb.q, 0)              as zonas_q,
      coalesce(wb.q,0) + coalesce(zb.q,0) as total,
      coalesce(vb.q, 0)              as ventas
    from base_prod bp
    left join equiv_cnt    ec on ec.sku = bp.sku
    left join wh_by_sku    wb on wb.sku = bp.sku
    left join zonas_by_sku zb on zb.sku = bp.sku
    left join ventas_by_sku vb on vb.sku = bp.sku
  ),
  calc as (
    select
      r.*,
      case when v_dias > 0 then r.ventas::numeric / v_dias else 0 end as rot_dia,
      case when (case when v_dias>0 then r.ventas::numeric/v_dias else 0 end) > 0 and r.total > 0
           then floor(r.total / (r.ventas::numeric / v_dias))::int
           else null end as dias_acabar
    from filas r
  ),
  clasif as (
    select
      c.*,
      case
        when c.total < 0                                                      then 'NEGATIVO'
        when c.minimo > 0 and c.total < c.minimo                              then 'BAJO_MINIMO'
        when c.rot_dia > 0 and c.dias_acabar is not null and c.dias_acabar < 7 then 'AGOTAR_PRONTO'
        when c.total > 0 and c.ventas = 0                                     then 'SIN_ROTACION'
        when c.minimo > 0 and c.total < c.minimo * 1.2                        then 'CERCA_MINIMO'
        else 'OK'
      end as alerta
    from calc c
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'skuBase',             cl.sku,
        'idProducto',          cl.id_producto,
        'descripcion',         coalesce(nullif(cl.descripcion,''), cl.sku),
        'codigoBarra',         coalesce(cl.codigo_barra, ''),
        'marca',               coalesce(cl.marca, ''),
        'idCategoria',         coalesce(cl.id_categoria, ''),
        'precioVenta',         cl.precio_venta,
        'precioCosto',         cl.precio_costo,
        'stockMinimo',         cl.minimo,
        'stockMaximo',         cl.maximo,
        'whCantidad',          cl.wh_q,
        'zonasCantidad',       cl.zonas_q,
        'totalCantidad',       cl.total,
        'ventasRango',         cl.ventas,
        'rotacionDia',         round(cl.rot_dia, 1),
        'diasParaAcabar',      cl.dias_acabar,
        'countPresentaciones', cl.count_pres,
        'countEquivalencias',  cl.count_equiv,
        'alerta',              cl.alerta
      )
      order by
        case cl.alerta
          when 'NEGATIVO'      then 0
          when 'BAJO_MINIMO'   then 1
          when 'AGOTAR_PRONTO' then 2
          when 'SIN_ROTACION'  then 3
          when 'CERCA_MINIMO'  then 4
          when 'OK'            then 5
          else 9
        end,
        lower(coalesce(nullif(cl.descripcion,''), cl.sku))
    ), '[]'::jsonb),
    count(*)::int
  into v_prods, v_total
  from clasif cl;

  return jsonb_build_object('ok', true,
    'data', jsonb_build_object('_almV', 2, 'productos', v_prods, 'total', coalesce(v_total,0), 'rangoDias', v_dias)
  ) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.catalogo_stock_resumen(jsonb) from public;
grant execute on function mos.catalogo_stock_resumen(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) mos.stock_unificado — FIX en ventas_zona (× factor). Resto IDÉNTICO a 117.
--    Es el detalle de UN producto (skuBase): las ventas por zona se contaban crudas; ahora cada línea
--    (matcheada por sku∈ids_pres o cb∈barras_pres) se multiplica por su factor (cb gana sobre id/sku; equiv→1).
--    STOCK WH/zonas NO se toca.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.stock_unificado(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_key   text := coalesce(nullif(btrim(coalesce(p->>'skuBase','')), ''), nullif(btrim(coalesce(p->>'idProducto','')), ''));
  v_dias  int;
  v_desde date;
  v_sku   text;
  v_prod  record;
  v_data  jsonb;
  v_wh_cant numeric;
  v_wh_det  jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_key is null then
    return jsonb_build_object('ok', false, 'error', 'Requiere skuBase o idProducto');
  end if;

  v_dias := coalesce(nullif(btrim(coalesce(p->>'rangoDias','')), '')::int, 7);
  if v_dias is null or v_dias <= 0 then v_dias := 7; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  v_desde := (now() at time zone 'America/Lima')::date - v_dias;

  select pr.id_producto, pr.sku_base, pr.descripcion, pr.codigo_barra,
         coalesce(pr.stock_minimo,0) as stock_minimo, coalesce(pr.stock_maximo,0) as stock_maximo,
         coalesce(pr.precio_costo,0) as precio_costo, coalesce(pr.precio_venta,0) as precio_venta
    into v_prod
    from mos.productos pr
   where pr.id_producto = v_key or pr.sku_base = v_key or pr.codigo_barra = v_key
   order by (pr.id_producto = v_key) desc, pr.id_producto
   limit 1;

  if not found then
    select coalesce(sum(coalesce(s.cantidad_disponible,0)),0),
           coalesce(jsonb_agg(jsonb_build_object(
             'codigoProducto', s.cod_producto, 'cantidad', coalesce(s.cantidad_disponible,0),
             'ultimaActualizacion', s.ultima_actualizacion)) filter (where s.cod_producto is not null), '[]'::jsonb)
      into v_wh_cant, v_wh_det
      from wh.stock s where s.cod_producto = v_key;
    return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'producto', jsonb_build_object(
        'idProducto', v_key, 'skuBase', '',
        'descripcion', '⚠ ' || v_key || ' (no existe en catálogo MOS)',
        'codigoBarra', '', 'stockMinimo', 0, 'stockMaximo', 0, 'precioCosto', 0, 'precioVenta', 0),
      'wh', jsonb_build_object('cantidad', coalesce(v_wh_cant,0), 'detalle', coalesce(v_wh_det,'[]'::jsonb)),
      'zonas', '[]'::jsonb,
      'total', jsonb_build_object('cantidad', coalesce(v_wh_cant,0), 'rotacionDia', 0, 'ventasRango', 0,
                                  'diasParaAcabar', null, 'rangoDiasConsultado', v_dias),
      'insights', jsonb_build_array(jsonb_build_object(
        'tipo','NO_EN_CATALOGO','severidad','ALTA',
        'mensaje','Este producto está en WH pero no en PRODUCTOS_MASTER de MOS',
        'accion','Crearlo en Catálogo MOS para activar tracking de zonas y rotación')),
      'sinCatalogo', true
    )) || mos._frescura_sombra();
  end if;

  v_sku := coalesce(nullif(v_prod.sku_base,''), v_prod.id_producto);

  with
  zonas_reg as (
    select upper(btrim(z.id_zona)) as zid, coalesce(z.nombre, z.id_zona) as nombre
    from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado, true) = true
  ),
  zona_resolver as (
    select upper(btrim(z.id_zona)) as raw, upper(btrim(z.id_zona)) as canon_id, coalesce(z.nombre, z.id_zona) as canon_nombre
    from mos.zonas z where nullif(btrim(z.id_zona),'') is not null
    union
    select upper(btrim(z.nombre)) as raw, upper(btrim(z.id_zona)) as canon_id, coalesce(z.nombre, z.id_zona) as canon_nombre
    from mos.zonas z where nullif(btrim(z.nombre),'') is not null
    union
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
  zona_resolver_u as (
    select distinct on (raw) raw, canon_id, canon_nombre from zona_resolver order by raw, canon_nombre nulls last
  ),
  presentaciones as (
    select pr.id_producto, pr.codigo_barra, pr.descripcion,
           case when coalesce(pr.factor_conversion,0)=0 then 1 else pr.factor_conversion end as factor
    from mos.productos pr
    where coalesce(nullif(pr.sku_base,''), pr.id_producto) = v_sku
  ),
  ids_pres as (select id_producto from presentaciones),
  barras_info as (
    select distinct on (cb) cb, tipo, descripcion from (
      select nullif(btrim(pr.codigo_barra),'') as cb, 'principal'::text as tipo, coalesce(pr.descripcion,'') as descripcion, 0 as ord
      from presentaciones pr where nullif(btrim(pr.codigo_barra),'') is not null
      union all
      select nullif(btrim(e.codigo_barra),'') as cb, 'equivalencia'::text as tipo, coalesce(e.descripcion,'') as descripcion, 1 as ord
      from mos.equivalencias e
      where e.sku_base = v_sku and coalesce(e.activo, true) = true and nullif(btrim(e.codigo_barra),'') is not null
    ) t order by cb, ord
  ),
  barras_pres as (select cb from barras_info),
  -- ⭐ FIX FACTOR: factor por código (presentación propia) y por id (línea de venta por sku=id_producto).
  --    Equivalentes → factor 1. cb gana sobre id.
  fac_cb as (
    select distinct on (cb) cb, factor from (
      select nullif(btrim(pr.codigo_barra),'') as cb, pr.factor, 0 as ord from presentaciones pr where nullif(btrim(pr.codigo_barra),'') is not null
      union all
      select nullif(btrim(e.codigo_barra),'') as cb, 1::numeric as factor, 1 as ord
      from mos.equivalencias e where e.sku_base = v_sku and coalesce(e.activo,true)=true and nullif(btrim(e.codigo_barra),'') is not null
    ) t order by cb, ord
  ),
  fac_id as (
    select pr.id_producto as idk, pr.factor from presentaciones pr
  ),
  equiv_cnt as (
    select count(*) as n from mos.equivalencias e
    where e.sku_base = v_sku and coalesce(e.activo, true) = true and nullif(btrim(e.codigo_barra),'') is not null
  ),
  wh_rows as (
    select s.cod_producto, coalesce(s.cantidad_disponible,0) as cant, s.ultima_actualizacion
    from wh.stock s
    where s.cod_producto in (select id_producto from ids_pres)
       or s.cod_producto in (select cb from barras_pres)
  ),
  wh_total as (select coalesce(sum(cant),0) as q from wh_rows),
  wh_por_cb as (select cod_producto as cb, sum(cant) as q from wh_rows group by cod_producto),
  sz_raw as (
    select nullif(btrim(z.cod_barras),'') as cb,
           r.canon_id as zid, r.canon_nombre as znombre,
           coalesce(z.cantidad,0) as cant
    from me.stock_zonas z
    cross join lateral (
      select coalesce(zr.canon_id, upper(btrim(z.zona_id))) as canon_id,
             coalesce(zr.canon_nombre, btrim(z.zona_id))     as canon_nombre
      from (select 1) _ left join zona_resolver_u zr on zr.raw = upper(btrim(z.zona_id))
    ) r
    where nullif(btrim(z.cod_barras),'') in (select cb from barras_pres)
  ),
  zona_acum as (
    select zid, max(znombre) as znombre, sum(cant) as cantidad
    from sz_raw where nullif(btrim(zid),'') is not null group by zid
  ),
  sz_por_cb as (select cb, sum(cant) as q from sz_raw group by cb),
  matriz as (
    select cb, jsonb_object_agg(zid, cant) as porzona
    from (select cb, zid, sum(cant) as cant from sz_raw where nullif(btrim(zid),'') is not null group by cb, zid) m
    group by cb
  ),
  ventas_validas as (
    select v.id_venta, nullif(btrim(v.estacion),'') as estacion
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
      and nullif(btrim(v.estacion),'') is not null
  ),
  -- ⭐ FIX FACTOR: ventas por zona con cantidad × factor (mismo predicado de match sku/cb que 117).
  ventas_zona as (
    select r.canon_id as zid,
           sum(coalesce(d.cantidad,0) * coalesce(fc.factor, fi.factor, 1)) as ventas
    from me.ventas_detalle d
    join ventas_validas vv on vv.id_venta = d.id_venta
    left join fac_cb fc on fc.cb  = upper(btrim(nullif(btrim(d.cod_barras),'')))
    left join fac_id fi on fi.idk = nullif(btrim(d.sku),'')
    cross join lateral (
      select coalesce(zr.canon_id, upper(btrim(vv.estacion))) as canon_id
      from (select 1) _ left join zona_resolver_u zr on zr.raw = upper(btrim(vv.estacion))
    ) r
    where nullif(btrim(d.sku),'') in (select id_producto from ids_pres)
       or nullif(btrim(d.cod_barras),'') in (select cb from barras_pres)
    group by r.canon_id
  ),
  zonas_universo as (
    select zid, nombre from zonas_reg
    union
    select za.zid, coalesce(za.znombre, za.zid) as nombre from zona_acum za
    union
    select vz.zid, vz.zid as nombre from ventas_zona vz
  ),
  zonas_universo_u as (
    select zid, max(nombre) as nombre from zonas_universo where nullif(btrim(zid),'') is not null group by zid
  ),
  zonas_arr as (
    select
      zu.zid,
      coalesce((select zr.nombre from zonas_reg zr where zr.zid = zu.zid), zu.nombre, zu.zid) as nombre,
      coalesce(za.cantidad, 0) as cantidad,
      coalesce(vz.ventas, 0)   as ventas_rango,
      (za.zid is not null)     as tiene_reg_stock,
      (vz.zid is not null)     as tiene_reg_venta
    from zonas_universo_u zu
    left join zona_acum   za on za.zid = zu.zid
    left join ventas_zona vz on vz.zid = zu.zid
  ),
  zonas_calc as (
    select
      za.*,
      (case when v_dias > 0 then za.ventas_rango::numeric / v_dias else 0 end) as rot_dia
    from zonas_arr za
  ),
  tot as (
    select
      (select q from wh_total) + coalesce(sum(zc.cantidad),0)                          as total_cant,
      coalesce(sum(round(zc.rot_dia,1)),0)                                             as total_rot,
      coalesce(sum(zc.ventas_rango),0)                                                 as total_ventas
    from zonas_calc zc
  )
  select jsonb_build_object(
    'producto', jsonb_build_object(
      'idProducto', v_prod.id_producto, 'skuBase', v_sku,
      'descripcion', v_prod.descripcion, 'codigoBarra', v_prod.codigo_barra,
      'stockMinimo', v_prod.stock_minimo, 'stockMaximo', v_prod.stock_maximo,
      'precioCosto', v_prod.precio_costo, 'precioVenta', v_prod.precio_venta),
    'codigosBarra', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'codigoBarra', bi.cb, 'tipo', bi.tipo, 'descripcion', bi.descripcion,
        'stockWh',    coalesce((select q from wh_por_cb w where w.cb = bi.cb), 0),
        'stockZonas', coalesce((select q from sz_por_cb  z where z.cb = bi.cb), 0),
        'stockTotal', coalesce((select q from wh_por_cb w where w.cb = bi.cb), 0) + coalesce((select q from sz_por_cb z where z.cb = bi.cb), 0),
        'porZona',    coalesce((select porzona from matriz m where m.cb = bi.cb), '{}'::jsonb)
      )), '[]'::jsonb) from barras_info bi),
    'countEquivalencias', (select n from equiv_cnt),
    'wh', jsonb_build_object(
      'cantidad', (select q from wh_total),
      'detalle', (select coalesce(jsonb_agg(jsonb_build_object(
                    'codigoProducto', wr.cod_producto, 'cantidad', wr.cant,
                    'ultimaActualizacion', wr.ultima_actualizacion)), '[]'::jsonb) from wh_rows wr)),
    'zonas', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'idZona', zc.zid, 'nombre', zc.nombre, 'cantidad', zc.cantidad,
        'ventasRango', zc.ventas_rango, 'rotacionDia', round(zc.rot_dia,1),
        'diasParaAcabar', case when zc.rot_dia > 0 and zc.cantidad > 0 then floor(zc.cantidad / zc.rot_dia)::int else null end,
        'tieneRegistroStock', zc.tiene_reg_stock, 'tieneRegistroVenta', zc.tiene_reg_venta,
        'sinStock', zc.cantidad <= 0, 'sinVentas', zc.ventas_rango <= 0)
        order by (case when zc.cantidad > 0 or zc.ventas_rango > 0 then 1 else 0 end) desc, zc.ventas_rango desc
      ), '[]'::jsonb) from zonas_calc zc),
    'total', jsonb_build_object(
      'cantidad', (select total_cant from tot),
      'rotacionDia', round((select total_rot from tot), 1),
      'ventasRango', (select total_ventas from tot),
      'diasParaAcabar', (select case when total_rot > 0 and total_cant > 0 then floor(total_cant / total_rot)::int else null end from tot),
      'rangoDiasConsultado', v_dias),
    'insights', (
      select coalesce(jsonb_agg(ins), '[]'::jsonb) from (
        select jsonb_build_object(
          'tipo','REPONER_ZONA','severidad','ALTA',
          'mensaje','Zona ' || zc.nombre || ' consume ' || round(zc.rot_dia,1) || '/d, alcanza ' || floor(zc.cantidad/zc.rot_dia)::int || ' días',
          'idZona', zc.zid,
          'accion','Trasladar desde WH (' || (select q from wh_total) || 'u disponibles)') as ins
        from zonas_calc zc
        where zc.rot_dia > 0 and zc.cantidad > 0 and floor(zc.cantidad/zc.rot_dia)::int < 7
        union all
        select jsonb_build_object(
          'tipo','SIN_ROTACION','severidad','MEDIA',
          'mensaje','Sin ventas en últimos ' || v_dias || ' días con ' || (select total_cant from tot) || 'u en stock',
          'accion','Considerar promo/descuento para rotar')
        where (select total_rot from tot) = 0 and (select total_cant from tot) > 0
        union all
        select jsonb_build_object(
          'tipo','BAJO_MINIMO','severidad','CRITICA',
          'mensaje','Stock total (' || (select total_cant from tot) || ') por debajo del mínimo (' || v_prod.stock_minimo || ')',
          'accion','Generar pedido de reposición')
        where v_prod.stock_minimo > 0 and (select total_cant from tot) < v_prod.stock_minimo
      ) z)
  )
  into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.stock_unificado(jsonb) from public;
grant execute on function mos.stock_unificado(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) mos.insights_stock — FIX en ventas_canon_zona (× factor). Resto IDÉNTICO a 117.
--    Las ventas por (canónico, zona) se resolvían por cod_barras → canónico, sumando cantidad cruda. Ahora cada
--    línea se multiplica por el factor del producto/equiv que matchea ese cod_barras (equiv → 1). Esto corrige
--    rot_dia → dias_restantes → DESPACHAR_DESDE_WH / TRASLADAR (cant_sugerida = ceil(rot×14)) y SIN_ROTACION.
--    STOCK por canónico (stock_canon_*) y WH (wh_por_canon) NO se tocan.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.insights_stock(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_dias  int;
  v_desde date;
  v_ins   jsonb;
  v_total int;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  v_dias := coalesce(nullif(btrim(coalesce(p->>'dias','')), '')::int, 30);
  if v_dias is null or v_dias <= 0 then v_dias := 30; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  v_desde := (now() at time zone 'America/Lima')::date - v_dias;

  with
  canonicos as (
    select pr.id_producto, pr.sku_base, pr.descripcion, pr.codigo_barra, coalesce(pr.stock_minimo,0) as stock_minimo
    from mos.productos pr
    where coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = '' and (pr.factor_conversion is null or pr.factor_conversion = 1)
  ),
  canon_by_id  as (select upper(btrim(c.id_producto)) as k, c.id_producto from canonicos c where nullif(btrim(c.id_producto),'') is not null),
  canon_by_sku as (select distinct on (upper(btrim(c.sku_base))) upper(btrim(c.sku_base)) as k, c.id_producto from canonicos c where nullif(btrim(c.sku_base),'') is not null order by upper(btrim(c.sku_base)), c.id_producto),
  prod_canon as (
    select pr.id_producto, pr.codigo_barra,
      case
        when coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = '' and (pr.factor_conversion is null or pr.factor_conversion = 1) then pr.id_producto
        when coalesce(nullif(btrim(pr.codigo_producto_base),''),'') <> '' then coalesce((select id_producto from canon_by_id where k = upper(btrim(pr.codigo_producto_base))),(select id_producto from canon_by_sku where k = upper(btrim(pr.codigo_producto_base))))
        when nullif(btrim(pr.sku_base),'') is not null then (select id_producto from canon_by_sku where k = upper(btrim(pr.sku_base)))
        else null
      end as canon_id
    from mos.productos pr
  ),
  mapa as (
    select upper(btrim(pc.id_producto)) as k, pc.canon_id from prod_canon pc where pc.canon_id is not null and nullif(btrim(pc.id_producto),'') is not null
    union select upper(btrim(pc.codigo_barra)), pc.canon_id from prod_canon pc where pc.canon_id is not null and nullif(btrim(pc.codigo_barra),'') is not null
    union select upper(btrim(e.codigo_barra)), cbs.id_producto from mos.equivalencias e join canon_by_sku cbs on cbs.k = upper(btrim(e.sku_base)) where coalesce(e.activo, true) = true and nullif(btrim(e.codigo_barra),'') is not null
  ),
  mapa_u as (select distinct on (k) k, canon_id from mapa order by k, canon_id),
  -- ⭐ FIX FACTOR: factor por código de barra (presentación propia) — equivalentes → 1, cb gana sobre equiv.
  fac_by_cb as (
    select distinct on (cb) cb, factor from (
      select upper(btrim(pr.codigo_barra)) as cb,
             case when coalesce(pr.factor_conversion,0)=0 then 1 else pr.factor_conversion end as factor, 0 as ord
      from mos.productos pr where nullif(btrim(pr.codigo_barra),'') is not null
      union all
      select upper(btrim(e.codigo_barra)) as cb, 1::numeric as factor, 1 as ord
      from mos.equivalencias e where coalesce(e.activo,true)=true and nullif(btrim(e.codigo_barra),'') is not null
    ) t order by cb, ord
  ),

  zonas_reg as (select upper(btrim(z.id_zona)) as zid, coalesce(z.nombre, z.id_zona) as nombre from mos.zonas z where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado, true) = true),
  zona_resolver as (
    select upper(btrim(z.id_zona)) as raw, upper(btrim(z.id_zona)) as canon_id, coalesce(z.nombre, z.id_zona) as canon_nombre from mos.zonas z where nullif(btrim(z.id_zona),'') is not null
    union select upper(btrim(z.nombre)), upper(btrim(z.id_zona)), coalesce(z.nombre, z.id_zona) from mos.zonas z where nullif(btrim(z.nombre),'') is not null
    union select upper(btrim(es.id_estacion)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.id_estacion),'') is not null
    union select upper(btrim(es.nombre)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.nombre),'') is not null
    union select upper(btrim(es.id_zona)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null
  ),
  zona_resolver_u as (select distinct on (raw) raw, canon_id, canon_nombre from zona_resolver order by raw, canon_nombre nulls last),
  stock_raw as (
    select m.canon_id, r.canon_id as zid, r.canon_nombre as znombre, coalesce(z.cantidad,0) as cant
    from me.stock_zonas z
    join mapa_u m on m.k = upper(btrim(z.cod_barras))
    cross join lateral (
      select coalesce(zru.canon_id, upper(btrim(z.zona_id))) as canon_id, coalesce(zru.canon_nombre, btrim(z.zona_id)) as canon_nombre
      from (select 1) _ left join zona_resolver_u zru on zru.raw = upper(btrim(z.zona_id))
    ) r
    where coalesce(z.cantidad,0) > 0 and m.canon_id is not null
  ),
  stock_canon_total as (select canon_id, sum(cant) as total from stock_raw group by canon_id),
  stock_canon_zona  as (select canon_id, zid, max(znombre) as znombre, sum(cant) as cant from stock_raw group by canon_id, zid),
  ventas_meta as (
    select v.id_venta, r.canon_id as zid
    from me.ventas v
    cross join lateral (
      select coalesce(zru.canon_id, upper(btrim(v.estacion))) as canon_id
      from (select 1) _ left join zona_resolver_u zru on zru.raw = upper(btrim(v.estacion))
    ) r
    where v.fecha is not null and (v.fecha at time zone 'America/Lima')::date >= v_desde and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  ),
  -- ⭐ FIX FACTOR: cantidad × factor del cod_barras (mismo resolver canónico que 117).
  ventas_canon_zona as (
    select coalesce((select canon_id from mapa_u where k = upper(btrim(d.cod_barras))), null) as canon_id,
           vm.zid, sum(coalesce(d.cantidad,0) * coalesce((select factor from fac_by_cb fb where fb.cb = upper(btrim(d.cod_barras))), 1)) as cant
    from me.ventas_detalle d join ventas_meta vm on vm.id_venta = d.id_venta
    where nullif(btrim(d.cod_barras),'') is not null
    group by 1, vm.zid
  ),
  vcz as (select canon_id, zid, sum(cant) as cant from ventas_canon_zona where canon_id is not null group by canon_id, zid),
  ventas_canon_total as (select canon_id, sum(cant) as total from vcz group by canon_id),
  zona_nombre as (
    select zid, max(nombre) as nombre from (
      select zid, znombre as nombre from stock_canon_zona
      union all select zr.zid, zr.nombre from zonas_reg zr
      union all select scz.zid, scz.znombre from stock_canon_zona scz
    ) z where nullif(btrim(zid),'') is not null group by zid
  ),
  wh_por_canon as (
    select m.canon_id, sum(coalesce(s.cantidad_disponible,0)) as q
    from wh.stock s join mapa_u m on m.k = upper(btrim(s.cod_producto))
    where nullif(btrim(s.cod_producto),'') is not null group by m.canon_id
  ),
  ins1 as (
    select jsonb_build_object(
      'tipo','SIN_ROTACION','severidad','MEDIA',
      'producto', coalesce(nullif(c.descripcion,''), c.id_producto),
      'codigoBarra', coalesce(nullif(c.codigo_barra,''), c.id_producto),
      'idProducto', c.id_producto, 'skuBase', coalesce(c.sku_base,''),
      'stock', sct.total,
      'mensaje', coalesce(c.descripcion,'') || ' tiene ' || sct.total || 'u sin venta en ' || v_dias || ' días',
      'accion','Lanzar promo o trasladar a otra zona') as obj
    from stock_canon_total sct join canonicos c on c.id_producto = sct.canon_id
    where sct.total >= 10 and coalesce((select total from ventas_canon_total v where v.canon_id = sct.canon_id),0) = 0
  ),
  base2 as (
    select
      vcz.canon_id, vcz.zid as zona_vend, vcz.cant as ventas,
      coalesce((select cant from stock_canon_zona scz where scz.canon_id = vcz.canon_id and scz.zid = vcz.zid),0) as stock_en_esa,
      (vcz.cant::numeric / v_dias) as rot_dia,
      coalesce((select q from wh_por_canon w where w.canon_id = vcz.canon_id),0) as wh_disp
    from vcz
    where vcz.zid in (select zid from zonas_reg)
  ),
  base2b as (
    select b.*,
      (b.stock_en_esa / nullif(b.rot_dia,0)) as dias_restantes,
      ceil(b.rot_dia * 14)::int as cant_sugerida,
      c.descripcion, c.id_producto, c.sku_base, c.codigo_barra
    from base2 b join canonicos c on c.id_producto = b.canon_id
    where b.rot_dia > 0
  ),
  base2c as (
    select * from base2b
    where dias_restantes is not null and dias_restantes < 7 and dias_restantes >= 0
  ),
  ins2a as (
    select b.canon_id, b.zona_vend, jsonb_build_object(
      'tipo','DESPACHAR_DESDE_WH',
      'severidad', case when b.dias_restantes < 3 then 'CRITICA' else 'ALTA' end,
      'producto', coalesce(nullif(b.descripcion,''), coalesce(nullif(b.codigo_barra,''), b.canon_id)),
      'codigoBarra', coalesce(nullif(b.codigo_barra,''), b.canon_id),
      'idProducto', b.id_producto, 'skuBase', coalesce(b.sku_base,''),
      'mensaje', 'Despachar de 🏭 WH → ' || coalesce((select nombre from zona_nombre zn where zn.zid = b.zona_vend), b.zona_vend)
                 || ': ' || coalesce((select nombre from zona_nombre zn where zn.zid = b.zona_vend), b.zona_vend)
                 || ' tiene ' || b.stock_en_esa || 'u (alcanza ' || floor(b.dias_restantes)::int || 'd) y vende '
                 || round(b.rot_dia,1) || '/d. WH dispone de ' || b.wh_disp || 'u (todas las variantes).',
      'accion','Despachar ' || b.cant_sugerida || 'u (cobertura 2 semanas)',
      'desde','WH','hacia', b.zona_vend, 'cantidadSugerida', b.cant_sugerida, 'stockWh', b.wh_disp) as obj
    from base2c b
    where b.wh_disp >= b.cant_sugerida
  ),
  ins2b_cands as (
    select b.canon_id, b.zona_vend, b.ventas, b.rot_dia, b.dias_restantes, b.cant_sugerida,
           b.descripcion, b.id_producto, b.sku_base, b.codigo_barra,
           scz.zid as zona_origen, scz.cant as stock_origen,
           coalesce((select cant from vcz v where v.canon_id = b.canon_id and v.zid = scz.zid),0) as ventas_otra
    from base2c b
    join stock_canon_zona scz on scz.canon_id = b.canon_id
    where b.wh_disp < b.cant_sugerida
      and scz.zid <> b.zona_vend
      and scz.zid in (select zid from zonas_reg)
      and scz.cant >= 5
      and coalesce((select cant from vcz v where v.canon_id = b.canon_id and v.zid = scz.zid),0) < b.ventas / 3.0
  ),
  ins2b_best as (
    select distinct on (canon_id, zona_vend) *
    from ins2b_cands order by canon_id, zona_vend, stock_origen desc, zona_origen
  ),
  ins2b as (
    select b.canon_id, b.zona_vend, jsonb_build_object(
      'tipo','TRASLADAR','severidad','MEDIA',
      'producto', coalesce(nullif(b.descripcion,''), coalesce(nullif(b.codigo_barra,''), b.canon_id)),
      'codigoBarra', coalesce(nullif(b.codigo_barra,''), b.canon_id),
      'idProducto', b.id_producto, 'skuBase', coalesce(b.sku_base,''),
      'mensaje', '🏭 WH sin stock — Trasladar de ' || coalesce((select nombre from zona_nombre zn where zn.zid = b.zona_origen), b.zona_origen)
                 || ' (' || b.stock_origen || 'u, sin venta) → ' || coalesce((select nombre from zona_nombre zn where zn.zid = b.zona_vend), b.zona_vend)
                 || ' (vende ' || round(b.rot_dia,1) || '/d, alcanza ' || floor(b.dias_restantes)::int || 'd)',
      'accion','Mover ' || least(b.stock_origen, b.cant_sugerida) || 'u entre zonas (operación manual)',
      'desde', b.zona_origen, 'hacia', b.zona_vend, 'cantidadSugerida', least(b.stock_origen, b.cant_sugerida)) as obj
    from ins2b_best b
  ),
  ins3 as (
    select jsonb_build_object(
      'tipo','REPOSICION','severidad','CRITICA',
      'producto', c.descripcion, 'idProducto', c.id_producto, 'skuBase', coalesce(c.sku_base,''),
      'stock', coalesce(sct.total,0) + coalesce(wpc.q,0), 'minimo', c.stock_minimo,
      'mensaje', c.descripcion || ' total ' || (coalesce(sct.total,0) + coalesce(wpc.q,0)) || 'u (todas variantes) < mínimo ' || c.stock_minimo,
      'accion','Generar pedido al proveedor') as obj
    from canonicos c
    left join stock_canon_total sct on sct.canon_id = c.id_producto
    left join wh_por_canon      wpc on wpc.canon_id = c.id_producto
    where c.stock_minimo > 0 and (coalesce(sct.total,0) + coalesce(wpc.q,0)) < c.stock_minimo
  ),
  todos as (
    select obj, 3 as prio_tipo from ins1
    union all select obj, 1 from ins2a
    union all select obj, 2 from ins2b
    union all select obj, 0 from ins3
  ),
  ordenados as (
    select obj,
      (case obj->>'severidad' when 'CRITICA' then 0 when 'ALTA' then 1 when 'MEDIA' then 2 when 'BAJA' then 3 else 9 end) as prio_sev,
      prio_tipo
    from todos
  )
  select
    coalesce((select jsonb_agg(o.obj order by o.prio_sev, o.prio_tipo) from (select * from ordenados order by prio_sev, prio_tipo limit 20) o), '[]'::jsonb),
    (select count(*)::int from ordenados)
  into v_ins, v_total;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    '_almV', 2, 'insights', v_ins, 'total', coalesce(v_total,0), 'rangoDias', v_dias
  )) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.insights_stock(jsonb) from public;
grant execute on function mos.insights_stock(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTAS (honestidad)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) IMPACTO REAL VERIFICADO: hay 274 productos con factor>1 y varios con ventas en el mes (ej. LEV187 vendió
--    13 presentaciones de factor 12 = 156 unidades base; el RPC reportaba ~conteo crudo). Subcontar ventas
--    inflaba diasCobertura/diasParaAcabar y subestimaba la rotación → alertas tardías. El fix es necesario.
--
-- 2) STOCK INTACTO: ninguna CTE de stock (wh.stock / me.stock_zonas) se modificó. whCantidad / zonasCantidad /
--    totalCantidad / stockActual / stock por zona se computan exactamente igual que 113/117. Regla del dueño.
--
-- 3) SHAPE INTACTO: mismas claves, mismos tipos, mismo orden, mismo gate, mismos grants, mismo _frescura_sombra.
--    Solo cambian los valores numéricos de ventas (vendidasMes / ventasRango / rotacionDia / diasParaAcabar) y
--    lo que derive de ellos (alertas SIN_ROTACION/AGOTAR_PRONTO, insights de despacho/traslado y sus cantidades).
--
-- 4) MATCH PRESERVADO: el factor se aplica sobre las MISMAS líneas que cada RPC ya seleccionaba (mismo filtro de
--    anulación, ventana de fecha, resolución de sku/cb/canónico). Prioridad de factor: cod_barras (presentación
--    propia) > id_producto (sku) > 1. Equivalentes activos = factor 1. factor null/0 → 1. Idéntico criterio a la
--    fundación 126 (me._riz_ventas_base), reusado.
--
-- 5) NO TOCADO A PROPÓSITO: productos_sin_venta (existencia booleana — el factor no cambia "¿hubo venta?") y
--    ranking_zonas (suma dinero S/, no unidades). dashboard_almacen no agrega ventas. RIZ (126/128) ya nacía
--    correcto. Estas RPCs no requieren cambio.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
