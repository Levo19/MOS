-- 117_mos_vistas_almacen.sql — [MIGRACIÓN MOS · FASE 2 · LECTURA-ALMACÉN CROSS-APP (WH+ME)]
-- Replica con PARIDAD razonable las 7 vistas/agregados de ALMACÉN que MOS calcula hoy en GAS:
--   · mos.stock_unificado(p)       ← getStockUnificado     → _getStockUnificadoImpl     (gas/Almacen.gs:528/537)
--   · mos.insights_stock(p)        ← getInsightsStock       → _getInsightsStockImpl       (Almacen.gs:2774/2780)
--   · mos.ranking_zonas(p)         ← getRankingZonas        → _getRankingZonasImpl        (Almacen.gs:2303/2309)
--   · mos.productos_sin_venta(p)   ← getProductosSinVenta   → _getProductosSinVentaImpl   (Almacen.gs:2398/2404)
--   · mos.alertas_operativas(p)    ← getAlertasOperativas   → _getAlertasOperativasImpl   (Almacen.gs:2493/2498)
--   · mos.guias_y_preingresos(p)   ← getGuiasYPreingresos   → _getGuiasYPreingresosImpl   (Almacen.gs:802/808)
--   · mos.operaciones_unificadas(p)← getOperacionesUnificadas→ _getOperacionesUnificadasImpl(Almacen.gs:858/865)
--
-- ⚠️ INERTE / NO-APLICAR-AUN: este archivo SOLO define las RPCs con su grant. NADIE las llama todavía (el
--    wiring de js/api.js read-paths + el flip de flags es tanda posterior). MOS sigue 100% por GAS. Este SQL
--    NO toca flags, NO toca sync, NO cablea frontend. Idéntico patrón inerte que 94/98/105/106/107/109/112/113.
--
-- ── FUENTES CRUZADAS (todas verificadas que existen en Supabase, salvo el GAP de PROVEEDORES WH; ver NOTAS) ──
--   · wh.stock              (03_schema_wh.sql:63)  — cod_producto / cantidad_disponible / ultima_actualizacion.
--   · wh.lotes_vencimiento  (03:84)  — cod_producto / fecha_vencimiento / cantidad_actual.
--   · wh.guias              (03:20)  — id_guia / tipo / fecha / usuario / id_proveedor / id_zona / numero_documento /
--                                       comentario / monto_total / estado / id_preingreso / foto.
--   · wh.preingresos        (03:163) — id_preingreso / fecha / id_proveedor / cargadores / usuario / monto / fotos /
--                                       comentario / estado / id_guia.
--   · me.stock_zonas        (02_schema_me.sql:254) — cod_barras / zona_id / cantidad.
--   · me.ventas (02:16) + me.ventas_detalle (02:51) — ventas en rango (estado_envio / estacion / total / fecha;
--                                       sku / cod_barras / cantidad).  ⚠ El GAS usa `estacion` (col idx 3) como zona-raw,
--                                       NO la columna zona_id de la sombra. Replicamos `estacion` (paridad fiel).
--   · me.guias_cabecera     (02:118) — id_guia / fecha / vendedor / zona_id / tipo / observacion / zona_destino / estado.
--   · mos.productos         (01:43)  — catálogo: sku_base / codigo_barra / descripcion / precio_venta / precio_costo /
--                                       stock_minimo / stock_maximo / codigo_producto_base / factor_conversion / estado.
--   · mos.equivalencias     (01:88)  — sku_base / codigo_barra / activo  (ampliar barrasAll de cada sku).
--   · mos.zonas (01:130) + mos.estaciones (01:141) — zona resolver + set de zonas REGISTRADAS.
--   · mos.proveedores       (04_schema_mos.sql:21) — id_proveedor / nombre  (provMap para enriquecer ops).
--
-- ── GATE + ENVOLTORIO (idéntico a 109/112/113) ──────────────────────────────────────────────────────────────
--   mos._claim_ok()        (74_mos_claim_ok_f0a.sql)  — service_role/GAS o claim app='MOS'; otro → APP_NO_AUTORIZADA.
--   mos._frescura_sombra() (94_mos_lecturas_proveedores_jornadas.sql) — agrega _heartbeat/_now/_ttl_min/_fresh.
--   TZ: America/Lima en TODOS los cortes de fecha. Este archivo NO redefine los helpers; los consume.
--
-- ── HONESTIDAD 40x — VEREDICTO POR FUNCIÓN (detalle en bloque NOTAS al final) ────────────────────────────────
--   Las 7 son PORTABLES con paridad razonable. NINGUNA quedó como "requiere sesión dedicada".
--   Caveats relevantes (NO bloqueantes, documentados):
--     · operaciones_unificadas: el GAS fusiona PROVEEDORES_MASTER(MOS) + PROVEEDORES(WH-sheet). La hoja WH
--       PROVEEDORES **NO está migrada** (03_schema_wh.sql:13 lo dice explícito). → provMap = SOLO mos.proveedores.
--       Para IDs de proveedor presentes únicamente en la hoja WH, el nombre cae al ID crudo (igual que el GAS
--       cuando el ID no está en ningún map). Es el ÚNICO gap real de FUENTE. Ver NOTA G.
--     · insights_stock (INSIGHT 2b TRASLADAR): el GAS toma `trasladosCandidatos[0]` (el PRIMER candidato según
--       orden de iteración de claves del objeto JS). Aquí se elige un candidato DETERMINISTA (mayor stock origen,
--       desempate por zid). Puede diferir EN CUÁL zona origen se sugiere si hay >1 candidato; el insight existe
--       igual. Ver NOTA H. RIESGO BAJO.
--     · Bloques `_debug` de las impls (zonasLeidasDeTablaZONAS, diagME, timezone, etc.) NO se replican: son
--       diagnóstico interno, no datos de negocio que el front consuma. Ver NOTA F.


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- HELPER LOCAL (interno a este archivo) — resolver de zona como SQL CTE reutilizable.
-- No se crea como función separada; cada RPC inlinea el patrón zona_resolver_u (idéntico al de 109) para
-- mantener cada función autocontenida y STABLE. (Replicado, no factorizado, por simplicidad de despliegue.)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) mos.stock_unificado(p) — p = { skuBase | idProducto (req), rangoDias (opc, default 7) }
--    Espeja _getStockUnificadoImpl. Detalle de UN producto: WH + zonas ME + ventas N días, por canónico/skuBase.
--    Si el código no está en catálogo MOS → respuesta degradada con solo WH (sinCatalogo:true).
--    Shape data:
--      { producto:{idProducto,skuBase,descripcion,codigoBarra,stockMinimo,stockMaximo,precioCosto,precioVenta},
--        codigosBarra:[{codigoBarra,tipo,descripcion,stockWh,stockZonas,stockTotal,porZona:{}}],
--        countEquivalencias, wh:{cantidad,detalle:[{codigoProducto,cantidad,ultimaActualizacion}]},
--        zonas:[{idZona,nombre,cantidad,ventasRango,rotacionDia,diasParaAcabar,tieneRegistroStock,
--                tieneRegistroVenta,sinStock,sinVentas}],
--        total:{cantidad,rotacionDia,ventasRango,diasParaAcabar,rangoDiasConsultado}, insights:[...] }
--    Envoltorio: { ok:true, data:{...} } || _frescura_sombra().
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

  -- prodBase: primer producto cuyo id_producto OR sku_base OR codigo_barra = v_key (orden estable por id).
  select pr.id_producto, pr.sku_base, pr.descripcion, pr.codigo_barra,
         coalesce(pr.stock_minimo,0) as stock_minimo, coalesce(pr.stock_maximo,0) as stock_maximo,
         coalesce(pr.precio_costo,0) as precio_costo, coalesce(pr.precio_venta,0) as precio_venta
    into v_prod
    from mos.productos pr
   where pr.id_producto = v_key or pr.sku_base = v_key or pr.codigo_barra = v_key
   order by (pr.id_producto = v_key) desc, pr.id_producto
   limit 1;

  -- ── Caso: NO está en catálogo MOS → degradado con solo WH (paridad: match por codigoProducto = key). ──
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
  -- ── Resolver de zona (idéntico a 109): mapea raw → canónico vía ZONAS+ESTACIONES; fallback UPPER(TRIM). ──
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

  -- ── Presentaciones del sku + barras (principales + equivalencias). barrasInfo con tipo. ──
  presentaciones as (
    select pr.id_producto, pr.codigo_barra, pr.descripcion
    from mos.productos pr
    where coalesce(nullif(pr.sku_base,''), pr.id_producto) = v_sku
  ),
  ids_pres as (select id_producto from presentaciones),
  -- barras: principales (de presentaciones) + equivalencias del sku que no estén ya como principal.
  barras_info as (
    select distinct on (cb) cb, tipo, descripcion from (
      select nullif(btrim(pr.codigo_barra),'') as cb, 'principal'::text as tipo, coalesce(pr.descripcion,'') as descripcion, 0 as ord
      from presentaciones pr where nullif(btrim(pr.codigo_barra),'') is not null
      union all
      select nullif(btrim(e.codigo_barra),'') as cb, 'equivalencia'::text as tipo, coalesce(e.descripcion,'') as descripcion, 1 as ord
      from mos.equivalencias e
      where e.sku_base = v_sku and coalesce(e.activo, true) = true and nullif(btrim(e.codigo_barra),'') is not null
    ) t order by cb, ord    -- principal gana sobre equivalencia para el mismo cb
  ),
  barras_pres as (select cb from barras_info),
  equiv_cnt as (
    select count(*) as n from mos.equivalencias e
    where e.sku_base = v_sku and coalesce(e.activo, true) = true and nullif(btrim(e.codigo_barra),'') is not null
  ),

  -- ── 1) Stock WH: filas cuyo cod_producto está en ids_pres o barras_pres. ──
  wh_rows as (
    select s.cod_producto, coalesce(s.cantidad_disponible,0) as cant, s.ultima_actualizacion
    from wh.stock s
    where s.cod_producto in (select id_producto from ids_pres)
       or s.cod_producto in (select cb from barras_pres)
  ),
  wh_total as (select coalesce(sum(cant),0) as q from wh_rows),
  wh_por_cb as (select cod_producto as cb, sum(cant) as q from wh_rows group by cod_producto),

  -- ── 2) Stock por zona (canon-resolved) — solo barras de este sku. ──
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
  zona_acum as (   -- por zona canónica: cantidad
    select zid, max(znombre) as znombre, sum(cant) as cantidad
    from sz_raw where nullif(btrim(zid),'') is not null group by zid
  ),
  sz_por_cb as (select cb, sum(cant) as q from sz_raw group by cb),
  -- matriz cb × zona
  matriz as (
    select cb, jsonb_object_agg(zid, cant) as porzona
    from (select cb, zid, sum(cant) as cant from sz_raw where nullif(btrim(zid),'') is not null group by cb, zid) m
    group by cb
  ),

  -- ── 3) Ventas N días por zona canónica (paridad: zona = `estacion` col idx 3, no anuladas, fecha>=desde). ──
  ventas_validas as (
    select v.id_venta, nullif(btrim(v.estacion),'') as estacion
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
      and nullif(btrim(v.estacion),'') is not null
  ),
  ventas_zona as (
    select r.canon_id as zid, sum(coalesce(d.cantidad,0)) as ventas
    from me.ventas_detalle d
    join ventas_validas vv on vv.id_venta = d.id_venta
    cross join lateral (
      select coalesce(zr.canon_id, upper(btrim(vv.estacion))) as canon_id
      from (select 1) _ left join zona_resolver_u zr on zr.raw = upper(btrim(vv.estacion))
    ) r
    where nullif(btrim(d.sku),'') in (select id_producto from ids_pres)
       or nullif(btrim(d.cod_barras),'') in (select cb from barras_pres)
    group by r.canon_id
  ),

  -- ── 4) Universo de zonas: TODAS las ZONAS activas + zonas con stock/ventas no registradas. ──
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
  -- ── 5) Totales ──
  tot as (
    select
      (select q from wh_total) + coalesce(sum(zc.cantidad),0)                          as total_cant,
      coalesce(sum(round(zc.rot_dia,1)),0)                                             as total_rot,  -- suma de rotDia REDONDEADO por zona (paridad: zonasArr suma rotacionDia ya redondeado)
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
      -- INSIGHT por zona: REPONER_ZONA (rot>0, cant>0, diasParaAcabar<7) + SIN_ROTACION total + BAJO_MINIMO total.
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
-- 2) mos.ranking_zonas(p) — p = { dias (opc int, default 30) }
--    Espeja _getRankingZonasImpl. Ventas ME por zona canónica REGISTRADA en MOS.ZONAS; no-registradas → bucket OTRAS.
--    Zona-raw = `estacion` (col idx 3) ; monto = `total` (col idx 6) ; anulado = estado_envio (col idx 8).
--    Incluye TODAS las zonas registradas aunque tengan 0 ventas.
--    Shape data: { _almV:2, zonas:[{idZona,nombre,ventas,tickets,ticketProm,vendedores,pctTotal}], totalVentas,
--                  totalTickets, rangoDias, ticketProm, ventasFueraDeZonasRegistradas, ticketsFueraDeZonasRegistradas }.
--    Orden: ventas desc. Envoltorio: { ok:true, data:{...} } || _frescura_sombra().
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.ranking_zonas(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_dias  int;
  v_desde date;
  v_data  jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  v_dias := coalesce(nullif(btrim(coalesce(p->>'dias','')), '')::int, 30);
  if v_dias is null or v_dias <= 0 then v_dias := 30; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  v_desde := (now() at time zone 'America/Lima')::date - v_dias;

  with
  zonas_reg as (
    select upper(btrim(z.id_zona)) as zid, coalesce(z.nombre, z.id_zona) as nombre
    from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado, true) = true
  ),
  zona_resolver as (
    select upper(btrim(z.id_zona)) as raw, upper(btrim(z.id_zona)) as canon_id, coalesce(z.nombre, z.id_zona) as canon_nombre
    from mos.zonas z where nullif(btrim(z.id_zona),'') is not null
    union select upper(btrim(z.nombre)), upper(btrim(z.id_zona)), coalesce(z.nombre, z.id_zona) from mos.zonas z where nullif(btrim(z.nombre),'') is not null
    union select upper(btrim(es.id_estacion)), upper(btrim(es.id_zona)),
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona)
           from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.id_estacion),'') is not null
    union select upper(btrim(es.nombre)), upper(btrim(es.id_zona)),
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona)
           from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.nombre),'') is not null
    union select upper(btrim(es.id_zona)), upper(btrim(es.id_zona)),
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona)
           from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null
  ),
  zona_resolver_u as (select distinct on (raw) raw, canon_id, canon_nombre from zona_resolver order by raw, canon_nombre nulls last),

  ventas as (
    select
      r.canon_id as zid,
      coalesce(v.total,0) as monto,
      nullif(btrim(v.vendedor),'') as vendedor,
      (zr.zid is not null) as registrada
    from me.ventas v
    cross join lateral (
      select coalesce(zru.canon_id, upper(btrim(v.estacion))) as canon_id
      from (select 1) _ left join zona_resolver_u zru on zru.raw = upper(btrim(v.estacion))
    ) r
    left join zonas_reg zr on zr.zid = r.canon_id
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
      and nullif(btrim(v.estacion),'') is not null
  ),
  tot as (
    select coalesce(sum(monto),0) as total_ventas, count(*)::int as total_tickets,
           coalesce(sum(monto) filter (where not registrada),0) as otras_ventas,
           count(*) filter (where not registrada)::int           as otras_tickets
    from ventas
  ),
  por_zona as (
    select zid, coalesce(sum(monto),0) as ventas, count(*)::int as tickets,
           count(distinct vendedor) filter (where vendedor is not null)::int as vendedores
    from ventas where registrada group by zid
  ),
  -- todas las registradas (aunque 0 ventas)
  filas as (
    select zr.zid, zr.nombre,
           coalesce(pz.ventas,0) as ventas, coalesce(pz.tickets,0) as tickets, coalesce(pz.vendedores,0) as vendedores
    from zonas_reg zr left join por_zona pz on pz.zid = zr.zid
  )
  select jsonb_build_object(
    '_almV', 2,
    'zonas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'idZona', f.zid, 'nombre', coalesce(f.nombre, f.zid),
        'ventas', round(f.ventas,2), 'tickets', f.tickets,
        'ticketProm', case when f.tickets > 0 then round(f.ventas / f.tickets, 2) else 0 end,
        'vendedores', f.vendedores,
        'pctTotal', case when (select total_ventas from tot) > 0 then round((f.ventas / (select total_ventas from tot)) * 1000)/10 else 0 end)
        order by f.ventas desc) from filas f), '[]'::jsonb),
    'totalVentas', round((select total_ventas from tot), 2),
    'totalTickets', (select total_tickets from tot),
    'rangoDias', v_dias,
    'ticketProm', case when (select total_tickets from tot) > 0 then round((select total_ventas from tot) / (select total_tickets from tot), 2) else 0 end,
    'ventasFueraDeZonasRegistradas', round((select otras_ventas from tot), 2),
    'ticketsFueraDeZonasRegistradas', (select otras_tickets from tot)
  ) into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.ranking_zonas(jsonb) from public;
