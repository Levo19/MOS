-- 437 · Wiring re-verificacion clave en me.cobrar_credito_directo (cobro de credito con caja receptora).

-- me.cobrar_credito_directo (accion=COBRAR_CREDITO_CON_EXTRA)
CREATE OR REPLACE FUNCTION me.cobrar_credito_directo(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idventa text := btrim(coalesce(p->>'idVenta',''));
  v_caja    text := btrim(coalesce(p->>'cajaReceptora', p->>'cajaDestino', ''));
  v_metodo  text := btrim(coalesce(p->>'metodo',''));
  v_metup   text := upper(btrim(coalesce(p->>'metodo','')));
  v_efe     numeric := coalesce((p->>'montoEfectivo')::numeric, 0);
  v_vir     numeric := coalesce((p->>'montoVirtual')::numeric, 0);
  v_vend    text := btrim(coalesce(p->>'vendedor', p->>'usuario', 'MOS-Admin'));
  v_obs     text := btrim(coalesce(p->>'obs',''));
  v_fp text; v_cli text; v_total numeric; v_cajaest text;
  v_concepto text := 'Abono deuda'; v_obsx text; v_id1 text; v_existe boolean;
  v_cobros int := 0;
  v_rvf jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'COBRAR_CREDITO_CON_EXTRA', coalesce(p->>'idVenta',''), coalesce(p->>'app','MOS'));
  if v_rvf is not null then return v_rvf; end if;
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','COBRO_OFF');
  end if;
  if v_idventa = '' then return jsonb_build_object('ok',false,'error','idVenta requerido'); end if;
  if v_caja    = '' then return jsonb_build_object('ok',false,'error','cajaReceptora requerida'); end if;
  if v_metodo  = '' then return jsonb_build_object('ok',false,'error','metodo requerido'); end if;

  -- lock por VENTA (mismo namespace que asignar 308 y confirmar 310) → serializa TODAS las
  -- vías de cobro de una venta: imposible registrar el dinero dos veces (directo vs confirmar).
  perform pg_advisory_xact_lock(hashtext('cobro:'||v_idventa));

  select upper(coalesce(forma_pago,'')), coalesce(cliente_nombre,''), coalesce(total,0)
    into v_fp, v_cli, v_total
    from me.ventas where id_venta = v_idventa;
  if not found then return jsonb_build_object('ok',false,'error','VENTA_NO_ENCONTRADA'); end if;
  if v_fp like 'ANULADO%' then return jsonb_build_object('ok',false,'error','VENTA_ANULADA'); end if;
  if v_fp not in ('CREDITO','POR_COBRAR') then
    -- ¿ya fue cobrada por ESTE mismo flujo (retry de red)? → éxito idempotente
    select exists(select 1 from me.movimientos_extra where id_extra in ('EX-DIR-'||v_idventa, 'EX-DIR-'||v_idventa||'-E', 'EX-DIR-'||v_idventa||'-V'))
      into v_existe;
    if v_existe then
      return jsonb_build_object('ok',true,'idempotente',true,'via','directo','idVenta',v_idventa,
        'formaPagoNueva',v_fp,'mensaje','Crédito ya cobrado');
    end if;
    return jsonb_build_object('ok',false,'error','VENTA_NO_PENDIENTE','estado',v_fp);
  end if;

  -- [500x HIGH] serializar con el CIERRE de la caja receptora (mismo lock que 315/27) ANTES de validar
  -- ABIERTA → un cobro directo no entra a una caja que se está cerrando en paralelo.
  perform pg_advisory_xact_lock(hashtext('cerrarcaja:'||v_caja));
  select upper(coalesce(estado,'')) into v_cajaest from me.cajas where id_caja = v_caja;
  if coalesce(v_cajaest,'') <> 'ABIERTA' then return jsonb_build_object('ok',false,'error','CAJA_RECEPTORA_NO_ABIERTA'); end if;

  v_obsx := 'Cobro de crédito ticket ' || v_idventa || ' · cliente ' || coalesce(nullif(v_cli,''),'—')
            || case when v_obs <> '' then ' · ' || v_obs else '' end;

  -- 1) movimiento(s) — mismas filas que cobrarCreditoConExtra; idExtra determinista EX-DIR-<idVenta>.
  if v_metup like 'MIXTO%' then
    if v_efe < 0 or v_vir < 0 then return jsonb_build_object('ok',false,'error','MONTO_INVALIDO'); end if;  -- [500x] no INGRESO negativo
    if abs((v_efe + v_vir) - v_total) > 0.01 then
      return jsonb_build_object('ok',false,'error','MIXTO_NO_CUADRA');
    end if;
    if v_efe > 0 then
      insert into me.movimientos_extra(id_extra,id_caja,ts,tipo,monto,concepto,obs,registrado_por)
      values ('EX-DIR-'||v_idventa||'-E', v_caja, now(), 'INGRESO', v_efe, v_concepto, v_obsx, v_vend)
      on conflict (id_extra) do nothing;
    end if;
    if v_vir > 0 then
      insert into me.movimientos_extra(id_extra,id_caja,ts,tipo,monto,concepto,obs,registrado_por)
      values ('EX-DIR-'||v_idventa||'-V', v_caja, now(), 'INGRESO_VIRTUAL', v_vir, v_concepto, v_obsx, v_vend)
      on conflict (id_extra) do nothing;
    end if;
  else
    v_id1 := 'EX-DIR-'||v_idventa;
    insert into me.movimientos_extra(id_extra,id_caja,ts,tipo,monto,concepto,obs,registrado_por)
    values (v_id1, v_caja, now(),
            case when v_metup = 'EFECTIVO' then 'INGRESO' else 'INGRESO_VIRTUAL' end,
            v_total, v_concepto, v_obsx, v_vend)
    on conflict (id_extra) do nothing;
  end if;

  -- 2) flip forma_pago (raw, paridad con el setValue del Sheet)
  update me.ventas set forma_pago = v_metodo where id_venta = v_idventa;

  -- 3) [mejora money-safe] cerrar cualquier cobro ASIGNADO vivo de esta venta → COBRADO
  --    (evita que un cajero lo cobre otra vez; el GAS lo dejaba colgado).
  update me.creditos_cobro_asignado
     set estado='COBRADO', fecha_res=now(), metodo_sug=v_metup,
         razon = coalesce(nullif(razon,''),'') || case when coalesce(razon,'')<>'' then ' · ' else '' end || 'Cobrado directo por admin',
         updated_at=now()
   where id_venta = v_idventa and upper(coalesce(estado,'')) = 'ASIGNADO';
  get diagnostics v_cobros = row_count;

  return jsonb_build_object('ok',true,'via','directo','idVenta',v_idventa,
    'formaPagoNueva',v_metodo,'monto',v_total,'cliente',v_cli,'cajaReceptora',v_caja,
    'cobrosCerrados',v_cobros,
    'mensaje','Crédito cobrado · S/ '||to_char(v_total,'FM999999990.00')||' registrado en '||v_caja);
end;
$function$
;

