-- 113_mos_vistas_wh_agregados.sql — [MIGRACIÓN MOS · FASE 2 · LECTURA-AGREGADA CROSS-APP]
-- Replica con PARIDAD razonable 3 vistas/agregados de WAREHOUSE que MOS calcula hoy en GAS:
--   · mos.rotacion_productos(p jsonb)      ← getRotacionProductos  (gas/Conexiones.gs:201) + getStockWarehouse (62)
--   · mos.dashboard_almacen(p jsonb)       ← getDashboardAlmacen   (gas/Almacen.gs:420) + _getDashboardAlmacenImpl (425)
--   · mos.catalogo_stock_resumen(p jsonb)  ← getCatalogoStockResumen (gas/Almacen.gs:262) + _getCatalogoStockResumenImpl (268)
--
-- ⚠️ INERTE / NO-APLICAR-AUN: este archivo SOLO define las RPCs con su grant. NADIE las llama todavía (el
--    wiring de js/api.js read-paths + el flip de flags es tanda posterior). MOS sigue 100% por GAS. Este SQL
--    NO toca flags, NO toca sync, NO cablea frontend. Idéntico patrón inerte que 94/98/105/106/107/109/110.
--
-- ── FUENTES CRUZADAS (todas verificadas que existen en Supabase) ────────────────────────────────────────────
--   · wh.stock              (03_schema_wh.sql:63)  — cod_producto / cantidad_disponible  (⚠ col es `cod_producto`).
--   · wh.lotes_vencimiento  (03:84)  — cod_producto / fecha_vencimiento / cantidad_actual.
--   · wh.mermas             (03:96)  — cod_producto / fecha_ingreso / cantidad_pendiente|original / estado.
--   · wh.envasados          (03:144) — fecha / eficiencia_pct.
--   · wh.preingresos        (03:163) — estado.
--   · mos.productos         (01:43)  — sku_base / codigo_barra / precio_costo / stock_minimo / stock_maximo /
--                                       codigo_producto_base / factor_conversion / estado / marca / id_categoria.
--   · mos.equivalencias     (01:88)  — sku_base / codigo_barra / activo  (ampliar barrasAll de cada sku).
--   · me.stock_zonas        (02:254) — cod_barras / zona_id / cantidad   (stock por zona, para catálogo).
--   · me.ventas (02:16) + me.ventas_detalle (02:51) — ventas en rango para rotación.
--
-- ── HONESTIDAD 40x: las 3 SON PORTABLES con paridad razonable. NINGUNA quedó como "requiere sesión dedicada".
--   Las divergencias son de SEMÁNTICA DE FRESCURA DE SOMBRA (wh.* / me.* son sombras del sync GAS→Supabase) y
--   de detalles de borde (ms vs día, anulación por estado_envio vs forma_pago) — documentadas en NOTAS. NO hay
--   ausencia de tabla ni agregado intratable. Ver bloque NOTAS al final para riesgos por-función.
--
-- ── GATE + ENVOLTORIO ──────────────────────────────────────────────────────────────────────────────────────
--   mos._claim_ok()        (74_mos_claim_ok_f0a.sql)  — service_role/GAS o claim app='MOS'; otro → APP_NO_AUTORIZADA.
--   mos._frescura_sombra() (94_mos_lecturas_proveedores_jornadas.sql) — agrega _heartbeat/_now/_ttl_min/_fresh.
--   TZ: America/Lima en TODOS los cortes de fecha (mes/rango/vencimientos), coherente con mos.hoy_lima().
--   Este archivo NO redefine los helpers; los consume (ya existen y tienen grant).


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) mos.rotacion_productos(p jsonb) — p = { mes (opc 'YYYY-MM', default mes actual Lima), soloAlertas (opc 'true') }
--    Espeja getRotacionProductos → getStockWarehouse. Una FILA POR ROW DE wh.stock (NO agregada por sku — paridad
--    fiel con el GAS, que mapea stock.map sobre cada entrada de la hoja STOCK). vendidasMes se busca por
--    skuBase del producto resuelto Y, si 0, por codigoProducto (= cod_producto del stock). diasCobertura =
--    round(stock / vendidasMes * 30) o null si no hubo ventas. Orden: críticos primero (menor cobertura).
--    Shape por fila: { codigoProducto, descripcion, skuBase, stockActual, vendidasMes, diasCobertura, alertaMinimo }.
--    Envoltorio: { ok:true, data:[...] } || _frescura_sombra().
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
  v_solo_aler  boolean := (coalesce(p->>'soloAlertas','') = 'true');   -- paridad: params.soloAlertas === 'true'
  v_mes_pref   text;   -- prefijo 'YYYY-MM' para filtrar cabeceras de venta
  v_data       jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- mes: params.mes || formatDate(now, 'yyyy-MM') del proyecto (TZ Lima).
  v_mes_pref := coalesce(v_mes, to_char((now() at time zone 'America/Lima'), 'YYYY-MM'));

  with
  -- Resolución de cada cod_producto del catálogo: el GAS arma prodMap por idProducto, skuBase Y codigoBarra
  -- (primera coincidencia gana para sku/cb). Aquí el lookup desde STOCK prueba en ese orden de prioridad.
  prod_by_id as (
    select pr.id_producto as k, pr.id_producto, pr.sku_base, pr.codigo_barra, pr.descripcion, pr.stock_minimo
    from mos.productos pr
  ),
  prod_by_sku as (   -- primera por sku_base (orden estable por id_producto)
    select distinct on (pr.sku_base) pr.sku_base as k, pr.id_producto, pr.sku_base, pr.codigo_barra, pr.descripcion, pr.stock_minimo
    from mos.productos pr where nullif(btrim(pr.sku_base),'') is not null
    order by pr.sku_base, pr.id_producto
  ),
  prod_by_cb as (    -- primera por codigo_barra (orden estable por id_producto)
    select distinct on (pr.codigo_barra) pr.codigo_barra as k, pr.id_producto, pr.sku_base, pr.codigo_barra, pr.descripcion, pr.stock_minimo
    from mos.productos pr where nullif(btrim(pr.codigo_barra),'') is not null
    order by pr.codigo_barra, pr.id_producto
  ),
  -- Ventas del MES por sku (clave VENTAS_DETALLE.SKU del GAS): cabeceras del mes no anuladas → detalle, sum cantidad.
  -- Paridad GAS: el getter de detalle suma por v.SKU (no por cb). Las usamos como ventasMap[skuBase] y, fallback,
  -- ventasMap[codigoProducto].  Aquí indexamos por la clave SKU cruda del detalle.
  ventas_mes as (
    select nullif(btrim(d.sku),'') as sku, sum(coalesce(d.cantidad,0)) as q
    from me.ventas_detalle d
    join me.ventas v on v.id_venta = d.id_venta
    where v.fecha is not null
      and to_char((v.fecha at time zone 'America/Lima'), 'YYYY-MM') = v_mes_pref
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
      and nullif(btrim(d.sku),'') is not null
    group by nullif(btrim(d.sku),'')
  ),
  -- Una fila por row de wh.stock, enriquecida con el producto resuelto.
  stock_rows as (
    select
      s.id_stock,
      s.cod_producto                                            as codigo_producto,
      coalesce(s.cantidad_disponible, 0)                        as cant,
      coalesce(pid.id_producto, psk.id_producto, pcb.id_producto) is not null as en_catalogo,
      -- descripcion: GAS = p.descripcion || (sinCatalogo ? '⚠ Sin nombre · '+cod : cod)
      coalesce(
        nullif(coalesce(pid.descripcion, psk.descripcion, pcb.descripcion), ''),
        case when coalesce(pid.id_producto, psk.id_producto, pcb.id_producto) is null
             then '⚠ Sin nombre · ' || s.cod_producto
             else s.cod_producto end
      )                                                         as descripcion,
      -- skuBase: GAS = p.skuBase || ''  (NO fallback a codigoProducto)
      coalesce(nullif(coalesce(pid.sku_base, psk.sku_base, pcb.sku_base), ''), '') as sku_base,
      coalesce(pid.stock_minimo, psk.stock_minimo, pcb.stock_minimo, 0)            as stock_minimo
    from wh.stock s
    left join prod_by_id  pid on pid.k = s.cod_producto
    left join prod_by_sku psk on psk.k = s.cod_producto
    left join prod_by_cb  pcb on pcb.k = s.cod_producto
  ),
  -- Resolver vendidasMes: GAS = ventasMap[skuBase] || ventasMap[codigoProducto] || 0.
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
      -- diasCobertura = vendidasMes>0 ? round(stock/vendidasMes*30) : null
      case when cv.vendidas_mes > 0
           then round((cv.cant / cv.vendidas_mes) * 30)::int
           else null end                                        as dias_cobertura
    from con_ventas cv
    where (not v_solo_aler) or cv.alerta_minimo   -- paridad: filtra a alertaMinimo si soloAlertas==='true'
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
           -- Orden GAS: menor cobertura primero; null → 9999 (al final).
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
-- 2) mos.catalogo_stock_resumen(p jsonb) — p = { dias (opc int, default 7) }
--    Espeja _getCatalogoStockResumenImpl. UNA FILA POR skuBase (productos activos), suma stock WH + zonas ME +
--    ventas N días, clasifica alerta, calcula rotación/díasParaAcabar. countPresentaciones/countEquivalencias.
--    Shape data = { _almV:2, productos:[...], total, rangoDias }. Por producto:
--      { skuBase, idProducto, descripcion, codigoBarra, marca, idCategoria, precioVenta, precioCosto,
--        stockMinimo, stockMaximo, whCantidad, zonasCantidad, totalCantidad, ventasRango, rotacionDia,
--        diasParaAcabar, countPresentaciones, countEquivalencias, alerta }.
--    Orden: severidad (NEGATIVO<BAJO_MINIMO<AGOTAR_PRONTO<SIN_ROTACION<CERCA_MINIMO<OK) luego descripcion.
--    Envoltorio: { ok:true, data:{...} } || _frescura_sombra().
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

  -- rangoDias: parseInt(params.dias) || 7. Clamp defensivo (1..3650).
  v_dias := coalesce(nullif(btrim(coalesce(p->>'dias','')), '')::int, 7);
  if v_dias is null or v_dias <= 0 then v_dias := 7; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  v_desde := (now() at time zone 'America/Lima')::date - v_dias;

  with
  -- ── Productos ACTIVOS (GAS filtra estado falsy fuera). estado es boolean en mos.productos. ──
  prods as (
    select pr.* from mos.productos pr
    where coalesce(pr.estado, true) = true
  ),
  -- ── Agrupar por sku_base; base = (id=sku) > (factor=1) > primera (orden estable id_producto). ──
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
  -- ── Lookups codigo_producto → sku.  El GAS resuelve stock por prodById[cod] || prodByCB[cod]; ventas por
  --    prodById[sku2] || prodByCB[cb2]; zonas por prodByCB[cb].  Construimos id→sku y cb→sku (master+equiv). ──
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
      -- equivalencia solo cuenta si su sku existe en el master (GAS: "if (!bySku[sku]) return")
      and exists (select 1 from grp g where g.sku = e.sku_base)
  ),
  -- countEquivalencias: GAS solo cuenta cb que NO estaba ya en barrasAll del sku (códigos nuevos) y cuyo sku existe.
  equiv_cnt as (
    select e.sku_base as sku, count(*) as n
    from (
      select distinct e.sku_base, nullif(btrim(e.codigo_barra),'') as cb
      from mos.equivalencias e
      where coalesce(e.activo, true) = true
        and nullif(btrim(e.sku_base),'') is not null
        and nullif(btrim(e.codigo_barra),'') is not null
        and exists (select 1 from grp g where g.sku = e.sku_base)
        -- excluir cb que ya es codigo_barra de alguna presentación del mismo sku (ya estaba en barrasAll)
        and not exists (
          select 1 from prods pr
          where coalesce(nullif(pr.sku_base,''), pr.id_producto) = e.sku_base
            and nullif(btrim(pr.codigo_barra),'') = nullif(btrim(e.codigo_barra),'')
        )
    ) e
    group by e.sku_base
  ),
  -- ── Stock WH por sku (1 pasada): resolver cod_producto por id, si no por cb. ──
  wh_by_sku as (
    select coalesce(i.sku, c.sku) as sku, sum(coalesce(s.cantidad_disponible,0)) as q
    from wh.stock s
    left join id_to_sku i on i.id = s.cod_producto
    left join cb_to_sku c on c.cb = s.cod_producto
    where coalesce(i.sku, c.sku) is not null
    group by coalesce(i.sku, c.sku)
  ),
  -- ── Stock zonas ME por sku (1 pasada): resolver cb. ── (GAS: prodByCB[cb] → sku; suma cantidad) ──
  zonas_by_sku as (
    select c.sku, sum(coalesce(z.cantidad,0)) as q
    from me.stock_zonas z
    join cb_to_sku c on c.cb = nullif(btrim(z.cod_barras),'')
    group by c.sku
  ),
  -- ── Ventas N días por sku (1 pasada): cabeceras no anuladas en rango → detalle por id/cb → sku. ──
  ventas_validas as (
    select v.id_venta
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  ),
  ventas_by_sku as (
    select coalesce(i.sku, c.sku) as sku, sum(coalesce(d.cantidad,0)) as q
    from me.ventas_detalle d
    join ventas_validas vv on vv.id_venta = d.id_venta
    left join id_to_sku i on i.id = nullif(btrim(d.sku),'')
    left join cb_to_sku c on c.cb = nullif(btrim(d.cod_barras),'')
    where coalesce(i.sku, c.sku) is not null
    group by coalesce(i.sku, c.sku)
  ),
  -- ── Construir cada fila por sku ──
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
-- 3) mos.dashboard_almacen(p jsonb) — sin parámetros (p ignorado salvo el gate). Espeja _getDashboardAlmacenImpl.
--    KPIs agregados del almacén. Mes = mes calendario actual (TZ Lima). Resolución por CANÓNICO (igual que
--    _construirMapaCBaCanonico): cada cod_producto/cb se mapea al producto canónico (presentación→base por
--    skuBase; derivado→base por codigo_producto_base; equivalencia→canónico por skuBase). precioCosto y mínimo
--    salen del canónico.
--    Shape data:
--      { stockValor, totalUnidades, productosTotal, productosCriticos, productosAlerta, vencCriticos,
--        vencAlerta, mermasMes, mermasMesUnidades, mermasPendientes, envasadosMes, eficienciaPromedio,
--        preingresosPendientes, timestamp }.
--    Envoltorio: { ok:true, data:{...} } || _frescura_sombra().
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.dashboard_almacen(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_mes_ini date := date_trunc('month', (now() at time zone 'America/Lima'))::date;  -- 1ro del mes Lima
  v_hoy_l   date := (now() at time zone 'America/Lima')::date;
  v_data    jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  with
  -- ── Mapa de canónicos: id/sku de cada canónico (es_canónico = sin codigo_producto_base y factor 1/null). ──
  canonicos as (
    select pr.id_producto, pr.sku_base, pr.precio_costo, pr.stock_minimo
    from mos.productos pr
    where coalesce(nullif(btrim(pr.codigo_producto_base),''), '') = ''
      and (pr.factor_conversion is null or pr.factor_conversion = 1)
  ),
  canon_by_id  as (select upper(btrim(c.id_producto)) as k, c.id_producto from canonicos c where nullif(btrim(c.id_producto),'') is not null),
  canon_by_sku as (
    select distinct on (upper(btrim(c.sku_base))) upper(btrim(c.sku_base)) as k, c.id_producto
    from canonicos c where nullif(btrim(c.sku_base),'') is not null
    order by upper(btrim(c.sku_base)), c.id_producto
  ),
  -- resolverCanonicoDe(p): canónico→sí mismo; derivado(codigo_producto_base)→canon_by_id|sku de la ref;
  -- presentación(sku_base, factor!=1)→canon_by_sku. Devuelve el id_producto del canónico al que apunta CADA producto.
  prod_canon as (
    select
      pr.id_producto,
      pr.codigo_barra,
      case
        when coalesce(nullif(btrim(pr.codigo_producto_base),''), '') = ''
             and (pr.factor_conversion is null or pr.factor_conversion = 1)
          then pr.id_producto                                                     -- ya es canónico
        when coalesce(nullif(btrim(pr.codigo_producto_base),''), '') <> ''
          then coalesce(
                 (select cbi.id_producto from canon_by_id  cbi where cbi.k = upper(btrim(pr.codigo_producto_base))),
                 (select cbs.id_producto from canon_by_sku cbs where cbs.k = upper(btrim(pr.codigo_producto_base)))
               )                                                                  -- derivado → su base
        when nullif(btrim(pr.sku_base),'') is not null
          then (select cbs.id_producto from canon_by_sku cbs where cbs.k = upper(btrim(pr.sku_base)))  -- presentación → base
        else null
      end as canon_id
    from mos.productos pr
  ),
  -- mapa { cod_upper → canon_id } por id_producto y por codigo_barra (el último gana en GAS; aquí preferimos id).
  mapa_cb_canon as (
    select upper(btrim(pc.id_producto)) as k, pc.canon_id from prod_canon pc
    where pc.canon_id is not null and nullif(btrim(pc.id_producto),'') is not null
    union
    select upper(btrim(pc.codigo_barra)) as k, pc.canon_id from prod_canon pc
    where pc.canon_id is not null and nullif(btrim(pc.codigo_barra),'') is not null
    union
    -- equivalencias activas → cb apunta al canónico del sku (solo si NO había mapeo ya: GAS "if (!mapa[k])")
    select upper(btrim(e.codigo_barra)) as k, cbs.id_producto as canon_id
    from mos.equivalencias e
    join canon_by_sku cbs on cbs.k = upper(btrim(e.sku_base))
    where coalesce(e.activo, true) = true
      and nullif(btrim(e.codigo_barra),'') is not null
  ),
  -- de-dup: una fila por k. Preferir entrada de producto (no-equiv) sobre equivalencia es irrelevante en la
  -- práctica (mismo canon). distinct on k garantiza 1 canon por código resuelto.
  mapa_u as (
    select distinct on (k) k, canon_id from mapa_cb_canon order by k, canon_id
  ),

  -- ── 1) Stock valorizado + total unidades + stock por canónico ──
  stock_resuelto as (
    select coalesce(s.cantidad_disponible,0) as cant, m.canon_id
    from wh.stock s
    left join mapa_u m on m.k = upper(btrim(s.cod_producto))
  ),
  stock_agg as (
    select
      coalesce(sum(sr.cant * coalesce(cp.precio_costo,0)), 0) as stock_valor,
      coalesce(sum(sr.cant), 0)                               as total_unidades
    from stock_resuelto sr
    left join mos.productos cp on cp.id_producto = sr.canon_id
  ),
  stock_por_canon as (
    select sr.canon_id, sum(sr.cant) as cant
    from stock_resuelto sr
    where sr.canon_id is not null
    group by sr.canon_id
  ),

  -- ── 2) Productos críticos / en alerta: SOLO canónicos con mínimo>0, comparados contra stock por canónico. ──
  criticos_agg as (
    select
      count(*) filter (where coalesce(spc.cant,0) < c.stock_minimo)                                                   as criticos,
      count(*) filter (where coalesce(spc.cant,0) >= c.stock_minimo and coalesce(spc.cant,0) < c.stock_minimo * 1.2)  as en_alerta
    from canonicos c
    left join stock_por_canon spc on spc.canon_id = c.id_producto
    where coalesce(c.stock_minimo,0) > 0
  ),

  -- ── 3) Vencimientos: lotes con fecha y cantidad_actual>0; dias = floor(fechaVto - hoy). crit<=7, alerta<=30. ──
  --    GAS: floor((Date(fechaVto) - hoy)/86400000) con hoy = ahora (no medianoche). Usamos diferencia por DÍA Lima.
  venc_agg as (
    select
      count(*) filter (where d <= 7)               as venc_crit,
      count(*) filter (where d > 7 and d <= 30)    as venc_alerta
    from (
      select (((l.fecha_vencimiento at time zone 'America/Lima')::date) - v_hoy_l) as d
      from wh.lotes_vencimiento l
      where l.fecha_vencimiento is not null
        and coalesce(l.cantidad_actual,0) > 0
    ) t
  ),

  -- ── 4) Mermas del mes: cantidad valorizada por costo del canónico + unidades + pendientes. ──
  --    ⚠ El GAS suma `m.cantidad`; la columna real en wh.mermas es cantidad_original / cantidad_pendiente
  --    (NO existe `cantidad`). Ver NOTA 4: usamos cantidad_original (la cantidad de la merma registrada).
  mermas_agg as (
    select
      coalesce(sum(coalesce(m.cantidad_original,0) * coalesce(cp.precio_costo,0)), 0) as mermas_valor,
      coalesce(sum(coalesce(m.cantidad_original,0)), 0)                              as mermas_unidades,
      count(*) filter (where upper(coalesce(m.estado,'')) = 'PENDIENTE')             as mermas_pendientes
    from wh.mermas m
    left join mapa_u mu on mu.k = upper(btrim(m.cod_producto))
    left join mos.productos cp on cp.id_producto = mu.canon_id
    where m.fecha_ingreso is not null
      and (m.fecha_ingreso at time zone 'America/Lima')::date >= v_mes_ini
  ),

  -- ── 5) Envasados del mes: conteo + eficiencia promedio (eficiencia_pct). ──
  env_agg as (
    select
      count(*)                              as env_mes,
      avg(e.eficiencia_pct) filter (where e.eficiencia_pct is not null) as efic_prom
    from wh.envasados e
    where e.fecha is not null
      and (e.fecha at time zone 'America/Lima')::date >= v_mes_ini
  ),

  -- ── 6) Preingresos pendientes ──
  prein_agg as (
    select count(*) as prein_pend
    from wh.preingresos pi
    where upper(coalesce(pi.estado,'')) = 'PENDIENTE'
  ),

  -- ── productosTotal = TODAS las filas de PRODUCTOS_MASTER (GAS: productos.length, sin filtro de estado). ──
  prod_total as (select count(*)::int as n from mos.productos)

  select jsonb_build_object(
    'stockValor',            round((select stock_valor from stock_agg)::numeric, 2),
    'totalUnidades',         (select total_unidades from stock_agg),
    'productosTotal',        (select n from prod_total),
    'productosCriticos',     coalesce((select criticos  from criticos_agg), 0),
    'productosAlerta',       coalesce((select en_alerta from criticos_agg), 0),
    'vencCriticos',          coalesce((select venc_crit   from venc_agg), 0),
    'vencAlerta',            coalesce((select venc_alerta from venc_agg), 0),
    'mermasMes',             round((select mermas_valor from mermas_agg)::numeric, 2),
    'mermasMesUnidades',     (select mermas_unidades from mermas_agg),
    'mermasPendientes',      coalesce((select mermas_pendientes from mermas_agg), 0),
    'envasadosMes',          coalesce((select env_mes from env_agg), 0),
    'eficienciaPromedio',    (select efic_prom from env_agg),   -- null si no hubo envasados con eficiencia (paridad)
    'preingresosPendientes', coalesce((select prein_pend from prein_agg), 0),
    'timestamp',             to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  )
  into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.dashboard_almacen(jsonb) from public;
