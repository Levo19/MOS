-- 436 · Wiring re-verificacion clave en RPCs de dinero del PANEL MOS (anular_venta, editar_forma_pago, editar_cliente). Def EN VIVO.

-- me.anular_venta  (accion=ANULACION)
CREATE OR REPLACE FUNCTION me.anular_venta(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_app    text := me.jwt_app();
  v_id     text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_mot    text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'');
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol    text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth   jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_ant    text;  v_hist jsonb;
  v_rep    jsonb;  v_caja text;  v_zona text;  v_cerr boolean;  v_tot jsonb;
  v_items  jsonb := '[]'::jsonb;  v_k text;  v_v numeric;
  v_repres jsonb := null;  v_pkres jsonb := null;
  v_rvf jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'ANULACION', coalesce(p->>'idVenta',''), coalesce(p->>'app','MOS'));
  if v_rvf is not null then return v_rvf; end if;
  -- Gate restringido a ('','MOS') A PROPÓSITO: el reposo de stock anidado (me.zona_registrar_guia)
  -- gatea mos._claim_ok() = jwt_app in ('','MOS) → un token 'mosExpress' pasaría el gate de aquí pero
  -- el reposo anidado lo rechazaría (APP_NO_AUTORIZADA) → se anularía + descontaría pickup SIN reponer
  -- stock = fantasma asimétrico que nunca se auto-cura (la 2da llamada es noop). Bloqueando 'mosExpress'
  -- aquí, los dos efectos quedan simétricos. ME tiene su propio anular (Caja.gs) por service_role ('').
  if v_app not in ('','MOS') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido'); end if;

  -- [500x] lock por venta ANTES del FOR UPDATE (mismo orden lock→row que confirmar/directo/editar,
  -- sin ABBA): serializa la anulación con un cobro en vuelo de la misma venta.
  perform pg_advisory_xact_lock(hashtext('cobro:'||v_id));
  select forma_pago, historial_cambios into v_ant, v_hist
  from me.ventas where id_venta = v_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Venta '||v_id||' no encontrada');
  end if;

  -- IDEMPOTENCIA (money-critical): si ya está ANULADO%, no re-disparar stock ni pickup.
  if upper(coalesce(v_ant,'')) like 'ANULADO%' then
    return jsonb_build_object('ok', true, 'noop', true, 'mensaje', 'Venta ya estaba anulada');
  end if;

  -- 1) Marcar ANULADO + historial (transición única gracias al guard de arriba).
  update me.ventas
    set forma_pago = 'ANULADO',
        historial_cambios = me._venta_hist_append(v_hist, jsonb_build_object(
          'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
          'source', 'ME_ANULAR_VENTA', 'accion', 'anular_venta_interna',
          'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes',coalesce(v_ant,''),'despues','ANULADO')),
          'autorizadoPor', v_auth, 'motivo', v_mot)),
        updated_at = now()
    where id_venta = v_id;

  -- [500x] anular cualquier cobro ASIGNADO vivo de esta venta (no dejar un cobro huérfano sobre un
  -- ticket ANULADO; el cajero no debe intentar cobrarlo).
  update me.creditos_cobro_asignado
     set estado='CANCELADO_ANULACION', fecha_res=now(), razon='Venta anulada', updated_at=now()
   where id_venta = v_id and upper(coalesce(estado,''))='ASIGNADO';

  -- Datos para reposición + pickup (lectura; mismas cantidades que descontó el cierre).
  v_rep  := me.venta_reposicion_datos(v_id);
  v_caja := coalesce(v_rep->>'id_caja','');
  v_cerr := coalesce((v_rep->>'caja_cerrada')::boolean, false);
  v_zona := coalesce(v_rep->>'zona','');
  v_tot  := coalesce(v_rep->'totales_por_cod','{}'::jsonb);

  -- 2) Reposición de stock SOLO si la caja ya cerró (su descuento ya ocurrió). Idempotente por
  --    idGuia 'ANUL:<id>'. ATÓMICA: si zona_registrar_guia LANZA (error real), todo el anular hace
  --    rollback → sin stock fantasma ni reposición perdida; el usuario reintenta limpio (no es noop
  --    porque forma_pago no se commiteó). Un {ok:false} normal NO lanza (no aplica acá: ENTRADA válida).
  if v_cerr and v_zona <> '' and jsonb_typeof(v_tot)='object' then
    for v_k, v_v in select key, value::numeric from jsonb_each_text(v_tot) loop
      if v_v > 0 then
        v_items := v_items || jsonb_build_array(jsonb_build_object('cod_barras', v_k, 'cantidad', v_v));
      end if;
    end loop;
    if jsonb_array_length(v_items) > 0 then
      v_repres := me.zona_registrar_guia(jsonb_build_object(
        'idGuia', 'ANUL:'||v_id, 'zona', v_zona, 'tipo', 'ENTRADA',
        'items', v_items, 'usuario', coalesce(v_user,''), 'origen', 'MOS_ANULAR'));
    end if;
  end if;

  -- 3) Descontar del pickup origen en WH (cross-app, MISMA tx → atómico). "Pickup no encontrado"
  --    devuelve {ok:false} SIN lanzar (caso normal best-effort: el pickup ya cerró o no existe) →
  --    el anular igual commitea. Solo un error SQL real (lock, etc.) lanza → rollback → retry limpio.
  --    Atómico evita el doble-descuento del pickup (NO idempotente) ante un retry tras fallo parcial.
  if v_caja <> '' and jsonb_typeof(v_tot)='object' and v_tot <> '{}'::jsonb then
    v_items := '[]'::jsonb;
    for v_k, v_v in select key, value::numeric from jsonb_each_text(v_tot) loop
      if v_v > 0 then
        v_items := v_items || jsonb_build_array(jsonb_build_object('codigoBarra', v_k, 'cantidad', v_v));
      end if;
    end loop;
    if jsonb_array_length(v_items) > 0 then
      v_pkres := wh.pickup_descontar_venta(jsonb_build_object('idCaja', v_caja, 'itemsAnulados', v_items));
    end if;
  end if;

  return jsonb_build_object('ok', true, 'mensaje', 'Venta anulada correctamente',
    'idVenta', v_id, 'antes', coalesce(v_ant,''),
    'reposicion', v_repres, 'pickup', v_pkres);
