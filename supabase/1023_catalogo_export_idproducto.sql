-- 1023 · catalogo_export: agrega idProducto al producto base (para abrir la curva precio/costo).
-- Redefine mos.catalogo_export (1022) añadiendo 'idProducto' a cada item base. El resto idéntico.

create or replace function mos.catalogo_export(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_items jsonb; v_res jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  with base as (
    select b.id_producto, b.sku_base, b.codigo_barra, b.descripcion, b.descripcion_ia, b.id_categoria::text categoria,
           upper(coalesce(b.unidad_medida,'')) unidad, (upper(coalesce(b.unidad_medida,''))='KGM') granel,
           coalesce(b.estado,true) activo, b.precio_venta, b.precio_costo, b.margen_pct
      from mos.productos b
     where b.tipo_producto::text = 'CANONICO'
  ),
  presq as (
    select p.sku_base,
           jsonb_agg(jsonb_build_object('empaque', coalesce(nullif(btrim(p.descripcion),''), p.codigo_barra),
                     'codigo', p.codigo_barra, 'factor', p.factor_conversion,
                     'precio', p.precio_venta, 'activo', coalesce(p.estado,true))
                     order by p.factor_conversion) presentaciones
      from mos.productos p where p.tipo_producto::text = 'PRESENTACION' group by p.sku_base
  ),
  derq as (
    select d.codigo_producto_base ref,
           jsonb_agg(jsonb_build_object('sku', d.sku_base, 'nombre', d.descripcion, 'codigo', d.codigo_barra,
                     'factor', d.factor_conversion, 'precio', d.precio_venta, 'costo', d.precio_costo,
                     'activo', coalesce(d.estado,true)) order by d.descripcion) derivados
      from mos.productos d where d.tipo_producto::text = 'DERIVADO' group by d.codigo_producto_base
  ),
  eqq as (
    select e.sku_base,
           jsonb_agg(jsonb_build_object('codigo', e.codigo_barra, 'descripcion', e.descripcion,
                     'activo', coalesce(e.activo,true)) order by e.codigo_barra) equivalencias
      from mos.equivalencias e where nullif(btrim(e.sku_base),'') is not null group by e.sku_base
  ),
  trq as (
    select t.sku_base, t.tramos from mos.precio_tramos t
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'idProducto', b.id_producto, 'sku', b.sku_base, 'codigo', b.codigo_barra, 'nombre', b.descripcion,
           'descIa', b.descripcion_ia, 'categoria', b.categoria, 'unidad', b.unidad, 'granel', b.granel,
           'activo', b.activo, 'precio', b.precio_venta, 'costo', b.precio_costo, 'margen', b.margen_pct,
           'presentaciones', coalesce(pr.presentaciones,'[]'::jsonb),
           'derivados',      coalesce(de.derivados,'[]'::jsonb),
           'equivalencias',  coalesce(eq.equivalencias,'[]'::jsonb),
           'tramos',         coalesce(tr.tramos,'[]'::jsonb)
         ) order by b.categoria nulls last, b.descripcion), '[]'::jsonb)
    into v_items
    from base b
    left join presq pr on pr.sku_base = b.sku_base
    left join derq  de on de.ref      = b.sku_base
    left join eqq   eq on eq.sku_base = b.sku_base
    left join trq   tr on tr.sku_base = b.sku_base;

  select jsonb_build_object(
    'productos', count(*), 'activos', count(*) filter (where coalesce(estado,true)),
    'valor', round(coalesce(sum(precio_venta) filter (where coalesce(estado,true)),0),2)
  ) into v_res from mos.productos where tipo_producto::text = 'CANONICO';

  return jsonb_build_object('ok', true, 'generado', to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI'),
    'resumen', v_res, 'items', v_items);
end $fn$;
revoke all on function mos.catalogo_export(jsonb) from public, anon;
grant execute on function mos.catalogo_export(jsonb) to authenticated, service_role;

select '1023 catalogo_export +idProducto listo' ok;
