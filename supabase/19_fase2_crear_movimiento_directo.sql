-- 19_fase2_crear_movimiento_directo.sql — Fase 2 ESCRITURA DIRECTA: la PWA crea el movimiento de caja
-- (ingreso/egreso, incl. *_VIRTUAL) directo en Supabase, sin pasar por GAS. Idempotente por id_extra
-- (generado por el cliente → reintento/doble-tap NO duplica). security definer, fail-closed por claim
-- app=mosExpress. grant authenticated. NO toca Sheets (mirrorMovimientoASheets lo espeja para que el
-- cierre —que lee Sheets— cuadre, + dispara la alerta de efectivo).
create or replace function me.crear_movimiento_directo(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_app     text := me.jwt_app();
  v_id      text := nullif(btrim(coalesce(p->>'id_extra','')), '');
  v_caja    text := coalesce(p->>'id_caja','');
  v_caja_ok boolean;
  v_ins     int;
begin
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if v_id  is null         then return jsonb_build_object('status','error','error','ID_EXTRA_REQUERIDO'); end if;

  -- idempotencia PRIMERO: si ya existe (reintento), devolver dedup sin re-validar la caja (ya se registró
  -- cuando estaba abierta) → evita un rechazo espurio si la caja cerró entre el 1er intento y el reintento.
  perform 1 from me.movimientos_extra where id_extra = v_id;
  if found then return jsonb_build_object('status','success','id_extra',v_id,'dedup',true); end if;

  -- caja debe estar ABIERTA para un movimiento NUEVO (parity con registrarExtraCajaConLog). fail-closed:
  -- no encontrada o no-ABIERTA → rechazar; el cliente cae al fallback GAS (que también valida contra Sheets).
  select (estado = 'ABIERTA') into v_caja_ok from me.cajas where id_caja = v_caja limit 1;
  if not coalesce(v_caja_ok, false) then return jsonb_build_object('status','error','error','CAJA_NO_ABIERTA'); end if;

  insert into me.movimientos_extra (id_extra, id_caja, ts, tipo, monto, concepto, obs, registrado_por,
                                    zona_id, dispositivo_id)
  values (v_id, v_caja, now(), coalesce(p->>'tipo','EGRESO'),
          coalesce((p->>'monto')::numeric, 0), coalesce(p->>'concepto',''), coalesce(p->>'obs',''),
          coalesce(p->>'registrado_por',''), coalesce(p->>'zona_id',''), coalesce(p->>'dispositivo_id',''))
  on conflict (id_extra) do nothing;
  get diagnostics v_ins = row_count;

  -- v_ins=0 ⇒ ya existía (reintento/doble-tap) → idempotente, no duplica
  return jsonb_build_object('status','success','id_extra',v_id,'dedup', v_ins = 0);
end;
$fn$;

revoke all on function me.crear_movimiento_directo(jsonb) from public;
grant execute on function me.crear_movimiento_directo(jsonb) to authenticated;
