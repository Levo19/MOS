-- ════════════════════════════════════════════════════════════════════
-- 554 — Notificar a WH cuando se APRUEBA un producto nuevo ("listo para
--       salir a venta"). Antes: al aprobar un PN solo cambiaba estado a
--       APROBADO; WH se enteraba solo si abría el dashboard. Ahora se
--       emite un PUSH a los dispositivos WH (apps:['warehouseMos']) en el
--       momento de la aprobación real (no en dedup).
--
-- Solo para productos GENUINAMENTE NUEVOS (observacion 'NUEVO' o vacía).
-- EQUIVALENTE y CORREGIR_CODIGO son operaciones de código sobre productos
-- que YA estaban a la venta → no son "nuevo listo para vender" → sin push.
--
-- El push jamás rompe la aprobación (envuelto en begin/exception null).
-- ════════════════════════════════════════════════════════════════════

create or replace function wh.marcar_producto_nuevo_aprobado(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_id   text := nullif(btrim(coalesce(p->>'id_producto_nuevo','')), '');
  v_por  text := coalesce(nullif(p->>'aprobado_por',''),'MOS');
  v_obs  text := coalesce(p->>'observacion','NUEVO');
  v_estado text;
  v_desc text; v_cb text;
begin
  if coalesce((select valor from mos.config where clave='WH_MARCAR_PRODUCTO_NUEVO_APROBADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_MARCAR_PRODUCTO_NUEVO_APROBADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- [B2]
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  select estado into v_estado from wh.producto_nuevo where id_producto_nuevo = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','PRODUCTO_NUEVO_NO_ENCONTRADO'); end if;
  if upper(coalesce(v_estado,'')) = 'APROBADO' then
    return jsonb_build_object('ok',true,'dedup',true,'id_producto_nuevo',v_id);
  end if;
  update wh.producto_nuevo set estado='APROBADO', aprobado_por=v_por, fecha_aprobacion=now(), observacion=v_obs
   where id_producto_nuevo = v_id
   returning descripcion, codigo_barra into v_desc, v_cb;

  -- [554] PUSH a WH: "listo para salir a venta" (solo productos nuevos reales).
  begin
    if upper(coalesce(v_obs,'')) not like 'EQUIVALENTE%' and upper(coalesce(v_obs,'')) not like 'CORREGIR%' then
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('apps', jsonb_build_array('warehouseMos')),
        'titulo', '🎉 Producto nuevo listo para vender',
        'cuerpo', coalesce(nullif(btrim(v_desc),''),'Un producto')||' ya está en el catálogo · ¡sácalo a venta!',
        'data', jsonb_build_object('tipo','wh_pn_aprobado','codigoBarra',coalesce(v_cb,''),'idProductoNuevo',v_id)
      ));
    end if;
  exception when others then null; end;

  return jsonb_build_object('ok',true,'dedup',false,'id_producto_nuevo',v_id);
end;
$function$;

grant execute on function wh.marcar_producto_nuevo_aprobado(jsonb) to anon, authenticated, service_role;
