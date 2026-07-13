-- 435 · Wiring re-verificacion clave (helper 434) en RPCs de dinero. Generado de la def EN VIVO.

-- me.cobrar_venta_directo  (accion=COBRAR_VENTA)
CREATE OR REPLACE FUNCTION me.cobrar_venta_directo(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_met   text := nullif(btrim(coalesce(p->>'metodo','')),'');
  v_caja  text := nullif(btrim(coalesce(p->>'cajaId','')),'');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_mot   text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'');
  v_ant   text; v_cajaAnt text; v_hist jsonb; v_cambios jsonb;
  v_rvf jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'COBRAR_VENTA', coalesce(p->>'idVenta',p->>'idVentaNV',p->>'idGuia',p->>'nombre',''), coalesce(p->>'app','MOS'));
  if v_rvf is not null then return v_rvf; end if;
  if v_app not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','COBRO_OFF');
  end if;
  if v_id  is null then return jsonb_build_object('ok',false,'error','idVenta requerido'); end if;
  if v_met is null then return jsonb_build_object('ok',false,'error','metodo requerido'); end if;

  -- lock por VENTA (mismo namespace que confirmar/directo/anular) → un COBRAR_VENTA no corre en
  -- paralelo con un cobro/anulación de la misma venta. Leo bajo el lock (FOR UPDATE).
  perform pg_advisory_xact_lock(hashtext('cobro:'||v_id));
  select forma_pago, coalesce(id_caja,''), historial_cambios into v_ant, v_cajaAnt, v_hist
  from me.ventas where id_venta = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Venta '||v_id||' no encontrada'); end if;

  -- ANULADO% es terminal (paridad GAS): no se cobra ni se revierte una venta anulada.
  if upper(coalesce(v_ant,'')) like 'ANULADO%' then
    return jsonb_build_object('ok',false,'error','La venta está ANULADA — no se puede cambiar su forma de pago');
  end if;

  v_cambios := jsonb_build_array(jsonb_build_object('campo','FormaPago','antes',coalesce(v_ant,''),'despues',v_met));
  if v_caja is not null and v_caja <> coalesce(v_cajaAnt,'') then
    v_cambios := v_cambios || jsonb_build_array(jsonb_build_object('campo','ID_Caja','antes',coalesce(v_cajaAnt,''),'despues',v_caja));
  end if;

  update me.ventas
     set forma_pago = v_met,
         id_caja = case when v_caja is not null then v_caja else id_caja end,   -- solo si viene cajaId (paridad GAS)
         historial_cambios = me._venta_hist_append(v_hist, jsonb_build_object(
           'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
           'source','ME_COBRAR_VENTA','accion','cobrar_venta',
           'cambios', v_cambios, 'autorizadoPor', v_auth, 'motivo', v_mot)),
         updated_at = now()
   where id_venta = v_id;

  return jsonb_build_object('ok',true,'via','directo','mensaje','Venta cobrada correctamente',
    'idVenta',v_id,'antes',coalesce(v_ant,''),'despues',v_met);
end;
$function$
;

-- me.creditar_venta_directo  (accion=CREDITAR_VENTA)
CREATE OR REPLACE FUNCTION me.creditar_venta_directo(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_obs   text := coalesce(p->>'obs','');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_ant   text; v_obsAnt text; v_hist jsonb;
  v_rvf jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'CREDITAR_VENTA', coalesce(p->>'idVenta',p->>'idVentaNV',p->>'idGuia',p->>'nombre',''), coalesce(p->>'app','MOS'));
  if v_rvf is not null then return v_rvf; end if;
  if v_app not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','COBRO_OFF');
  end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idVenta requerido'); end if;

  perform pg_advisory_xact_lock(hashtext('cobro:'||v_id));
  select forma_pago, coalesce(obs,''), historial_cambios into v_ant, v_obsAnt, v_hist
  from me.ventas where id_venta = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Venta '||v_id||' no encontrada'); end if;

  if upper(coalesce(v_ant,'')) like 'ANULADO%' then
    return jsonb_build_object('ok',false,'error','La venta está ANULADA — no se puede creditar');
  end if;

  update me.ventas
     set forma_pago = 'CREDITO', obs = v_obs,
         historial_cambios = me._venta_hist_append(v_hist, jsonb_build_object(
           'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
           'source','ME_CREDITAR_VENTA','accion','convertir_a_credito',
           'cambios', jsonb_build_array(
             jsonb_build_object('campo','FormaPago','antes',coalesce(v_ant,''),'despues','CREDITO'),
             jsonb_build_object('campo','Obs','antes',coalesce(v_obsAnt,''),'despues',v_obs)),
           'autorizadoPor', v_auth, 'motivo', coalesce(nullif(v_obs,''),''))),
         updated_at = now()
   where id_venta = v_id;

  return jsonb_build_object('ok',true,'via','directo','mensaje','Crédito registrado',
    'idVenta',v_id,'antes',coalesce(v_ant,''));
