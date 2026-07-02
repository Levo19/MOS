-- ============================================================================
-- 320_me_rechazar_cobro_asignado.sql — Cutover cero-GAS del RECHAZO de cobro asignado
-- ----------------------------------------------------------------------------
-- Replica fiel de gas Creditos.gs::rechazarCobroAsignado (el CAJERO rechaza un cobro que le
-- asignaron: "el cliente no llegó", etc). Efectos GAS: cobro ASIGNADO → RECHAZADO + fecha_res +
-- razon (truncada 250). La VENTA NO cambia (sigue CREDITO → re-asignable). El push al admin
-- asignador es best-effort (lo dispara el frontend / lo cubre el polling de MOS).
-- A diferencia de cancelar/reasignar (que son del panel admin='MOS'), el rechazo lo hace el
-- CAJERO en MosExpress → gate app in ('mosExpress','MOS'). Flag ME_COBRO_DIRECTO (kill-switch,
-- OFF → 'COBRO_OFF' → el frontend cae a GAS). Idempotente (guard estado + advisory-lock por venta).
-- ============================================================================

create or replace function me.rechazar_cobro_asignado(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idcobro text := btrim(coalesce(p->>'idCobro',''));
  v_razon   text := left(btrim(coalesce(p->>'razon','')), 250);
  v_row     me.creditos_cobro_asignado%rowtype;
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','COBRO_OFF');
  end if;
  if v_idcobro = '' then return jsonb_build_object('ok',false,'error','idCobro requerido'); end if;
  if v_razon   = '' then return jsonb_build_object('ok',false,'error','razon es obligatoria'); end if;

  -- [lock por VENTA] mismo namespace 'cobro:'||idVenta que asignar/confirmar/directo/cancelar/reasignar
  -- → el rechazo NO corre en paralelo con un cobro en vuelo de la misma venta. Leo → lock → re-leo.
  select * into v_row from me.creditos_cobro_asignado where id_cobro = v_idcobro limit 1;
  if not found then return jsonb_build_object('ok',false,'error','COBRO_NO_ENCONTRADO'); end if;
  perform pg_advisory_xact_lock(hashtext('cobro:'||v_row.id_venta));
  select * into v_row from me.creditos_cobro_asignado where id_cobro = v_idcobro limit 1;
  if not found then return jsonb_build_object('ok',false,'error','COBRO_NO_ENCONTRADO'); end if;
  -- idempotencia: si ya está rechazado, éxito silencioso
  if upper(coalesce(v_row.estado,'')) = 'RECHAZADO' then
    return jsonb_build_object('ok',true,'idempotente',true,'idCobro',v_idcobro,'mensaje','Cobro ya estaba rechazado');
  end if;
  -- solo se rechaza un cobro ASIGNADO (no COBRADO/CANCELADO/REASIGNADO/EXPIRADO) — money-safe:
  -- si ya se COBRÓ, rechazar borraría un cobro real → lo bloqueamos.
  if upper(coalesce(v_row.estado,'')) <> 'ASIGNADO' then
    return jsonb_build_object('ok',false,'error','COBRO_NO_ASIGNADO','estado',v_row.estado);
  end if;

  update me.creditos_cobro_asignado
     set estado = 'RECHAZADO', fecha_res = now(), razon = v_razon, updated_at = now()
   where id_cobro = v_idcobro;
  -- NB: la venta NO se toca (sigue CREDITO → el admin puede re-asignar). Paridad GAS exacta.

  return jsonb_build_object(
    'ok', true, 'via','directo', 'idCobro', v_idcobro, 'idVenta', v_row.id_venta,
    'mensaje','Cobro rechazado',
    -- info para el push al admin asignador (best-effort; el frontend/MOS lo usa si aplica)
    'pushUsuario', v_row.admin_asignador,
    'pushTitulo','⚠ Cobro rechazado · ' || coalesce(v_row.cliente_nombre,''),
    'pushCuerpo','S/ ' || to_char(coalesce(v_row.monto,0),'FM999999990.00') || ' rechazado: ' || left(v_razon,100)
  );
end;
$fn$;
revoke all on function me.rechazar_cobro_asignado(jsonb) from public;
grant execute on function me.rechazar_cobro_asignado(jsonb) to authenticated, service_role;
