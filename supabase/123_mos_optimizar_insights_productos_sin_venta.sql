-- 123_mos_optimizar_insights_productos_sin_venta.sql
-- [PERF] Optimiza mos.insights_stock(jsonb) y mos.productos_sin_venta(jsonb) para que bajen del
-- statement_timeout=8s del rol `authenticated` (hoy ~10s y ~15.5s → 500 en el frontend).
--
-- DIAGNÓSTICO (EXPLAIN ANALYZE sobre datos reales — tablas chicas, máx 6226 filas):
--   El cuello de botella NO es falta de índices (las tablas son chicas y ya hay índices en los joins),
--   sino SUBQUERIES CORRELACIONADAS sobre CTEs:
--     · `(select canon_id from mapa_u where k = upper(btrim(d.sku/cod_barras)))` se ejecuta POR FILA de
--       me.ventas_detalle. `mapa_u` es un CTE de ~4794 filas que NO se puede indexar → cada lookup es un
--       Seq Scan O(n). Con 1819 filas → ~8.7M comparaciones. EXPLAIN:
--         "SubPlan 8/9 -> CTE Scan on mapa_u (rows=4794) loops=1819"  actual time → 13.3s.
--     · `prod_canon` resolvía el canónico con subqueries correlacionadas contra canon_by_id/canon_by_sku
--       (SubPlan 3/4/5, loops=218/535) → 1.3s adicionales en su Seq Scan.
--
-- FIX (NO cambia shape de salida, ni firma, ni gate mos._claim_ok(), ni security definer / search_path='' / grants):
--   Reescribir las correlaciones como LEFT JOIN explícitos. El planner usa Hash Join (O(n+m)) en vez de
--   nested-loop sobre el CTE. Misma lógica COALESCE(por_sku, por_cb) y misma resolución de canónico.
--   Idempotente: solo CREATE OR REPLACE FUNCTION (mismo nombre/firma).

