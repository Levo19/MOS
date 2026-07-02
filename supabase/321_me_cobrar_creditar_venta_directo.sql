-- ============================================================================
-- 321_me_cobrar_creditar_venta_directo.sql — Cutover cero-GAS de COBRAR_VENTA / CREDITAR_VENTA
-- ----------------------------------------------------------------------------
-- Replica FIEL de gas Caja.gs::cobrarVentaExistente (COBRAR_VENTA) y creditarVenta (CREDITAR_VENTA).
-- Ambos son SETTERS de forma_pago (NO crean movimientos_extra, NO tocan stock/pickup/guía):
--   · me.cobrar_venta_directo : forma_pago := metodo (+ id_caja := cajaId si viene). Cubre cobrar un
--       POR_COBRAR, cambiar moneda de una cobrada, y revertir a POR_COBRAR. La plata se reconoce por
--       el forma_pago+id_caja de la venta en el arqueo del cierre (por eso id_caja es money-relevante:
--       define en qué caja cuenta el efectivo). Idempotente (setear el mismo valor no duplica nada).
--   · me.creditar_venta_directo : forma_pago := 'CREDITO' (+ obs = nota del deudor).
-- Ambos: gate app in ('mosExpress','MOS') + flag ME_COBRO_DIRECTO (kill-switch → 'COBRO_OFF' → GAS);
--   lock 'cobro:'||idVenta (serializa con confirmar/directo/anular/cancelar de la MISMA venta, paridad
--   con el _conLockCred de GAS); guard ANULADO% terminal; historial_cambios (paridad auditarLog).
-- El PIN admin se valida en el frontend (GAS tampoco lo valida server-side; adminAuth = auditoría).
-- ============================================================================

-- ── COBRAR_VENTA (setter general de forma_pago + id_caja) ────────────────────
create or replace function me.cobrar_venta_directo(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_met   text := nullif(btrim(coalesce(p->>'metodo','')),'');
  v_caja  text := nullif(btrim(coalesce(p->>'cajaId','')),'');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_mot   text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'');
  v_ant   text; v_cajaAnt text; v_hist jsonb; v_cambios jsonb;
begin
  if v_app not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','COBRO_OFF');
  end if;
  if v_id  is null then return jsonb_build_object('ok',false,'error','idVenta requerido'); end if;
  if v_met is null then return jsonb_build_object('ok',false,'error','metodo requerido'); end if;

  -- lock por VENTA (mismo namespace que confirmar/directo/anular) → un COBRAR_VENTA no corre en
  -- paralelo con un cobro/anulación de la misma venta. Leo bajo el lock (FOR UPDATE).
  perform pg_advisory_xact_lock(hashtext('cobro:'||v_id));
  select forma_pago, coalesce(id_caja,''), historial_cambios into v_ant, v_cajaAnt, v_hist
  from me.ventas where id_venta = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Venta '||v_id||' no encontrada'); end if;

  -- ANULADO% es terminal (paridad GAS): no se cobra ni se revierte una venta anulada.
  if upper(coalesce(v_ant,'')) like 'ANULADO%' then
    return jsonb_build_object('ok',false,'error','La venta está ANULADA — no se puede cambiar su forma de pago');
  end if;

  v_cambios := jsonb_build_array(jsonb_build_object('campo','FormaPago','antes',coalesce(v_ant,''),'despues',v_met));
  if v_caja is not null and v_caja <> coalesce(v_cajaAnt,'') then
    v_cambios := v_cambios || jsonb_build_array(jsonb_build_object('campo','ID_Caja','antes',coalesce(v_cajaAnt,''),'despues',v_caja));
  end if;

  update me.ventas
     set forma_pago = v_met,
         id_caja = case when v_caja is not null then v_caja else id_caja end,   -- solo si viene cajaId (paridad GAS)
         historial_cambios = me._venta_hist_append(v_hist, jsonb_build_object(
           'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
           'source','ME_COBRAR_VENTA','accion','cobrar_venta',
           'cambios', v_cambios, 'autorizadoPor', v_auth, 'motivo', v_mot)),
         updated_at = now()
   where id_venta = v_id;

  return jsonb_build_object('ok',true,'via','directo','mensaje','Venta cobrada correctamente',
    'idVenta',v_id,'antes',coalesce(v_ant,''),'despues',v_met);
end;
$fn$;
revoke all on function me.cobrar_venta_directo(jsonb) from public, anon;
grant execute on function me.cobrar_venta_directo(jsonb) to authenticated, service_role;


-- ── CREDITAR_VENTA (→ CREDITO + obs) ─────────────────────────────────────────
create or replace function me.creditar_venta_directo(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app   text := me.jwt_app();
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_obs   text := coalesce(p->>'obs','');
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_rol   text := coalesce(nullif(btrim(coalesce(p->>'rol','')),''),'');
  v_auth  jsonb := coalesce(p->'autorizadoPor','null'::jsonb);
  v_ant   text; v_obsAnt text; v_hist jsonb;
begin
  if v_app not in ('mosExpress','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','COBRO_OFF');
  end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idVenta requerido'); end if;

  perform pg_advisory_xact_lock(hashtext('cobro:'||v_id));
  select forma_pago, coalesce(obs,''), historial_cambios into v_ant, v_obsAnt, v_hist
  from me.ventas where id_venta = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Venta '||v_id||' no encontrada'); end if;

  if upper(coalesce(v_ant,'')) like 'ANULADO%' then
    return jsonb_build_object('ok',false,'error','La venta está ANULADA — no se puede creditar');
  end if;

  update me.ventas
     set forma_pago = 'CREDITO', obs = v_obs,
         historial_cambios = me._venta_hist_append(v_hist, jsonb_build_object(
           'ts', to_jsonb(now()), 'usuario', coalesce(v_user,''), 'rol', v_rol,
           'source','ME_CREDITAR_VENTA','accion','convertir_a_credito',
           'cambios', jsonb_build_array(
             jsonb_build_object('campo','FormaPago','antes',coalesce(v_ant,''),'despues','CREDITO'),
             jsonb_build_object('campo','Obs','antes',coalesce(v_obsAnt,''),'despues',v_obs)),
           'autorizadoPor', v_auth, 'motivo', coalesce(nullif(v_obs,''),''))),
         updated_at = now()
   where id_venta = v_id;

  return jsonb_build_object('ok',true,'via','directo','mensaje','Crédito registrado',
    'idVenta',v_id,'antes',coalesce(v_ant,''));
end;
$fn$;
revoke all on function me.creditar_venta_directo(jsonb) from public, anon;
grant execute on function me.creditar_venta_directo(jsonb) to authenticated, service_role;
