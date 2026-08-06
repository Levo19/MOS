CREATE OR REPLACE FUNCTION wh.mermas_eliminar_batch(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ids   text[] := (select coalesce(array_agg(x), '{}') from jsonb_array_elements_text(coalesce(p->'ids','[]'::jsonb)) x);
  v_lid   text := nullif(btrim(coalesce(p->>'local_id','')), '');
  v_usr   text := coalesce(p->>'usuario','');
  v_obs   text := coalesce(p->>'observacion','');
  v_guia  text;
  v_linea int := 0;
  v_n     int := 0;
  v_skip  int := 0;
  m       record;
  v_id    text;
begin
  if not wh._claim_ok() and not mos._claim_ok() then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if array_length(v_ids,1) is null then
    return jsonb_build_object('ok',false,'error','SIN_IDS'); end if;
  if v_lid is null then
    return jsonb_build_object('ok',false,'error','FALTA_LOCAL_ID'); end if;
  if not wh._dedup_nuevo(v_lid, 'mermas_eliminar_batch') then
    return jsonb_build_object('ok',true,'dedup',true); end if;

  v_guia := 'GSLOTE_' || v_lid;
  insert into wh.guias (id_guia,tipo,fecha,usuario,comentario,monto_total,estado,id_proveedor,id_zona,numero_documento,id_preingreso,foto)
  values (v_guia,'SALIDA_MERMA',now(),coalesce(nullif(v_usr,''),'sistema'),
          'Eliminación en LOTE de ' || array_length(v_ids,1) || ' merma(s)' ||
          case when v_obs <> '' then ' · ' || v_obs else '' end,
          0,'CERRADA','','','','','')
  on conflict (id_guia) do nothing;

  foreach v_id in array v_ids loop
    select * into m from wh.mermas where id_merma = v_id limit 1 for update;
    if not found or coalesce(m.cantidad_pendiente,0) <= 0 then
      v_skip := v_skip + 1; continue; end if;

    -- fila VIEJA: sus unidades seguían contadas en el stock → salen ahora (atómico)
    if not coalesce(m.stock_descontado,false) then
      update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - m.cantidad_pendiente,
                          ultima_actualizacion = now()
       where upper(cod_producto) = upper(m.cod_producto);
    end if;

    v_linea := v_linea + 1;
    insert into wh.guia_detalle (id_guia,linea,cod_producto,cant_esperada,cant_recibida,precio_unitario,id_lote,observacion,id_producto_nuevo,id_detalle,fecha_vencimiento)
    values (v_guia, v_linea, m.cod_producto, m.cantidad_pendiente, m.cantidad_pendiente,
            coalesce(m.costo_unitario,0), coalesce(m.id_lote,''),
            'Merma ' || m.id_merma || case when coalesce(m.culpa,'') <> '' then ' · culpa ' || m.culpa else '' end,
            '', 'LOTDET_' || m.id_merma, null)
    on conflict do nothing;

    update wh.mermas set
      cantidad_desechada  = coalesce(cantidad_desechada,0) + cantidad_pendiente,
      cantidad_pendiente  = 0,
      estado              = case when coalesce(cantidad_reparada,0) > 0 then 'RESUELTA' else 'DESECHADA' end,
      fecha_resolucion    = now(),
      observacion_resolucion = case when v_obs <> '' then v_obs else observacion_resolucion end,
      id_guia_salida      = v_guia
    where id_merma = v_id;
    v_n := v_n + 1;
  end loop;

  if v_n = 0 then
    -- nada eliminable: no dejar la guía vacía huérfana
    delete from wh.guias where id_guia = v_guia
      and not exists (select 1 from wh.guia_detalle d where d.id_guia = v_guia);
    return jsonb_build_object('ok',true,'eliminadas',0,'omitidas',v_skip,'id_guia_salida','');
  end if;

  return jsonb_build_object('ok',true,'id_guia_salida',v_guia,'eliminadas',v_n,'omitidas',v_skip);
end; $function$
