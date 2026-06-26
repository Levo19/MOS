-- ============================================================
-- 260_me_ventas_edicion_directa.sql
-- CUTOVER ventas-ME · Etapa 3 (escritura directa 100% Supabase, cero GAS)
-- ------------------------------------------------------------
-- Migra las 3 ediciones de ticket que hoy van MOS→GAS→bridge-ME a RPCs
-- atómicas en Postgres. Porta FIELMENTE la lógica canónica de ME:
--   · me.editar_forma_pago  ← EditarVenta.gs:editarFormaPagoVenta  (sin afectar caja)
--   · me.editar_cliente     ← EditarVenta.gs:editarClienteVenta    (bloqueo CPE emitido)
--   · me.anular_venta       ← Caja.gs:anularVentaIndividual        (idempotente + stock + pickup)
-- y el efecto cross-app del anular:
--   · wh.pickup_descontar_venta ← warehouseMos/Guias.gs:pickupDescontarVenta
--
-- INERTE hasta que el frontend MOS flipée el flag ME_EDIT_DIRECTO (gateado allá).
-- Estas RPCs NO se auto-ejecutan; solo responden cuando el front las llama.
--
-- ⚠️ BLOCKER de coexistencia (documentado): el sync ME Hoja→sombra (MigracionME.gs,
--    cada 15min, cola 500) re-upsertea me.ventas desde la Hoja. Una edición Supabase-
--    only se REVIERTE salvo que `ventas` esté en ME_SYNC_OFF_TABLAS. El cutover NO se
--    activa hasta confirmar/agregar `ventas` al sync-off (paso de flip controlado).
--
-- Money-safety:
--   · anular es IDEMPOTENTE (noop si ya ANULADO%) → stock+pickup se disparan 1 sola vez.
--   · reposición de stock = me.zona_registrar_guia ENTRADA idGuia 'ANUL:<id>' (dedup por refId).
--   · pickup descuento bajo FOR UPDATE (sin doble-decremento concurrente).
--   · gate de app en cada RPC (service_role/GAS '' permitido; otras apps bloqueadas).
-- ============================================================

