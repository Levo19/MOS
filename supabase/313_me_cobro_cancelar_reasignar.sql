-- ============================================================================
-- 313_me_cobro_cancelar_reasignar.sql — Cutover cero-GAS de cancelar/reasignar cobro
-- ----------------------------------------------------------------------------
-- Replica fiel de gas Creditos.gs::cancelarCobroAsignado / reasignarCobroAsignado.
--  · cancelar : cobro ASIGNADO → CANCELADO_ADMIN + venta.forma_pago → CREDITO (re-asignable).
--  · reasignar: cobro ASIGNADO → REASIGNADO + crea uno nuevo vía me.asignar_cobro_cajero.
-- Gate: jwt_app='MOS' (panel admin) + flag ME_COBRO_DIRECTO='1' (ya EN VIVO). Idempotente
-- (guard estado ASIGNADO + advisory-lock por cobro). Push lo dispara el frontend.
-- ============================================================================

create or replace function me.cancelar_cobro_asignado(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idcobro text := btrim(coalesce(p->>'idCobro',''));
  v_admin   text := regexp_replace(btrim(coalesce(p->>'adminNombre', p->>'admin', 'MOS-Admin')), '^admin:', '', 'i');
  v_razon   text := left(btrim(coalesce(p->>'razon','')), 200);
  v_row     me.creditos_cobro_asignado%rowtype;
begin
  if coalesce(me.jwt_app(),'') <> 'MOS' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','COBRO_OFF');
  end if;
  if v_idcobro = '' then return jsonb_build_object('ok',false,'error','idCobro requerido'); end if;

  perform pg_advisory_xact_lock(hashtext('cobrocancel:'||v_idcobro));
  select * into v_row from me.creditos_cobro_asignado where id_cobro = v_idcobro limit 1;
  if not found then return jsonb_build_object('ok',false,'error','COBRO_NO_ENCONTRADO'); end if;
  -- idempotencia: si ya está cancelado por admin, éxito silencioso
  if upper(coalesce(v_row.estado,'')) = 'CANCELADO_ADMIN' then
    return jsonb_build_object('ok',true,'idempotente',true,'idCobro',v_idcobro,'mensaje','Cobro ya estaba cancelado');
  end if;
  -- solo se cancela un cobro ASIGNADO (no COBRADO/REASIGNADO/EXPIRADO)
  if upper(coalesce(v_row.estado,'')) <> 'ASIGNADO' then
    return jsonb_build_object('ok',false,'error','COBRO_NO_ASIGNADO','estado',v_row.estado);
  end if;

  update me.creditos_cobro_asignado
     set estado = 'CANCELADO_ADMIN', fecha_res = now(),
         razon  = 'Cancelado por admin' || case when v_razon <> '' then ': '||v_razon else '' end,
         updated_at = now()
   where id_cobro = v_idcobro;

  -- revertir el ticket a CRÉDITO (paridad GAS) para que quede re-asignable
  update me.ventas set forma_pago = 'CREDITO'
   where id_venta = v_row.id_venta and upper(coalesce(forma_pago,'')) in ('CREDITO','POR_COBRAR');

  return jsonb_build_object(
    'ok', true, 'idCobro', v_idcobro, 'idVenta', v_row.id_venta, 'via','directo',
    'mensaje','Cobro cancelado y ticket retornado a CRÉDITO',
    'pushVendedor', v_row.vendedor_dest,
    'pushTitulo','⊘ Cobro cancelado',
    'pushCuerpo', v_admin || ' canceló el cobro del ticket ' || coalesce(nullif(v_row.correlativo,''), v_row.id_venta) || '. Ya no debes cobrarlo.'
  );
end;
$fn$;
revoke all on function me.cancelar_cobro_asignado(jsonb) from public;
grant execute on function me.cancelar_cobro_asignado(jsonb) to authenticated, service_role;


create or replace function me.reasignar_cobro_asignado(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idcobro text := btrim(coalesce(p->>'idCobro',''));
  v_caja    text := btrim(coalesce(p->>'cajaDestino',''));
  v_admin   text := regexp_replace(btrim(coalesce(p->>'adminNombre', p->>'admin', 'MOS-Admin')), '^admin:', '', 'i');
  v_row     me.creditos_cobro_asignado%rowtype;
  v_nuevo   jsonb;
begin
  if coalesce(me.jwt_app(),'') <> 'MOS' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','COBRO_OFF');
  end if;
  if v_idcobro = '' then return jsonb_build_object('ok',false,'error','idCobro requerido'); end if;
  if v_caja = ''    then return jsonb_build_object('ok',false,'error','cajaDestino requerida'); end if;

  perform pg_advisory_xact_lock(hashtext('cobrocancel:'||v_idcobro));
  select * into v_row from me.creditos_cobro_asignado where id_cobro = v_idcobro limit 1;
  if not found then return jsonb_build_object('ok',false,'error','COBRO_NO_ENCONTRADO'); end if;
  if upper(coalesce(v_row.estado,'')) <> 'ASIGNADO' then
    return jsonb_build_object('ok',false,'error','COBRO_NO_ASIGNADO','estado',v_row.estado);
  end if;
  if v_row.caja_destino = v_caja then
    return jsonb_build_object('ok',false,'error','MISMA_CAJA');
  end if;

  -- marcar el viejo como REASIGNADO
  update me.creditos_cobro_asignado
     set estado = 'REASIGNADO', fecha_res = now(),
         razon  = 'Reasignado a '||v_caja, updated_at = now()
   where id_cobro = v_idcobro;

  -- crear el nuevo cobro (valida caja destino ABIERTA + venta pendiente + no duplicado)
  v_nuevo := me.asignar_cobro_cajero(jsonb_build_object(
    'idVenta',        v_row.id_venta,
    'cajaDestino',    v_caja,
    'metodoSugerido', coalesce(v_row.metodo_sug,''),
    'adminNombre',    v_admin,
    'mensajeAdmin',   'Reasignación #'||(coalesce(v_row.reasignaciones,0)+1),
    'horasTTL',       coalesce(v_row.horas_ttl,1)
  ));

  -- si la creación falló, revertir el viejo a ASIGNADO (no dejar el crédito huérfano)
  if not coalesce((v_nuevo->>'ok')::boolean, false) then
    update me.creditos_cobro_asignado set estado='ASIGNADO', fecha_res=null, razon='', updated_at=now()
     where id_cobro = v_idcobro;
    return jsonb_build_object('ok',false,'error', coalesce(v_nuevo->>'error','REASIGNACION_FALLIDA'),'detalle',v_nuevo);
  end if;

  return jsonb_build_object(
    'ok', true, 'via','directo', 'idCobroViejo', v_idcobro, 'idVenta', v_row.id_venta,
    'idCobro', v_nuevo->>'idCobro', 'cajeroDestino', v_nuevo->>'cajeroDestino',
    'horasTTL', v_nuevo->'horasTTL', 'fechaVencimiento', v_nuevo->>'fechaVencimiento',
    'mensaje', 'Cobro reasignado a '||coalesce(v_nuevo->>'cajeroDestino', v_caja),
    'pushTitulo', v_nuevo->>'pushTitulo', 'pushCuerpo', v_nuevo->>'pushCuerpo'
  );
end;
$fn$;
revoke all on function me.reasignar_cobro_asignado(jsonb) from public;
grant execute on function me.reasignar_cobro_asignado(jsonb) to authenticated, service_role;
