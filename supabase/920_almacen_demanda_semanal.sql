-- [920] mos.almacen_demanda_semanal — DEMANDA por semana en ALMACÉN = despachado + DEUDA (demanda
-- insatisfecha = lo SOLICITADO por las zonas y no despachado). Alimenta la proyección y el gráfico
-- (dos segmentos: despachado + deuda). El front pasa los códigos del canónico (evita re-mapear sku→cods).
--   solicitado: me.zona_pedido_log (todas las zonas piden a almacén) por semana.
--   despachado: wh.guia_detalle de guías SALIDA_ZONA cerradas, por esos códigos, por semana (best-effort:
--               usa cantidad_aplicada y, si es 0/null, cant_esperada; bucketea por wh.guias.fecha).
create or replace function mos.almacen_demanda_semanal(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_sku  text := btrim(coalesce(p->>'sku',''));
  v_cods text[];
  v_lunes date := date_trunc('week', (now() at time zone 'America/Lima'))::date;
  v_desde date := v_lunes - 28;
  v_hasta date := v_lunes - 1;
  v jsonb;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select array_agg(btrim(x)) into v_cods from jsonb_array_elements_text(coalesce(p->'codigos','[]'::jsonb)) x where btrim(x) <> '';
  v_cods := coalesce(v_cods, array[]::text[]);

  with weeks as (select generate_series(0,3) as sem),
  desp as (
    select ((g.fecha::date - v_desde)/7)::int as sem,
           sum(coalesce(nullif(gd.cantidad_aplicada,0), gd.cant_esperada, 0)) as q
    from wh.guias g
    join wh.guia_detalle gd on gd.id_guia = g.id_guia
    where upper(coalesce(g.tipo,'')) = 'SALIDA_ZONA'
      and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
      and g.fecha::date between v_desde and v_hasta
      and gd.cod_producto = any(v_cods)
    group by 1
  ),
  soli as (
    select ((d::date - v_desde)/7)::int as sem, sum(cantidad) as q
    from (select (ts at time zone 'America/Lima') as d, cantidad from me.zona_pedido_log where sku_base = v_sku) y
    where d::date between v_desde and v_hasta
    group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'sem', w.sem,
      'despachado', round(coalesce(dd.q,0),2),
      'solicitado', round(coalesce(ss.q,0),2),
      'deuda',      greatest(0, round(coalesce(ss.q,0) - coalesce(dd.q,0), 2))
    ) order by w.sem), '[]'::jsonb)
  into v
  from weeks w left join desp dd on dd.sem = w.sem left join soli ss on ss.sem = w.sem;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object('semanas', v, 'desde', to_char(v_desde,'YYYY-MM-DD'), 'hasta', to_char(v_hasta,'YYYY-MM-DD')));
end $function$;
grant execute on function mos.almacen_demanda_semanal(jsonb) to authenticated, anon, service_role;
