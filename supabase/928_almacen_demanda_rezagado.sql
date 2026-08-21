-- [928] La DEUDA (demanda insatisfecha) = pendiente REZAGADO de los pickups acumulados por zona — la MISMA
-- definición que usa Considerados (wh.pickups fuente=ACUMULADO_SEMANAL, estado=REZAGADO, solicitado−despachado>0).
-- Antes la deuda salía de me.zona_pedido_log (parcial y con ventana de 4 sem) → COCINERO (deuda de hace 5 sem)
-- no aparecía. Ahora la deuda es lo que REALMENTE se debe hoy, venga de cuando venga.
--
-- Dos funciones:
--  A) mos.almacen_demanda_bulk({})       → meta/clasificación de TODO el grupo: sem[4]=despacho+envasado por
--                                           semana (rotación) + pend (deuda propia) + pendDeriv (deuda de
--                                           derivados ×factor) + stock. Front: meta = smart(sem)+pend+pendDeriv.
--  B) mos.almacen_demanda_rez({skus})    → detalle para el gráfico: semanas[4]{despacho,envasado} + pendZonas
--                                           [{zona,pend}] + hijos[{cod,nombre,factor,pend,aporte}] + stock + esInsumo.

-- Vista lógica reutilizable: pendiente rezagado por sku y zona (>0).
create or replace function mos._rez_pend_sku_zona()
returns table(sku text, zona text, pend numeric) language sql stable security definer set search_path to '' as $$
  select it->>'skuBase' as sku, coalesce(pk.id_zona,'') as zona,
         sum(wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))) as pend
    from wh.pickups pk cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
   where pk.fuente = 'ACUMULADO_SEMANAL' and upper(coalesce(pk.estado,'')) = 'REZAGADO'
     and coalesce(it->>'skuBase','') <> ''
   group by 1,2
  having sum(wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))) > 0
$$;
grant execute on function mos._rez_pend_sku_zona() to authenticated, anon, service_role;

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
    select cd.sku, ((g.fecha::date - v_desde)/7)::int sem,
           sum(case when upper(coalesce(g.tipo,''))='SALIDA_ZONA' then coalesce(nullif(gd.cantidad_aplicada,0),gd.cant_esperada,0)
                    when upper(coalesce(g.tipo,''))='SALIDA_ENVASADO' then coalesce(nullif(gd.cantidad_aplicada,0),gd.cant_esperada,gd.cant_recibida,0) else 0 end) q
      from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia
      join codes cd on cd.cod = btrim(gd.cod_producto)
     where upper(coalesce(g.tipo,'')) in ('SALIDA_ZONA','SALIDA_ENVASADO') and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
       and g.fecha::date between v_desde and v_hasta and upper(coalesce(gd.observacion,'')) not like 'ANULADO%'
     group by 1,2
  ),
  flow_json as (select sku, jsonb_agg(round(q,3) order by sem) sem, sum(q) tot from flow group by sku),
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

create or replace function mos.almacen_demanda_rez(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_skus text[];
  v_lunes date := date_trunc('week', (now() at time zone 'America/Lima'))::date;
  v_desde date := v_lunes - 28; v_hasta date := v_lunes - 1; v jsonb;
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
  desp as (select cd.sku, ((g.fecha::date - v_desde)/7)::int sem, sum(coalesce(nullif(gd.cantidad_aplicada,0),gd.cant_esperada,0)) q
     from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia join codes cd on cd.cod=btrim(gd.cod_producto)
    where upper(coalesce(g.tipo,''))='SALIDA_ZONA' and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA') and g.fecha::date between v_desde and v_hasta and upper(coalesce(gd.observacion,'')) not like 'ANULADO%' group by 1,2),
  env as (select cd.sku, ((g.fecha::date - v_desde)/7)::int sem, sum(coalesce(nullif(gd.cantidad_aplicada,0),gd.cant_esperada,gd.cant_recibida,0)) q
     from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia join codes cd on cd.cod=btrim(gd.cod_producto)
    where upper(coalesce(g.tipo,''))='SALIDA_ENVASADO' and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA') and g.fecha::date between v_desde and v_hasta and upper(coalesce(gd.observacion,'')) not like 'ANULADO%' group by 1,2),
  wk as (select generate_series(0,3) sem),
  rz as (select upper(btrim(sku)) sku, zona, pend from mos._rez_pend_sku_zona()),
  sem_json as (
    select r.sku, jsonb_agg(jsonb_build_object('sem',w.sem,'despacho',round(coalesce(dp.q,0),3),'envasado',round(coalesce(ep.q,0),3)) order by w.sem) semanas
      from (select unnest(v_skus) sku) r cross join wk w
      left join desp dp on dp.sku=r.sku and dp.sem=w.sem
      left join env ep on ep.sku=r.sku and ep.sem=w.sem
     group by r.sku
  ),
  pend_json as (
    select rz.sku, jsonb_agg(jsonb_build_object('zona',rz.zona,'pend',round(rz.pend,2)) order by rz.pend desc) zonas, round(sum(rz.pend),3) pend
      from rz where rz.sku = any(v_skus) group by 1
  ),
  child_pend as (
    select ch.parent, ch.ccod, ch.cnom, ch.conv, coalesce(sum(r2.pend),0) pend
      from child ch left join rz r2 on r2.sku = ch.csku
     group by 1,2,3,4
  ),
  child_json as (
    select parent, jsonb_agg(jsonb_build_object('cod',ccod,'nombre',cnom,'factor',conv,'pend',round(pend,2),'aporte',round(pend*conv,3)) order by pend*conv desc) hijos,
           round(sum(pend*conv),3) pend_deriv
      from child_pend group by parent
  ),
  stock as (select cd.sku, sum(greatest(0,coalesce(s.cantidad_disponible,0))) q from wh.stock s join codes cd on cd.cod=btrim(s.cod_producto) where cd.sku = any(v_skus) group by 1)
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', r.sku,
           'esInsumo', exists(select 1 from mos.productos pi where upper(btrim(pi.sku_base))=r.sku and pi.es_insumo is true),
           'semanas', coalesce(sj.semanas,'[]'::jsonb),
           'pendZonas', coalesce(pj.zonas,'[]'::jsonb),
           'pend', coalesce(pj.pend,0),
           'hijos', coalesce(cj.hijos,'[]'::jsonb),
           'pendDeriv', coalesce(cj.pend_deriv,0),
           'stock', round(coalesce(st.q,0),3)
         )), '[]'::jsonb) into v
    from (select unnest(v_skus) sku) r
    left join sem_json  sj on sj.sku=r.sku
    left join pend_json pj on pj.sku=r.sku
    left join child_json cj on cj.parent=r.sku
    left join stock st on st.sku=r.sku;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v));
end $function$;
grant execute on function mos.almacen_demanda_rez(jsonb) to authenticated, anon, service_role;
