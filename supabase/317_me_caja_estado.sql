-- ============================================================================
-- 317_me_caja_estado.sql — Estado de una caja (para que ME verifique al bootear)
-- ----------------------------------------------------------------------------
-- Bug: ME restaura la caja del localStorage si es de HOY, sin chequear el server.
-- Si MOS la cerró (forzado / cierre / auto-cierre nocturno), el local sigue diciendo
-- "hoy" → ME muestra una caja FANTASMA abierta. Esta RPC ligera deja que ME confirme
-- contra me.cajas (tabla viva) y limpie el estado local si la caja ya no está ABIERTA.
-- Read-only, gate jwt_app in (mosExpress, MOS).
-- ============================================================================

create or replace function me.caja_estado(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idCaja','')),''); v_est text; v_found boolean;
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','MOS') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idCaja requerido'); end if;
  select upper(coalesce(estado,'')) into v_est from me.cajas where id_caja = v_id;
  v_found := found;
  return jsonb_build_object('ok', true, 'idCaja', v_id, 'existe', v_found,
    'estado', coalesce(v_est,''), 'abierta', (coalesce(v_est,'') = 'ABIERTA'));
end;
$fn$;
revoke all on function me.caja_estado(jsonb) from public;
grant execute on function me.caja_estado(jsonb) to authenticated, service_role;
