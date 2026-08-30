-- [998] Optimización analíticas: correlacionada→JOIN en el mapa canónico (prod_canon).
--  alertas_operativas y dashboard_almacen recalculaban el canon_id con 3 SUBCONSULTAS CORRELACIONADAS
--  por producto (N+1 sobre CTEs canon_by_id/canon_by_sku). Como esas claves son ÚNICAS (id PK / distinct on),
--  se convierten a LEFT JOIN → el planner hashea una vez en vez de escanear por fila. SALIDA IDÉNTICA
--  (verificado md5 del data, quitando timestamp): alertas 1286→91ms (-93%), dashboard 1337→153ms (-89%).
--  Solo estructura de la query; cero cambio de lógica/salida. Aplicado en vivo (create or replace).

CREATE OR REPLACE FUNCTION mos.alertas_operativas(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
        when coalesce(nullif(btrim(pr.codigo_producto_base),''),'') <> '' then coalesce(cbi_base.id_producto, cbs_base.id_producto)
        when nullif(btrim(pr.sku_base),'') is not null then cbs_sku.id_producto
        else null
      end as canon_id
    from mos.productos pr
    left join canon_by_id  cbi_base on cbi_base.k = upper(btrim(pr.codigo_producto_base))
    left join canon_by_sku cbs_base on cbs_base.k = upper(btrim(pr.codigo_producto_base))
    left join canon_by_sku cbs_sku  on cbs_sku.k  = upper(btrim(pr.sku_base))
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
$function$


CREATE OR REPLACE FUNCTION mos.dashboard_almacen(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
                 cbi_b.id_producto,
                 cbs_b.id_producto
               )                                                                  -- derivado → su base
        when nullif(btrim(pr.sku_base),'') is not null
          then cbs_s.id_producto  -- presentación → base
        else null
      end as canon_id
    from mos.productos pr
    left join canon_by_id  cbi_b on cbi_b.k = upper(btrim(pr.codigo_producto_base))
    left join canon_by_sku cbs_b on cbs_b.k = upper(btrim(pr.codigo_producto_base))
    left join canon_by_sku cbs_s on cbs_s.k = upper(btrim(pr.sku_base))
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
$function$

select '998 analiticas correlacionada a join listo' as ok;
