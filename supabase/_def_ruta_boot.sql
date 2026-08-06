CREATE OR REPLACE FUNCTION mos.ruta_boot(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_prods jsonb; v_clis jsonb; v_pct numeric;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'codigo_barra', pr.codigo_barra, 'descripcion', pr.descripcion,
    'unidad', coalesce(pr.unidad,'NIU'), 'precio_venta', pr.precio_venta,
    'tramos', coalesce(pr.tramos_mayoreo,'[]'::jsonb),
    'stock', coalesce(s.cantidad_disponible,0)
  ) order by pr.descripcion), '[]'::jsonb) into v_prods
  from mos.productos pr
  left join wh.stock s on s.cod_producto = pr.codigo_barra
  where pr.estado = true and pr.canal_mayoreo = true;

  select coalesce(jsonb_agg(jsonb_build_object(
    'documento', cf.documento, 'nombre', cf.nombre, 'tipo_doc', cf.tipo_doc,
    'direccion', coalesce(cf.direccion,''),
    'tipo_negocio', coalesce(ce.tipo_negocio,''), 'direccion_entrega', coalesce(ce.direccion_entrega,''),
    'telefono_wsp', coalesce(ce.telefono_wsp,''), 'dia_visita', coalesce(ce.dia_visita,''),
    'notas', coalesce(ce.notas,'')
  ) order by cf.nombre), '[]'::jsonb) into v_clis
  from me.clientes_frecuentes cf
  left join ruta.clientes_ext ce on ce.documento = cf.documento;

  select (v)::text::numeric into v_pct from ruta.config where k = 'comision_pct';
  return jsonb_build_object('ok', true, 'productos', v_prods, 'clientes', v_clis,
    'comision_pct', coalesce(v_pct, 3));
end; $function$
