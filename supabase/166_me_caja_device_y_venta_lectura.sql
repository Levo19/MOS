-- ============================================================
-- 166_me_caja_device_y_venta_lectura.sql
-- Residuales del cutover delete-safe de ME: lecturas que aún tocaban el Sheet.
-- ------------------------------------------------------------
-- 1) me.caja_abierta_por_device(p_device)
--    Para retomarCajaPorDeviceId / confirmarRetomaCaja (Caja.gs). Hoy leen la
--    hoja CAJAS (col PrintNode_ID = deviceId) para hallar la caja ABIERTA del
--    dispositivo. Esta RPC devuelve esa caja desde me.cajas (printnode_id) +
--    la lista de cajas ABIERTAS de DÍAS ANTERIORES (zombi) para que GAS pueda
--    seguir disparando el auto-cierre (_cerrarCajaAtomicoCore, ya Supabase).
--
-- 2) me.venta_estado_lectura(p_id_venta)
--    Para cobrarVentaExistente / creditarVenta (Caja.gs). Hoy leen
--    VENTAS_CABECERA para traer forma_pago (col 8), id_caja (col 10) y obs
--    (col 14) de UNA venta. Esta RPC devuelve esos 3 campos desde me.ventas.
--
-- Money-safety: AMBAS son 100% LECTURA (STABLE, sin efectos). No cobran, no
-- creditan, no cierran caja, no mueven stock. La escritura durable sigue por
-- _dualWriteVentaPatchME (me.ventas, fuente de verdad) y _cerrarCajaAtomicoCore.
-- Gate de app idéntico a cierre_datos_caja: service_role (GAS) → jwt_app()=''
-- → permitido; tokens de otra app → APP_NO_AUTORIZADA. SECURITY DEFINER +
-- search_path='' + grants service_role/authenticated, sin public/anon.
-- ============================================================

-- ------------------------------------------------------------
-- 1) Caja ABIERTA del dispositivo (match printnode_id = deviceId)
-- ------------------------------------------------------------
-- Replica retomarCajaPorDeviceId: recorre las cajas de atrás hacia adelante
-- (la más reciente), toma la PRIMERA ABIERTA cuyo printnode_id = deviceId.
-- "Más reciente" = mayor fecha_apertura (nulls al final), desempata por
-- created_at — equivalente a "desde el final de la hoja" pero determinista.
-- Devuelve también `zombis`: ids de cajas ABIERTAS cuya fecha_apertura es de un
-- día anterior (hora Lima) a HOY → GAS las auto-cierra antes de resolver retoma.
create or replace function me.caja_abierta_por_device(p_device text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_app   text := me.jwt_app();
  v_dev   text := nullif(btrim(coalesce(p_device,'')),'');
  v_caja  me.cajas%rowtype;
  v_found boolean := false;
  v_zomb  text[];
begin
  -- Gate de app (igual que cierre_datos_caja). service_role (GAS) → ''.
  if v_app <> '' and v_app <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_dev is null then
    return jsonb_build_object('ok', false, 'error', 'DEVICE_REQUERIDO');
  end if;

  -- Zombis: cajas ABIERTAS de un día calendario anterior a HOY (Lima).
  -- Mismo criterio que _autoCerrarCajasViejas (diaApert < hoy). printnode_id
  -- libre: el auto-cierre del día aplica a cualquier caja vieja, no solo la del device.
  select array_agg(id_caja)
  into v_zomb
  from me.cajas
  where upper(coalesce(estado,'')) = 'ABIERTA'
    and fecha_apertura is not null
    and to_char(fecha_apertura at time zone 'America/Lima','YYYY-MM-DD')
        < to_char(now() at time zone 'America/Lima','YYYY-MM-DD');
  v_zomb := coalesce(v_zomb, array[]::text[]);

  -- Caja ABIERTA del device, la más reciente.
  select * into v_caja
  from me.cajas
  where upper(coalesce(estado,'')) = 'ABIERTA'
    and coalesce(printnode_id,'') = v_dev
  order by fecha_apertura desc nulls last, created_at desc nulls last
  limit 1;
  v_found := found;

  if not v_found then
    return jsonb_build_object('ok', true, 'encontrada', false,
      'zombis', to_jsonb(v_zomb));
  end if;

  return jsonb_build_object(
    'ok', true,
    'encontrada', true,
    'id_caja', coalesce(v_caja.id_caja,''),
    'vendedor', coalesce(v_caja.vendedor,''),
    'estacion', coalesce(v_caja.estacion,''),
    'zona', coalesce(v_caja.zona_id,''),
    'monto_inicial', coalesce(v_caja.monto_inicial,0),
    'estado', coalesce(v_caja.estado,''),
    'printnode_id', coalesce(v_caja.printnode_id,''),
    'fecha_apertura', v_caja.fecha_apertura,
    'zombis', to_jsonb(v_zomb)
  );
end;
$function$;

revoke all on function me.caja_abierta_por_device(text) from public, anon;
grant execute on function me.caja_abierta_por_device(text) to authenticated, service_role;

-- ------------------------------------------------------------
-- 2) Estado de UNA venta (forma_pago / id_caja / obs) para cobrar/creditar
-- ------------------------------------------------------------
create or replace function me.venta_estado_lectura(p_id_venta text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p_id_venta,'')),'');
  v_forma text;
  v_caja  text;
  v_obs   text;
begin
  if v_app <> '' and v_app <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'ID_VENTA_REQUERIDO');
  end if;

  select forma_pago, id_caja, obs
  into v_forma, v_caja, v_obs
  from me.ventas where id_venta = v_id limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'VENTA_NO_ENCONTRADA', 'id_venta', v_id);
  end if;

  return jsonb_build_object(
    'ok', true,
    'id_venta', v_id,
    'forma_pago', coalesce(v_forma,''),
    'id_caja', coalesce(v_caja,''),
    'obs', coalesce(v_obs,'')
  );
end;
$function$;

revoke all on function me.venta_estado_lectura(text) from public, anon;
grant execute on function me.venta_estado_lectura(text) to authenticated, service_role;
