-- 268_me_editar_cliente_tipodoc.sql
-- me.editar_cliente: aceptar `tipoDocCliente` explícito (para Carné de Extranjería = 4,
-- Pasaporte = 7, etc., que NO se detectan por longitud 8/11). Backward-compatible: si no
-- viene, cae a la detección por longitud (8=DNI/1, 11=RUC/6, otro=0) como antes.
-- (Redefine sobre la versión 264 que ya tenía FOR UPDATE + upsert clientes_frecuentes.)
create or replace function me.editar_cliente(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $fn$
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
  v_tdc_in text := nullif(regexp_replace(coalesce(p->>'tipoDocCliente',''),'\D','','g'),'');  -- explícito si vino
  v_tipo  text;  v_nf text;  v_docA text;  v_nomA text;  v_hist jsonb;
  v_tdc   smallint;
  v_cambios jsonb := '[]'::jsonb;
begin
  if v_app not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido'); end if;

  select tipo_doc, nf_estado, cliente_doc, cliente_nombre, historial_cambios
    into v_tipo, v_nf, v_docA, v_nomA, v_hist
  from me.ventas where id_venta = v_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Venta '||v_id||' no encontrada');
  end if;

  if coalesce(v_tipo,'') <> 'NOTA_DE_VENTA' and coalesce(v_nf,'') = 'EMITIDO' then
    return jsonb_build_object('ok', false,
      'error', 'CPE emitido ('||coalesce(v_tipo,'')||') no se puede editar. Solicite la baja del CPE primero.');
  end if;

  -- tipo_doc_cliente: explícito (CE=4, Pasaporte=7, ...) si vino; si no, por longitud (compat).
  v_tdc := case
    when v_tdc_in is not null then v_tdc_in::smallint
    when length(v_doc) = 8  then 1
    when length(v_doc) = 11 then 6
    else 0 end;

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

  if v_doc <> '' and v_nom <> '' then
    insert into me.clientes_frecuentes (documento, nombre, tipo_doc, direccion)
    values (v_doc, v_nom, v_tdc::text, v_dir)
    on conflict (documento) do update
      set nombre = case when btrim(coalesce(me.clientes_frecuentes.nombre,''))='' then excluded.nombre else me.clientes_frecuentes.nombre end,
          direccion = coalesce(nullif(excluded.direccion,''), me.clientes_frecuentes.direccion);
  end if;

  return jsonb_build_object('ok', true, 'mensaje', 'Cliente actualizado',
    'idVenta', v_id, 'cambios', jsonb_array_length(v_cambios));
end;
$fn$;
revoke all on function me.editar_cliente(jsonb) from public, anon;
grant execute on function me.editar_cliente(jsonb) to authenticated, service_role;
