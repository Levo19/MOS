-- ============================================================================
-- 310_me_confirmar_cobro_cero_gas.sql — Confirm del cobro (money-write) cero-GAS
-- ----------------------------------------------------------------------------
-- Última pieza del ciclo de cobro. Reemplaza gas/Creditos.gs::confirmarCobroAsignado
-- (que envuelve cobrarCreditoConExtra). El cajero, al recibir el dinero, confirma:
--   1) crea el/los movimiento(s) de caja (INGRESO / INGRESO_VIRTUAL / MIXTO) en la
--      caja receptora — MISMAS filas que escribe el GAS → el cierre (que ya lee
--      me.movimientos_extra vía me.cierre_datos_caja, ME_LECTURA_CIERRE_DIRECTA=ON)
--      las cuadra idéntico, sin Hoja;
--   2) flip me.ventas.forma_pago al método elegido (paridad con el Sheet setValue);
--   3) marca el cobro COBRADO.
-- Atómico (advisory-lock por cobro), idempotente (idExtra determinista + guard COBRADO),
-- valida venta pendiente + caja receptora ABIERTA. INERTE hasta ME_COBRO_DIRECTO='1'.
-- ============================================================================

create or replace function me.confirmar_cobro(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idcobro text := btrim(coalesce(p->>'idCobro',''));
  v_metodo  text := btrim(coalesce(p->>'metodoFinal',''));
  v_metup   text := upper(btrim(coalesce(p->>'metodoFinal','')));
  v_efe     numeric := coalesce((p->>'montoEfectivo')::numeric, 0);
  v_vir     numeric := coalesce((p->>'montoVirtual')::numeric, 0);
  v_vend    text := btrim(coalesce(p->>'vendedor', p->>'usuario', ''));
  v_obs     text := btrim(coalesce(p->>'obs',''));
  c         me.creditos_cobro_asignado%rowtype;
  v_fp text; v_cli text; v_total numeric; v_cajaest text;
  v_concepto text := 'Abono deuda'; v_obsx text; v_id1 text;
begin
  -- el cajero confirma desde ME; MOS admin también permitido (paridad de operación)
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','COBRO_OFF');
  end if;
  if v_idcobro = '' then return jsonb_build_object('ok',false,'error','idCobro requerido'); end if;
  if v_metodo  = '' then return jsonb_build_object('ok',false,'error','metodoFinal requerido'); end if;

  -- serializar por VENTA (no por cobro): así el confirmar-asignado y el cobrar-directo
  -- (me.cobrar_credito_directo, 314) compiten por el MISMO lock 'cobro:'||idVenta y no pueden
  -- registrar el dinero dos veces. Leo el cobro para obtener la venta, tomo el lock, y re-leo
  -- el estado fresco bajo el lock (anti-TOCTOU). Mismo namespace que asignar (308).
  select * into c from me.creditos_cobro_asignado where id_cobro = v_idcobro;
  if not found then return jsonb_build_object('ok',false,'error','COBRO_NO_ENCONTRADO'); end if;
  perform pg_advisory_xact_lock(hashtext('cobro:'||c.id_venta));
  select * into c from me.creditos_cobro_asignado where id_cobro = v_idcobro;
  -- idempotencia: ya cobrado → devolver éxito sin re-registrar dinero
  if upper(coalesce(c.estado,'')) = 'COBRADO' then
    return jsonb_build_object('ok',true,'idCobro',v_idcobro,'idVenta',c.id_venta,'idempotente',true,'via','directo',
      'cajaDest',c.caja_destino,'monto',c.monto,'adminAsig',c.admin_asignador,'cliente',c.cliente_nombre,'metodo',c.metodo_sug);
  end if;
  if upper(coalesce(c.estado,'')) <> 'ASIGNADO' then
    return jsonb_build_object('ok',false,'error','COBRO_NO_ASIGNADO_'||upper(coalesce(c.estado,'')));
  end if;

  -- venta debe seguir pendiente (no anulada, no ya pagada)
  select upper(coalesce(forma_pago,'')), coalesce(cliente_nombre,''), coalesce(total,0)
    into v_fp, v_cli, v_total
    from me.ventas where id_venta = c.id_venta;
  if not found then return jsonb_build_object('ok',false,'error','VENTA_NO_ENCONTRADA'); end if;
  if v_fp = 'ANULADO' then return jsonb_build_object('ok',false,'error','VENTA_ANULADA'); end if;
  if v_fp not in ('CREDITO','POR_COBRAR') then return jsonb_build_object('ok',false,'error','VENTA_NO_PENDIENTE'); end if;

  -- caja receptora (la del cobro) debe estar ABIERTA
  select upper(coalesce(estado,'')) into v_cajaest from me.cajas where id_caja = c.caja_destino;
  if coalesce(v_cajaest,'') <> 'ABIERTA' then return jsonb_build_object('ok',false,'error','CAJA_RECEPTORA_NO_ABIERTA'); end if;

  v_obsx := 'Cobro de crédito ticket ' || c.id_venta || ' · cliente ' || coalesce(nullif(v_cli,''),'—')
            || case when v_obs <> '' then ' · ' || v_obs else '' end;

  -- 1) movimiento(s) — mismas filas que cobrarCreditoConExtra. idExtra determinista
  --    desde idCobro → reintento/doble-tap NO duplica (on conflict do nothing).
  if v_metup like 'MIXTO%' then
    if abs((v_efe + v_vir) - v_total) > 0.01 then
      return jsonb_build_object('ok',false,'error','MIXTO_NO_CUADRA');
    end if;
    if v_efe > 0 then
      insert into me.movimientos_extra(id_extra,id_caja,ts,tipo,monto,concepto,obs,registrado_por)
      values ('EX-'||v_idcobro||'-E', c.caja_destino, now(), 'INGRESO', v_efe, v_concepto, v_obsx, v_vend)
      on conflict (id_extra) do nothing;
    end if;
    if v_vir > 0 then
      insert into me.movimientos_extra(id_extra,id_caja,ts,tipo,monto,concepto,obs,registrado_por)
      values ('EX-'||v_idcobro||'-V', c.caja_destino, now(), 'INGRESO_VIRTUAL', v_vir, v_concepto, v_obsx, v_vend)
      on conflict (id_extra) do nothing;
    end if;
  else
    v_id1 := 'EX-'||v_idcobro;
    insert into me.movimientos_extra(id_extra,id_caja,ts,tipo,monto,concepto,obs,registrado_por)
    values (v_id1, c.caja_destino, now(),
            case when v_metup = 'EFECTIVO' then 'INGRESO' else 'INGRESO_VIRTUAL' end,
            v_total, v_concepto, v_obsx, v_vend)
    on conflict (id_extra) do nothing;
  end if;

  -- 2) flip forma_pago (paridad con el setValue del Sheet: guarda el método tal cual)
  update me.ventas set forma_pago = v_metodo where id_venta = c.id_venta;

  -- 3) marcar el cobro COBRADO
  update me.creditos_cobro_asignado
     set estado='COBRADO', fecha_res=now(), metodo_sug=v_metup
   where id_cobro = v_idcobro;

  return jsonb_build_object('ok',true,'idCobro',v_idcobro,'idVenta',c.id_venta,'via','directo',
    'cajaDest',c.caja_destino,'monto',v_total,'adminAsig',c.admin_asignador,'cliente',v_cli,'metodo',v_metup,
    'pushTitulo','✅ Cobro confirmado · '||coalesce(nullif(v_cli,''),'cliente'),
    'pushCuerpo','S/ '||to_char(v_total,'FM999999990.00')||' cobrado en '||c.caja_destino||' ('||v_metup||')');