end;
$function$
;

-- me.editar_forma_pago  (accion=EDITAR_CLIENTE_VENTA)
CREATE OR REPLACE FUNCTION me.editar_forma_pago(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_new   text := nullif(btrim(coalesce(p->>'formaPagoNueva','')),'');
  v_mot   text := nullif(btrim(coalesce(p->>'motivo','')),'');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_ant   text;
  v_hist  jsonb;
  v_rvf jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'EDITAR_CLIENTE_VENTA', coalesce(p->>'idVenta',''), coalesce(p->>'app','MOS'));
  if v_rvf is not null then return v_rvf; end if;
  if v_app not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id  is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido'); end if;
  if v_new is null then return jsonb_build_object('ok', false, 'error', 'formaPagoNueva requerida'); end if;
  if v_mot is null then return jsonb_build_object('ok', false, 'error', 'motivo es obligatorio para auditoría'); end if;

  -- [500x MED] tomar el lock de la venta ANTES del FOR UPDATE (mismo namespace 'cobro:'||idVenta que
  -- confirmar/directo, y en el MISMO orden lock→row para no crear ABBA): serializa la edición manual
  -- de forma_pago con un cobro en vuelo de la misma venta.
  perform pg_advisory_xact_lock(hashtext('cobro:'||v_id));
  select forma_pago, historial_cambios into v_ant, v_hist
  from me.ventas where id_venta = v_id for update;   -- 264: FOR UPDATE serializa read-then-append
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Venta '||v_id||' no encontrada');
  end if;
  if upper(coalesce(v_ant,'')) like 'ANULADO%' then
    return jsonb_build_object('ok', false, 'error', 'No se puede modificar un ticket anulado');
  end if;

  -- [500x MED] si el ticket deja de ser un crédito pendiente, anular cualquier cobro ASIGNADO vivo
  -- (si no, el cajero podría cobrarlo otra vez = doble cobro de la misma deuda).
  if upper(v_new) not in ('CREDITO','POR_COBRAR') then
    update me.creditos_cobro_asignado
       set estado='CANCELADO_ADMIN', fecha_res=now(),
           razon='Anulado por edición de forma de pago', updated_at=now()
     where id_venta = v_id and upper(coalesce(estado,''))='ASIGNADO';
  end if;

  update me.ventas
    set forma_pago = v_new,
        historial_cambios = me._venta_hist_append(v_hist, jsonb_build_object(
          'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
          'source', 'ME_EDITAR_FORMA_PAGO', 'accion', 'editar_forma_pago',
          'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes',coalesce(v_ant,''),'despues',v_new)),
          'autorizadoPor', v_auth, 'motivo', v_mot)),
        updated_at = now()
    where id_venta = v_id;

  return jsonb_build_object('ok', true, 'mensaje', 'Forma de pago actualizada',
    'idVenta', v_id, 'antes', coalesce(v_ant,''), 'despues', v_new);
end;
$function$
;

