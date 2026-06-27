CREATE OR REPLACE FUNCTION me.convertir_nv_cpe(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_app   text := me.jwt_app();
  v_idnv  text := nullif(btrim(coalesce(p->>'idVentaNV','')),'');
  v_tipo  text := upper(coalesce(p->>'tipoDocNuevo',''));
  v_doc   text := btrim(coalesce(p->>'clienteDoc',''));
  v_nom   text := btrim(coalesce(p->>'clienteNombre',''));
  v_dir   text := coalesce(p->>'clienteDireccion','');
  v_serie text := nullif(btrim(coalesce(p->>'serieNueva','')),'');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_nv    me.ventas%rowtype;
  v_items jsonb := '[]'::jsonb;
  v_d     record;
  v_tipoc int;
  v_local text;
  v_fac   jsonb;
  v_corr  text; v_estado text; v_nfest text; v_newid text;
  v_total numeric;
  v_linea int := 0;
  v_ins   int;
  v_exist text;
  v_caja_abierta boolean;
begin
  if v_app not in ('MOS','mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if not fac._on() then
    return jsonb_build_object('ok', false, 'error', 'FAC_DESACTIVADO');
  end if;
  if v_idnv  is null then return jsonb_build_object('ok', false, 'error', 'idVentaNV requerido'); end if;
  if v_tipo not in ('BOLETA','FACTURA') then return jsonb_build_object('ok', false, 'error', 'tipoDocNuevo debe ser BOLETA o FACTURA'); end if;
  if v_serie is null then return jsonb_build_object('ok', false, 'error', 'serieNueva requerida'); end if;
  if v_tipo = 'BOLETA'  and v_doc !~ '^\d{8}$'  then return jsonb_build_object('ok', false, 'error', 'BOLETA requiere DNI de 8 dígitos'); end if;
  if v_tipo = 'FACTURA' and v_doc !~ '^\d{11}$' then return jsonb_build_object('ok', false, 'error', 'FACTURA requiere RUC de 11 dígitos'); end if;

  v_local := 'CONVERT-' || v_idnv;

  select * into v_nv from me.ventas where id_venta = v_idnv for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Venta original '||v_idnv||' no encontrada'); end if;

  -- Idempotencia: NV ya convertida → devolver el CPE existente.
  if upper(coalesce(v_nv.forma_pago,'')) like 'ANULADO%' then
    if v_nv.forma_pago = 'ANULADO_CONVERSION' then
      select id_venta into v_exist from me.ventas where ref_local = v_local limit 1;
      if v_exist is not null then
        return jsonb_build_object('ok', true, 'dedup', true, 'idVentaNuevo', v_exist,
          'correlativoNuevo', (select correlativo from me.ventas where id_venta = v_exist),
          'mensaje', 'La NV ya había sido convertida (idempotente)');
      end if;
    end if;
    return jsonb_build_object('ok', false, 'error', 'La venta original ya fue anulada/convertida');
  end if;

  if coalesce(v_nv.tipo_doc,'') <> 'NOTA_DE_VENTA' then
    return jsonb_build_object('ok', false, 'error', 'Solo se convierten NOTA_DE_VENTA. Esta es '||coalesce(v_nv.tipo_doc,''));
  end if;

  -- H8: la conversión directa solo procede si la caja origen está ABIERTA (el CPE hereda esa caja
  -- con fecha=now()). Si está cerrada/arqueada → CAJA_NO_ABIERTA → el front cae a GAS (que maneja
  -- post-cierre). Evita meter un ticket en una caja ya conciliada (descuadre cross-período).
  select (estado = 'ABIERTA') into v_caja_abierta from me.cajas where id_caja = v_nv.id_caja limit 1;
  if not coalesce(v_caja_abierta, false) then
    return jsonb_build_object('ok', false, 'error', 'CAJA_NO_ABIERTA');
  end if;

  -- H2: items con base recomputada desde el subtotal COBRADO (gravado: subtotal/1.18; otros: subtotal),
  -- para que la línea NubeFact tenga IGV consistente (≥0) y no dependa de valor_unitario histórico/NULL.
  select coalesce(jsonb_agg(jsonb_build_object(
      'sku', d.sku, 'nombre', d.nombre, 'cantidad', d.cantidad, 'precio', d.precio,
      'valor_unitario', case
          when coalesce(d.tipo_igv,1) = 1 and coalesce(d.cantidad,0) > 0
            then round((coalesce(d.subtotal,0)/1.18) / d.cantidad, 2)
          when coalesce(d.cantidad,0) > 0
            then round(coalesce(d.subtotal,0) / d.cantidad, 2)
          else 0 end,
      'subtotal', coalesce(d.subtotal,0), 'tipo_igv', coalesce(d.tipo_igv,1),
      'unidad_medida', coalesce(d.unidad_medida,'NIU'), 'cod_sunat', '', 'cod_barras', coalesce(d.cod_barras,'')
    ) order by d.linea), '[]'::jsonb)
  into v_items
  from me.ventas_detalle d where d.id_venta = v_idnv;
  if jsonb_array_length(v_items) = 0 then return jsonb_build_object('ok', false, 'error', 'La venta original no tiene items'); end if;

  v_total := coalesce(v_nv.total, 0);
  v_tipoc := case when v_tipo = 'FACTURA' then 6 else 1 end;

  v_fac := fac.emitir_cpe(jsonb_build_object(
    'tipo_doc', v_tipo, 'serie', v_serie,
    'cliente', jsonb_build_object('tipo', v_tipoc, 'doc', v_doc, 'nombre', v_nom, 'direccion', v_dir),
    'items', v_items, 'total', v_total,
    'local_id', v_local, 'origen', 'CONVERT', 'ref_externa', v_idnv, 'creado_por', coalesce(v_user,'')));
  if coalesce(v_fac->>'status','') <> 'success' then
    return jsonb_build_object('ok', false, 'error', coalesce(v_fac->>'error','emisión fac falló'), 'fac', v_fac);
  end if;
  v_corr   := v_fac->>'correlativo';
  v_estado := v_fac->>'estado';
  v_nfest  := case when v_estado in ('EMITIDO','STUB','PENDIENTE') then v_estado else 'RECHAZADO' end;

  v_newid := 'V-' || (floor(extract(epoch from clock_timestamp())*1000))::bigint::text
                  || '-' || substr(md5(random()::text || clock_timestamp()::text || v_local), 1, 8);
  insert into me.ventas (id_venta, fecha, vendedor, estacion, cliente_doc, cliente_nombre, total,
     tipo_doc, forma_pago, correlativo, id_caja, dispositivo_id, estado_envio, ref_local, obs,
     tipo_doc_cliente, nf_estado, nf_hash, nf_enlace, zona_id)
  values (v_newid, now(), coalesce(nullif(v_user,''), v_nv.vendedor), v_nv.estacion, v_doc, v_nom, v_total,
     v_tipo, v_nv.forma_pago, v_corr, v_nv.id_caja, v_nv.dispositivo_id, 'COMPLETADO', v_local,
     'Conversión retroactiva de '||v_idnv, v_tipoc, v_nfest, v_fac->>'hash', v_fac->>'pdf', coalesce(v_nv.zona_id,''))
  on conflict (ref_local) where ref_local is not null and ref_local <> '' do nothing;

  -- H1: guard de row_count. Si el header NO se grabó (ya existía me.ventas con este ref_local), NO seguir
  -- con detalle huérfano ni anular: devolver la venta existente (dedup) o RAISE (rollback del correlativo).
  get diagnostics v_ins = row_count;
  if v_ins = 0 then
    select id_venta into v_exist from me.ventas where ref_local = v_local limit 1;
    if v_exist is not null then
      return jsonb_build_object('ok', true, 'dedup', true, 'idVentaNuevo', v_exist,
        'correlativoNuevo', (select correlativo from me.ventas where id_venta = v_exist),
        'mensaje', 'CPE ya registrado para esta conversión (idempotente)');
    end if;
    raise exception 'INSERT_INCONSISTENTE: header CONVERT % no grabó y no se halló fila por ref_local', v_local;
  end if;

  for v_d in select * from me.ventas_detalle where id_venta = v_idnv order by linea loop
    v_linea := v_linea + 1;
    insert into me.ventas_detalle (id_venta, linea, sku, nombre, cantidad, precio, subtotal,
       cod_barras, valor_unitario, tipo_igv, unidad_medida)
    values (v_newid, v_linea, v_d.sku, v_d.nombre, v_d.cantidad, v_d.precio, v_d.subtotal,
       coalesce(v_d.cod_barras,''),
       -- [LOW18 500x-2] valor_unitario recomputado (= el que va a NubeFact en v_items), no el histórico
       -- de la NV, para que la línea-sombra del CPE sea coherente con el IGV emitido.
       case
         when coalesce(v_d.tipo_igv,1)=1 and coalesce(v_d.cantidad,0)>0 then round((coalesce(v_d.subtotal,0)/1.18)/v_d.cantidad,2)
         when coalesce(v_d.cantidad,0)>0 then round(coalesce(v_d.subtotal,0)/v_d.cantidad,2)
         else 0 end,
       v_d.tipo_igv, v_d.unidad_medida)
    on conflict (id_venta, linea) do nothing;
  end loop;

  update me.ventas
    set forma_pago = 'ANULADO_CONVERSION',
        obs = 'Convertido a '||v_tipo||' '||v_corr,
        historial_cambios = me._venta_hist_append(v_nv.historial_cambios, jsonb_build_object(
          'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
          'source', 'ME_CONVERTIR_NV_CPE', 'accion', 'anular_por_conversion',
          'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes',coalesce(v_nv.forma_pago,''),'despues','ANULADO_CONVERSION')),
          'autorizadoPor', v_auth,
          'ref', jsonb_build_object('idVentaCPE', v_newid, 'correlativoCPE', v_corr, 'tipoDoc', v_tipo))),
        updated_at = now()
    where id_venta = v_idnv;

  return jsonb_build_object('ok', true, 'idVentaNuevo', v_newid, 'correlativoNuevo', v_corr,
    'nfEstado', v_nfest, 'nfHash', coalesce(v_fac->>'hash',''), 'nfEnlace', coalesce(v_fac->>'pdf',''),
    'qr', coalesce(v_fac->>'qr',''));
end;
$function$
;