-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) mos.productos_sin_venta — versión optimizada (paridad de shape: {ok, data:{_almV, productos[], rangoDias}, ...frescura})
-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════
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
  -- prod_canon: resolver canónico vía LEFT JOIN (antes: subqueries correlacionadas SubPlan 3/4/5).
  prod_canon as (
    select pr.id_producto, pr.codigo_barra,
      case
        when coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = '' and (pr.factor_conversion is null or pr.factor_conversion = 1)
          then pr.id_producto
        when coalesce(nullif(btrim(pr.codigo_producto_base),''),'') <> ''
          then coalesce(cbi_base.id_producto, cbs_base.id_producto)
        when nullif(btrim(pr.sku_base),'') is not null
          then cbs_sku.id_producto
        else null
      end as canon_id
    from mos.productos pr
    left join canon_by_id  cbi_base on cbi_base.k = upper(btrim(pr.codigo_producto_base)) and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') <> ''
    left join canon_by_sku cbs_base on cbs_base.k = upper(btrim(pr.codigo_producto_base)) and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') <> ''
    left join canon_by_sku cbs_sku  on cbs_sku.k  = upper(btrim(pr.sku_base))             and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = '' and nullif(btrim(pr.sku_base),'') is not null
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
  -- ANTES: subqueries correlacionadas sobre mapa_u por fila (SubPlan 8/9, 13.3s). AHORA: LEFT JOIN → hash join.
  canon_vendidos as (
    select distinct coalesce(m_sku.canon_id, m_cb.canon_id) as canon_id
    from me.ventas_detalle d
    join ventas_validas vv on vv.id_venta = d.id_venta
    left join mapa_u m_sku on m_sku.k = upper(btrim(d.sku))
    left join mapa_u m_cb  on m_cb.k  = upper(btrim(d.cod_barras))
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
      -- orden por stock desc; tie-break determinista por id_producto (antes el empate era inestable: dependía
      -- del orden físico del seq scan). Mismo SET y mismos valores; ahora salida estable y reproducible.
      select jsonb_agg(q.obj order by q.ord desc, q.id_prod) from (
        select jsonb_build_object(
          'idProducto', c.id_producto, 'skuBase', c.sku_base, 'descripcion', c.descripcion,
          'codigoBarra', c.codigo_barra, 'precioVenta', c.precio_venta,
          'stockEnZonas', spc.total,
          'breakdownZonas', coalesce((
            select jsonb_agg(jsonb_build_object('idZona', szc.zid, 'nombre', coalesce(szc.znombre, szc.zid), 'cantidad', szc.cant) order by szc.cant desc)
            from stock_zona_canon szc where szc.canon_id = spc.canon_id), '[]'::jsonb)
        ) as obj,
        spc.total as ord,
        c.id_producto as id_prod
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


-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) mos.insights_stock — versión optimizada (paridad de shape: {ok, data:{_almV, insights[], total, rangoDias}, ...frescura})
-- ══════════════════════════════════════════════════════════════════════════════════════════════════════════
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
  -- prod_canon: resolver canónico vía LEFT JOIN (antes: subqueries correlacionadas por fila).
  prod_canon as (
    select pr.id_producto, pr.codigo_barra,
      case
        when coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = '' and (pr.factor_conversion is null or pr.factor_conversion = 1) then pr.id_producto
        when coalesce(nullif(btrim(pr.codigo_producto_base),''),'') <> '' then coalesce(cbi_base.id_producto, cbs_base.id_producto)
        when nullif(btrim(pr.sku_base),'') is not null then cbs_sku.id_producto
        else null
      end as canon_id
    from mos.productos pr
    left join canon_by_id  cbi_base on cbi_base.k = upper(btrim(pr.codigo_producto_base)) and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') <> ''
    left join canon_by_sku cbs_base on cbs_base.k = upper(btrim(pr.codigo_producto_base)) and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') <> ''
    left join canon_by_sku cbs_sku  on cbs_sku.k  = upper(btrim(pr.sku_base))             and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = '' and nullif(btrim(pr.sku_base),'') is not null
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
  -- ANTES: subquery correlacionada sobre mapa_u por fila. AHORA: LEFT JOIN → hash join.
  ventas_canon_zona as (
    select m_cb.canon_id as canon_id,
           vm.zid, sum(coalesce(d.cantidad,0)) as cant
    from me.ventas_detalle d
    join ventas_meta vm on vm.id_venta = d.id_venta
    left join mapa_u m_cb on m_cb.k = upper(btrim(d.cod_barras))
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
    left join ventas_canon_total v on v.canon_id = sct.canon_id
    where sct.total >= 10 and coalesce(v.total,0) = 0
  ),

  -- ════════ INSIGHT 2 — por (canónico, zona vendedora registrada) que se queda sin stock <7d ════════
  base2 as (
    select
      vcz.canon_id, vcz.zid as zona_vend, vcz.cant as ventas,
      coalesce(scz.cant,0) as stock_en_esa,
      (vcz.cant::numeric / v_dias) as rot_dia,
      coalesce(w.q,0) as wh_disp
    from vcz
    join zonas_reg zr on zr.zid = vcz.zid                 -- zona vendedora REGISTRADA
    left join stock_canon_zona scz on scz.canon_id = vcz.canon_id and scz.zid = vcz.zid
    left join wh_por_canon w on w.canon_id = vcz.canon_id
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
           coalesce(vo.cant,0) as ventas_otra
    from base2c b
    join stock_canon_zona scz on scz.canon_id = b.canon_id
    join zonas_reg zro on zro.zid = scz.zid
    left join vcz vo on vo.canon_id = b.canon_id and vo.zid = scz.zid
    where b.wh_disp < b.cant_sugerida
      and scz.zid <> b.zona_vend
      and scz.cant >= 5
      and coalesce(vo.cant,0) < b.ventas / 3.0
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