-- me.editar_cliente  (accion=EDITAR_CLIENTE_VENTA)
CREATE OR REPLACE FUNCTION me.editar_cliente(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_doc   text := btrim(coalesce(p->>'clienteDoc',''));
  v_nom   text := btrim(coalesce(p->>'clienteNombre',''));
  v_dir   text := nullif(btrim(coalesce(p->>'clienteDireccion','')),'');
  v_mot   text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_tid   text := btrim(coalesce(p->>'tipoId',''));   -- [417] tipo SUNAT explícito (manda sobre inferencia)
  v_tipo  text;  v_nf text;  v_docA text;  v_nomA text;  v_hist jsonb;
  v_tdc   smallint;
  v_cambios jsonb := '[]'::jsonb;
  v_rvf jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'EDITAR_CLIENTE_VENTA', coalesce(p->>'idVenta',''), coalesce(p->>'app','MOS'));
  if v_rvf is not null then return v_rvf; end if;
  if v_app not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido'); end if;
  if v_tid not in ('','0','1','4','6','7') then
    return jsonb_build_object('ok', false, 'error', 'tipoId inválido (catálogo 06: 0/1/4/6/7)');
  end if;

  select tipo_doc, nf_estado, cliente_doc, cliente_nombre, historial_cambios
    into v_tipo, v_nf, v_docA, v_nomA, v_hist
  from me.ventas where id_venta = v_id for update;   -- 264: FOR UPDATE serializa read-then-append
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Venta '||v_id||' no encontrada');
  end if;

  if coalesce(v_tipo,'') <> 'NOTA_DE_VENTA' and coalesce(v_nf,'') = 'EMITIDO' then
    return jsonb_build_object('ok', false,
      'error', 'CPE emitido ('||coalesce(v_tipo,'')||') no se puede editar. Solicite la baja del CPE primero.');
  end if;

  -- [417] tipo_doc_cliente: explícito si vino; la inferencia de respaldo exige
  -- prefijo RUC REAL para marcar 6 (un CE/Pasaporte numérico de 11 díg ya no
  -- se disfraza de RUC → no habilita FACTURA). Catálogo 06: 1 DNI · 4 CE · 6 RUC · 7 Pasaporte.
  v_tdc := case
             when v_tid <> '' then case v_tid when '1' then 1 when '4' then 4 when '6' then 6 when '7' then 7 else 0 end
             when v_doc ~ '^\d{8}$' then 1
             when v_doc ~ '^(10|15|16|17|20)\d{9}$' then 6
             else 0
           end;

  if coalesce(v_docA,'') <> v_doc then
    v_cambios := v_cambios || jsonb_build_array(jsonb_build_object('campo','Cliente_Doc','antes',coalesce(v_docA,''),'despues',v_doc));
  end if;
  if coalesce(v_nomA,'') <> v_nom then
    v_cambios := v_cambios || jsonb_build_array(jsonb_build_object('campo','Cliente_Nombre','antes',coalesce(v_nomA,''),'despues',v_nom));
  end if;

  update me.ventas
    set cliente_doc = v_doc,
        cliente_nombre = v_nom,
        tipo_doc_cliente = v_tdc,
        historial_cambios = case when jsonb_array_length(v_cambios) > 0
          then me._venta_hist_append(v_hist, jsonb_build_object(
            'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
            'source', 'ME_EDITAR_CLIENTE', 'accion', 'editar_cliente',
            'cambios', v_cambios, 'autorizadoPor', v_auth, 'motivo', v_mot))
          else historial_cambios end,
        updated_at = now()
    where id_venta = v_id;

  -- Back-fill del directorio de clientes frecuentes (paridad con verificarYAgregaCliente del GAS).
  -- No pisa nombre/direccion existentes con vacío (solo rellena si estaban vacíos).
  if v_doc <> '' and v_nom <> '' then
    insert into me.clientes_frecuentes (documento, nombre, tipo_doc, tipo_id, direccion)
    values (v_doc, v_nom, v_tdc::text, case when v_tid <> '' then v_tid else case v_tdc when 1 then '1' when 6 then '6' else '' end end, v_dir)
    on conflict (documento) do update
      set nombre = case when btrim(coalesce(me.clientes_frecuentes.nombre,''))='' then excluded.nombre else me.clientes_frecuentes.nombre end,
          tipo_id = case when btrim(excluded.tipo_id) <> '' then excluded.tipo_id else me.clientes_frecuentes.tipo_id end,
          direccion = coalesce(nullif(excluded.direccion,''), me.clientes_frecuentes.direccion);
  end if;

  return jsonb_build_object('ok', true, 'mensaje', 'Cliente actualizado',
    'idVenta', v_id, 'cambios', jsonb_array_length(v_cambios));
end;
$function$
;

