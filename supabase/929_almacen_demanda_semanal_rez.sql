-- [929] mos.almacen_demanda_rez v2 — análisis SEMANA POR SEMANA (últimas 6 semanas). Cada semana lleva sus
-- barras: 🔵 despacho a zona · 🟡 deuda insatisfecha (rezagado en el bucket de ESA semana, por zona) ·
-- 🟣 envasado · 🟠 deuda de derivados (rezagado de los derivados en esa semana × factor). Así el admin ve
-- CUÁNDO se debió y decide pedir de forma inteligente. La deuda se ubica en la semana de su bucket
-- (rezagado más viejo que 6 sem se pliega en la columna más antigua). Solo lectura.
--   semanas[i] = {sem, despacho, envasado, deuda, deudaDeriv, deudaZonas:[{zona,pend}]}  (i=0 más antigua)
--   hijosSem = [{cod,nombre,factor,aporteSem:[6]}]  → detalle de la 🟠 por semana.
create or replace function mos.almacen_demanda_rez(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_skus  text[];
  v_lunes date := date_trunc('week', (now() at time zone 'America/Lima'))::date;
  v_desde date := v_lunes - 28;   -- 4 semanas
  v_hasta date := v_lunes - 1;
  v jsonb;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select array_agg(upper(btrim(x))) into v_skus from jsonb_array_elements_text(coalesce(p->'skus','[]'::jsonb)) x where btrim(x)<>'';
  v_skus := coalesce(v_skus, array[]::text[]);
  if array_length(v_skus,1) is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('items','[]'::jsonb)); end if;

  with
  child as (
    select upper(btrim(d.codigo_producto_base)) parent, upper(btrim(d.sku_base)) csku, d.codigo_barra ccod, d.descripcion cnom, d.factor_conversion_base::numeric conv
      from mos.productos d where upper(btrim(coalesce(d.codigo_producto_base,''))) = any(v_skus) and coalesce(d.factor_conversion_base,0)>0
    union all
    select upper(btrim(d.envase_sku)) parent, upper(btrim(d.sku_base)) csku, d.codigo_barra ccod, d.descripcion cnom, 0.001::numeric conv
      from mos.productos d where upper(btrim(coalesce(d.envase_sku,''))) = any(v_skus)
  ),
  allsku as (select unnest(v_skus) sku union select csku from child),
  codes as (
    select upper(btrim(pr.sku_base)) sku, btrim(pr.codigo_barra) cod from mos.productos pr where coalesce(pr.codigo_barra,'')<>'' and upper(btrim(pr.sku_base)) in (select sku from allsku)
    union select upper(btrim(eq.sku_base)) sku, btrim(eq.codigo_barra) cod from mos.equivalencias eq where coalesce(eq.codigo_barra,'')<>'' and upper(btrim(eq.sku_base)) in (select sku from allsku)
  ),
  wk as (select generate_series(0,3) as sem),
  -- despacho/envasado por sku y semana (col 0..5, 0 = más antigua)
  desp as (select cd.sku, greatest(0,least(3, ((g.fecha::date - v_desde)/7)::int)) sem, sum(coalesce(nullif(gd.cantidad_aplicada,0),gd.cant_esperada,0)) q
     from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia join codes cd on cd.cod=btrim(gd.cod_producto)
    where upper(coalesce(g.tipo,''))='SALIDA_ZONA' and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA') and g.fecha::date between v_desde and v_hasta and upper(coalesce(gd.observacion,'')) not like 'ANULADO%' group by 1,2),
  env as (select cd.sku, greatest(0,least(3, ((g.fecha::date - v_desde)/7)::int)) sem, sum(coalesce(nullif(gd.cantidad_aplicada,0),gd.cant_esperada,gd.cant_recibida,0)) q
     from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia join codes cd on cd.cod=btrim(gd.cod_producto)
    where upper(coalesce(g.tipo,''))='SALIDA_ENVASADO' and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA') and g.fecha::date between v_desde and v_hasta and upper(coalesce(gd.observacion,'')) not like 'ANULADO%' group by 1,2),
  -- rezagado por sku, semana (del bucket) y zona. Bucket < v_desde (>6 sem) se pliega en la col 0.
  rez as (
    select upper(btrim(it->>'skuBase')) sku,
           greatest(0, least(3, ((to_date(right(pk.id_pickup,10),'YYYY-MM-DD') - v_desde)/7)::int)) sem,
           coalesce(pk.id_zona,'') zona,
           sum(wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))) pend
      from wh.pickups pk cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
     where pk.fuente='ACUMULADO_SEMANAL' and upper(coalesce(pk.estado,''))='REZAGADO'
       and right(pk.id_pickup,10) ~ '^\d{4}-\d{2}-\d{2}$'
       and coalesce(it->>'skuBase','')<>''
     group by 1,2,3
    having sum(wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))) > 0
  ),
  -- deuda propia por sku y semana (suma de zonas) + detalle por zona
  deuda_wk as (select sku, sem, sum(pend) pend, jsonb_agg(jsonb_build_object('zona',zona,'pend',round(pend,2)) order by pend desc) zonas from rez where sku = any(v_skus) group by 1,2),
  -- deuda de derivados por parent y semana (rezagado del hijo × factor)
  cderez as (select ch.parent, r.sem, sum(r.pend*ch.conv) q from child ch join rez r on r.sku=ch.csku group by 1,2),
  -- detalle por hijo y semana (para explicar la 🟠)
  child_wk as (select ch.parent, ch.ccod, ch.cnom, ch.conv, r.sem, sum(r.pend) pend from child ch join rez r on r.sku=ch.csku group by 1,2,3,4,5),
  hijos_json as (
    select parent, jsonb_agg(j order by tot desc) hijos from (
      select cw.parent, cw.cnom nom, sum(cw.pend*cw.conv) tot,
             jsonb_build_object('cod',cw.ccod,'nombre',cw.cnom,'factor',cw.conv,
               'aporteSem', (select jsonb_agg(round(coalesce((select sum(pend*cw.conv) from child_wk z where z.parent=cw.parent and z.ccod=cw.ccod and z.sem=w2.sem),0),3) order by w2.sem) from wk w2)) j
        from child_wk cw group by cw.parent, cw.ccod, cw.cnom, cw.conv
    ) z group by parent
  ),
  sem_json as (
    select r.sku, jsonb_agg(jsonb_build_object(
             'sem', w.sem,
             'despacho', round(coalesce(dp.q,0),3),
             'envasado', round(coalesce(ep.q,0),3),
             'deuda', round(coalesce(dw.pend,0),3),
             'deudaDeriv', round(coalesce(cx.q,0),3),
             'deudaZonas', coalesce(dw.zonas,'[]'::jsonb)
           ) order by w.sem) semanas
      from (select unnest(v_skus) sku) r cross join wk w
      left join desp dp on dp.sku=r.sku and dp.sem=w.sem
      left join env  ep on ep.sku=r.sku and ep.sem=w.sem
      left join deuda_wk dw on dw.sku=r.sku and dw.sem=w.sem
      left join cderez cx on cx.parent=r.sku and cx.sem=w.sem
     group by r.sku
  ),
  stock as (select cd.sku, sum(greatest(0,coalesce(s.cantidad_disponible,0))) q from wh.stock s join codes cd on cd.cod=btrim(s.cod_producto) where cd.sku = any(v_skus) group by 1)
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', r.sku,
           'esInsumo', exists(select 1 from mos.productos pi where upper(btrim(pi.sku_base))=r.sku and pi.es_insumo is true),
           'semanas', coalesce(sj.semanas,'[]'::jsonb),
           'hijos', coalesce(hj.hijos,'[]'::jsonb),
           'stock', round(coalesce(st.q,0),3)
         )), '[]'::jsonb) into v
    from (select unnest(v_skus) sku) r
    left join sem_json sj on sj.sku=r.sku
    left join hijos_json hj on hj.parent=r.sku
    left join stock st on st.sku=r.sku;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v, 'nsem', 4));
end $function$;
grant execute on function mos.almacen_demanda_rez(jsonb) to authenticated, anon, service_role;
