-- 379 · kill-GAS (MOS) recalcularStockMinMaxAuto — auto min/max desde velocidad de venta.
-- Réplica fiel del GAS Almacen.gs:2674: ventas últimos N días (no anuladas) por sku canónico →
-- ventasSemana = total/(N/7) → min=ceil(vSem), max=ceil(vSem*1.2) → escribe al canónico de cada sku.
-- Fire-and-forget throttled 12h desde el front. Idempotente (no reescribe si min/max iguales).
create or replace function mos.recalcular_stock_min_max_auto(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_dias    int     := greatest(7, least(120, coalesce(mos._numn(p->>'dias'),28)::int));
  v_semanas numeric := v_dias / 7.0;
  v_desde   timestamptz := now() - (v_dias || ' days')::interval;
  v_act int := 0; v_sc int := 0; v_sv int := 0; v_err int := 0;
  rec record;
  v_row text; v_min int; v_max int; v_minA numeric; v_maxA numeric;
  v_sample jsonb := '[]'::jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  perform set_config('statement_timeout','120s',true);

  for rec in
    with sales as (
      select d.sku, btrim(coalesce(d.cod_barras,'')) as cb, sum(coalesce(d.cantidad,0)) as qty
        from me.ventas_detalle d
        join me.ventas v on v.id_venta = d.id_venta
       where v.fecha >= v_desde
         and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
       group by d.sku, btrim(coalesce(d.cod_barras,''))
    ),
    -- resuelve cada línea al sku canónico: id_producto=sku → cb=codigo_barra → equivalencia cb→sku_base
    resolved as (
      select coalesce(
        (select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) from mos.productos pr where pr.id_producto = s.sku limit 1),
        (select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) from mos.productos pr where s.cb <> '' and pr.codigo_barra = s.cb limit 1),
        (select e.sku_base from mos.equivalencias e where s.cb <> '' and e.codigo_barra = s.cb and coalesce(e.activo,true) limit 1)
      ) as sku_canon, s.qty
      from sales s
    )
    select sku_canon, sum(qty) as total
      from resolved
     where sku_canon is not null
     group by sku_canon
  loop
    if coalesce(rec.total,0) <= 0 then v_sv := v_sv + 1; continue; end if;
    v_min := ceil((rec.total / v_semanas));
    v_max := ceil((rec.total / v_semanas) * 1.2);
    -- canónico: id==sku, luego factor=1 sin base, luego cualquiera (réplica rowCanonBySku del GAS)
    v_row := null;
    select id_producto, coalesce(stock_minimo,0), coalesce(stock_maximo,0)
      into v_row, v_minA, v_maxA
      from mos.productos
     where coalesce(nullif(btrim(sku_base),''), id_producto) = rec.sku_canon
     order by (id_producto = rec.sku_canon) desc,
              (coalesce(factor_conversion,1) = 1 and btrim(coalesce(codigo_producto_base,'')) = '') desc
     limit 1;
    if v_row is null then v_err := v_err + 1; continue; end if;
    if v_minA = v_min and v_maxA = v_max then v_sc := v_sc + 1; continue; end if;
    update mos.productos set stock_minimo = v_min, stock_maximo = v_max where id_producto = v_row;
    v_act := v_act + 1;
    if jsonb_array_length(v_sample) < 20 then
      v_sample := v_sample || jsonb_build_object('sku', rec.sku_canon, 'min', v_min, 'max', v_max);
    end if;
  end loop;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'actualizados',v_act,'sinCambio',v_sc,'sinVentas',v_sv,'errores',v_err,
    'ventana', v_dias || ' días', 'sample', v_sample));
end; $fn$;

revoke all on function mos.recalcular_stock_min_max_auto(jsonb) from public, anon;
grant execute on function mos.recalcular_stock_min_max_auto(jsonb) to authenticated, service_role;
