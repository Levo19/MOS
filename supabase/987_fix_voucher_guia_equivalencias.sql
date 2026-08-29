-- [987] FIX A2 (revisión senior): el SQL 983 rebasó wh._voucher_guia sobre la versión 566 (vieja) y PERDIÓ
--  el fix de equivalencias 569/570 en TODOS los vouchers (no solo MosGo): resolución por mos.equivalencias,
--  join tolerante (codigo_barra OR id_producto, normalizado), y esProductoNuevo/esSinIdentificar por match de
--  equivalencia. Se rebasa sobre la 570 CORRECTA y se le añade SOLO el ribbon "GUÍA DE REMISIÓN" de MosGo.
create or replace function wh._voucher_guia(v_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  v_g wh.guias%rowtype; v_prov text; v_det jsonb;
  v_pk text; v_ped text; v_cli text; v_vend text; v_remision boolean := false;
begin
  select * into v_g from wh.guias where id_guia = v_id;
  if not found then return null; end if;
  select nombre into v_prov from mos.proveedores where id_proveedor = v_g.id_proveedor;

  -- [983] ¿guía de un pedido MosGo? → cliente + vendedor del pedido (para el ribbon de remisión).
  v_pk := substring(coalesce(v_g.comentario,'') from '\[pickup:(PCK-MOSGO-[^\]]+)\]');
  if v_pk is not null then
    v_remision := true;
    v_ped := regexp_replace(v_pk, '^PCK-MOSGO-', '');
    select nombre_cliente, vendedor into v_cli, v_vend from ruta.pedidos where id_pedido = v_ped;
  end if;

  -- [570] detalle con EQUIVALENCIAS (restaurado): pr por codigo_barra o id_producto; si no, por equivalencia.
  select coalesce(jsonb_agg(jsonb_build_object(
    'descripcion',     coalesce(pr.descripcion, eqp.descripcion, pn.descripcion, d.cod_producto),
    'codigoProducto',  d.cod_producto,
    'cantidad',        coalesce(d.cant_recibida, 0),
    'esProductoNuevo', (pr.id_producto is null and eq.sku_base is null and (pn.descripcion is not null or d.cod_producto like 'NLEV%')),
    'esSinIdentificar',(pr.id_producto is null and eq.sku_base is null and pn.descripcion is null and d.cod_producto not like 'NLEV%')
  ) order by d.linea), '[]'::jsonb) into v_det
  from wh.guia_detalle d
  left join mos.productos pr on (upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_producto)) or pr.id_producto = d.cod_producto)
  left join lateral (select e.sku_base from mos.equivalencias e where upper(btrim(e.codigo_barra)) = upper(btrim(d.cod_producto)) and e.activo is true limit 1) eq on (pr.id_producto is null)
  left join lateral (select px.descripcion from mos.productos px where px.sku_base = eq.sku_base
                      order by (coalesce(nullif(btrim(px.codigo_producto_base),''),'')='' and coalesce(px.factor_conversion,1)=1) desc, px.id_producto limit 1) eqp on true
  left join wh.producto_nuevo pn on pn.codigo_barra = d.cod_producto
  where d.id_guia = v_id and coalesce(d.observacion,'') <> 'ANULADO';

  return jsonb_build_object(
    'kind','guia', 'idGuia',v_g.id_guia, 'tipoGuia',coalesce(v_g.tipo,''), 'estado',coalesce(v_g.estado,''),
    'fecha',coalesce(v_g.fecha::text,''),
    'proveedor', case when v_remision then coalesce(nullif(btrim(v_cli),''),'Cliente') else coalesce(v_prov, v_g.id_proveedor, '') end,
    'usuario',coalesce(v_g.usuario,''), 'comentario',coalesce(v_g.comentario,''), 'foto',coalesce(v_g.foto,''),
    'idPreingreso',coalesce(v_g.id_preingreso,''),
    'remision', v_remision, 'cliente', coalesce(v_cli,''), 'vendedor', coalesce(v_vend,''), 'idPedido', coalesce(v_ped,''),
    'detalle', v_det);
end; $$;

select '987 fix A2 voucher_guia equivalencias+remision listo' as ok;
