-- 356: [FIX Regla A] Cierre forzado de cajas ME a las 23h (complementa mos-cierre-forzado-11pm, que cerraba
-- la SESIÓN/liquidaciones + forzar_logout pero NO me.cajas). Reusa el cierre PROBADO me.cerrar_caja (auto-computa
-- monto_final = inicial + efectivo + ingresos - egresos, anula POR_COBRAR, genera efectos). estado_final=CERRADA_AUTO
-- → NO dispara el trigger de push de cierre (tg_me_caja_push_upd lo excluye). Best-effort por caja: una que falle
-- no frena las demás. Cron propio (no toca el cron de sesiones que ya corre bien).
create or replace function me.cerrar_cajas_dia_forzado()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare r record; v_res jsonb; v_ok int := 0; v_err int := 0;
begin
  -- me.cerrar_caja exige claim app='mosExpress' + flag ME_CIERRE_DIRECTO=1 (kill-switch respetado).
  perform set_config('request.jwt.claims', '{"app":"mosExpress"}', true);
  for r in select id_caja from me.cajas where estado = 'ABIERTA' loop
    begin
      v_res := me.cerrar_caja(jsonb_build_object('id_caja', r.id_caja, 'estado_final', 'CERRADA_AUTO'));
      if coalesce(v_res->>'status','') = 'success' then v_ok := v_ok + 1; else v_err := v_err + 1; end if;
    exception when others then v_err := v_err + 1;  -- aísla el fallo de una caja
    end;
  end loop;
  insert into mos.cron_log(job, ok, resultado) values ('cerrar_cajas_11pm', true, jsonb_build_object('cerradas', v_ok, 'errores', v_err));
  return jsonb_build_object('ok', true, 'cerradas', v_ok, 'errores', v_err);
exception when others then
  insert into mos.cron_log(job, ok, resultado) values ('cerrar_cajas_11pm', false, jsonb_build_object('excepcion', SQLERRM));
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end; $fn$;
revoke all on function me.cerrar_cajas_dia_forzado() from public, anon;
grant execute on function me.cerrar_cajas_dia_forzado() to service_role;

-- 23:01 Lima = 04:01 UTC (1 min después del cierre de sesiones, para que corra al final del día). Idempotente.
select cron.unschedule('me-cierre-cajas-11pm') where exists (select 1 from cron.job where jobname='me-cierre-cajas-11pm');
select cron.schedule('me-cierre-cajas-11pm', '1 4 * * *', 'select me.cerrar_cajas_dia_forzado();');
