-- 428 · [catálogo v4] FIX resolución de analitica_producto (bug preexistente destapado):
-- sku_base es código de grupo, no id del padre — el climb anulaba v_prod (2373 productos afectados).
-- Generado por patch quirúrgico sobre pg_get_functiondef (solo cambió el bloque de resolución).
CREATE OR REPLACE FUNCTION mos.analitica_producto(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id_in    text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_cb_in    text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_sku_in   text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_dias     int;
  v_desde    date;
  v_hoy      date := (now() at time zone 'America/Lima')::date;

  v_prod     mos.productos%rowtype;
  v_sku_base text;
  v_costo    numeric;
  v_precio   numeric;

  v_total_u  numeric := 0;
  v_total_i  numeric := 0;
  v_me_ok    boolean := false;
  v_wh_ok    boolean := false;
  v_stock    numeric := 0;

  v_data     jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- Requiere al menos un identificador (paridad: !idProducto && !codigoBarra && !skuBase → error).
  if v_id_in is null and v_cb_in is null and v_sku_in is null then
    return jsonb_build_object('ok', false, 'error', 'Requiere idProducto');
  end if;

  -- dias = parseInt(params.dias) || 30. Clamp defensivo.
  v_dias := coalesce(nullif(btrim(coalesce(p->>'dias','')), '')::int, 30);
  if v_dias is null or v_dias <= 0 then v_dias := 30; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  -- GAS: desde = hoy - dias*86400000 (ms); aquí corte por DÍA Lima (= hoy - dias). Borde ≤1 día parcial (ver NOTA G).
  v_desde := v_hoy - v_dias;

  -- ── Resolver el producto (réplica del orden del GAS) ──────────────────────────────────────────
  -- 1) por idProducto; si es presentación (skuBase distinto del id) subir al base.
  if v_id_in is not null then
    select * into v_prod from mos.productos where id_producto = v_id_in limit 1;
    -- [428 FIX catálogo v4] el climb viejo asumía sku_base = id del padre; en la data real
    -- sku_base es el CÓDIGO DE GRUPO (ej LEV149) → el select vacío ANULABA v_prod y devolvía
    -- 'Producto no encontrado' para 2373 productos. Ahora: solo sube si es PRESENTACIÓN,
    -- busca el CANÓNICO del grupo, y si no lo halla CONSERVA el producto original.
    if found and coalesce(nullif(v_prod.factor_conversion,0),1) <> 1
       and coalesce(nullif(btrim(v_prod.codigo_producto_base),''),'') = ''
       and nullif(btrim(v_prod.sku_base),'') is not null then
      declare v_base428 mos.productos%rowtype;
      begin
        select * into v_base428 from mos.productos
         where (id_producto = v_prod.sku_base or nullif(btrim(sku_base),'') = v_prod.sku_base)
           and coalesce(nullif(factor_conversion,0),1) = 1
           and coalesce(nullif(btrim(codigo_producto_base),''),'') = ''
         order by (id_producto = v_prod.sku_base) desc, id_producto limit 1;
        if v_base428.id_producto is not null then v_prod := v_base428; end if;
      end;
    end if;
  end if;
  -- 2) si no hubo match y hay codigoBarra, por codigoBarra.
  if v_prod.id_producto is null and v_cb_in is not null then
    select * into v_prod from mos.productos where codigo_barra = v_cb_in limit 1;
  end if;
  -- 3) (extensión defensiva — el GAS solo prueba idProducto/codigoBarra, pero acepta skuBase como param)
  --    si aún no hay match y vino skuBase, resolver el producto base de ese sku.
  if v_prod.id_producto is null and v_sku_in is not null then
    select * into v_prod from mos.productos
     where id_producto = v_sku_in
        or (nullif(btrim(sku_base),'') = v_sku_in)
     order by (id_producto = v_sku_in) desc, id_producto
     limit 1;
  end if;

  if v_prod.id_producto is null then
    return jsonb_build_object('ok', false, 'error', 'Producto no encontrado');
  end if;

  v_sku_base := coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto);  -- GAS: prod.skuBase || prod.idProducto
  v_costo    := coalesce(v_prod.precio_costo, 0);
  v_precio   := coalesce(v_prod.precio_venta, 0);

  -- ── Grupo: todos los codigosBarra del grupo (base + presentaciones). GAS: productos donde
  --    skuBase===skuBase OR idProducto===skuBase → map(codigoBarra) filter Boolean. ─────────────
  with
  grupo_prod as (
    select pr.id_producto, nullif(btrim(pr.codigo_barra),'') as cb
    from mos.productos pr
    where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku_base
       or pr.id_producto = v_sku_base
  ),
  -- cbGrupo del GAS = solo codigoBarra de presentaciones (NO incluye equivalencias). Replicado fiel:
  cb_grupo as (
    select distinct cb from grupo_prod where cb is not null
  ),
  -- ── VENTAS N días: cabeceras no anuladas en rango → mapa id_venta→fecha; detalle match por
  --    SKU===skuBase OR cbGrupo contiene Cod_Barras OR cbGrupo contiene SKU. (GAS exacto.) ──────
  cab as (
    select v.id_venta, (v.fecha at time zone 'America/Lima')::date as f
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      -- ⚠ GAS analitica filtra anulación por FormaPago !== 'ANULADO' (NO Estado_Envio). Ver NOTA A.
      and upper(coalesce(v.forma_pago,'')) <> 'ANULADO'
  ),
  det as (
    select c.f as fecha,
           coalesce(d.cantidad, 0)::numeric as qty,
           -- precio = Precio || prod.precioVenta; subtotal = Subtotal || qty*precio
           coalesce(d.subtotal, coalesce(d.cantidad,0) * coalesce(d.precio, v_precio))::numeric as imp
    from me.ventas_detalle d
    join cab c on c.id_venta = d.id_venta
    where (
            nullif(btrim(d.sku),'') = v_sku_base
         or nullif(btrim(d.cod_barras),'') in (select cb from cb_grupo)
         or nullif(btrim(d.sku),'')        in (select cb from cb_grupo)
          )
  ),
  ventas_dia as (
    select fecha, sum(qty) as u, sum(imp) as imp
    from det group by fecha
  )
  select coalesce(sum(u),0), coalesce(sum(imp),0), (count(*) >= 0)
    into v_total_u, v_total_i, v_me_ok
  from ventas_dia;
  -- meConectado: el GAS lo pone true al leer las hojas ME. La sombra siempre "existe" → true.
  v_me_ok := true;

  -- ── STOCK desde wh.stock: GAS filtra getStockWarehouse por codigoProducto===idProducto OR
  --    skuBase===skuBase. wh.stock NO tiene zona → "zonas" = filas de stock del grupo. ─────────
  v_wh_ok := true;
  select coalesce(sum(coalesce(s.cantidad_disponible,0)),0)
    into v_stock
  from wh.stock s
  where s.cod_producto = v_prod.id_producto
     or s.cod_producto in (
          select pr.id_producto from mos.productos pr
          where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku_base
        );

  -- ── ENSAMBLE del data (mismo árbol que el return del GAS) ──────────────────────────────────────
  with
  grupo_prod as (
    select pr.id_producto from mos.productos pr
    where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku_base
       or pr.id_producto = v_sku_base
  ),
  cb_grupo as (
    select distinct nullif(btrim(pr.codigo_barra),'') as cb
    from mos.productos pr
    where (coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku_base or pr.id_producto = v_sku_base)
      and nullif(btrim(pr.codigo_barra),'') is not null
  ),
  -- serie de ventas (re-derivada para el JSON, idéntico filtro que arriba)
  cab as (
    select v.id_venta, (v.fecha at time zone 'America/Lima')::date as f
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      and upper(coalesce(v.forma_pago,'')) <> 'ANULADO'
  ),
  det as (
    select c.f as fecha,
           coalesce(d.cantidad,0)::numeric as qty,
           coalesce(d.subtotal, coalesce(d.cantidad,0) * coalesce(d.precio, v_precio))::numeric as imp
    from me.ventas_detalle d
    join cab c on c.id_venta = d.id_venta
    where ( nullif(btrim(d.sku),'') = v_sku_base
         or nullif(btrim(d.cod_barras),'') in (select cb from cb_grupo)
         or nullif(btrim(d.sku),'')        in (select cb from cb_grupo) )
  ),
  ventas_dia as (
    select fecha, sum(qty) as u, sum(imp) as imp from det group by fecha
  ),
  -- serie completa con ceros para los `dias` días [desde .. desde+dias-1] (GAS: for d in 0..dias).
  serie as (
    select gs::date as f,
           coalesce(vd.u, 0)   as u,
           coalesce(vd.imp, 0) as imp
    from generate_series(v_desde, v_desde + (v_dias - 1), interval '1 day') gs
    left join ventas_dia vd on vd.fecha = gs::date
    order by gs
  ),
  serie_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'fecha', to_char(s.f,'YYYY-MM-DD'), 'u', s.u, 'imp', s.imp
           ) order by s.f), '[]'::jsonb) as arr
    from serie s
  ),
  -- zonas de stock (filas de wh.stock del grupo) — paridad: stockRes.data.filter(...).
  stock_zonas as (
    select jsonb_build_object(
             'codigoProducto', s.cod_producto,
             'cantidadDisponible', coalesce(s.cantidad_disponible,0)
           ) as z
    from wh.stock s
    where s.cod_producto = v_prod.id_producto
       or s.cod_producto in (select id_producto from grupo_prod)
  ),
  stock_zonas_json as (
    select coalesce(jsonb_agg(z), '[]'::jsonb) as arr from stock_zonas
  ),
  -- historial de precios: el GAS filtra por (idProducto OR skuBase). mos.historial_precios NO tiene
  -- id_producto (04:42) → matcheamos por sku_base = skuBase (rama principal) y, como proxy del idProducto,
  -- por codigo_barra = prod.codigo_barra. Ver NOTA P. Orden fecha asc, últimas 20.
  hist_rows as (
    select h.fecha, h.precio_anterior, h.precio_nuevo, h.usuario, h.motivo, h.sku_base, h.codigo_barra
    from mos.historial_precios h
    where coalesce(nullif(btrim(h.sku_base),''),'') = v_sku_base
       or coalesce(nullif(btrim(h.codigo_barra),''),'') = coalesce(v_prod.codigo_barra,'__none__')
    order by h.fecha asc nulls first
  ),
  hist_last20 as (
    select * from (
      select hr.*, row_number() over (order by hr.fecha asc nulls first) as rn,
             count(*) over () as tot
      from hist_rows hr
    ) z where z.rn > greatest(z.tot - 20, 0)
    order by z.fecha asc nulls first
  ),
  hist_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'fecha', to_char(h.fecha at time zone 'America/Lima','YYYY-MM-DD'),
             'precioAnterior', h.precio_anterior,
             'precioNuevo', h.precio_nuevo,
             'usuario', h.usuario,
             'motivo', h.motivo,
             'skuBase', h.sku_base,
             'codigoBarra', h.codigo_barra
           ) order by h.fecha asc nulls first), '[]'::jsonb) as arr
    from hist_last20 h
  ),
  -- pedidos de proveedor que incluyen el producto: items jsonb → buscar item con
  -- idProducto===prod.idProducto OR skuBase===skuBase OR codigoBarra ∈ cbGrupo.
  ped as (
    select pp.id_pedido, pp.id_proveedor, pp.estado,
           (pp.fecha_creacion at time zone 'America/Lima')::date as fecha,
           it.item
    from mos.pedidos_proveedor pp
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(pp.items) = 'array' then pp.items else '[]'::jsonb end
    ) as it(item)
    where (it.item->>'idProducto') = v_prod.id_producto
       or (it.item->>'skuBase')    = v_sku_base
       or (it.item->>'codigoBarra') in (select cb from cb_grupo)
  ),
  ped_norm as (
    select id_pedido, id_proveedor, estado, fecha,
           coalesce((item->>'cantidad')::numeric, 0) as cantidad,
           coalesce(
             (item->>'costoUnitario')::numeric,
             (item->>'costo')::numeric,
             (item->>'precio')::numeric, 0) as costo
    from ped
  ),
  ped_top20 as (
    select * from ped_norm order by fecha desc nulls last limit 20
  ),
  ped_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'idPedido', pn.id_pedido,
             'idProveedor', pn.id_proveedor,
             'fecha', to_char(pn.fecha,'YYYY-MM-DD'),
             'cantidad', pn.cantidad,
             'costo', pn.costo,
             'estado', pn.estado
           ) order by pn.fecha desc nulls last), '[]'::jsonb) as arr
    from ped_top20 pn
  ),
  prov_json as (
    select coalesce(jsonb_agg(distinct jsonb_build_object(
             'idProveedor', pr.id_proveedor,
             'nombre', pr.nombre,
             'formaPago', pr.forma_pago
           )), '[]'::jsonb) as arr
    from mos.proveedores pr
    where pr.id_proveedor in (select distinct id_proveedor from ped_norm where id_proveedor is not null)
  )
  select jsonb_build_object(
    'producto', jsonb_build_object(
      'idProducto',  v_prod.id_producto,
      'descripcion', coalesce(nullif(v_prod.descripcion,''), '—'),
      'codigoBarra', coalesce(v_prod.codigo_barra,''),
      'skuBase',     v_sku_base,
      'precioVenta', v_precio,
      'precioCosto', v_costo,
      'stockMinimo', coalesce(v_prod.stock_minimo,0),
      'stockMaximo', coalesce(v_prod.stock_maximo,0),
      'unidad',      coalesce(nullif(v_prod.unidad,''), 'UND'),
      'idCategoria', coalesce(v_prod.id_categoria,'')
    ),
    'periodo', jsonb_build_object('dias', v_dias, 'desde', to_char(v_desde,'YYYY-MM-DD')),
    'ventas', jsonb_build_object(
      'serie',         (select arr from serie_json),
      'totalUnidades', v_total_u,
      'totalImporte',  v_total_i,
      'promDia',       case when v_dias > 0 then v_total_u / v_dias else 0 end
    ),
    'stock', jsonb_build_object(
      'total',  v_stock,
      'zonas',  (select arr from stock_zonas_json),
      'minimo', coalesce(v_prod.stock_minimo,0),
      'maximo', coalesce(v_prod.stock_maximo,0)
    ),
    'financiero', jsonb_build_object(
      'margenPct',     case when v_precio > 0 then (v_precio - v_costo) / v_precio * 100 else 0 end,
      'utilidadBruta', v_total_i - v_total_u * v_costo,
      'precioVenta',   v_precio,
      'precioCosto',   v_costo
    ),
    'compras', jsonb_build_object(
      'pedidos',     (select arr from ped_json),
      'proveedores', (select arr from prov_json)
    ),
    'historialPrecios', (select arr from hist_json),
    'proyeccion', jsonb_build_object(
      'promDia',        case when v_dias > 0 then v_total_u / v_dias else 0 end,
      'unidades30dias', ceil((case when v_dias > 0 then v_total_u / v_dias else 0 end) * 30)::int,
      'coberturaDias',  case when (case when v_dias>0 then v_total_u/v_dias else 0 end) > 0
                             then round(v_stock / (v_total_u / v_dias))::int else null end,
      'sugerirComprar', greatest(0, ceil((case when v_dias>0 then v_total_u/v_dias else 0 end) * 30)::int - v_stock)
    ),
    'conexiones', jsonb_build_object('me', v_me_ok, 'wh', v_wh_ok)
  )
  into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$function$
;
