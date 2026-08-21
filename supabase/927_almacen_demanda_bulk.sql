-- [927] mos.almacen_demanda_bulk — META demand-flow de TODOS los productos de almacén, para clasificar
-- bien: meta = despacho + envasado + deuda propia + deuda de derivados (proyección de 1 semana en el front).
-- Un producto con rotación cero PERO con demanda insatisfecha (deuda>0) deja de ser "muerto" → "Pedir ya".
-- Devuelve solo los skus con ALGO en la ventana (los demás quedan con su meta por picos = ~0). Solo lectura.
--   sem[i] = despacho_i + envasado_i + deudaPropia_i + deudaDeriv_i  (total de la semana i, 0=más vieja).
--   deuda  = Σ (deudaPropia + deudaDeriv) en 4 semanas (para saber si hay demanda insatisfecha).
create or replace function mos.almacen_demanda_bulk(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_lunes date := date_trunc('week', (now() at time zone 'America/Lima'))::date;
  v_desde date := v_lunes - 28;
  v_hasta date := v_lunes - 1;
  v jsonb;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  with
  codes as (
    select upper(btrim(pr.sku_base)) as sku, btrim(pr.codigo_barra) as cod
      from mos.productos pr where coalesce(pr.codigo_barra,'')<>'' and coalesce(pr.sku_base,'')<>''
    union
    select upper(btrim(eq.sku_base)) as sku, btrim(eq.codigo_barra) as cod
      from mos.equivalencias eq where coalesce(eq.codigo_barra,'')<>'' and coalesce(eq.sku_base,'')<>''
  ),
  desp as (
    select cd.sku, ((g.fecha::date - v_desde)/7)::int as sem,
           sum(coalesce(nullif(gd.cantidad_aplicada,0), gd.cant_esperada, 0)) as q
      from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia
      join codes cd on cd.cod = btrim(gd.cod_producto)
     where upper(coalesce(g.tipo,''))='SALIDA_ZONA' and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
       and g.fecha::date between v_desde and v_hasta and upper(coalesce(gd.observacion,'')) not like 'ANULADO%'
     group by 1,2
  ),
  env as (
    select cd.sku, ((g.fecha::date - v_desde)/7)::int as sem,
           sum(coalesce(nullif(gd.cantidad_aplicada,0), gd.cant_esperada, gd.cant_recibida, 0)) as q
      from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia
      join codes cd on cd.cod = btrim(gd.cod_producto)
     where upper(coalesce(g.tipo,''))='SALIDA_ENVASADO' and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
       and g.fecha::date between v_desde and v_hasta and upper(coalesce(gd.observacion,'')) not like 'ANULADO%'
     group by 1,2
  ),
  soli as (
    select upper(btrim(y.sku_base)) as sku, ((y.d::date - v_desde)/7)::int as sem, sum(y.cantidad) as q
      from (select sku_base, (ts at time zone 'America/Lima') as d, cantidad from me.zona_pedido_log) y
     where y.d::date between v_desde and v_hasta group by 1,2
  ),
  child as (
    select upper(btrim(d.codigo_producto_base)) as parent, upper(btrim(d.sku_base)) as csku, d.factor_conversion_base::numeric as conv
      from mos.productos d where coalesce(btrim(d.codigo_producto_base),'')<>'' and coalesce(d.factor_conversion_base,0)>0
    union all
    select upper(btrim(d.envase_sku)) as parent, upper(btrim(d.sku_base)) as csku, 0.001::numeric as conv
      from mos.productos d where coalesce(btrim(d.envase_sku),'')<>''
  ),
  wk as (select generate_series(0,3) as sem),
  cdeuda as (
    select ch.parent, w.sem, sum(greatest(0, coalesce(cs.q,0) - coalesce(cd.q,0)) * ch.conv) as q
      from child ch cross join wk w
      left join soli cs on cs.sku=ch.csku and cs.sem=w.sem
      left join desp cd on cd.sku=ch.csku and cd.sem=w.sem
     group by 1,2
  ),
  allp as (
    select sku from desp union select sku from env union select sku from soli union select parent from child
  ),
  per as (
    select ap.sku, w.sem,
           coalesce(dp.q,0) + coalesce(ep.q,0) + greatest(0, coalesce(sp.q,0) - coalesce(dp.q,0)) + coalesce(cx.q,0) as tot,
           greatest(0, coalesce(sp.q,0) - coalesce(dp.q,0)) + coalesce(cx.q,0) as deuda
      from allp ap cross join wk w
      left join desp dp on dp.sku=ap.sku and dp.sem=w.sem
      left join env  ep on ep.sku=ap.sku and ep.sem=w.sem
      left join soli sp on sp.sku=ap.sku and sp.sem=w.sem
      left join cdeuda cx on cx.parent=ap.sku and cx.sem=w.sem
  ),
  agg as (
    select sku,
           jsonb_agg(round(tot,3) order by sem) as sem,
           round(sum(deuda),3) as deuda_tot,
           sum(tot) as tot_all
      from per group by sku
  )
  select coalesce(jsonb_agg(jsonb_build_object('sku', sku, 'sem', sem, 'deuda', deuda_tot)), '[]'::jsonb)
    into v
    from agg where tot_all > 0;   -- solo skus con algo en la ventana (los demás quedan con su meta vieja)

  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v, 'desde', to_char(v_desde,'YYYY-MM-DD'), 'hasta', to_char(v_hasta,'YYYY-MM-DD')));
end $function$;
grant execute on function mos.almacen_demanda_bulk(jsonb) to authenticated, anon, service_role;
