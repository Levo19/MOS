-- 141 · zona_pickup_detalle v2 — pedido desde me.ventas (helper canónico), NO desde los
-- PCK-CC (que pueden tener factor obsoleto del bug granel). Despacho desde guías [pickup:].
-- Cierra la inconsistencia: MOS mostraba 0.0187 del laurel porque leía un PCK-CC absorbido viejo.
create or replace function wh.zona_pickup_detalle(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_zona   text := coalesce(nullif(btrim(coalesce(p->>'zona', p->>'id_zona','')),''), '');
  v_bucket date := wh._bucket_dom((now() at time zone 'America/Lima')::date);
  v_items  jsonb;
begin
  if v_zona = '' then return jsonb_build_object('ok', false, 'error', 'Requiere zona'); end if;
  with ped as (   -- pedido = ventas de cajas CERRADAS del bucket, al canónico (regla peso/unidad)
    select cv.sku_base sku,
           (coalesce(cj.fecha_cierre,cj.fecha_apertura) at time zone 'America/Lima')::date dia,
           sum(cv.cant) cant
    from me.cajas cj
    join me.ventas v on v.id_caja=cj.id_caja
    join me.ventas_detalle vd on vd.id_venta=v.id_venta
    cross join lateral mos._venta_canonico(vd.cod_barras, vd.cantidad::numeric, vd.unidad_medida) cv
    where coalesce(cj.zona_id,'')=v_zona and cj.fecha_cierre is not null
      and upper(coalesce(v.forma_pago,''))<>'ANULADO'
      and wh._bucket_dom((coalesce(cj.fecha_cierre,cj.fecha_apertura) at time zone 'America/Lima')::date)=v_bucket
      and coalesce(cv.sku_base,'')<>''
    group by 1,2
  ),
  desp as (   -- despacho = guías SALIDA_ZONA DESDE pickup ([pickup:]); lista sombra/directa NO cuenta
    select coalesce(
        (select pr.sku_base from mos.productos pr where pr.codigo_barra=gd.cod_producto limit 1),
        (select e.sku_base from mos.equivalencias e where e.codigo_barra=gd.cod_producto and e.activo limit 1),
        gd.cod_producto) sku, (g.fecha at time zone 'America/Lima')::date dia,
           sum(coalesce(gd.cant_recibida, gd.cantidad_aplicada, 0)) cant
    from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia
    where g.tipo='SALIDA_ZONA' and g.comentario like '%[pickup:%' and coalesce(g.id_zona,'')=v_zona
      and wh._bucket_dom((g.fecha at time zone 'America/Lima')::date)=v_bucket
    group by 1,2
  ),
  skus as (select sku from ped union select sku from desp),
  agg as (
    select s.sku,
      coalesce((select pp.descripcion from mos.productos pp where pp.sku_base=s.sku order by (pp.codigo_producto_base is null) desc limit 1), s.sku) nombre,
      coalesce((select sum(cant) from ped where ped.sku=s.sku),0) pedido,
      coalesce((select sum(cant) from desp where desp.sku=s.sku),0) despacho
    from skus s
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'skuBase', a.sku, 'nombre', a.nombre,
    'solicitado', a.pedido, 'despachado', a.despacho,
    'pendiente', greatest(0, a.pedido - a.despacho),
    'historial', (
      select coalesce(jsonb_agg(h.obj order by (h.obj->>'fecha'), (h.obj->>'tipo') desc), '[]'::jsonb)
      from (
        select jsonb_build_object('fecha',dia,'tipo','pedido','cant',cant) obj from ped where ped.sku=a.sku
        union all
        select jsonb_build_object('fecha',dia,'tipo','despacho','cant',cant) from desp where desp.sku=a.sku
      ) h)
  ) order by greatest(0, a.pedido - a.despacho) desc), '[]'::jsonb)
  into v_items from agg a where a.pedido>0;

  return jsonb_build_object('ok',true,'zona',v_zona,'bucket',to_char(v_bucket,'YYYY-MM-DD'),
    'items', v_items, 'total_items', jsonb_array_length(v_items),
    'total_pendiente', (select coalesce(sum(greatest(0,(x->>'solicitado')::numeric-(x->>'despachado')::numeric)),0) from jsonb_array_elements(v_items) x),
    'total_despachado', (select coalesce(sum((x->>'despachado')::numeric),0) from jsonb_array_elements(v_items) x));
end; $fn$;
