-- 384 · kill-GAS ME: cambiar la impresora de una caja ABIERTA (solo config, sin PrintNode).
-- Réplica de Caja.gs cambiarImpresoraCaja: UPDATE me.cajas set estacion, printnode_id where id_caja and estado='ABIERTA'.
-- Gate me._claim_zona_ok (acepta mosExpress/MOS). El front ya exige PIN admin antes de llamar.
create or replace function me.cambiar_impresora_caja(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_id  text := nullif(btrim(coalesce(p->>'idCaja','')),'');
  v_est text := nullif(btrim(coalesce(p->>'estacionNombre', p->>'estacion','')),'');
  v_pn  text := nullif(btrim(coalesce(p->>'printnodeId', p->>'printNodeId','')),'');
  v_n int;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('status','error','mensaje','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('status','error','mensaje','idCaja requerido'); end if;
  update me.cajas
     set estacion    = coalesce(v_est, estacion),
         printnode_id = coalesce(v_pn, printnode_id),
         updated_at  = now()
   where id_caja = v_id and upper(coalesce(estado,'')) = 'ABIERTA';
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('status','error','mensaje','Caja no encontrada o no está ABIERTA'); end if;
  return jsonb_build_object('status','success');
end; $fn$;

revoke all on function me.cambiar_impresora_caja(jsonb) from public, anon;
grant execute on function me.cambiar_impresora_caja(jsonb) to authenticated, service_role;
