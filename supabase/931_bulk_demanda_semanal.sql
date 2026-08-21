-- [931] mos.almacen_demanda_bulk v3 — META INTELIGENTE SEMANA POR SEMANA. Antes: smart(rotación) + deuda
-- TOTAL de golpe (inflaba con deudas viejas). Ahora: la META = smart(DEMANDA SEMANAL), donde la demanda de
-- cada semana = despacho + envasado + deuda propia (rezagado en esa semana) + deuda de derivados (en esa
-- semana). Así el smart analiza el COMPORTAMIENTO (si cae, proyecta bajo; lo viejo pesa menos solo). El
-- front hace meta = _zonaMetaSmart(sem). `pend`/`pendDeriv` (totales) quedan solo para el chip "hay deuda".
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
  wk as (select generate_series(0,3) as sem),
  flow as (
    select cd.sku, greatest(0,least(3, ((g.fecha::date - v_desde)/7)::int)) sem,
           sum(case when upper(coalesce(g.tipo,''))='SALIDA_ZONA' then coalesce(nullif(gd.cantidad_aplicada,0),gd.cant_esperada,0)
                    when upper(coalesce(g.tipo,''))='SALIDA_ENVASADO' then coalesce(nullif(gd.cantidad_aplicada,0),gd.cant_esperada,gd.cant_recibida,0) else 0 end) q
      from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia join codes cd on cd.cod = btrim(gd.cod_producto)
     where upper(coalesce(g.tipo,'')) in ('SALIDA_ZONA','SALIDA_ENVASADO') and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
       and g.fecha::date between v_desde and v_hasta and upper(coalesce(gd.observacion,'')) not like 'ANULADO%'
     group by 1,2
  ),
  -- rezagado (deuda) por sku y SEMANA del bucket (más viejo que 4 sem → col 0)
  rezwk as (
    select upper(btrim(it->>'skuBase')) sku,
           greatest(0, least(3, ((to_date(right(pk.id_pickup,10),'YYYY-MM-DD') - v_desde)/7)::int)) sem,
           sum(wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))) pend
      from wh.pickups pk cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
     where pk.fuente='ACUMULADO_SEMANAL' and upper(coalesce(pk.estado,''))='REZAGADO'
       and right(pk.id_pickup,10) ~ '^\d{4}-\d{2}-\d{2}$' and coalesce(it->>'skuBase','')<>''
     group by 1,2
    having sum(wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))) > 0
  ),
  child as (
    select upper(btrim(d.codigo_producto_base)) parent, upper(btrim(d.sku_base)) csku, d.factor_conversion_base::numeric conv
      from mos.productos d where coalesce(btrim(d.codigo_producto_base),'')<>'' and coalesce(d.factor_conversion_base,0)>0
    union all
    select upper(btrim(d.envase_sku)) parent, upper(btrim(d.sku_base)) csku, 0.001::numeric conv
      from mos.productos d where coalesce(btrim(d.envase_sku),'')<>''
  ),
  cderezwk as (select ch.parent sku, r.sem, sum(r.pend*ch.conv) q from child ch join rezwk r on r.sku=ch.csku group by 1,2),
  allp as (select sku from flow union select sku from rezwk union select sku from cderezwk),
  -- demanda semanal = flow + deuda propia + deuda derivados (por semana), alineada a 4 con ceros
  demanda as (
    select ap.sku, jsonb_agg(round(coalesce(f.q,0)+coalesce(r.pend,0)+coalesce(cd.q,0),3) order by w.sem) sem,
           sum(coalesce(f.q,0)+coalesce(r.pend,0)+coalesce(cd.q,0)) tot
      from allp ap cross join wk w
      left join flow f on f.sku=ap.sku and f.sem=w.sem
      left join rezwk r on r.sku=ap.sku and r.sem=w.sem
      left join cderezwk cd on cd.sku=ap.sku and cd.sem=w.sem
     group by ap.sku
  ),
  pend_tot as (select sku, sum(pend) pend from rezwk group by 1),
  pderiv_tot as (select sku, sum(q) q from cderezwk group by 1),
  stock as (select cd.sku, sum(greatest(0,coalesce(s.cantidad_disponible,0))) q from wh.stock s join codes cd on cd.cod=btrim(s.cod_producto) group by 1)
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', d.sku,
           'sem', d.sem,
           'pend', round(coalesce(pt.pend,0),3),
           'pendDeriv', round(coalesce(pd.q,0),3),
           'stock', round(coalesce(st.q,0),3)
         )), '[]'::jsonb) into v
    from demanda d
    left join pend_tot pt on pt.sku=d.sku
    left join pderiv_tot pd on pd.sku=d.sku
    left join stock st on st.sku=d.sku
   where d.tot > 0;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v));
end $function$;
grant execute on function mos.almacen_demanda_bulk(jsonb) to authenticated, anon, service_role;
