-- [983] MosGo F3b — la guía del despacho de un pedido MosGo se presenta como "GUÍA DE REMISIÓN" con el
--  NOMBRE DEL CLIENTE (no un proveedor). _voucher_guia detecta la guía MOSGO por su comentario
--  '[pickup:PCK-MOSGO-<pedido>]', trae el cliente + vendedor del pedido y marca remision=true. El voucher.js
--  usa eso para el ribbon "GUÍA DE REMISIÓN" y poner al cliente como título. Solo presentación (no fiscal).
create or replace function wh._voucher_guia(v_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  v_g wh.guias%rowtype; v_prov text; v_det jsonb;
  v_pk text; v_ped text; v_cli text; v_vend text; v_remision boolean := false;
begin
  select * into v_g from wh.guias where id_guia = v_id;
  if not found then return null; end if;
  select nombre into v_prov from mos.proveedores where id_proveedor = v_g.id_proveedor;

  -- [983] ¿guía de un pedido MosGo? → cliente + vendedor del pedido.
  v_pk := substring(coalesce(v_g.comentario,'') from '\[pickup:(PCK-MOSGO-[^\]]+)\]');
  if v_pk is not null then
    v_remision := true;
    v_ped := regexp_replace(v_pk, '^PCK-MOSGO-', '');
    select nombre_cliente, vendedor into v_cli, v_vend from ruta.pedidos where id_pedido = v_ped;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'descripcion',     coalesce(pr.descripcion, pn.descripcion, d.cod_producto),
    'codigoProducto',  d.cod_producto,
    'cantidad',        coalesce(d.cant_recibida, 0),
    'esProductoNuevo', (pr.descripcion is null and (pn.descripcion is not null or d.cod_producto like 'NLEV%')),
    'esSinIdentificar',(pr.descripcion is null and pn.descripcion is null and d.cod_producto not like 'NLEV%')
  ) order by d.linea), '[]'::jsonb) into v_det
  from wh.guia_detalle d
  left join mos.productos pr on pr.codigo_barra = d.cod_producto
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

select '983 voucher guia remision mosgo listo' as ok;
