-- 380 · kill-GAS (MOS) wrapper cross-app: rotación semanal de WH leída desde el panel MOS.
-- Antes: MOS-GAS → WH-GAS (postToWarehouse). Ahora: mos.wh_rotacion_semanal gatea mos._claim_ok()
-- y delega en wh.rotacion_semanal (SECURITY DEFINER puede llamar la interna sin pasar wh._claim_ok,
-- que rechazaría el token MOS). Solo LECTURA (wh.envasados/guias) → sin riesgo de dinero/stock.
create or replace function mos.wh_rotacion_semanal(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_sem  int  := greatest(1, least(52, coalesce(mos._numn(p->>'semanas'),8)::int));
  v_cods text := nullif(btrim(coalesce(p->>'codigos', p->>'codigosProducto','')),'');
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- wh.rotacion_semanal ya devuelve {ok:true, data:{etiquetas, productos}} → se reenvía tal cual.
  return wh.rotacion_semanal(v_sem, v_cods);
end; $fn$;

revoke all on function mos.wh_rotacion_semanal(jsonb) from public, anon;
grant execute on function mos.wh_rotacion_semanal(jsonb) to authenticated, service_role;