end;
$function$
;

-- me.anular_venta_directo  (accion=ANULACION)
CREATE OR REPLACE FUNCTION me.anular_venta_directo(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_app    text := me.jwt_app();
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_res    jsonb;
  v_rvf jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'ANULACION', coalesce(p->>'idVenta',p->>'idVentaNV',p->>'idGuia',p->>'nombre',''), coalesce(p->>'app','MOS'));
  if v_rvf is not null then return v_rvf; end if;
  -- Gate del POS ME: token mosExpress (o MOS). Mismo criterio que cobrar/creditar_venta_directo.
  if v_app not in ('mosExpress', 'MOS') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- Kill-switch (paridad con COBRO_OFF): OFF → el front NO cae a GAS, reporta no-disponible.
  if coalesce((select valor from mos.config where clave = 'ME_ANULAR_DIRECTO' limit 1), '0') <> '1' then
    return jsonb_build_object('ok', false, 'error', 'ME_ANULAR_DIRECTO_OFF');
  end if;

  -- Elevar el claim a MOS (transaction-local) para que el reposo anidado autorice; reusar me.anular_venta
  -- ÍNTEGRO (atómico/idempotente). Restaurar el claim al final (el rollback lo revierte igual si algo lanza).
  perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app', 'MOS'))::text, true);
  v_res := me.anular_venta(p);
  perform set_config('request.jwt.claims', v_claims::text, true);
  return v_res;
end;
$function$
;