grant execute on function mos.ranking_zonas(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) mos.productos_sin_venta(p) — p = { dias (opc int, default 30) }
--    Espeja _getProductosSinVentaImpl. Canónicos con stock en zonas (>0) y NINGUNA variante/equivalente vendida
--    en el rango. Resolución por CANÓNICO (mapaCanon). Stock por zona breakdown.
--    Shape data: { _almV:2, productos:[{idProducto,skuBase,descripcion,codigoBarra,precioVenta,stockEnZonas,
--                  breakdownZonas:[{idZona,nombre,cantidad}]}], rangoDias }.
--    Orden: stockEnZonas desc. Envoltorio: { ok:true, data:{...} } || _frescura_sombra().
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.productos_sin_venta(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_dias  int;
  v_desde date;
  v_data  jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  v_dias := coalesce(nullif(btrim(coalesce(p->>'dias','')), '')::int, 30);
  if v_dias is null or v_dias <= 0 then v_dias := 30; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  v_desde := (now() at time zone 'America/Lima')::date - v_dias;

  with
  -- ── Mapa código → canónico (id/cb del producto + equivalencias). Canónico = sin base Y factor∈{null,1}. ──
  canonicos as (
    select pr.id_producto, pr.sku_base, pr.descripcion, pr.codigo_barra, coalesce(pr.precio_venta,0) as precio_venta
    from mos.productos pr
    where coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = '' and (pr.factor_conversion is null or pr.factor_conversion = 1)
  ),
  canon_by_id  as (select upper(btrim(c.id_producto)) as k, c.id_producto from canonicos c where nullif(btrim(c.id_producto),'') is not null),
  canon_by_sku as (
    select distinct on (upper(btrim(c.sku_base))) upper(btrim(c.sku_base)) as k, c.id_producto
    from canonicos c where nullif(btrim(c.sku_base),'') is not null order by upper(btrim(c.sku_base)), c.id_producto
  ),
  prod_canon as (
    select pr.id_producto, pr.codigo_barra,
      case
        when coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = '' and (pr.factor_conversion is null or pr.factor_conversion = 1)
          then pr.id_producto
        when coalesce(nullif(btrim(pr.codigo_producto_base),''),'') <> ''
          then coalesce((select id_producto from canon_by_id where k = upper(btrim(pr.codigo_producto_base))),
                        (select id_producto from canon_by_sku where k = upper(btrim(pr.codigo_producto_base))))
        when nullif(btrim(pr.sku_base),'') is not null
          then (select id_producto from canon_by_sku where k = upper(btrim(pr.sku_base)))
        else null
      end as canon_id
    from mos.productos pr
  ),
  mapa as (
    select upper(btrim(pc.id_producto)) as k, pc.canon_id from prod_canon pc where pc.canon_id is not null and nullif(btrim(pc.id_producto),'') is not null
    union
    select upper(btrim(pc.codigo_barra)), pc.canon_id from prod_canon pc where pc.canon_id is not null and nullif(btrim(pc.codigo_barra),'') is not null
    union
    select upper(btrim(e.codigo_barra)), cbs.id_producto
    from mos.equivalencias e join canon_by_sku cbs on cbs.k = upper(btrim(e.sku_base))
    where coalesce(e.activo, true) = true and nullif(btrim(e.codigo_barra),'') is not null
  ),
  mapa_u as (select distinct on (k) k, canon_id from mapa order by k, canon_id),

  -- ── Resolver de zona ──
  zonas_reg as (
    select upper(btrim(z.id_zona)) as zid, coalesce(z.nombre, z.id_zona) as nombre from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado, true) = true
  ),
  zona_resolver as (
    select upper(btrim(z.id_zona)) as raw, upper(btrim(z.id_zona)) as canon_id, coalesce(z.nombre, z.id_zona) as canon_nombre from mos.zonas z where nullif(btrim(z.id_zona),'') is not null
    union select upper(btrim(z.nombre)), upper(btrim(z.id_zona)), coalesce(z.nombre, z.id_zona) from mos.zonas z where nullif(btrim(z.nombre),'') is not null
    union select upper(btrim(es.id_estacion)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.id_estacion),'') is not null
    union select upper(btrim(es.nombre)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.nombre),'') is not null
    union select upper(btrim(es.id_zona)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null
  ),
  zona_resolver_u as (select distinct on (raw) raw, canon_id, canon_nombre from zona_resolver order by raw, canon_nombre nulls last),

  -- ── Canónicos vendidos en rango (por sku idx1 o cb idx6 → canónico). ──
  ventas_validas as (
    select v.id_venta from me.ventas v
    where v.fecha is not null and (v.fecha at time zone 'America/Lima')::date >= v_desde and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  ),
  canon_vendidos as (
    select distinct coalesce(
      (select canon_id from mapa_u where k = upper(btrim(d.sku))),
      (select canon_id from mapa_u where k = upper(btrim(d.cod_barras)))
    ) as canon_id
    from me.ventas_detalle d join ventas_validas vv on vv.id_venta = d.id_venta
  ),

  -- ── Stock por canónico + zona (cb>0 → canónico). ──
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
  stock_por_canon as (select canon_id, sum(cant) as total from stock_raw group by canon_id),
  stock_zona_canon as (
    select canon_id, zid, max(znombre) as znombre, sum(cant) as cant
    from stock_raw where nullif(btrim(zid),'') is not null group by canon_id, zid
  )
  select jsonb_build_object(
    '_almV', 2,
    'productos', coalesce((
      select jsonb_agg(q.obj order by q.ord desc) from (
        select jsonb_build_object(
          'idProducto', c.id_producto, 'skuBase', c.sku_base, 'descripcion', c.descripcion,
          'codigoBarra', c.codigo_barra, 'precioVenta', c.precio_venta,
          'stockEnZonas', spc.total,
          'breakdownZonas', coalesce((
            select jsonb_agg(jsonb_build_object('idZona', szc.zid, 'nombre', coalesce(szc.znombre, szc.zid), 'cantidad', szc.cant) order by szc.cant desc)
            from stock_zona_canon szc where szc.canon_id = spc.canon_id), '[]'::jsonb)
        ) as obj,
        spc.total as ord
        from stock_por_canon spc
        join canonicos c on c.id_producto = spc.canon_id
        where spc.total > 0
          and not exists (select 1 from canon_vendidos cv where cv.canon_id = spc.canon_id)
      ) q), '[]'::jsonb),
    'rangoDias', v_dias
  ) into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.productos_sin_venta(jsonb) from public;
