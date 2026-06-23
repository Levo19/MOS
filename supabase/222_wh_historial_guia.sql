-- 222_wh_historial_guia.sql — getHistorialGuia 100% Supabase (Frente 4, read-only audit admin/master).
-- Compone el timeline desde 6 fuentes Supabase (réplica fiel del GAS Historial.gs):
--   1 wh.guias (CREACION + CIERRE_ESTADO + FOTO)  2 wh.ops_log (OP_*)  3 wh.stock_movimientos (STOCK_*)
--   4 wh.producto_nuevo (PN_REGISTRADO/PN_APROBADO)  5 wh.mermas (MERMA_PROCESADA)  + itemsActuales (guia_detalle)
-- Se omite SYNC_LOG (legacy GAS, no existe en Supabase; solo aportaba match heurístico de ops viejas).
-- Gating: _claim_ok + rol ADMIN/MASTER (verificado server-side en mos.personal, no se confía en el rol del cliente)
-- o claveAdmin válida. Flag WH_HISTORIAL_DIRECTO. Lectura → si error/transport, frontend cae a GAS.

create or replace function wh._icono_op(p_tipo text)
returns text language sql immutable set search_path = '' as $fn$
  select case upper(coalesce(p_tipo,''))
    when 'SCAN' then '📲' when 'EDIT_QTY' then '✏' when 'DELETE_ITEM' then '🗑'
    when 'ANULAR_DETALLE' then '🚫' when 'ANULAR_GUIA' then '❌' when 'PN_REGISTRAR' then '🆕'
    when 'MERMA_AGREGAR' then '🗑' when 'MERMA_SOLUCIONAR' then '♻' when 'MERMA_PROCESAR' then '⚡'
    when 'CARGADOR_ADD' then '🛺' when 'CARGADOR_REMOVE' then '➖' when 'CREAR_GUIA' then '🆕'
    when 'CERRAR_GUIA' then '🔒' when 'REABRIR_GUIA' then '🔓' else '•' end;
$fn$;

create or replace function wh._titulo_op(p_tipo text, p_pl jsonb)
returns text language sql immutable set search_path = '' as $fn$
  select case upper(coalesce(p_tipo,''))
    when 'SCAN' then 'Scan: ' || coalesce(p_pl->>'codigoProducto','?') || ' × ' || coalesce(p_pl->>'cantidad', p_pl->>'cantidadRecibida', '1')
    when 'EDIT_QTY' then 'Cantidad cambiada · detalle ' || coalesce(p_pl->>'idDetalle','')
    when 'DELETE_ITEM' then 'Item anulado · detalle ' || coalesce(p_pl->>'idDetalle','')
    when 'ANULAR_DETALLE' then 'Item anulado · detalle ' || coalesce(p_pl->>'idDetalle','')
    when 'CREAR_GUIA' then 'Guía creada (op-log)'
    when 'CERRAR_GUIA' then 'Guía cerrada (op-log)'
    when 'REABRIR_GUIA' then 'Guía reabierta (op-log)'
    when 'PN_REGISTRAR' then 'Producto nuevo: ' || coalesce(p_pl->>'descripcion', p_pl->>'codigoBarra', '')
    else upper(coalesce(p_tipo,'')) end;
$fn$;

