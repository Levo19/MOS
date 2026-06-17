-- ============================================================
-- 119_mos_computados.sql — [MIGRACIÓN MOS · FASE 2 · VISTAS COMPUTADAS CROSS-APP · INERTE]
-- Porta a RPC Supabase los getters COMPUTADOS de MOS que cruzan apps (mos + wh + me):
--   · mos.resumen_todos_dia(p jsonb {fecha})   ← getResumenTodosDia (gas/Evaluaciones.gs:829)  [DINERO]
--   · mos.analitica_producto(p jsonb {...})     ← getAnaliticaProducto (gas/Conexiones.gs:267)
--
-- ⚠️ INERTE / NO-APLICAR-AUN: este archivo SOLO define RPCs con su grant. NADIE las llama todavía
--    (el wiring de read-paths + flip de flags es tanda posterior). MOS sigue 100% por GAS. Idéntico
--    patrón inerte que 93/94/109/110/113.
--
-- ── QUÉ SE PORTA Y QUÉ NO (honestidad 40x · ver bloque NOTAS al final) ──────────────────────────────
--   ✅ mos.analitica_producto  — PORTABLE COMPLETA. Todas las fuentes existen en Supabase
--      (mos.productos/equivalencias/historial_precios/pedidos_proveedor/proveedores + me.ventas/
--      ventas_detalle + wh.stock). Shape paritario 1:1 con getAnaliticaProducto.data.
--   ⚠️ mos.resumen_todos_dia   — DINERO. Se construye REUSANDO mos.resumen_dia (93), que YA porta y validó
--      el cómputo de dinero (montoBase/pagoEnvasado/bonoMeta) + KPIs (ventasReales/envasados/metaVenta/
--      zonaPrincipal) con paridad EXACTA. Aquí solo se envuelve para "TODAS las personas del día". PERO:
--      el getResumenTodosDia del GAS arma cada fila con getResumenDia(...).data COMPLETO (scoreFinal,
--      bonusScore, manual.{limpieza,checks,comentarios}, sancion/bonificacion+detalles, totalDia, metaPct,
--      evaluacionesCount), MÁS personas VIRTUALES "MEX:<nombre>" para vendedores ME sin master, MÁS un
--      cruce con LIQUIDACIONES_DIA para liqEstado/vetada. Esos campos NO los computa mos.resumen_dia.
--      → mos.resumen_todos_dia entrega EL SUBSET DE DINERO+KPIs con paridad exacta; los campos de UI
--        (score/manual/sanción/bonificación/virtuals/liqEstado) quedan PENDIENTES = REQUIERE SESIÓN
--        DEDICADA (portar getResumenDia COMPLETO + _calcularKpisAutoDia auditPct + selección por evidencia
--        + virtuales + cruce LIQUIDACIONES_DIA). Ver NOTA R.
--   ❌ getEcoStatus  — NO SE PORTA. REQUIERE SESIÓN DEDICADA. Razón dura: depende de ZONAS_CONFIG (que NO
--      está migrada — 02_schema_me.sql:352 dice explícitamente que se reconstruirá como VISTA sobre
--      mos.estaciones/series en Fase 2), del parseo correlativo→serie→zona, y de strings de tiempo
--      relativo ("hace N min"). Sin ZONAS_CONFIG no hay mapa serie→zona ni estación→zona → el desglose
--      por zona (que es el corazón del semáforo) no es reproducible con paridad. Ver NOTA E.
--
-- ── GATE + ENVOLTORIO (igual que 113) ────────────────────────────────────────────────────────────────
--   mos._claim_ok()        (74)  — service_role/GAS o claim app='MOS'; otro → APP_NO_AUTORIZADA.
--   mos._frescura_sombra() (94)  — agrega _heartbeat/_now/_ttl_min/_fresh al envoltorio.
--   TZ America/Lima en todos los cortes de fecha. camelCase paritario. revoke public + grant
--   service_role+authenticated.
-- ============================================================