grant execute on function mos.productos_sin_venta(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) mos.alertas_operativas(p) — p ignorado salvo el gate. Espeja _getAlertasOperativasImpl.
--    3 alertas: STOCK_CRITICO (canónicos con min>0 y stock WH por canónico < min), VENCIMIENTO_CRITICO
--    (lotes con cantidad_actual>0 y 0<=dias<=7), PREINGRESOS_PENDIENTES.
--    Shape data: { alertas:[{tipo,severidad,cantidad,mensaje,topItems?}], total, timestamp }.
--    Envoltorio: { ok:true, data:{...} } || _frescura_sombra().
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.alertas_operativas(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_hoy_l   date := (now() at time zone 'America/Lima')::date;
  v_alertas jsonb := '[]'::jsonb;
  v_crit_count int; v_crit_top jsonb;
  v_venc_count int; v_venc_top jsonb;
  v_pre_count  int;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

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
  wh_por_canon as (
    select m.canon_id, sum(coalesce(s.cantidad_disponible,0)) as q
    from wh.stock s join mapa_u m on m.k = upper(btrim(s.cod_producto))
    where nullif(btrim(s.cod_producto),'') is not null group by m.canon_id
  ),
  criticos as (
    select c.id_producto, c.descripcion, coalesce(wpc.q,0) as cant, c.stock_minimo as minimo
    from canonicos c left join wh_por_canon wpc on wpc.canon_id = c.id_producto
    where c.stock_minimo > 0 and coalesce(wpc.q,0) < c.stock_minimo
  )
  select count(*)::int,
         coalesce((select jsonb_agg(jsonb_build_object('idProducto', t.id_producto, 'descripcion', t.descripcion, 'stock', t.cant, 'minimo', t.minimo))
                   from (select * from criticos order by id_producto limit 5) t), '[]'::jsonb)
    into v_crit_count, v_crit_top
  from criticos;

  if v_crit_count > 0 then
    v_alertas := v_alertas || jsonb_build_array(jsonb_build_object(
      'tipo','STOCK_CRITICO','severidad','CRITICA','cantidad', v_crit_count,
      'mensaje', v_crit_count || ' producto(s) por debajo del mínimo en almacén central',
      'topItems', v_crit_top));
  end if;

  -- VENCIMIENTO_CRITICO: dias = floor(fechaVto - hoy) por DÍA Lima; 0<=dias<=7.
  with venc as (
    select l.cod_producto, coalesce(l.cantidad_actual,0) as cantidad,
           (((l.fecha_vencimiento at time zone 'America/Lima')::date) - v_hoy_l) as dias
    from wh.lotes_vencimiento l
    where l.fecha_vencimiento is not null and coalesce(l.cantidad_actual,0) > 0
  )
  select count(*) filter (where dias >= 0 and dias <= 7)::int,
         coalesce((select jsonb_agg(jsonb_build_object('codigoProducto', v.cod_producto, 'dias', v.dias, 'cantidad', v.cantidad))
                   from (select * from venc where dias >= 0 and dias <= 7 order by cod_producto limit 5) v), '[]'::jsonb)
    into v_venc_count, v_venc_top
  from venc;

  if v_venc_count > 0 then
    v_alertas := v_alertas || jsonb_build_array(jsonb_build_object(
      'tipo','VENCIMIENTO_CRITICO','severidad','ALTA','cantidad', v_venc_count,
      'mensaje', v_venc_count || ' lote(s) vencen en ≤7 días',
      'topItems', v_venc_top));
  end if;

  select count(*)::int into v_pre_count from wh.preingresos pi where upper(coalesce(pi.estado,'')) = 'PENDIENTE';
  if v_pre_count > 0 then
    v_alertas := v_alertas || jsonb_build_array(jsonb_build_object(
      'tipo','PREINGRESOS_PENDIENTES','severidad','MEDIA','cantidad', v_pre_count,
      'mensaje', v_pre_count || ' preingreso(s) esperando aprobación'));
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'alertas', v_alertas,
    'total', jsonb_array_length(v_alertas),
    'timestamp', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  )) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.alertas_operativas(jsonb) from public;