-- ------------------------------------------------------------
-- wh.pickup_descontar_venta — porta pickupDescontarVenta (cross-app → Supabase)
-- params: { idCaja, idGuiaME?, itemsAnulados:[{codigoBarra,cantidad}] }
-- Ajusta el pickup origen PENDIENTE/EN_PROCESO de esa caja: resta `solicitado`
-- a los items cuyo codigosOriginales contenga el código anulado; quita items en 0;
-- si queda vacío → estado CANCELADO. NO toca pickups ya COMPLETADO/CANCELADO/PARCIAL.
-- Best-effort por diseño del caller (el anular nunca aborta si esto falla).
-- ------------------------------------------------------------
create or replace function wh.pickup_descontar_venta(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_app    text := me.jwt_app();
  v_caja   text := nullif(btrim(coalesce(p->>'idCaja','')),'');
  v_guiaME text := nullif(btrim(coalesce(p->>'idGuiaME','')),'');
  v_anul   jsonb := coalesce(p->'itemsAnulados', '[]'::jsonb);
  v_pk     record;
  v_items  jsonb;
  v_final  jsonb := '[]'::jsonb;
  v_it     jsonb;
  v_an     jsonb;
  v_cod    text;
  v_qty    numeric;
  v_sol    numeric;
  v_ajustes int := 0;
  v_codigos jsonb;
  v_matched boolean;
begin
  -- Gate de app: MOS panel (MOS) / ME (mosExpress) / WH / GAS service_role ('').
  if v_app not in ('','MOS','mosExpress','warehouseMos') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if jsonb_typeof(v_anul) <> 'array' or jsonb_array_length(v_anul) = 0 then
    return jsonb_build_object('ok', false, 'error', 'Sin itemsAnulados');
  end if;
  if v_caja is null and v_guiaME is null then
    return jsonb_build_object('ok', false, 'error', 'Requiere idCaja o idGuiaME');
  end if;

  -- Localizar el pickup origen por notas (idGuiaME= o idCaja=), bloqueando la fila.
  select * into v_pk
  from wh.pickups
  where ( (v_guiaME is not null and notas ilike '%idGuiaME='||v_guiaME||'%')
       or (v_caja   is not null and notas ilike '%idCaja='||v_caja||'%') )
  order by fecha_creado desc nulls last
  limit 1
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Pickup origen no encontrado');
  end if;

  -- Pickup ya cerrado → no se ajusta (paridad con GAS).
  if v_pk.estado in ('COMPLETADO','CANCELADO','PARCIAL') then
    return jsonb_build_object('ok', true, 'ajustado', false,
      'motivo', 'Pickup ya cerrado: '||v_pk.estado);
  end if;

  v_items := coalesce(v_pk.items, '[]'::jsonb);
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok', true, 'ajustado', false, 'motivo', 'Sin items');
  end if;

  -- Recorrer items del pickup; por cada uno, restar lo anulado que matchee su codigosOriginales.
  for v_it in select value from jsonb_array_elements(v_items) loop
    v_sol     := coalesce((v_it->>'solicitado')::numeric, 0);
    v_codigos := coalesce(v_it->'codigosOriginales', '[]'::jsonb);

    for v_an in select value from jsonb_array_elements(v_anul) loop
      v_cod := upper(btrim(coalesce(v_an->>'codigoBarra','')));
      v_qty := coalesce((v_an->>'cantidad')::numeric, 0);
      if v_cod = '' or v_qty <= 0 then continue; end if;
      -- ¿este item del pickup cubre ese código?
      v_matched := exists (
        select 1 from jsonb_array_elements_text(v_codigos) c
        where upper(btrim(c)) = v_cod
      );
      if v_matched then
        v_sol := greatest(0, v_sol - v_qty);
        v_ajustes := v_ajustes + 1;
      end if;
    end loop;

    if v_sol > 0 then
      v_final := v_final || jsonb_build_array(jsonb_set(v_it, '{solicitado}', to_jsonb(v_sol)));
    end if;
    -- items con solicitado=0 se descartan (no se agregan a v_final)
  end loop;

  if jsonb_array_length(v_final) = 0 then
    update wh.pickups
      set estado = 'CANCELADO', items = '[]'::jsonb, ultima_actividad = now()
      where id_pickup = v_pk.id_pickup;
    return jsonb_build_object('ok', true, 'ajustado', true, 'ajustes', v_ajustes,
      'cancelado', true, 'idPickup', v_pk.id_pickup);
  end if;

  update wh.pickups
    set items = v_final, ultima_actividad = now()
    where id_pickup = v_pk.id_pickup;
  return jsonb_build_object('ok', true, 'ajustado', true, 'ajustes', v_ajustes,
    'cancelado', false, 'idPickup', v_pk.id_pickup);
end;
$fn$;
revoke all on function wh.pickup_descontar_venta(jsonb) from public, anon;
grant execute on function wh.pickup_descontar_venta(jsonb) to authenticated, service_role;


-- ------------------------------------------------------------
-- me.venta_reposicion_datos — REDEFINIR para ampliar gate a 'MOS'
-- (idéntica a SQL 164 salvo el gate; el panel admin MOS la llama anidada
--  desde me.anular_venta y antes sólo permitía ''/mosExpress → bloqueaba la
--  reposición de stock al anular desde MOS = money bug). Lectura STABLE, inocua.
-- ------------------------------------------------------------
create or replace function me.venta_reposicion_datos(p_id_venta text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_app    text := me.jwt_app();
  v_id     text := nullif(btrim(coalesce(p_id_venta,'')),'');
  v_caja   text;
  v_forma  text;
  v_zona   text;
  v_cerr   boolean := false;
  v_tot    jsonb;
begin
  if v_app not in ('', 'MOS', 'mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'ID_VENTA_REQUERIDO');
  end if;

  select id_caja, forma_pago into v_caja, v_forma
  from me.ventas where id_venta = v_id limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'VENTA_NO_ENCONTRADA', 'id_venta', v_id);
  end if;

  v_caja := nullif(btrim(coalesce(v_caja,'')),'');
  if v_caja is null then
    return jsonb_build_object('ok', true, 'id_venta', v_id, 'id_caja', '',
      'caja_cerrada', false, 'zona', '', 'totales_por_cod', '{}'::jsonb,
      'forma_pago', coalesce(v_forma,''));
  end if;

  select gc.zona_id into v_zona
  from me.guias_cabecera gc
  where gc.tipo = 'SALIDA_VENTAS'
    and coalesce(gc.observacion,'') ilike '%'||v_caja||'%'
  order by gc.fecha desc nulls last
  limit 1;
  v_cerr := found;

  select coalesce(jsonb_object_agg(cb, cant), '{}'::jsonb)
  into v_tot
  from (
    select upper(btrim(coalesce(nullif(d.cod_barras,''), d.sku))) as cb,
           sum(coalesce(d.cantidad,0)) as cant
    from me.ventas_detalle d
    where d.id_venta = v_id
      and coalesce(nullif(d.cod_barras,''), d.sku) is not null
      and btrim(coalesce(nullif(d.cod_barras,''), d.sku)) <> ''
    group by 1
    having sum(coalesce(d.cantidad,0)) > 0
  ) t;

  return jsonb_build_object(
    'ok', true, 'id_venta', v_id, 'id_caja', v_caja,
    'caja_cerrada', v_cerr, 'zona', coalesce(v_zona,''),
    'totales_por_cod', v_tot, 'forma_pago', coalesce(v_forma,''));
end;
$function$;
revoke all on function me.venta_reposicion_datos(text) from public, anon;
grant execute on function me.venta_reposicion_datos(text) to authenticated, service_role;


-- ------------------------------------------------------------
-- me._venta_hist_append — helper: arma+anexa una entrada de historial_cambios
-- (jsonb array, cap 200). Paridad con auditarLog→_audAppend de ME.
-- ------------------------------------------------------------
create or replace function me._venta_hist_append(
  p_actual jsonb, p_entry jsonb
) returns jsonb
language sql
immutable
set search_path = ''
as $fn$
  with base as (
    select (case when jsonb_typeof(coalesce(p_actual,'null'::jsonb)) = 'array'
                 then p_actual else '[]'::jsonb end)
           || jsonb_build_array(p_entry) as arr
  ),
  elems as (
    select e, ord from base, jsonb_array_elements(arr) with ordinality t(e, ord)
  ),
  recientes as (   -- conservar las 200 más recientes (la nueva entrada tiene el ord mayor)
    select e, ord from elems order by ord desc limit 200
  )
  select coalesce(jsonb_agg(e order by ord), '[]'::jsonb) from recientes;
$fn$;
revoke all on function me._venta_hist_append(jsonb, jsonb) from public, anon;
grant execute on function me._venta_hist_append(jsonb, jsonb) to authenticated, service_role;


-- ------------------------------------------------------------
-- me.editar_forma_pago — corrige FormaPago sin afectar caja
-- params: { idVenta, formaPagoNueva, motivo(req), usuario, rol, autorizadoPor }
-- ------------------------------------------------------------
create or replace function me.editar_forma_pago(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
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
begin
  if v_app not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id  is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido'); end if;
  if v_new is null then return jsonb_build_object('ok', false, 'error', 'formaPagoNueva requerida'); end if;
  if v_mot is null then return jsonb_build_object('ok', false, 'error', 'motivo es obligatorio para auditoría'); end if;

  select forma_pago, historial_cambios into v_ant, v_hist
  from me.ventas where id_venta = v_id limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Venta '||v_id||' no encontrada');
  end if;

  -- Guard: no editar forma de pago de una venta anulada (incl. ANULADO_CONVERSION).
  if upper(coalesce(v_ant,'')) like 'ANULADO%' then
    return jsonb_build_object('ok', false, 'error', 'No se puede modificar un ticket anulado');
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
$fn$;
revoke all on function me.editar_forma_pago(jsonb) from public, anon;
grant execute on function me.editar_forma_pago(jsonb) to authenticated, service_role;


-- ------------------------------------------------------------
-- me.editar_cliente — cambia cliente (solo si NO es CPE emitido)
-- params: { idVenta, clienteDoc, clienteNombre, clienteDireccion, motivo, usuario, rol, autorizadoPor }
-- ------------------------------------------------------------
create or replace function me.editar_cliente(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_doc   text := btrim(coalesce(p->>'clienteDoc',''));
  v_nom   text := btrim(coalesce(p->>'clienteNombre',''));
  v_mot   text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
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
  from me.ventas where id_venta = v_id limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Venta '||v_id||' no encontrada');
  end if;

  -- Bloqueo SUNAT: un CPE EMITIDO no se puede editar.
  if coalesce(v_tipo,'') <> 'NOTA_DE_VENTA' and coalesce(v_nf,'') = 'EMITIDO' then
    return jsonb_build_object('ok', false,
      'error', 'CPE emitido ('||coalesce(v_tipo,'')||') no se puede editar. Solicite la baja del CPE primero.');
  end if;

  v_tdc := case when length(v_doc) = 8 then 1 when length(v_doc) = 11 then 6 else 0 end;

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

  return jsonb_build_object('ok', true, 'mensaje', 'Cliente actualizado',
    'idVenta', v_id, 'cambios', jsonb_array_length(v_cambios));
end;
$fn$;
revoke all on function me.editar_cliente(jsonb) from public, anon;
grant execute on function me.editar_cliente(jsonb) to authenticated, service_role;


-- ------------------------------------------------------------
-- me.anular_venta — anula UNA venta (idempotente) + repone stock + descuenta pickup
-- params: { idVenta, motivo, usuario, rol, autorizadoPor }
-- ------------------------------------------------------------
create or replace function me.anular_venta(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
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
begin
  -- Gate restringido a ('','MOS') A PROPÓSITO: el reposo de stock anidado (me.zona_registrar_guia)
  -- gatea mos._claim_ok() = jwt_app in ('','MOS) → un token 'mosExpress' pasaría el gate de aquí pero
  -- el reposo anidado lo rechazaría (APP_NO_AUTORIZADA) → se anularía + descontaría pickup SIN reponer
  -- stock = fantasma asimétrico que nunca se auto-cura (la 2da llamada es noop). Bloqueando 'mosExpress'
  -- aquí, los dos efectos quedan simétricos. ME tiene su propio anular (Caja.gs) por service_role ('').
  if v_app not in ('','MOS') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido'); end if;

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
$fn$;
revoke all on function me.anular_venta(jsonb) from public, anon;
grant execute on function me.anular_venta(jsonb) to authenticated, service_role;