create schema if not exists mos;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) mos.analitica_producto(p jsonb) — p = { idProducto | codigoBarra | skuBase, dias (opc int, default 30) }
--    Espeja getAnaliticaProducto (Conexiones.gs:267). Resuelve el producto (preferencia idProducto → subir a
--    base por skuBase → codigoBarra), arma el GRUPO de códigos (base + presentaciones + equivalencias), suma
--    ventas N días desde me.ventas_detalle (cruce por id_venta con cabecera no-anulada), serie diaria con ceros,
--    stock total desde wh.stock, historial de precios (últimos 20), pedidos de proveedor que incluyen el sku,
--    proyección y rentabilidad. Shape paritario con getAnaliticaProducto.data.
--    Envoltorio: { ok:true, data:{...} } || _frescura_sombra().
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.analitica_producto(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
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
    if found and nullif(btrim(v_prod.sku_base),'') is not null and v_prod.sku_base <> v_prod.id_producto then
      select * into v_prod from mos.productos where id_producto = v_prod.sku_base limit 1;
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
$fn$;

revoke all on function mos.analitica_producto(jsonb) from public;
grant execute on function mos.analitica_producto(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) mos.resumen_todos_dia(p jsonb) — p = { fecha (opc 'YYYY-MM-DD', default hoy Lima) }
--    Espeja getResumenTodosDia (Evaluaciones.gs:829) ⚠ SOLO EN SU SUBSET DE DINERO+KPIs (ver cabecera + NOTA R).
--    Reusa mos.resumen_dia(p_fecha, NULL) — que calcula montoBase/pagoEnvasado/bonoMeta + ventasReales/
--    envasados/metaVenta/zonaPrincipal/presente/auditado para TODO el personal evaluable con paridad EXACTA.
--    Aquí se FILTRA a `presente=true` para emular "personal del día" (el GAS solo lista a quien tiene evidencia
--    operativa real del día: sesión WH o caja/venta ME). Las personas evaluables sin actividad NO salen.
--    Shape data = array de objetos resumen_dia (idPersonal/nombre/rol/appOrigen/presente/auditado/
--    aplicaBonoMeta/ventasReales/envasados/metaVenta/zonaPrincipal/montoBase/pagoEnvasado/bonoMeta/tarifaEnvasado).
--    PENDIENTE (no portado, requiere sesión dedicada): scoreFinal, bonusScore, manual.*, sancion/bonificacion,
--    totalDia, metaPct, evaluacionesCount, personas VIRTUALES "MEX:<nombre>", y cruce liqEstado/vetada con
--    LIQUIDACIONES_DIA. Ver NOTA R.
--    Envoltorio: { ok:true, fecha, _parcial:true, data:[...] } || _frescura_sombra().
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.resumen_todos_dia(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_fecha date := coalesce(nullif(btrim(coalesce(p->>'fecha','')), '')::date, (now() at time zone 'America/Lima')::date);
  v_rd    jsonb;
  v_data  jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- Reusar el motor de dinero ya validado: resumen_dia para TODAS las personas (p_id_personal = NULL).
  -- mos.resumen_dia ya aplica el gate internamente; aquí ya pasamos el nuestro, no duplica riesgo.
  v_rd := mos.resumen_dia(v_fecha, null);

  -- Si resumen_dia falló (p.ej. gate), propagar.
  if coalesce((v_rd->>'ok')::boolean, false) is not true then
    return v_rd;
  end if;

  -- Filtrar a presente=true (emular "personal del día" por evidencia operativa real).
  select coalesce(jsonb_agg(elem order by elem->>'idPersonal'), '[]'::jsonb)
    into v_data
  from jsonb_array_elements(coalesce(v_rd->'data','[]'::jsonb)) as elem
  where coalesce((elem->>'presente')::boolean, false) = true;

  return jsonb_build_object(
    'ok', true,
    'fecha', to_char(v_fecha,'YYYY-MM-DD'),
    -- _parcial: bandera HONESTA — esta RPC entrega el subset de dinero+KPIs, NO el shape UI completo de
    -- getResumenTodosDia. El read-path debe tratarla como tal (o caer a GAS) hasta portar lo pendiente.
    '_parcial', true,
    'data', v_data
  ) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.resumen_todos_dia(jsonb) from public;
grant execute on function mos.resumen_todos_dia(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTAS DE PARIDAD / DIVERGENCIAS / GAPS (honestidad 40x)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- A) ANULACIÓN — analitica_producto: el GAS de getAnaliticaProducto filtra por FormaPago !== 'ANULADO'
--    (NO Estado_Envio), distinto de getRotacionProductos/_getCatalogoStockResumenImpl que miran Estado_Envio
--    (ver 113 NOTA E). Aquí replicamos EXACTO lo de analitica: upper(forma_pago) <> 'ANULADO'. Ojo si en el
--    futuro se unifica el criterio de anulación del ecosistema: este filtro debe seguir al GAS de SU getter.
--
-- P) HISTORIAL_PRECIOS — mos.historial_precios NO tiene columna id_producto; el GAS filtra HISTORIAL_PRECIOS
--    por (h.idProducto === prod.idProducto OR h.skuBase === skuBase). La tabla migrada solo tiene sku_base y
--    codigo_barra (04:42-53). Replicamos el match por sku_base = skuBase (rama principal del GAS) Y, como
--    proxy del idProducto, por codigo_barra = prod.codigo_barra. RIESGO BAJO: en la práctica el historial se
--    escribe con sku_base (ver 12_fase1d_mos_historial / 77). La rama idProducto del GAS (h.idProducto ===
--    prod.idProducto) NO tiene equivalente directo de columna; el match por codigo_barra del producto base la
--    aproxima. Si se quisiera cubrir también presentaciones, ampliar a codigo_barra IN (cbGrupo).
--
-- G) VENTANA DE VENTAS — analitica usa corte por DÍA Lima (fecha::date >= hoy - dias); el GAS usa
--    `desde = new Date(hoy - dias*86400000)` (corte por ms) y arma la serie con `dias` puntos. La serie aquí
--    cubre [desde .. desde+dias-1] = exactamente `dias` días, igual que el for del GAS. Diferencia ≤1 día
--    parcial en el borde inferior (mismo criterio que 113 NOTA G). RIESGO BAJO.
--
-- S) STOCK SIN ZONA — wh.stock no tiene dimensión de zona (03:63). El GAS `stock.zonas` es simplemente las
--    filas de getStockWarehouse que matchean el producto/grupo. Aquí stock_zonas emite { codigoProducto,
--    cantidadDisponible } por fila de wh.stock del grupo — coherente con que la sombra no modela zonas de WH.
--    `total` = suma. PARIDAD razonable (la app no usa zonas de WH para este panel).
--
-- C) FRESCURA DE SOMBRA — me.ventas/ventas_detalle y wh.stock son SOMBRAS del sync GAS→Supabase. _frescura_
--    sombra() expone _fresh para que el front decida caer a GAS. El GAS siempre ve "fresco" (lee hoja en vivo).
--    Antes del cutover de analitica/resumen, el sync de esas tablas DEBE estar vivo.
--
-- R) resumen_todos_dia — SUBSET DE DINERO, NO PARIDAD UI COMPLETA. Lo que SÍ es exacto (reusa mos.resumen_dia,
--    validado 40x + 100x en 93): montoBase, pagoEnvasado, bonoMeta, ventasReales, envasados, metaVenta,
--    zonaPrincipal, presente, auditado, aplicaBonoMeta. Lo PENDIENTE (= REQUIERE SESIÓN DEDICADA):
--      1. getResumenDia COMPLETO por persona: scoreFinal (pondera ventasPct/auditPct/limpieza/control),
--         bonusScore, manual.{limpiezaPct,limpiezaProfPct,checksAcum,controlPct,comentarios}, sancion+detalles,
--         bonificacion+detalles, totalDia, metaPct, evaluacionesCount, tarifaDiaria. Requiere portar
--         _calcularKpisAutoDia.auditPct (lee me.auditorias / wh.auditorias con match por nombre) y _getEvalConfig
--         pesos — NO trivial y es money-display.
--      2. SELECCIÓN del día por EVIDENCIA + VIRTUALES: el GAS lista WH-por-sesión + ME-por-caja/venta, y crea
--         personas virtuales "MEX:<nombre>" para vendedores ME que no están en master (con montoBase del
--         genérico ME por rol). Aquí solo filtramos presente=true sobre personal REAL → NO genera virtuales.
--         Un vendedor ME sin master NO aparece (el GAS sí lo muestra). DIVERGENCIA de cardinalidad.
--      3. liqEstado / vetada: el GAS cruza con LIQUIDACIONES_DIA por (idPersonal, fecha) y marca
--         liqEstado (PENDIENTE/PAGADA/VETADA) + vetada=true. No portado aquí (hay mos.liquidaciones_dia en
--         114, pero el cruce + overlay vetada es UI y no se cableó).
--    ⇒ Esta RPC es segura para alimentar TOTALES de dinero del día por persona, NO para reemplazar el panel
--      Personal del Día tal cual. La bandera _parcial:true lo señaliza. Recomendación: el flip de Personal del
--      Día se hace en sesión dedicada que porte getResumenDia completo (incluido auditPct/score) + virtuales +
--      liqEstado. Mientras tanto, ese panel sigue por GAS.
--
-- E) getEcoStatus — NO PORTADO · REQUIERE SESIÓN DEDICADA. Bloqueador duro: ZONAS_CONFIG (la fuente del mapa
--    serie→zona y estación→zona, que vive en la hoja de ME) NO está migrada a Supabase. 02_schema_me.sql:352
--    lo dice explícito: "ZONAS_CONFIG: NO se crea como tabla — es derivada del catálogo MOS. En Fase 2 se
--    reconstruye como VISTA sobre mos.estaciones/impresoras/series." El semáforo de getEcoStatus depende de:
--      · _zonaDeCorrelativo(corr): split('-')[0] → serieZonaMap[serie]  (necesita Serie_Nota/Boleta/Factura→zona)
--      · estZonaMap[estacion] → zona  (necesita Estacion_Nombre→zona)
--      · agrupar ventas/personal/cajas por zona, "última venta hace N min" (string relativo al now del request)
--    Sin ZONAS_CONFIG (o su vista equivalente sobre mos.series_documentales + mos.estaciones) NO hay paridad
--    confiable del desglose por zona, que es el corazón del panel. Construirlo a medias (sin zonas, o con un
--    mapeo inventado) sería peor que dejarlo en GAS. ⇒ Se difiere a sesión dedicada que primero materialice la
--    vista ZONAS_CONFIG sobre mos.* (series por estacion/zona) y luego arme el semáforo. El resto del cómputo
--    (guías WH del día por tipo ENTRADA/INGRESO vs salida, sesión ACTIVA, stockCritico = stock < mínimo, ventas
--    del día totales) SÍ es portable y puede reaprovechar wh.guias/wh.sesiones/wh.stock + me.ventas/me.cajas.
--
-- ROTACIÓN — getRotacion / getRotacionProductos (Conexiones.gs:201) YA está portado como mos.rotacion_productos
--    en 113_mos_vistas_wh_agregados.sql (línea 44). Es LA MISMA función (mismo cómputo: stock WH × ventas del
--    mes ME → díasCobertura, una fila por row de stock, orden por menor cobertura). ⇒ REDUNDANTE: NO se
--    re-crea aquí. Si el read-path necesita rotación, debe llamar mos.rotacion_productos (113).
--
-- ── RIESGOS / ACCIÓN REQUERIDA ANTES DE APLICAR ────────────────────────────────────────────────────────────
--   RIESGO 1 (paridad historial · analitica): el match de HISTORIAL_PRECIOS aproxima la rama idProducto del
--     GAS con codigo_barra=prod.codigo_barra (mos.historial_precios no tiene id_producto). En datos reales el
--     historial se escribe por sku_base → cobertura efectiva alta. VERIFICAR si algún histórico legacy se
--     escribió solo por codigo_barra de presentación (entonces ampliar a cbGrupo). Ver NOTA P.
--   RIESGO 2 (paridad dinero · resumen_todos_dia): es PARCIAL por diseño (_parcial:true). NO cablear al panel
--     Personal del Día como reemplazo 1:1 — solo para totales de dinero por persona presente. Ver NOTA R.
--   RIESGO 3 (frescura): ambas RPC leen sombras me.*/wh.*; exigir _fresh antes del cutover (NOTA C).
--   RIESGO 4 (resumen_todos_dia llama a otra RPC definer): mos.resumen_todos_dia invoca mos.resumen_dia, que
--     re-evalúa su propio gate mos._claim_ok(). Doble gate (inofensivo). search_path='' en ambas → el call
--     calificado mos.resumen_dia resuelve sin depender de search_path. OK.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
