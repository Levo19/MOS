-- 134 · OPTIMIZACION mos.insights_stock: subconsultas correlacionadas por fila (prod_canon,
-- ventas_canon_zona) -> LEFT JOIN. Resultado IDENTICO (validado dias 7/30/90), 17.6s -> 0.6s (29x).
-- Sin esto PostgREST cortaba por statement_timeout -> 500. No toca dinero (RPC de solo lectura).

CREATE OR REPLACE FUNCTION mos.insights_stock(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
        when coalesce(nullif(btrim(pr.codigo_producto_base),''),'') <> '' then coalesce(cbi_b.id_producto, cbs_b.id_producto)
        when nullif(btrim(pr.sku_base),'') is not null then cbs_s.id_producto
        else null
      end as canon_id
    from mos.productos pr
    left join canon_by_id  cbi_b on cbi_b.k = upper(btrim(pr.codigo_producto_base))
    left join canon_by_sku cbs_b on cbs_b.k = upper(btrim(pr.codigo_producto_base))
    left join canon_by_sku cbs_s on cbs_s.k = upper(btrim(pr.sku_base))
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
    select mu.canon_id, vm.zid,
           sum(coalesce(d.cantidad,0) * coalesce(fb.factor, 1)) as cant
    from me.ventas_detalle d
    join ventas_meta vm on vm.id_venta = d.id_venta
    left join mapa_u mu on mu.k = upper(btrim(d.cod_barras))
    left join fac_by_cb fb on fb.cb = upper(btrim(d.cod_barras))
    where nullif(btrim(d.cod_barras),'') is not null
    group by mu.canon_id, vm.zid
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
$function$

