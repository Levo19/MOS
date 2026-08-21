-- [926] mos.almacen_demanda_envasable — demanda semanal de un producto ENVASABLE (granel o insumo),
-- en 4 series por semana (para barras LADO A LADO), + desglose de sus "hijos" (derivados):
--   🔵 despacho      = SALIDA_ZONA de sus códigos (lo que salió como producto a zonas).
--   🟣 envasado      = SALIDA_ENVASADO de sus códigos (granel consumido / insumo gastado).
--   🟡 deudaPropia   = max(0, solicitado(propio) − despacho(propio)).
--   🟠 deudaDerivados= Σ hijos [ max(0, solicitado(hijo) − despacho(hijo)) × factor ], donde
--        · granel: hijos = derivados con codigo_producto_base = sku, factor = factor_conversion_base (kg).
--        · insumo: hijos = derivados con envase_sku = sku, factor = 0.001 (millar: 1 envase por unidad).
-- El front proyecta la META con _zonaMetaSmart(Σ de las 4 series) y compra = max(0, meta − stock).
-- BATCH: {skus:[...]}. Devuelve items keyed por sku. Solo lectura.
create or replace function mos.almacen_demanda_envasable(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_skus  text[];
  v_lunes date := date_trunc('week', (now() at time zone 'America/Lima'))::date;
  v_desde date := v_lunes - 28;
  v_hasta date := v_lunes - 1;
  v jsonb;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select array_agg(upper(btrim(x))) into v_skus from jsonb_array_elements_text(coalesce(p->'skus','[]'::jsonb)) x where btrim(x)<>'';
  v_skus := coalesce(v_skus, array[]::text[]);
  if array_length(v_skus,1) is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('items','[]'::jsonb)); end if;

  with
  req as (select distinct unnest(v_skus) as sku),
  child as (
    select upper(btrim(d.codigo_producto_base)) as parent, upper(btrim(d.sku_base)) as csku,
           d.codigo_barra as ccod, d.descripcion as cnom, d.factor_conversion_base::numeric as conv
      from mos.productos d
     where upper(btrim(coalesce(d.codigo_producto_base,''))) = any(v_skus) and coalesce(d.factor_conversion_base,0) > 0
    union all
    select upper(btrim(d.envase_sku)) as parent, upper(btrim(d.sku_base)) as csku,
           d.codigo_barra as ccod, d.descripcion as cnom, 0.001::numeric as conv
      from mos.productos d
     where upper(btrim(coalesce(d.envase_sku,''))) = any(v_skus) and coalesce(btrim(d.envase_sku),'') <> ''
  ),
  allsku as (select sku from req union select csku from child),
  codes as (
    select upper(btrim(pr.sku_base)) as sku, btrim(pr.codigo_barra) as cod
      from mos.productos pr where coalesce(pr.codigo_barra,'')<>'' and upper(btrim(pr.sku_base)) in (select sku from allsku)
    union
    select upper(btrim(eq.sku_base)) as sku, btrim(eq.codigo_barra) as cod
      from mos.equivalencias eq where coalesce(eq.codigo_barra,'')<>'' and upper(btrim(eq.sku_base)) in (select sku from allsku)
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
      from (select sku_base, (ts at time zone 'America/Lima') as d, cantidad from me.zona_pedido_log
             where upper(btrim(sku_base)) in (select sku from allsku)) y
     where y.d::date between v_desde and v_hasta group by 1,2
  ),
  wk as (select generate_series(0,3) as sem),
  cdeuda as (   -- 🟠 deuda de derivados × factor, por parent y semana
    select ch.parent, w.sem, sum(greatest(0, coalesce(cs.q,0) - coalesce(cd.q,0)) * ch.conv) as q
      from child ch cross join wk w
      left join soli cs on cs.sku=ch.csku and cs.sem=w.sem
      left join desp cd on cd.sku=ch.csku and cd.sem=w.sem
     group by 1,2
  ),
  per as (
    select r.sku, w.sem,
           round(coalesce(dp.q,0),3) as despacho,
           round(coalesce(ep.q,0),3) as envasado,
           round(greatest(0, coalesce(sp.q,0) - coalesce(dp.q,0)),3) as deuda_propia,
           round(coalesce(cx.q,0),3) as deuda_deriv
      from req r cross join wk w
      left join desp dp on dp.sku=r.sku and dp.sem=w.sem
      left join env  ep on ep.sku=r.sku and ep.sem=w.sem
      left join soli sp on sp.sku=r.sku and sp.sem=w.sem
      left join cdeuda cx on cx.parent=r.sku and cx.sem=w.sem
  ),
  sem_json as (
    select sku, jsonb_agg(jsonb_build_object('sem',sem,'despacho',despacho,'envasado',envasado,
             'deudaPropia',deuda_propia,'deudaDerivados',deuda_deriv) order by sem) as semanas
      from per group by sku
  ),
  child_wk as (   -- deuda del hijo por semana (para explicar la naranja al clickear)
    select ch.parent, ch.ccod, ch.cnom, ch.conv, w.sem,
           greatest(0, coalesce(cs.q,0) - coalesce(cd.q,0)) as deuda
      from child ch cross join wk w
      left join soli cs on cs.sku=ch.csku and cs.sem=w.sem
      left join desp cd on cd.sku=ch.csku and cd.sem=w.sem
  ),
  child_json as (
    select parent, jsonb_agg(j order by tot desc, nom) as hijos from (
      select cw.parent, cw.cnom as nom, sum(cw.deuda*cw.conv) as tot,
             jsonb_build_object('cod',cw.ccod,'nombre',cw.cnom,'factor',cw.conv,
               'deudaSem', jsonb_agg(round(cw.deuda,2) order by cw.sem),
               'aporteSem', jsonb_agg(round(cw.deuda*cw.conv,3) order by cw.sem),
               'aporteTot', round(sum(cw.deuda*cw.conv),3)) as j
        from child_wk cw group by cw.parent, cw.ccod, cw.cnom, cw.conv
    ) z group by parent
  ),
  stock as (
    select cd.sku, sum(greatest(0, coalesce(s.cantidad_disponible,0))) as q
      from wh.stock s join codes cd on cd.cod = btrim(s.cod_producto)
     where cd.sku in (select sku from req) group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', r.sku,
           'esInsumo', exists(select 1 from mos.productos pi where upper(btrim(pi.sku_base))=r.sku and (pi.es_insumo is true)),
           'semanas', coalesce(sj.semanas,'[]'::jsonb),
           'hijos', coalesce(cj.hijos,'[]'::jsonb),
           'stockProducto', round(coalesce(st.q,0),3)
         )), '[]'::jsonb)
    into v
    from req r
    left join sem_json  sj on sj.sku=r.sku
    left join child_json cj on cj.parent=r.sku
    left join stock st on st.sku=r.sku;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v, 'desde', to_char(v_desde,'YYYY-MM-DD'), 'hasta', to_char(v_hasta,'YYYY-MM-DD')));
end $function$;
grant execute on function mos.almacen_demanda_envasable(jsonb) to authenticated, anon, service_role;