end;
$fn$;
revoke all on function me.confirmar_cobro(jsonb) from public;
grant execute on function me.confirmar_cobro(jsonb) to authenticated, service_role;

-- ── LECTURA del cajero: cobros ASIGNADO pendientes de SU caja (reemplaza el GAS
--    `cobros_asignados_cajero`). Gateada por el mismo flag → INERTE hasta el cutover.
create or replace function me.cobros_pendientes_caja(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_caja text := btrim(coalesce(p->>'cajaId', p->>'idCaja', '')); v_data jsonb;
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','COBRO_OFF');
  end if;
  if v_caja = '' then return jsonb_build_object('ok',false,'error','cajaId requerido'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'idCobro', id_cobro, 'idVenta', id_venta, 'cajaDestino', caja_destino,
           'metodoSug', metodo_sug, 'monto', monto, 'cliente', cliente_nombre,
           'correlativo', correlativo, 'mensajeAdmin', mensaje_admin,
           'adminAsig', admin_asignador, 'horasTTL', horas_ttl,
           'fechaVencimiento', case when fecha_vencimiento is null then '' else to_char(fecha_vencimiento at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') end
         ) order by fecha_asig), '[]'::jsonb)
    into v_data
    from me.creditos_cobro_asignado
   where caja_destino = v_caja and upper(coalesce(estado,'')) = 'ASIGNADO';
  return jsonb_build_object('ok', true, 'cobros', v_data);
end;
$fn$;
revoke all on function me.cobros_pendientes_caja(jsonb) from public;
grant execute on function me.cobros_pendientes_caja(jsonb) to authenticated, service_role;
