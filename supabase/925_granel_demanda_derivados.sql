-- [925] mos.granel_demanda_derivados — META de un GRANEL ENVASABLE = Σ(faltante_derivado × fcb).
-- Lo que el admin de almacén compra al proveedor es el GRANEL. Un derivado corto por X unidades exige
-- X × factor_conversion_base kg de granel para envasarlo. Sumado sobre todos los derivados = kg de granel
-- que hay que tener; comprar = max(0, necesario − stock del granel). Si los derivados están llenos → 0
-- (no hace falta envasar más ahora; el stock de granel es buffer).
--   faltante_derivado = max(0, meta_derivado − have_derivado), con
--     meta_derivado = Σ me.zona_esperado.esperado del derivado en zonas retail,
--     have_derivado = stock efectivo (positivos) del derivado en almacén (wh.stock) + zonas (me.stock_zonas).
-- BATCH: recibe {skus:[...]} (skus de granel), devuelve un item por granel con el desglose de derivados.
create or replace function mos.granel_demanda_derivados(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_skus text[];
  v jsonb;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select array_agg(upper(btrim(x))) into v_skus
    from jsonb_array_elements_text(coalesce(p->'skus','[]'::jsonb)) x where btrim(x) <> '';
  v_skus := coalesce(v_skus, array[]::text[]);
  if array_length(v_skus,1) is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('items','[]'::jsonb)); end if;

  with
  -- stock efectivo (positivos) por sku_base — almacén y zonas
  alm as (
    select upper(btrim(coalesce(pr.sku_base, eq.sku_base))) as sku,
           sum(greatest(0, coalesce(s.cantidad_disponible,0))) as q
      from wh.stock s
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
     where coalesce(pr.sku_base, eq.sku_base) is not null
     group by 1
  ),
  zon as (
    select upper(btrim(coalesce(pr.sku_base, eq.sku_base))) as sku,
           sum(greatest(0, coalesce(sz.cantidad,0))) as q
      from me.stock_zonas sz
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(sz.cod_barras,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(sz.cod_barras,''))
     where coalesce(pr.sku_base, eq.sku_base) is not null
     group by 1
  ),
  -- meta del derivado = Σ zona_esperado retail por su sku_base
  dmeta as (
    select upper(btrim(sku_base)) as sku, sum(coalesce(esperado,0)) as meta
      from me.zona_esperado
     where upper(coalesce(zona_id,'')) not like '%ALMAC%' and coalesce(btrim(sku_base),'') <> ''
     group by 1
  ),
  -- derivados de los graneles pedidos (fcb>0)
  der as (
    select upper(btrim(d.codigo_producto_base)) as granel,
           upper(btrim(d.sku_base)) as dsku,
           d.codigo_barra, d.descripcion,
           d.factor_conversion_base::numeric as fcb
      from mos.productos d
     where upper(btrim(coalesce(d.codigo_producto_base,''))) = any(v_skus)
       and coalesce(d.factor_conversion_base,0) > 0
  ),
  calc as (
    select der.granel, der.codigo_barra, der.descripcion, der.fcb,
           coalesce(dm.meta,0) as meta,
           coalesce(al.q,0) + coalesce(zo.q,0) as have,
           greatest(0, coalesce(dm.meta,0) - (coalesce(al.q,0) + coalesce(zo.q,0))) as falta
      from der
      left join dmeta dm on dm.sku = der.dsku
      left join alm   al on al.sku = der.dsku
      left join zon   zo on zo.sku = der.dsku
  ),
  agg as (
    select granel,
           round(sum(falta * fcb), 3) as granel_nec,
           jsonb_agg(jsonb_build_object(
             'cod', codigo_barra, 'nombre', descripcion, 'fcb', fcb,
             'meta', round(meta,2), 'have', round(have,2), 'falta', round(falta,2),
             'granel', round(falta * fcb, 3)
           ) order by falta * fcb desc, descripcion) as derivados
      from calc group by granel
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', a.granel,
           'granelNecesario', a.granel_nec,
           'stockGranel', round(coalesce(g.q,0),3),
           'comprar', greatest(0, round(a.granel_nec - coalesce(g.q,0), 3)),
           'derivados', a.derivados
         )), '[]'::jsonb)
    into v
    from agg a
    left join alm g on g.sku = a.granel;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v));
end $function$;
grant execute on function mos.granel_demanda_derivados(jsonb) to authenticated, anon, service_role;
