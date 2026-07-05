-- 376 · kill-GAS (MOS) batch3 — CRUD admin sin RPC. Gate mos._claim_ok().
-- actualizarNotifConfig, restaurarNotifDefault, resolverAlertaAuditoria, actualizarEquivalencia,
-- crear/actualizarProductoProveedor, actualizarDispositivo.

create or replace function mos.actualizar_notif_config(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idNotif','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idNotif requerido'); end if;
  update mos.notificaciones_config set
    titulo           = coalesce(p->>'titulo', titulo),
    descripcion      = coalesce(p->>'descripcion', descripcion),
    icono            = coalesce(p->>'icono', icono),
    activa           = coalesce(nullif(btrim(coalesce(p->>'activa','')),'')::boolean, activa),
    audiencia_roles  = coalesce(p->>'audienciaRoles', audiencia_roles),
    audiencia_usuarios = coalesce(p->>'audienciaUsuarios', audiencia_usuarios),
    prioridad        = coalesce(p->>'prioridad', prioridad),
    silenciada_hasta = coalesce(nullif(btrim(coalesce(p->>'silenciadaHasta','')),'')::timestamptz, silenciada_hasta),
    sonido_custom    = coalesce(p->>'sonidoCustom', sonido_custom),
    ts_actualizado   = now(),
    actualizado_por  = coalesce(p->>'usuario', actualizado_por)
   where id_notif = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','notif no encontrada'); end if;
  return jsonb_build_object('ok',true);
end; $fn$;

create or replace function mos.restaurar_notif_default(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idNotif','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idNotif requerido'); end if;
  -- default = activa true, sin silenciar, audiencia abierta.
  update mos.notificaciones_config set activa=true, silenciada_hasta=null,
    audiencia_roles=null, audiencia_usuarios=null, ts_actualizado=now(), actualizado_por=coalesce(p->>'usuario',actualizado_por)
   where id_notif = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','notif no encontrada'); end if;
  return jsonb_build_object('ok',true);
end; $fn$;

create or replace function mos.resolver_alerta_auditoria(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idAlerta','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idAlerta requerido'); end if;
  update mos.alertas_log set leida = true where id = v_id;
  get diagnostics v_n = row_count;
  -- también marca la stock_diferencia si el id apunta ahí (tolerante).
  if v_n = 0 then update mos.stock_diferencias set estado='RESUELTA' where id::text = v_id; get diagnostics v_n = row_count; end if;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','alerta no encontrada'); end if;
  return jsonb_build_object('ok',true);
end; $fn$;

create or replace function mos.actualizar_equivalencia(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idEquiv','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idEquiv requerido'); end if;
  update mos.equivalencias set
    codigo_barra = coalesce(nullif(btrim(coalesce(p->>'codigoBarra','')),''), codigo_barra),
    descripcion  = coalesce(p->>'descripcion', descripcion),
    activo       = coalesce(nullif(btrim(coalesce(p->>'activo','')),'')::boolean, activo)
   where id_equiv = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','equivalencia no encontrada'); end if;
  return jsonb_build_object('ok',true);
end; $fn$;

create or replace function mos.crear_producto_proveedor(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idPp','')),'');
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if nullif(btrim(coalesce(p->>'idProveedor','')),'') is null then return jsonb_build_object('ok',false,'error','idProveedor requerido'); end if;
  if v_id is null then v_id := 'PP' || (extract(epoch from clock_timestamp())*1000)::bigint; end if;
  insert into mos.proveedores_productos (id_pp, id_proveedor, sku_base, codigo_barra, descripcion,
    precio_referencia, minimo_compra, dias_entrega, activa, notas, unidades_por_bulto, ultima_actualizacion)
  values (v_id, p->>'idProveedor', coalesce(p->>'skuBase',''), coalesce(p->>'codigoBarra',''), coalesce(p->>'descripcion',''),
    nullif(btrim(coalesce(p->>'precioReferencia','')),'')::numeric, nullif(btrim(coalesce(p->>'minimoCompra','')),'')::numeric,
    nullif(btrim(coalesce(p->>'diasEntrega','')),'')::numeric, true, coalesce(p->>'notas',''),
    nullif(btrim(coalesce(p->>'unidadesPorBulto','')),'')::numeric, now())
  on conflict (id_pp) do update set sku_base=excluded.sku_base, codigo_barra=excluded.codigo_barra,
    descripcion=excluded.descripcion, precio_referencia=excluded.precio_referencia, minimo_compra=excluded.minimo_compra,
    dias_entrega=excluded.dias_entrega, notas=excluded.notas, unidades_por_bulto=excluded.unidades_por_bulto, ultima_actualizacion=now();
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPp',v_id));
end; $fn$;

create or replace function mos.actualizar_producto_proveedor(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idPp','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idPp requerido'); end if;
  update mos.proveedores_productos set
    sku_base          = coalesce(p->>'skuBase', sku_base),
    codigo_barra      = coalesce(p->>'codigoBarra', codigo_barra),
    descripcion       = coalesce(p->>'descripcion', descripcion),
    precio_referencia = coalesce(nullif(btrim(coalesce(p->>'precioReferencia','')),'')::numeric, precio_referencia),
    minimo_compra     = coalesce(nullif(btrim(coalesce(p->>'minimoCompra','')),'')::numeric, minimo_compra),
    dias_entrega      = coalesce(nullif(btrim(coalesce(p->>'diasEntrega','')),'')::numeric, dias_entrega),
    notas             = coalesce(p->>'notas', notas),
    unidades_por_bulto= coalesce(nullif(btrim(coalesce(p->>'unidadesPorBulto','')),'')::numeric, unidades_por_bulto),
    ultima_actualizacion = now()
   where id_pp = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','no encontrado'); end if;
  return jsonb_build_object('ok',true);
end; $fn$;

create or replace function mos.actualizar_dispositivo(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idDispositivo', p->>'deviceId','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idDispositivo requerido'); end if;
  update mos.dispositivos set
    nombre_equipo = coalesce(nullif(btrim(coalesce(p->>'nombreEquipo','')),''), nombre_equipo),
    estado        = coalesce(nullif(btrim(coalesce(p->>'estado','')),''), estado),
    forzar_wizard = coalesce(nullif(btrim(coalesce(p->>'forzarWizard','')),'')::boolean, forzar_wizard),
    forzar_push   = coalesce(nullif(btrim(coalesce(p->>'forzarPush','')),'')::boolean, forzar_push),
    forzar_reverify = coalesce(nullif(btrim(coalesce(p->>'forzarReverify','')),'')::boolean, forzar_reverify)
   where id_dispositivo = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','dispositivo no encontrado'); end if;
  return jsonb_build_object('ok',true);
end; $fn$;

revoke all on function mos.actualizar_notif_config(jsonb), mos.restaurar_notif_default(jsonb), mos.resolver_alerta_auditoria(jsonb),
  mos.actualizar_equivalencia(jsonb), mos.crear_producto_proveedor(jsonb), mos.actualizar_producto_proveedor(jsonb),
  mos.actualizar_dispositivo(jsonb) from public, anon;
grant execute on function mos.actualizar_notif_config(jsonb), mos.restaurar_notif_default(jsonb), mos.resolver_alerta_auditoria(jsonb),
  mos.actualizar_equivalencia(jsonb), mos.crear_producto_proveedor(jsonb), mos.actualizar_producto_proveedor(jsonb),
  mos.actualizar_dispositivo(jsonb) to authenticated, service_role;