create or replace function wh.historial_guia(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'idGuia','')), '');
  v_clave text := nullif(btrim(coalesce(p->>'claveAdmin','')), '');
  v_idp   text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_usr   text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_g     wh.guias%rowtype;
  v_autor boolean := false;
  v_rol   text;
  v_eventos jsonb;
  v_items   jsonb;
  v_estado  text;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idGuia requerido'); end if;

  -- ── Autorización (réplica _checkAutorizacionHistorial): rol admin/master server-side, o clave válida ──
  if v_idp is not null or v_usr is not null then
    select upper(coalesce(rol,'')) into v_rol from mos.personal
      where lower(coalesce(app_origen,'')) = 'warehousemos'
        and ( (v_idp is not null and id_personal::text = v_idp)
           or (v_usr is not null and lower(coalesce(nombre,'')) = lower(v_usr)) )
      order by (id_personal::text = v_idp) desc limit 1;
    if v_rol in ('ADMIN','MASTER') then v_autor := true; end if;
  end if;
  if (not v_autor) and v_clave is not null then
    if coalesce((mos.verificar_clave_admin(v_clave, 'ver_historial_guia', v_id, 'warehouseMos', null, null, null, null)->>'autorizado')::boolean, false)
    then v_autor := true; end if;
  end if;
  if not v_autor then return jsonb_build_object('ok',false,'error','no autorizado · solo admin/master'); end if;

  -- ── Guía base ──
  select * into v_g from wh.guias where id_guia = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','Guía no encontrada'); end if;
  v_estado := upper(coalesce(v_g.estado,''));

  -- ── itemsActuales (guia_detalle, claves camelCase espejo de la Hoja) ──
  select coalesce(jsonb_agg(jsonb_build_object(
           'idGuia', d.id_guia, 'linea', d.linea, 'idDetalle', d.id_detalle,
           'codProducto', d.cod_producto, 'cantEsperada', d.cant_esperada, 'cantRecibida', d.cant_recibida,
           'precioUnitario', d.precio_unitario, 'idLote', d.id_lote, 'observacion', d.observacion,
           'idProductoNuevo', d.id_producto_nuevo, 'fechaVencimiento', d.fecha_vencimiento,
           'cantidadAplicada', d.cantidad_aplicada) order by d.linea), '[]'::jsonb)
    into v_items from wh.guia_detalle d where d.id_guia = v_id;

  -- ── Eventos: una CTE por fuente, unidas y ordenadas cronológicamente ──
  with ev as (
    -- 1a. CREACION
    select v_g.fecha as ts, jsonb_build_object(
      'ts', v_g.fecha, 'tipo','CREACION','icono','🆕','usuario', coalesce(v_g.usuario,''), 'deviceId','',
      'titulo', 'Guía creada · ' || coalesce(v_g.tipo,''),
      'detalle', jsonb_build_object('tipo',v_g.tipo,'idProveedor',v_g.id_proveedor,'idZona',v_g.id_zona,
        'numeroDocumento',v_g.numero_documento,'comentario',v_g.comentario,'idPreingreso',v_g.id_preingreso)) as e
    -- 1b. CIERRE_ESTADO
    union all
    select v_g.fecha, jsonb_build_object(
      'ts', v_g.fecha, 'tipo','CIERRE_ESTADO','icono','🔒','usuario',coalesce(v_g.usuario,''),'deviceId','',
      'titulo', 'Estado actual: ' || v_g.estado || case when v_g.monto_total is not null then ' · S/. ' || to_char(v_g.monto_total,'FM999990.00') else '' end,
      'detalle', jsonb_build_object('estado',v_g.estado,'montoTotal',v_g.monto_total))
    where v_estado in ('CERRADA','AUTOCERRADA')
    -- 1c. FOTO
    union all
    select v_g.fecha, jsonb_build_object('ts',v_g.fecha,'tipo','FOTO','icono','📷','usuario',coalesce(v_g.usuario,''),
      'titulo','Foto adjunta','detalle',jsonb_build_object('url',v_g.foto))
    where nullif(btrim(coalesce(v_g.foto,'')),'') is not null
    -- 2. OPS_LOG
    union all
    select coalesce(o.fecha_aplicado, o.fecha_creado), jsonb_build_object(
      'ts', coalesce(o.fecha_aplicado,o.fecha_creado), 'tipo','OP_'||coalesce(o.tipo,''),
      'icono', wh._icono_op(o.tipo), 'usuario', coalesce(o.usuario,''), 'deviceId', coalesce(o.device_id,''),
      'titulo', wh._titulo_op(o.tipo, case when jsonb_typeof(o.payload)='object' then o.payload else '{}'::jsonb end),
      'estado', o.estado, 'error', coalesce(o.error,''),
      'detalle', jsonb_build_object('tipo',o.tipo,'payload', case when jsonb_typeof(o.payload)='object' then o.payload else '{}'::jsonb end,'idOp',o.id_op))
    from wh.ops_log o where o.id_guia = v_id
    -- 3. STOCK_MOVIMIENTOS (origen = idGuia exacto o prefijo idGuia#)
    union all
    select m.fecha, jsonb_build_object(
      'ts', m.fecha, 'tipo','STOCK_'||coalesce(m.tipo_operacion,''),
      'icono', case when coalesce(m.delta,0) > 0 then '📈' else '📉' end, 'usuario', coalesce(m.usuario,''),
      'titulo', 'Stock ' || case when coalesce(m.delta,0)>0 then '+' else '' end || m.delta::text || ' · ' || coalesce(m.cod_producto,''),
      'detalle', jsonb_build_object('codigoProducto',m.cod_producto,'delta',m.delta,'stockAntes',m.stock_antes,
        'stockDespues',m.stock_despues,'tipoOperacion',m.tipo_operacion,'observacion',null))
    from wh.stock_movimientos m where m.origen = v_id or m.origen like v_id || '#%'
    -- 4a. PN_REGISTRADO
    union all
    select coalesce(pn.fecha_registro, v_g.fecha), jsonb_build_object(
      'ts', coalesce(pn.fecha_registro, v_g.fecha), 'tipo','PN_REGISTRADO','icono','🆕','usuario',coalesce(pn.usuario,''),
      'titulo','Producto nuevo registrado: ' || coalesce(nullif(pn.descripcion,''), pn.codigo_barra, ''),
      'detalle', jsonb_build_object('idProductoNuevo',pn.id_producto_nuevo,'codigoBarra',pn.codigo_barra,'cantidad',pn.cantidad,'estado',pn.estado))
    from wh.producto_nuevo pn where pn.id_guia = v_id
    -- 4b. PN_APROBADO
    union all
    select pn.fecha_aprobacion, jsonb_build_object(
      'ts', pn.fecha_aprobacion, 'tipo','PN_APROBADO','icono','✓','usuario', coalesce(pn.aprobado_por,''),
      'titulo','Producto nuevo aprobado: ' || coalesce(pn.descripcion,''),
      'detalle', jsonb_build_object('idProductoNuevo',pn.id_producto_nuevo,'aprobadoPor',pn.aprobado_por))
    from wh.producto_nuevo pn where pn.id_guia = v_id and pn.fecha_aprobacion is not null
    -- 5. MERMAS (esta guía es la SALIDA generada)
    union all
    select coalesce(mz.fecha_resolucion, mz.fecha_ingreso), jsonb_build_object(
      'ts', coalesce(mz.fecha_resolucion, mz.fecha_ingreso), 'tipo','MERMA_PROCESADA','icono','🗑','usuario',coalesce(mz.usuario,''),
      'titulo','Merma procesada: ' || coalesce(mz.cod_producto,'') || ' × ' || coalesce(mz.cantidad_desechada, mz.cantidad_original, 0)::text,
      'detalle', jsonb_build_object('idMerma',mz.id_merma,'codigoProducto',mz.cod_producto,'motivo',mz.motivo))
    from wh.mermas mz where coalesce(mz.id_guia_salida, mz.id_guia) = v_id
  )
  select coalesce(jsonb_agg(e order by ts asc nulls first), '[]'::jsonb) into v_eventos from ev;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idGuia', v_id, 'eventos', v_eventos, 'itemsActuales', v_items,
    'generadoEn', to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'totalEventos', jsonb_array_length(v_eventos)));
end;
$fn$;

insert into mos.config (clave, valor, descripcion) values
  ('WH_HISTORIAL_DIRECTO','1','WH: getHistorialGuia directo (compone wh.guias/ops_log/stock_mov/producto_nuevo/mermas). Read-only.')
on conflict (clave) do nothing;

revoke all on function wh._icono_op(text) from public;
revoke all on function wh._titulo_op(text, jsonb) from public;
revoke all on function wh.historial_guia(jsonb) from public;
grant execute on function wh._icono_op(text) to authenticated;
grant execute on function wh._titulo_op(text, jsonb) to authenticated;
grant execute on function wh.historial_guia(jsonb) to authenticated;
