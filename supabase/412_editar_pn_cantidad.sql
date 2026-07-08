-- 412 · wh.editar_pn_cantidad → reemplaza el bridge GAS wh_editarPNCantidad (MOS edita la cantidad de un
-- producto-nuevo PENDIENTE durante la aprobación). Orquesta atómico: guard estado + update PN + sync lote
-- (wh._sync_lote_desde_detalle, ya portado) + propaga a guia_detalle. Antes DIFERIDO por el port del lote.
-- Gate MOS+warehouseMos (lo llama el panel MOS). Cero-GAS.

create or replace function wh.editar_pn_cantidad(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_idpn  text := btrim(coalesce(p->>'idProductoNuevo',''));
  v_cant  numeric := coalesce((p->>'cantidad')::numeric, 0);
  v_usr   text := btrim(coalesce(p->>'usuario',''));
  v_cod text; v_guia text; v_fv text; v_est text; v_n int;
begin
  if coalesce(me.jwt_app(),'') not in ('MOS','warehouseMos') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_idpn = '' then return jsonb_build_object('ok',false,'error','Falta idProductoNuevo'); end if;
  if not (v_cant > 0) then return jsonb_build_object('ok',false,'error','Cantidad debe ser > 0'); end if;

  select codigo_barra, id_guia, coalesce(fecha_vencimiento::text,''), upper(coalesce(estado,''))
    into v_cod, v_guia, v_fv, v_est
  from wh.producto_nuevo where id_producto_nuevo = v_idpn;
  if not found then return jsonb_build_object('ok',false,'error','PN no encontrado: '||v_idpn); end if;
  if v_est <> 'PENDIENTE' then
    return jsonb_build_object('ok',false,'error','PN ya fue procesado (estado='||v_est||'), no se puede editar la cantidad');
  end if;

  -- 1) actualizar la cantidad del PN
  update wh.producto_nuevo set cantidad = v_cant where id_producto_nuevo = v_idpn;

  -- 2) sincronizar el lote si el PN tiene fecha de vencimiento (idempotente por cod+guia+fecha)
  if nullif(v_fv,'') is not null and coalesce(v_cod,'') <> '' then
    begin
      perform wh._sync_lote_desde_detalle('', v_cod, v_cant, left(v_fv,10),
              coalesce(nullif(v_guia,''), 'PN:'||v_idpn), null);
    exception when others then null;  -- el lote es best-effort; el edit de cantidad no debe fallar por esto
    end;
  end if;

  -- 3) propagar a guia_detalle (por id_producto_nuevo; fallback cod+guia)
  update wh.guia_detalle set cant_esperada = v_cant, cant_recibida = v_cant
   where id_producto_nuevo = v_idpn;
  get diagnostics v_n = row_count;
  if v_n = 0 and coalesce(v_cod,'') <> '' and coalesce(v_guia,'') <> '' then
    update wh.guia_detalle set cant_esperada = v_cant, cant_recibida = v_cant
     where cod_producto = v_cod and id_guia = v_guia;
  end if;

  return jsonb_build_object('ok',true,'data', jsonb_build_object('idProductoNuevo',v_idpn,'cantidad',v_cant,'detalleActualizado',v_n));
end; $fn$;

grant execute on function wh.editar_pn_cantidad(jsonb) to authenticated, service_role, anon;
