-- [930] FIX mos.almacen_demanda_bulk — el array `sem` (rotación semanal) venía SOLO con las semanas que
-- tuvieron movimiento (jsonb_agg sobre las filas existentes) → p.ej. [1,32] en vez de [1,32,0,0]. Eso
-- descoloca a _zonaMetaSmart: trata el 32 (viejo) como "reciente y creciente" → meta inflada (113 en vez
-- de 73). Ahora se rellenan los 4 ceros (cross join con las 4 semanas), alineado igual que el gráfico (929).
create or replace function mos.almacen_demanda_bulk(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_lunes date := date_trunc('week', (now() at time zone 'America/Lima'))::date;
  v_desde date := v_lunes - 28; v_hasta date := v_lunes - 1; v jsonb;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  with
  codes as (
    select upper(btrim(pr.sku_base)) sku, btrim(pr.codigo_barra) cod from mos.productos pr where coalesce(pr.codigo_barra,'')<>'' and coalesce(pr.sku_base,'')<>''
    union select upper(btrim(eq.sku_base)) sku, btrim(eq.codigo_barra) cod from mos.equivalencias eq where coalesce(eq.codigo_barra,'')<>'' and coalesce(eq.sku_base,'')<>''
  ),
  flow as (
    select cd.sku, greatest(0,least(3, ((g.fecha::date - v_desde)/7)::int)) sem,
           sum(case when upper(coalesce(g.tipo,''))='SALIDA_ZONA' then coalesce(nullif(gd.cantidad_aplicada,0),gd.cant_esperada,0)
                    when upper(coalesce(g.tipo,''))='SALIDA_ENVASADO' then coalesce(nullif(gd.cantidad_aplicada,0),gd.cant_esperada,gd.cant_recibida,0) else 0 end) q
      from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia
      join codes cd on cd.cod = btrim(gd.cod_producto)
     where upper(coalesce(g.tipo,'')) in ('SALIDA_ZONA','SALIDA_ENVASADO') and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
       and g.fecha::date between v_desde and v_hasta and upper(coalesce(gd.observacion,'')) not like 'ANULADO%'
     group by 1,2
  ),
  wk as (select generate_series(0,3) as sem),
  flow_json as (   -- [930] 4 semanas ALINEADAS (con ceros), no solo las que tuvieron movimiento
    select f.sku, jsonb_agg(round(coalesce(fl.q,0),3) order by w.sem) sem, sum(coalesce(fl.q,0)) tot
      from (select distinct sku from flow) f
      cross join wk w
      left join flow fl on fl.sku=f.sku and fl.sem=w.sem
     group by f.sku
  ),
  rez as (select upper(btrim(sku)) sku, sum(pend) pend from mos._rez_pend_sku_zona() group by 1),
  child as (
    select upper(btrim(d.codigo_producto_base)) parent, upper(btrim(d.sku_base)) csku, d.factor_conversion_base::numeric conv
      from mos.productos d where coalesce(btrim(d.codigo_producto_base),'')<>'' and coalesce(d.factor_conversion_base,0)>0
    union all
    select upper(btrim(d.envase_sku)) parent, upper(btrim(d.sku_base)) csku, 0.001::numeric conv
      from mos.productos d where coalesce(btrim(d.envase_sku),'')<>''
  ),
  cderez as (select ch.parent, sum(coalesce(rz.pend,0)*ch.conv) q from child ch left join rez rz on rz.sku=ch.csku group by 1),
  allp as (select sku from flow_json union select sku from rez union select parent sku from cderez),
  stock as (select cd.sku, sum(greatest(0,coalesce(s.cantidad_disponible,0))) q from wh.stock s join codes cd on cd.cod=btrim(s.cod_producto) group by 1)
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', ap.sku,
           'sem', coalesce(fj.sem, '[0,0,0,0]'::jsonb),
           'pend', round(coalesce(rz.pend,0),3),
           'pendDeriv', round(coalesce(cd.q,0),3),
           'stock', round(coalesce(st.q,0),3)
         )), '[]'::jsonb) into v
    from allp ap
    left join flow_json fj on fj.sku=ap.sku
    left join rez rz on rz.sku=ap.sku
    left join cderez cd on cd.parent=ap.sku
    left join stock st on st.sku=ap.sku
   where coalesce(fj.tot,0) > 0 or coalesce(rz.pend,0) > 0 or coalesce(cd.q,0) > 0;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v));
end $function$;
grant execute on function mos.almacen_demanda_bulk(jsonb) to authenticated, anon, service_role;