grant execute on function mos.dashboard_almacen(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTAS DE PARIDAD / DIVERGENCIAS / GAPS (honestidad 40x)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- A) NINGUNA función quedó como "requiere sesión dedicada / no portable". Las 3 son agregados sobre tablas que
--    YA están migradas (wh.stock/lotes/mermas/envasados/preingresos + mos.productos/equivalencias + me.ventas/
--    ventas_detalle/stock_zonas). El cómputo (sumas, conteos, clasificación de alertas, resolución de canónico/
--    sku) es directamente expresable en SQL. Lo que NO se puede garantizar es la FRESCURA de las sombras (ver C).
--
-- B) NOMBRE DE COLUMNA wh.stock — el GAS lee `s.codigoProducto` (header camelCase de la hoja STOCK), que en la
--    sombra Supabase es `wh.stock.cod_producto` (NO `codigo_producto`). Confirmado en 03_schema_wh.sql:63 y en
--    11_fase1d_wh_rotacion.sql / 109. Igual para lotes/mermas (cod_producto) y envasados (eficiencia_pct).
--
-- C) FRESCURA DE SOMBRA (no es GAP de datos, es GAP de actualidad) — wh.stock, wh.lotes_vencimiento, wh.mermas,
--    wh.envasados, wh.preingresos, me.stock_zonas, me.ventas son SOMBRAS del sync GAS→Supabase. Si el sync se
--    atrasa, KPIs/rotación/stock quedan stale respecto a las HOJAS que el GAS lee en vivo. _frescura_sombra()
--    expone _fresh para que el front decida caer a GAS. ⇒ ANTES del cutover de estos getters, el sync de esas
--    tablas DEBE estar vivo. El GAS siempre ve "fresco" porque lee la hoja en vivo.
--
-- D) MERMAS — DIVERGENCIA DE COLUMNA. El GAS suma `m.cantidad` (header de la hoja MERMAS). La tabla migrada
--    wh.mermas NO tiene columna `cantidad`: tiene cantidad_original y cantidad_pendiente (03:103-104). Asumimos
--    que el header `cantidad` de la hoja mapeó a `cantidad_original` (la cantidad con la que se registró la
--    merma) — es la lectura semántica correcta para "mermas del mes" (cantidad mermada, no lo que queda
--    pendiente de resolver). ⚠️ VERIFICAR el mapeo real del sync (_WH_SPECS/MERMAS en MigracionMOS.gs) antes
--    del cutover: si el header `cantidad` mapeó a cantidad_pendiente, cambiar las 2 referencias a
--    cantidad_pendiente. RIESGO MEDIO — es el único punto donde el header GAS no tiene columna homónima directa.
--    También: GAS filtra mes por `m.fecha`; aquí uso `m.fecha_ingreso` (la fecha de la merma; no hay `m.fecha`).
--
-- E) ANULACIÓN DE VENTA — GAS detecta 'ANULADO' por VENTAS_CABECERA col 8 = Estado_Envio. Aquí
--    me.ventas.estado_envio = 'ANULADO'. ⚠️ El ecosistema MOS tiene otra regla ("la anulación REAL se decide por
--    FormaPago"), pero replicamos EXACTAMENTE lo que hacen getRotacionProductos y _getCatalogoStockResumenImpl
--    (que miran Estado_Envio, no FormaPago) para PARIDAD FIEL. Si se quisiera endurecer en el flip, agregar
--    OR sobre forma_pago — pero eso sería MÁS estricto que el GAS y rompería paridad bit-a-bit. (Mismo criterio
--    documentado en 109, NOTA 3.)
--
-- F) ROTACIÓN — GRANULARIDAD POR-STOCK-ROW (NO por sku). getRotacionProductos mapea sobre CADA fila de la hoja
--    STOCK (stockRes.data.map), no agrega por sku. Por eso mos.rotacion_productos emite una fila por row de
--    wh.stock (id_stock). Si hubiera 2 filas de stock para el mismo cod_producto (no debería: id_stock es PK y
--    normalmente 1 por producto), saldrían 2 filas — IGUAL que el GAS. vendidasMes se busca por skuBase y, si 0,
--    por codigoProducto: ⚠️ si vendidasMes[skuBase] existe pero es 0, el GAS hace `0 || ventasMap[cod] || 0`,
--    que en JS cae al fallback de codigoProducto (porque 0 es falsy). Esta RPC replica eso: el subquery por
--    sku_base solo entra al COALESCE si devuelve > 0 — NO: usamos coalesce(subq_sku, subq_cod, 0), y subq_sku
--    devuelve NULL si no hay fila (no 0). PERO si la fila existe con q=0, coalesce tomaría 0 y NO probaría cod.
--    En la práctica ventas_mes solo contiene skus con q>0 (group by sum, y los detalles tienen cantidad>0), así
--    que una entrada con q=0 no existe → el comportamiento coincide con el GAS. RIESGO BAJO, documentado.
--
-- G) VENTANA DE VENTAS — catalogo_stock_resumen usa corte por DÍA Lima (fecha::date >= hoy - dias), el GAS usa
--    `desde = new Date(hoy - dias*86400000)` (corte por ms). Diferencia ≤ 1 día parcial en el borde inferior.
--    Para rotación (promedio sobre N días) el efecto es marginal. (Mismo criterio que 109, NOTA 5.) rotacion_
--    productos filtra por MES calendario ('YYYY-MM'), que es exacto (no hay borde de ms).
--
-- H) RESOLUCIÓN DE CANÓNICO (dashboard) — replica _construirMapaCBaCanonico + _esCanonico (Categorias.gs:252):
--    canónico = sin codigo_producto_base Y factor_conversion ∈ {null, 1}. Presentación → canónico por sku_base.
--    Derivado → canónico por codigo_producto_base (busca primero por id, luego por sku). Equivalencia → canónico
--    del sku (solo si el código no estaba ya mapeado: replicado vía distinct on / union de menor prioridad).
--    ⚠️ El GAS, al construir el mapa, hace `if (!mapa[k]) mapa[k]=canonico` para equivalencias (productos primero,
--    equiv después). El distinct on (k) order by k, canon_id de mapa_u NO garantiza ese orden de prioridad exacto
--    si un mismo código apareciera como producto Y como equivalencia con canónicos distintos (caso inválido por
--    la regla "1 cb → 1 canónico"). En datos válidos coincide. RIESGO BAJO.
--
-- I) productosTotal — GAS usa `productos.length` = TODAS las filas de PRODUCTOS_MASTER (sin filtrar estado) en el
--    dashboard. Replicado con count(*) de mos.productos completo (no filtra estado), a diferencia de
--    catalogo_stock_resumen que SÍ filtra activos (paridad con cada impl respectiva).
--
-- J) VENCIMIENTOS — GAS: dias = floor((Date(fechaVto) - hoy)/86400000) con hoy = `new Date()` (instante actual,
--    no medianoche). Aquí uso (fechaVto::date Lima) - hoy::date Lima, diferencia entera de días de calendario.
--    ⚠️ DIVERGENCIA DE BORDE: para un lote que vence "hoy a las 23h" el GAS daría dias=0 (cuenta como crítico),
--    aquí también 0. Para uno que vence "mañana a las 1am" GAS daría 0 (menos de 24h → floor=0), aquí daría 1.
--    Diferencia de a lo más 1 en el umbral exacto (7/30). Impacto: un lote en el borde podría caer en
--    crítico↔alerta o alerta↔fuera. RIESGO BAJO (los umbrales son holgados). Si se exige paridad al instante,
--    cambiar a floor((l.fecha_vencimiento - now())/interval '1 day').
--
-- K) EFICIENCIA / MERMAS / STOCK numéricos — emitidos como número JSON (paridad con _sheetToObjects → Number).
--    rotacionDia/round(.,1) ≡ Math.round(x*10)/10. stockValor/mermasMes redondeados a 2 (Math.round(x*100)/100).
--    eficienciaPromedio = avg o null (GAS: null si no hubo envasados con eficiencia) — paridad. timestamp ISO Z.
--
-- L) CACHE — el GAS cachea (catalogoStockResumen 180s, dashboard 300s) vía CacheService. Aquí NO hay cache: la
--    RPC computa en vivo cada llamada (Postgres es rápido para estos agregados). El front puede cachear su lado.
--    NO es una divergencia de datos, solo de latencia/costo. STABLE permite reuso dentro de una misma query.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
