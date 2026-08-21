-- [936 · FASE 3 notificaciones] mos.estrellas_criticas_listar — LECTURA de las estrellas por agotarse,
-- agrupadas por zona, para la sección del dashboard de WH (título grande por zona). Misma detección que el
-- cron 935: bcg=ESTRELLA · zona retail · esperado>=2 · stock efectivo zona <= 20% meta · almacén > 0
-- (accionable, hay qué despachar). Solo lectura; la usa warehouseMos (y quien quiera).
create or replace function mos.estrellas_criticas_listar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v jsonb;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  with eff as (
    select coalesce(pr.sku_base, eq.sku_base) as sku_base, sz.zona_id,
           sum(greatest(0, coalesce(sz.cantidad,0))) as eff
      from me.stock_zonas sz
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(sz.cod_barras,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(sz.cod_barras,''))
     where coalesce(pr.sku_base, eq.sku_base) is not null group by 1, 2
  ),
  alm as (
    select coalesce(pr.sku_base, eq.sku_base) as sku_base, sum(greatest(0, coalesce(s.cantidad_disponible,0))) as alm
      from wh.stock s
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
     where coalesce(pr.sku_base, eq.sku_base) is not null group by 1
  ),
  nom as (
    select upper(btrim(sku_base)) as k,
           (array_agg(descripcion order by (case when codigo_producto_base is null then 0 else 1 end), length(coalesce(descripcion,'')) desc))[1] as nombre
      from mos.productos
     where coalesce(factor_conversion,1) = 1 and coalesce(estado, true) = true
       and nullif(btrim(coalesce(descripcion,'')),'') is not null and nullif(btrim(coalesce(sku_base,'')),'') is not null
     group by 1
  ),
  crit as (
    select ze.zona_id, ze.sku_base, coalesce(nom.nombre, ze.sku_base) as nombre,
           round(coalesce(e.eff,0),2) as eff, round(ze.esperado,2) as esperado, round(coalesce(a.alm,0),2) as almacen
      from me.zona_esperado ze
      left join eff e on e.zona_id = ze.zona_id and e.sku_base = ze.sku_base
      left join alm a on a.sku_base = ze.sku_base
      left join nom on nom.k = upper(btrim(ze.sku_base))
     where upper(coalesce(ze.bcg,'')) = 'ESTRELLA'
       and upper(coalesce(ze.zona_id,'')) not like '%ALMAC%'
       and coalesce(ze.esperado,0) >= 2
       and coalesce(e.eff,0) <= coalesce(ze.esperado,0) * 0.20
       and coalesce(a.alm,0) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object('zona', zona_id, 'total', n, 'items', items) order by n desc), '[]'::jsonb)
    into v
    from (
      select zona_id, count(*)::int n,
             jsonb_agg(jsonb_build_object('sku', sku_base, 'nombre', nombre, 'eff', eff, 'esperado', esperado, 'almacen', almacen)
                       order by (esperado - eff) desc, nombre) items
        from crit group by zona_id
    ) z;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('zonas', v),
    'total', (select coalesce(jsonb_array_length(v),0)));
end $function$;
grant execute on function mos.estrellas_criticas_listar(jsonb) to authenticated, anon, service_role;

select mos.estrellas_criticas_listar('{}'::jsonb) as muestra;