grant execute on function mos.alertas_operativas(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 5) mos.guias_y_preingresos(p) — p = { dias (opc int, default 7) }
--    Espeja _getGuiasYPreingresosImpl. Guías recientes (fecha>=desde), preingresos pendientes (todos) +
--    procesados recientes, guías abiertas viejas (>24h), y resumen del día (Hoy = TZ Lima).
--    Shape data: { guias:[...], preingresosPendientes:[...], preingresosProcesados:[...], guiasAbiertasViejas:[...],
--                  resumen:{ingresosHoy,despachosHoy,envasadosHoy,montoIngresoHoy} }.
--    Cada guía/preingreso se devuelve como objeto camelCase (to_jsonb de la fila, renombrado a las claves del GAS).
--    Envoltorio: { ok:true, data:{...} } || _frescura_sombra().
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.guias_y_preingresos(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_dias    int;
  v_desde   timestamptz;
  v_hace24  timestamptz := now() - interval '24 hours';
  v_hoy_l   date := (now() at time zone 'America/Lima')::date;
  v_data    jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  v_dias := coalesce(nullif(btrim(coalesce(p->>'dias','')), '')::int, 7);
  if v_dias is null or v_dias <= 0 then v_dias := 7; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  -- GAS: desde = ahora - dias*86400000 (corte por ms). Paridad: now() - interval.
  v_desde := now() - make_interval(days => v_dias);

  with
  -- Forma camelCase de la guía (claves que el GAS expone vía _safeReadWhGuias / _sheetToObjects de WH GUIAS).
  guia_json as (
    select g.fecha, jsonb_build_object(
      'idGuia', g.id_guia, 'tipo', g.tipo,
      'fecha', to_char(g.fecha at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'usuario', g.usuario, 'idProveedor', g.id_proveedor, 'idZona', g.id_zona,
      'numeroDocumento', g.numero_documento, 'comentario', g.comentario,
      'montoTotal', coalesce(g.monto_total,0), 'estado', g.estado,
      'idPreingreso', g.id_preingreso, 'foto', g.foto) as obj,
      coalesce(g.monto_total,0) as monto, upper(coalesce(g.tipo,'')) as tipo_u, upper(coalesce(g.estado,'')) as estado_u
    from wh.guias g
  ),
  pre_json as (
    select pi.fecha, upper(coalesce(pi.estado,'')) as estado_u, jsonb_build_object(
      'idPreingreso', pi.id_preingreso,
      'fecha', to_char(pi.fecha at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'idProveedor', pi.id_proveedor, 'cargadores', pi.cargadores, 'usuario', pi.usuario,
      'monto', coalesce(pi.monto,0), 'fotos', pi.fotos, 'comentario', pi.comentario,
      'estado', pi.estado, 'idGuia', pi.id_guia) as obj
    from wh.preingresos pi
  )
  select jsonb_build_object(
    'guias', coalesce((select jsonb_agg(gj.obj order by gj.fecha desc) from guia_json gj where gj.fecha is not null and gj.fecha >= v_desde), '[]'::jsonb),
    'preingresosPendientes', coalesce((select jsonb_agg(pj.obj) from pre_json pj where pj.estado_u = 'PENDIENTE'), '[]'::jsonb),
    'preingresosProcesados', coalesce((select jsonb_agg(pj.obj order by pj.fecha desc) from pre_json pj where pj.estado_u = 'PROCESADO' and pj.fecha is not null and pj.fecha >= v_desde), '[]'::jsonb),
    'guiasAbiertasViejas', coalesce((select jsonb_agg(gj.obj) from guia_json gj where gj.estado_u = 'ABIERTA' and gj.fecha is not null and gj.fecha < v_hace24), '[]'::jsonb),
    'resumen', jsonb_build_object(
      'ingresosHoy', (select count(*) from guia_json gj where gj.fecha is not null and gj.fecha >= v_desde and (gj.fecha at time zone 'America/Lima')::date = v_hoy_l and (gj.tipo_u like '%INGRESO_PROVEEDOR%' or gj.tipo_u like '%INGRESO%')),
      'despachosHoy', (select count(*) from guia_json gj where gj.fecha is not null and gj.fecha >= v_desde and (gj.fecha at time zone 'America/Lima')::date = v_hoy_l and (gj.tipo_u like '%SALIDA_ZONA%' or gj.tipo_u like '%DESPACHO%' or gj.tipo_u like '%SALIDA%')),
      'envasadosHoy', (select count(*) from guia_json gj where gj.fecha is not null and gj.fecha >= v_desde and (gj.fecha at time zone 'America/Lima')::date = v_hoy_l and (gj.tipo_u like '%SALIDA_ENVASADO%' or gj.tipo_u like '%ENVASADO%')),
      'montoIngresoHoy', round(coalesce((select sum(gj.monto) from guia_json gj where gj.fecha is not null and gj.fecha >= v_desde and (gj.fecha at time zone 'America/Lima')::date = v_hoy_l and (gj.tipo_u like '%INGRESO_PROVEEDOR%' or gj.tipo_u like '%INGRESO%')), 0), 2))
  ) into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.guias_y_preingresos(jsonb) from public;
grant execute on function mos.guias_y_preingresos(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 6) mos.operaciones_unificadas(p) — p = { dias (opc int, default 7) }
--    Espeja _getOperacionesUnificadasImpl. Operaciones WH (guías + preingresos pendientes con anexo preingreso) +
--    ME (guias_cabecera), agrupadas por día (TZ Lima), orden fecha desc.
--    ⚠ provMap = SOLO mos.proveedores (la hoja WH PROVEEDORES no está migrada → ver NOTA G).
--    Shape data: { _almV:2, porDia:[{fecha,totalMonto,totalOps,operaciones:[op...]}], total, rangoDias }.
--    op (WH guía): { fuente:'WH', fuenteLabel:'Almacén central', idGuia, tipo, fecha, usuario, idProveedor,
--      nombreProveedor, idZona, idZonaCanonId, idZonaCanonNom, numeroDocumento, comentario, montoTotal, estado,
--      idPreingreso, preingreso:{...}|null, foto, esPreingreso:false }.
--    op (WH preingreso pendiente): { ..., tipo:'PREINGRESO', esPreingreso:true, idGuiaGenerada, fotos }.
--    op (ME guía): { fuente:'ME', fuenteLabel:'Zona <nombre>', idGuia, tipo, fecha, usuario, idZona, idZonaCanonId,
--      idZonaCanonNom, comentario, zonaDestino, estado, montoTotal:0, esPreingreso:false }.
--    Envoltorio: { ok:true, data:{...} } || _frescura_sombra().
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.operaciones_unificadas(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_dias  int;
  v_desde timestamptz;
  v_data  jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  v_dias := coalesce(nullif(btrim(coalesce(p->>'dias','')), '')::int, 7);
  if v_dias is null or v_dias <= 0 then v_dias := 7; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  v_desde := now() - make_interval(days => v_dias);

  with
  -- ── Resolver de zona ──
  zonas_reg as (select upper(btrim(z.id_zona)) as zid, coalesce(z.nombre, z.id_zona) as nombre from mos.zonas z where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado, true) = true),
  zona_resolver as (
    select upper(btrim(z.id_zona)) as raw, upper(btrim(z.id_zona)) as canon_id, coalesce(z.nombre, z.id_zona) as canon_nombre from mos.zonas z where nullif(btrim(z.id_zona),'') is not null
    union select upper(btrim(z.nombre)), upper(btrim(z.id_zona)), coalesce(z.nombre, z.id_zona) from mos.zonas z where nullif(btrim(z.nombre),'') is not null
    union select upper(btrim(es.id_estacion)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.id_estacion),'') is not null
    union select upper(btrim(es.nombre)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.nombre),'') is not null
    union select upper(btrim(es.id_zona)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null
  ),
  zona_resolver_u as (select distinct on (raw) raw, canon_id, canon_nombre from zona_resolver order by raw, canon_nombre nulls last),
  -- provMap: SOLO mos.proveedores (la hoja WH PROVEEDORES no está migrada).
  prov as (select id_proveedor, nombre from mos.proveedores),
  -- preingresos indexados (anexo) + cross-check de guías que apuntan a un preingreso.
  pre_proc_by_guia as (select distinct nullif(btrim(g.id_preingreso),'') as id_pre from wh.guias g where nullif(btrim(g.id_preingreso),'') is not null),

  -- ── 1) WH GUIAS (con anexo preingreso) ──
  wh_guias as (
    select g.fecha, jsonb_build_object(
      'fuente','WH','fuenteLabel','Almacén central',
      'idGuia', coalesce(g.id_guia,''), 'tipo', coalesce(g.tipo,''),
      'fecha', to_char(g.fecha at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'usuario', coalesce(g.usuario,''), 'idProveedor', coalesce(g.id_proveedor,''),
      'nombreProveedor', case when nullif(btrim(g.id_proveedor),'') is not null then coalesce((select nombre from prov where id_proveedor = g.id_proveedor), g.id_proveedor) else '' end,
      'idZona', coalesce(g.id_zona,''),
      'idZonaCanonId',  case when nullif(btrim(g.id_zona),'') is not null then coalesce((select canon_id from zona_resolver_u where raw = upper(btrim(g.id_zona))), upper(btrim(g.id_zona))) else '' end,
      'idZonaCanonNom', case when nullif(btrim(g.id_zona),'') is not null then coalesce((select canon_nombre from zona_resolver_u where raw = upper(btrim(g.id_zona))), btrim(g.id_zona)) else '' end,
      'numeroDocumento', coalesce(g.numero_documento,''), 'comentario', coalesce(g.comentario,''),
      'montoTotal', coalesce(g.monto_total,0), 'estado', coalesce(g.estado,''),
      'idPreingreso', coalesce(g.id_preingreso,''),
      'preingreso', case when nullif(btrim(g.id_preingreso),'') is not null and pi.id_preingreso is not null
        then jsonb_build_object('idPreingreso', coalesce(pi.id_preingreso,''), 'monto', coalesce(pi.monto,0),
               'comentario', coalesce(pi.comentario,''), 'fotos', coalesce(pi.fotos,''), 'cargadores', coalesce(pi.cargadores,''),
               'usuario', coalesce(pi.usuario,''), 'estado', coalesce(pi.estado,''),
               'fecha', case when pi.fecha is not null then to_char(pi.fecha at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') else '' end)
        else null end,
      'foto', coalesce(g.foto,''), 'esPreingreso', false) as obj,
      coalesce(g.monto_total,0) as monto
    from wh.guias g
    left join wh.preingresos pi on pi.id_preingreso = g.id_preingreso
    where g.fecha is not null and g.fecha >= v_desde
  ),

  -- ── 2) WH PREINGRESOS pendientes (no procesado/anulado, sin idGuia propio, sin guía que lo referencie) ──
  wh_pre as (
    select pi.fecha, jsonb_build_object(
      'fuente','WH','fuenteLabel','Almacén central',
      'idGuia', coalesce(pi.id_preingreso,''), 'tipo','PREINGRESO',
      'fecha', to_char(pi.fecha at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'usuario', coalesce(pi.usuario,''), 'idProveedor', coalesce(pi.id_proveedor,''),
      'nombreProveedor', case when nullif(btrim(pi.id_proveedor),'') is not null then coalesce((select nombre from prov where id_proveedor = pi.id_proveedor), pi.id_proveedor) else '' end,
      'idZona','', 'comentario', coalesce(pi.comentario,''),
      'montoTotal', coalesce(pi.monto,0),
      'estado', coalesce(nullif(upper(coalesce(pi.estado,'')),''),'PENDIENTE'),
      'idGuiaGenerada', coalesce(pi.id_guia,''), 'esPreingreso', true, 'fotos', coalesce(pi.fotos,'')) as obj,
      coalesce(pi.monto,0) as monto
    from wh.preingresos pi
    where upper(coalesce(pi.estado,'')) not in ('PROCESADO','ANULADO')
      and nullif(btrim(pi.id_guia),'') is null
      and not exists (select 1 from pre_proc_by_guia pp where pp.id_pre = nullif(btrim(pi.id_preingreso),''))
      and pi.fecha is not null and pi.fecha >= v_desde
  ),

  -- ── 3) ME GUIAS_CABECERA ──
  me_guias as (
    select gc.fecha, jsonb_build_object(
      'fuente','ME',
      'fuenteLabel','Zona ' || coalesce((select canon_nombre from zona_resolver_u where raw = upper(btrim(gc.zona_id))), btrim(gc.zona_id), ''),
      'idGuia', coalesce(gc.id_guia,''), 'tipo', coalesce(gc.tipo,''),
      'fecha', to_char(gc.fecha at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'usuario', coalesce(gc.vendedor,''), 'idZona', coalesce(gc.zona_id,''),
      'idZonaCanonId',  case when nullif(btrim(gc.zona_id),'') is not null then coalesce((select canon_id from zona_resolver_u where raw = upper(btrim(gc.zona_id))), upper(btrim(gc.zona_id))) else '' end,
      'idZonaCanonNom', case when nullif(btrim(gc.zona_id),'') is not null then coalesce((select canon_nombre from zona_resolver_u where raw = upper(btrim(gc.zona_id))), btrim(gc.zona_id)) else '' end,
      'comentario', coalesce(gc.observacion,''), 'zonaDestino', coalesce(gc.zona_destino,''),
      'estado', coalesce(gc.estado,''), 'montoTotal', 0, 'esPreingreso', false) as obj,
      0::numeric as monto
    from me.guias_cabecera gc
    where gc.fecha is not null and gc.fecha >= v_desde
  ),

  todas as (
    select fecha, obj, monto from wh_guias
    union all select fecha, obj, monto from wh_pre
    union all select fecha, obj, monto from me_guias
  ),
  por_dia as (
    select to_char(t.fecha at time zone 'America/Lima', 'YYYY-MM-DD') as dia,
           jsonb_agg(t.obj order by t.fecha desc) as ops,
           round(sum(t.monto),2) as total_monto, count(*)::int as total_ops
    from todas t group by to_char(t.fecha at time zone 'America/Lima', 'YYYY-MM-DD')
  )
  select jsonb_build_object(
    '_almV', 2,
    'porDia', coalesce((select jsonb_agg(jsonb_build_object('fecha', pd.dia, 'totalMonto', pd.total_monto, 'totalOps', pd.total_ops, 'operaciones', pd.ops) order by pd.dia desc) from por_dia pd), '[]'::jsonb),
    'total', (select count(*) from todas),
    'rangoDias', v_dias
  ) into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.operaciones_unificadas(jsonb) from public;
grant execute on function mos.operaciones_unificadas(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 7) mos.insights_stock(p) — p = { dias (opc int, default 30) }
--    Espeja _getInsightsStockImpl. 4 tipos de insight, resolución por CANÓNICO, zonas REGISTRADAS estrictas:
--      · SIN_ROTACION:        canónico con stock zonas >=10 y 0 ventas en rango.
--      · DESPACHAR_DESDE_WH:  zona vendedora se queda sin stock (<7d) y WH tiene >= cantidadSugerida (rot*14).
--      · TRASLADAR:           idem pero WH no alcanza → otra zona con stock>=5 y ventas < ventas/3.
--      · REPOSICION:          canónico con (stock zonas + stock WH) < mínimo.
--    Orden: severidad (CRITICA<ALTA<MEDIA<BAJA) luego tipo (REPOSICION<DESPACHAR_DESDE_WH<TRASLADAR<SIN_ROTACION).
--    Devuelve TOP 20 (slice). Shape data: { _almV:2, insights:[...], total, rangoDias }.
--    Envoltorio: { ok:true, data:{...} } || _frescura_sombra().
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
  -- ── Mapa código → canónico ──
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

  -- ── Resolver de zona + set registradas ──
  zonas_reg as (select upper(btrim(z.id_zona)) as zid, coalesce(z.nombre, z.id_zona) as nombre from mos.zonas z where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado, true) = true),
  zona_resolver as (
    select upper(btrim(z.id_zona)) as raw, upper(btrim(z.id_zona)) as canon_id, coalesce(z.nombre, z.id_zona) as canon_nombre from mos.zonas z where nullif(btrim(z.id_zona),'') is not null
    union select upper(btrim(z.nombre)), upper(btrim(z.id_zona)), coalesce(z.nombre, z.id_zona) from mos.zonas z where nullif(btrim(z.nombre),'') is not null
    union select upper(btrim(es.id_estacion)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.id_estacion),'') is not null
    union select upper(btrim(es.nombre)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.nombre),'') is not null
    union select upper(btrim(es.id_zona)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null
  ),
  zona_resolver_u as (select distinct on (raw) raw, canon_id, canon_nombre from zona_resolver order by raw, canon_nombre nulls last),

  -- ── Stock por canónico + zona (cantidad>0). Nombre canónico de zona. ──
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

  -- ── Ventas por canónico + zona (zona = `estacion`, no anulada, fecha>=desde). ──
  ventas_meta as (
    select v.id_venta, r.canon_id as zid
    from me.ventas v
    cross join lateral (
      select coalesce(zru.canon_id, upper(btrim(v.estacion))) as canon_id
      from (select 1) _ left join zona_resolver_u zru on zru.raw = upper(btrim(v.estacion))
    ) r
    where v.fecha is not null and (v.fecha at time zone 'America/Lima')::date >= v_desde and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  ),
  ventas_canon_zona as (
    select coalesce((select canon_id from mapa_u where k = upper(btrim(d.cod_barras))), null) as canon_id,
           vm.zid, sum(coalesce(d.cantidad,0)) as cant
    from me.ventas_detalle d join ventas_meta vm on vm.id_venta = d.id_venta
    where nullif(btrim(d.cod_barras),'') is not null
    group by 1, vm.zid
  ),
  vcz as (select canon_id, zid, sum(cant) as cant from ventas_canon_zona where canon_id is not null group by canon_id, zid),
  ventas_canon_total as (select canon_id, sum(cant) as total from vcz group by canon_id),

  -- nombre canónico de zona consolidado (de stock o ventas)
  zona_nombre as (
    select zid, max(nombre) as nombre from (
      select zid, znombre as nombre from stock_canon_zona
      union all select zr.zid, zr.nombre from zonas_reg zr
      union all select scz.zid, scz.znombre from stock_canon_zona scz
    ) z where nullif(btrim(zid),'') is not null group by zid
  ),

  -- ── WH por canónico ──
  wh_por_canon as (
    select m.canon_id, sum(coalesce(s.cantidad_disponible,0)) as q
    from wh.stock s join mapa_u m on m.k = upper(btrim(s.cod_producto))
    where nullif(btrim(s.cod_producto),'') is not null group by m.canon_id
  ),

  -- ════════ INSIGHT 1 — SIN_ROTACION ════════
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

  -- ════════ INSIGHT 2 — por (canónico, zona vendedora registrada) que se queda sin stock <7d ════════
  base2 as (
    select
      vcz.canon_id, vcz.zid as zona_vend, vcz.cant as ventas,
      coalesce((select cant from stock_canon_zona scz where scz.canon_id = vcz.canon_id and scz.zid = vcz.zid),0) as stock_en_esa,
      (vcz.cant::numeric / v_dias) as rot_dia,
      coalesce((select q from wh_por_canon w where w.canon_id = vcz.canon_id),0) as wh_disp
    from vcz
    where vcz.zid in (select zid from zonas_reg)         -- zona vendedora REGISTRADA
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
  -- 2a DESPACHAR_DESDE_WH (WH alcanza)
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
  -- 2b TRASLADAR (WH no alcanza → otra zona registrada con stock>=5 y ventasOtra < ventas/3).
  --    Candidato DETERMINISTA: mayor stock origen, desempate por zid (ver NOTA H — el GAS toma el "primero").
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
    -- solo si NO hubo despacho WH para ese (canon, zona) — base2c ya separó por wh_disp<cant_sugerida, exclusivo de 2a.
  ),

  -- ════════ INSIGHT 3 — REPOSICION (stock zonas + WH < mínimo) ════════
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

  -- ── Unir todos con orden (severidad, tipo). ──
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
-- NOTAS DE PARIDAD / DIVERGENCIAS / GAPS (honestidad 40x) — por función + transversales
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- A) VEREDICTO GLOBAL — las 7 son PORTABLES. NINGUNA quedó como "requiere sesión dedicada". El cómputo (sumas,
--    conteos, resolución de canónico/sku/zona, clasificación de alertas/insights) es expresable en SQL sobre
--    tablas YA migradas. Lo no garantizable es la FRESCURA de las sombras (ver B) y 2 puntos de borde menores
--    (G = proveedores WH no migrados; H = candidato de traslado). Ambos documentados y de RIESGO BAJO.
--
-- B) FRESCURA DE SOMBRA (transversal, no es GAP de datos) — wh.stock, wh.lotes_vencimiento, wh.guias,
--    wh.preingresos, me.stock_zonas, me.ventas/ventas_detalle, me.guias_cabecera son SOMBRAS del sync
--    GAS→Supabase. Si el sync se atrasa, todo lo agregado queda stale vs las HOJAS que el GAS lee en vivo.
--    _frescura_sombra() expone _fresh para que el front decida caer a GAS. ⇒ ANTES del cutover de CUALQUIERA
--    de estos getters, el sync de las tablas que consume DEBE estar vivo. (Mismo principio que 109/113.)
--
-- C) ZONA-RAW = `estacion`, NO `zona_id` (transversal a stock_unificado/ranking_zonas/insights) — todas las
--    impls de Almacen.gs que computan zona de VENTA leen VENTAS_CABECERA col idx 3 = Estacion (no Zona_ID).
--    me.ventas tiene AMBAS columnas (estacion + zona_id, 02_schema_me.sql:26/37). Replicamos `estacion` para
--    PARIDAD FIEL. Si en el futuro se prefiriera zona_id (más limpio), sería una MEJORA, no paridad.
--    RIESGO: si `estacion` viene vacío y zona_id no, el GAS lo descarta (continue) → aquí también (filtramos
--    nullif(estacion,'')). Coincide.
--
-- D) ANULACIÓN DE VENTA = estado_envio (transversal) — el GAS detecta 'ANULADO' por VENTAS_CABECERA col 8 =
--    Estado_Envio. Aquí me.ventas.estado_envio = 'ANULADO'. El ecosistema tiene otra regla ("anulación real por
--    FormaPago") pero replicamos lo que hacen estas impls (miran Estado_Envio). Mismo criterio que 109/113.
--
-- E) RESOLUCIÓN DE CANÓNICO (productos_sin_venta/alertas_operativas/insights_stock) — replica
--    _construirMapaCBaCanonico + _esCanonico: canónico = sin codigo_producto_base Y factor∈{null,1}; presentación
--    → canónico por sku_base; derivado → canónico por codigo_producto_base (id luego sku); equivalencia →
--    canónico del sku. distinct on (k) garantiza 1 canónico por código resuelto. En datos válidos (regla
--    "1 cb → 1 canónico") coincide con el GAS. RIESGO BAJO. Igual que 113 NOTA H.
--
-- F) BLOQUES `_debug` NO REPLICADOS (stock_unificado._debug, operaciones_unificadas._debug, diagME, etc.) —
--    son diagnóstico interno (timezone, conteos de lectura, zonas leídas crudas, fechas de muestra). NO son
--    datos de negocio que el front consuma para renderizar. Se omiten a propósito. Si el front dependiera de
--    alguno (no debería), agregarlo es trivial. DECISIÓN: shape de NEGOCIO paritario, sin ruido de diagnóstico.
--
-- G) ⚠ operaciones_unificadas — PROVEEDORES WH NO MIGRADO (único GAP de FUENTE real). El GAS fusiona
--    PROVEEDORES_MASTER (MOS) + la hoja WH PROVEEDORES para el provMap. La hoja WH PROVEEDORES **no existe en
--    Supabase** (03_schema_wh.sql:13: "NO se migran PRODUCTOS/PROVEEDORES/... no existen en WH"). Por eso aquí
--    provMap = SOLO mos.proveedores. Consecuencia: un id_proveedor presente ÚNICAMENTE en la hoja WH (no en
--    mos.proveedores) mostrará el ID crudo en lugar del nombre. El GAS, en ese mismo caso, SÍ resolvería el
--    nombre desde la hoja WH. ⇒ DIVERGENCIA SOLO en nombreProveedor de ops cuyo proveedor no esté en el master
--    MOS. RIESGO BAJO-MEDIO (el master MOS suele ser superset; los preingresos WH normalmente referencian
--    proveedores del catálogo). Si fuera necesario, migrar la hoja WH PROVEEDORES o unificar al alta. Documentado.
--
-- H) ⚠ insights_stock — INSIGHT 2b TRASLADAR, candidato no-determinista en el GAS. El GAS construye
--    trasladosCandidatos iterando Object.keys(stockInfo.zonas) y toma `[0]` (el PRIMERO según orden de claves
--    del objeto JS, que NO está garantizado y depende del orden de inserción/historial). Aquí se elige un
--    candidato DETERMINISTA: mayor stock_origen, desempate por zona_origen (zid asc). Cuando hay >1 candidato
--    válido, la zona origen sugerida PUEDE diferir de la del GAS — pero el insight TRASLADAR existe igual, con
--    el mismo destino y la misma severidad. Es además un comportamiento MÁS estable que el del GAS. RIESGO BAJO.
--    (También: ins2a y ins2b son MUTUAMENTE EXCLUYENTES por (canon, zona) vía el predicado wh_disp ≷ cant_sugerida,
--    igual que el `return;` del GAS tras emitir el despacho WH.)
--
-- I) stock_unificado — TOTAL.rotacionDia (paridad de redondeo). El GAS calcula totalRot = Σ zonasArr.rotacionDia,
--    donde cada zona.rotacionDia YA viene redondeado a 1 decimal (Math.round(rot*10)/10). Replicamos sum(round
--    (rot_dia,1)) (suma de redondeados), NO round(sum(rot_dia)). diasParaAcabar total usa ese totalRot. Es una
--    sutileza pero se replica fiel. zonas[].rotacionDia también round(.,1). ventasRango total = Σ ventas zona.
--
-- J) stock_unificado — orden de zonas y de codigosBarra. zonas: (cantidad>0 OR ventas>0) primero, luego
--    ventas desc — paridad con el sort del GAS. codigosBarra: principal antes que equivalencia para el mismo cb
--    (distinct on cb order by cb, ord) — paridad con barrasInfo (push de principales primero). Universo de zonas
--    = TODAS las ZONAS activas + zonas con stock/ventas no registradas (paridad con idsTodas). Nombre de zona
--    registrada gana sobre el de stock/ventas (paridad con nombreCanonMap + zonasMaster primero).
--
-- K) guias_y_preingresos — el GAS lee tipos/estados case-insensitive (toUpperCase) y los matchea por substring
--    (indexOf). Replicado con upper() + LIKE '%...%'. resumen.*Hoy filtran por _hoyMidnight (medianoche LOCAL del
--    script = Lima). Aquí: (fecha at tz Lima)::date = hoy Lima. Las guías del resumen se toman del conjunto YA
--    filtrado por rango (guiasFiltradas), igual que el GAS (que pasa guiasFiltradas a _contarPorTipoYRango). Por
--    eso el sub-filtro incluye `fecha >= v_desde`. Para dias>=1 el "hoy" siempre cae dentro del rango (no cambia
--    el resultado), pero se mantiene por fidelidad estructural.
--    El parser de fecha del GAS (_parseFecha, múltiples formatos) NO se necesita: en Supabase fecha es timestamptz
--    nativo (ya parseado en el backfill). Las filas con fecha null se descartan (igual que _parseFecha→null).
--
-- L) operaciones_unificadas — VENTANA por ms (now() - dias). El GAS filtra fecha >= (hoy - dias*86400000) con
--    Date nativo. Replicado con now() - make_interval(days). El agrupado por día usa to_char(fecha at tz Lima)
--    (paridad con Utilities.formatDate(f, tz Lima)). Orden de operaciones dentro del día: fecha desc (paridad).
--    Orden de días: dia desc (paridad con Object.keys.sort().reverse()). preingreso anexo: solo si la guía tiene
--    id_preingreso Y existe el preingreso (paridad). preingresos pendientes: estado not in (PROCESADO,ANULADO)
--    AND sin id_guia propio AND ninguna guía lo referencia (cross-check, paridad con preProcesadosByGuia).
--
-- M) ranking_zonas — incluye TODAS las zonas registradas (left join zonas_reg), aunque tengan 0 ventas (paridad
--    con el "asegurar que todas aparezcan"). bucket OTRAS = ventas de zonas NO registradas (filter not registrada).
--    vendedores = count distinct de `vendedor` (col idx 2) por zona. pctTotal = round(ventas/totalVentas*1000)/10
--    (1 decimal, paridad). monto = `total` (col idx 6). NO usa zona_id de la sombra (ver C).
--
-- N) alertas_operativas — STOCK_CRITICO recorre SOLO canónicos con min>0 y compara contra stock WH POR CANÓNICO
--    (suma de variantes/equivalentes). topItems = primeros 5 (orden por id_producto — el GAS toma los 5 primeros
--    en orden de recorrido de `productos`, que es orden de hoja; aquí order by id_producto es DETERMINISTA y puede
--    diferir EN CUÁLES 5 si hay >5 críticos, pero el `cantidad` total y el mensaje coinciden). VENCIMIENTO_CRITICO:
--    dias = (fechaVto::date Lima) - hoy Lima, 0<=dias<=7 (el GAS usa floor((Date(vto)-now)/86400000); diferencia
--    de borde ≤1 día en el umbral exacto, como en 113 NOTA J). RIESGO BAJO. timestamp ISO Z. total = nº alertas.
--
-- O) productos_sin_venta — canónicos con stock zonas (>0) cuya NINGUNA variante/equivalente se vendió en rango.
--    canon_vendidos = distinct canónico resuelto desde sku(idx1) o cb(idx6) del detalle de ventas válidas. Stock
--    por canónico/zona solo de filas cantidad>0 (paridad: `if (qty<=0) return`). breakdownZonas: cantidad desc.
--    Orden final: stockEnZonas desc. precioVenta del canónico. RIESGO BAJO.
--
-- P) TIPOS NUMÉRICOS / EMOJIS — cantidades/stock/ventas como número JSON (paridad _sheetToObjects→Number).
--    round(.,1) ≡ Math.round(x*10)/10 ; round(.,2) ≡ Math.round(x*100)/100. Los emojis 🏭/⚠ en mensajes de
--    insight/stock_unificado se preservan literalmente (paridad de texto exacta del GAS).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