-- me.convertir_nv_cpe  (accion=CONVERTIR_NV_A_CPE)
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
  v_exist text;
  v_rvf jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'CONVERTIR_NV_A_CPE', coalesce(p->>'idVenta',p->>'idVentaNV',p->>'idGuia',p->>'nombre',''), coalesce(p->>'app','MOS'));
  if v_rvf is not null then return v_rvf; end if;
  -- Gate: panel MOS o ME (mismas apps que fac._app_ok). service_role ('') NO: fac lo rechazaría.
  if v_app not in ('MOS','mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- Kill-switch fiscal: si la emisión directa está OFF → el front cae a GAS (inerte).
  if not fac._on() then
    return jsonb_build_object('ok', false, 'error', 'FAC_DESACTIVADO');
  end if;
  if v_idnv  is null then return jsonb_build_object('ok', false, 'error', 'idVentaNV requerido'); end if;
  if v_tipo not in ('BOLETA','FACTURA') then return jsonb_build_object('ok', false, 'error', 'tipoDocNuevo debe ser BOLETA o FACTURA'); end if;
  -- serieNueva es OPCIONAL: si no viene, fac.emitir_cpe la deriva de la ZONA de emisión de la NV.
  -- Las validaciones de CLIENTE (factura RUC+nombre+dir; boleta>700 exige ID; bancarización) las hace
  -- fac.emitir_cpe server-side (una sola fuente de verdad, misma regla que ME/MOS) → NO duplicar aquí:
  -- la boleta ≤ S/700 puede ir SIN documento (VARIOS), como en el POS.

  v_local := 'CONVERT-' || v_idnv;

  -- Leer la NV (lock).
  select * into v_nv from me.ventas where id_venta = v_idnv for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Venta original '||v_idnv||' no encontrada'); end if;

  -- Idempotencia: si la NV YA está convertida y existe el CPE → devolverlo (retry-friendly).
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

  -- Construir items desde el detalle de la NV (mismas líneas → mismo físico).
  select coalesce(jsonb_agg(jsonb_build_object(
      'sku', d.sku, 'nombre', d.nombre, 'cantidad', d.cantidad, 'precio', d.precio,
      'valor_unitario', d.valor_unitario, 'subtotal', d.subtotal, 'tipo_igv', d.tipo_igv,
      'unidad_medida', d.unidad_medida, 'cod_sunat', '', 'cod_barras', coalesce(d.cod_barras,'')
    ) order by d.linea), '[]'::jsonb)
  into v_items
  from me.ventas_detalle d where d.id_venta = v_idnv;
  if jsonb_array_length(v_items) = 0 then return jsonb_build_object('ok', false, 'error', 'La venta original no tiene items'); end if;

  v_total := coalesce(v_nv.total, 0);
  -- tipo_doc_cliente por el DOC real: RUC 11 → 6, DNI 8 → 1, si no → 0 (VARIOS). fac valida factura/>700.
  v_tipoc := case when v_doc ~ '^\d{11}$' then 6 when v_doc ~ '^\d{8}$' then 1 else 0 end;

  -- EMITIR vía la capa central fac (mintea correlativo + NubeFact, idempotente por local_id). Misma tx → atómico.
  v_fac := fac.emitir_cpe(jsonb_build_object(
    'tipo_doc', v_tipo, 'serie', v_serie, 'zona', coalesce(v_nv.zona_id,''),   -- serie por zona de emisión de la NV
    'medio_de_pago', coalesce(nullif(btrim(v_nv.forma_pago),''),'EFECTIVO'),   -- bancarización (medio de la NV; fallback si vacío)
    'cliente', jsonb_build_object('tipo', v_tipoc, 'doc', v_doc, 'nombre', v_nom, 'direccion', v_dir),
    'items', v_items, 'total', v_total,
    'local_id', v_local, 'origen', 'CONVERT', 'ref_externa', v_idnv, 'creado_por', coalesce(v_user,'')));
  if coalesce(v_fac->>'status','') <> 'success' then
    -- FAC_DESACTIVADO/APP_NO_AUTORIZADA → front cae a GAS; rechazo/total_no_cuadra → propaga (rollback total).
    return jsonb_build_object('ok', false, 'error', coalesce(v_fac->>'error','emisión fac falló'), 'fac', v_fac);
  end if;
  v_corr   := v_fac->>'correlativo';
  v_estado := v_fac->>'estado';   -- STUB | EMITIDO | PENDIENTE | RECHAZADO
  v_nfest  := case when v_estado in ('EMITIDO','STUB','PENDIENTE') then v_estado else 'RECHAZADO' end;

  -- Crear la venta CPE. HEREDA la caja ORIGINAL de la NV (stock net −1: el cierre/guía de esa
  -- caja cubre la salida; el converter NO mueve stock). ref_local='CONVERT-<idnv>' = idempotente.
  v_newid := 'V-' || (floor(extract(epoch from clock_timestamp())*1000))::bigint::text
                  || '-' || substr(md5(random()::text || clock_timestamp()::text || v_local), 1, 8);
  insert into me.ventas (id_venta, fecha, vendedor, estacion, cliente_doc, cliente_nombre, total,
     tipo_doc, forma_pago, correlativo, id_caja, dispositivo_id, estado_envio, ref_local, obs,
     tipo_doc_cliente, nf_estado, nf_hash, nf_enlace, zona_id)
  values (v_newid, now(), coalesce(nullif(v_user,''), v_nv.vendedor), v_nv.estacion, v_doc, v_nom, v_total,
     v_tipo, v_nv.forma_pago, v_corr, v_nv.id_caja, v_nv.dispositivo_id, 'COMPLETADO', v_local,
     'Conversión retroactiva de '||v_idnv, v_tipoc, v_nfest, v_fac->>'hash', v_fac->>'pdf', coalesce(v_nv.zona_id,''))
  on conflict (ref_local) where ref_local is not null and ref_local <> '' do nothing;

  -- Detalle de la CPE (mismas líneas que la NV).
  for v_d in select * from me.ventas_detalle where id_venta = v_idnv order by linea loop
    v_linea := v_linea + 1;
    insert into me.ventas_detalle (id_venta, linea, sku, nombre, cantidad, precio, subtotal,
       cod_barras, valor_unitario, tipo_igv, unidad_medida)
    values (v_newid, v_linea, v_d.sku, v_d.nombre, v_d.cantidad, v_d.precio, v_d.subtotal,
       coalesce(v_d.cod_barras,''), v_d.valor_unitario, v_d.tipo_igv, v_d.unidad_medida)
    on conflict (id_venta, linea) do nothing;
  end loop;

  -- Anular la NV original (ANULADO_CONVERSION + obs + historial). SIN reposición de stock ni
  -- descuento de pickup (hay CPE de reemplazo; reponer dejaría el neto en 0 = sobreconteo).
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

-- me.reabrir_guia_zona  (accion=REABRIR_GUIA)
CREATE OR REPLACE FUNCTION me.reabrir_guia_zona(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id     text := nullif(btrim(coalesce(p->>'idGuia', p->>'idGuiaWH', '')), '');
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_estado text;
  v_rvf jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'REABRIR_GUIA', coalesce(p->>'idVenta',p->>'idVentaNV',p->>'idGuia',p->>'nombre',''), coalesce(p->>'app','MOS'));
  if v_rvf is not null then return v_rvf; end if;
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;

  select estado into v_estado from me.guias_cabecera where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  if upper(coalesce(v_estado,'')) = 'ABIERTA' then
    return jsonb_build_object('ok',true,'dedup',true,'idGuia',v_id,'estado','ABIERTA','eraEstado',v_estado);
  end if;

  -- reabrir + tocar el reloj (para que el autocierre vuelva a contar la inactividad desde ahora).
  update me.guias_cabecera set estado = 'ABIERTA', ultima_actividad = now() where id_guia = v_id;

  return jsonb_build_object('ok',true,'idGuia',v_id,'estado','ABIERTA','eraEstado',v_estado,'reabiertoPor',v_user);
end;
$function$
;

-- mos.bloquear_vendedor_me  (accion=BLOQUEAR_VENDEDOR)
CREATE OR REPLACE FUNCTION mos.bloquear_vendedor_me(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_nom text := nullif(btrim(coalesce(p->>'nombre','')),'');
  v_app text := coalesce(p->>'appOrigen','mosExpress');
  v_bloq boolean := coalesce((p->>'bloquear')::boolean, false);
  v_por text := coalesce(nullif(btrim(coalesce(p->>'bloqueadoPor','')),''),'admin');
  v_mot text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'bloqueo_admin');
  v_id  text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_n int;
  v_rvf jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'BLOQUEAR_VENDEDOR', coalesce(p->>'idVenta',p->>'idVentaNV',p->>'idGuia',p->>'nombre',''), coalesce(p->>'app','MOS'));
  if v_rvf is not null then return v_rvf; end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','Requiere nombre'); end if;
  if v_bloq then
    -- BLOQUEAR: fila de bloqueo sin unlock (unlock_hasta NULL = bloqueo vigente).
    update mos.bloqueos_usuario set unlock_hasta = null, motivo = v_mot, bloqueado_por = v_por, fecha_bloqueo = now()
     where upper(btrim(coalesce(nombre,''))) = upper(v_nom) or (v_id is not null and id_personal = v_id);
    get diagnostics v_n = row_count;
    if v_n = 0 then
      insert into mos.bloqueos_usuario (id_bloqueo, id_personal, nombre, app_origen, motivo, bloqueado_por, fecha_bloqueo, unlock_hasta)
      values ('BQ_'||coalesce(nullif(v_id,''),'x')||'_'||(extract(epoch from clock_timestamp())*1000)::bigint,
        coalesce(v_id,''), v_nom, v_app, v_mot, v_por, now(), null);
    end if;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('bloqueado',true));
  else
    -- DESBLOQUEAR: unlock_hasta lejano (acceso restaurado).
    update mos.bloqueos_usuario set unlock_hasta = now() + interval '100 years', desbloqueado_por = v_por
     where upper(btrim(coalesce(nombre,''))) = upper(v_nom) or (v_id is not null and id_personal = v_id);
    return jsonb_build_object('ok',true,'data',jsonb_build_object('bloqueado',false));
  end if;
end; $function$
;

