-- 258 · FIX Ronda 1 — me.cancelar_apertura: cierra una caja recién abierta y abandonada (logout durante el
-- await de apertura directa) → evita la caja huérfana ABIERTA que bloquea la zona el resto del día.
-- Liviano (no arqueo, no guía): solo marca CERRADA_AUTO si sigue ABIERTA. Idempotente. app=mosExpress.
create or replace function me.cancelar_apertura(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app  text := me.jwt_app();
  v_id   text := nullif(btrim(coalesce(p->>'idCaja','')),'');
  v_n    int;
begin
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('status','error','error','ID_CAJA_REQUERIDO'); end if;
  update me.cajas set estado='CERRADA_AUTO', fecha_cierre=now()
   where id_caja = v_id and estado = 'ABIERTA';
  get diagnostics v_n = row_count;
  return jsonb_build_object('status','success','cerradas', v_n);
end;
$fn$;
revoke all on function me.cancelar_apertura(jsonb) from public, anon;
grant execute on function me.cancelar_apertura(jsonb) to authenticated, service_role;
notify pgrst, 'reload schema';
