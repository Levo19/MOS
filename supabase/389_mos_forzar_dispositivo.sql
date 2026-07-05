-- 389 · kill-GAS MOS — forzar acción en dispositivo (push/wizard/reverify). Valida clave admin + setea flag
-- que el dispositivo lee en su heartbeat. Réplica de Config.gs forzarPushDispositivo/forzarWizardDispositivo.
create or replace function mos.forzar_dispositivo(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'deviceId', p->>'idDispositivo','')),'');
  v_campo text := lower(coalesce(p->>'campo', p->>'tipo','push'));
  v_clave text := coalesce(p->>'claveAdmin','');
  v_verif jsonb; v_col text; v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere deviceId'); end if;
  if v_clave = '' then return jsonb_build_object('ok',false,'error','Requiere claveAdmin'); end if;
  v_col := case v_campo when 'wizard' then 'forzar_wizard' when 'reverify' then 'forzar_reverify' else 'forzar_push' end;
  v_verif := mos.verificar_clave_admin(v_clave, 'FORZAR_'||upper(v_campo), v_id, coalesce(p->>'app',''), v_id, 'Forzar '||v_campo);
  if not coalesce((v_verif->>'autorizado')::boolean,false) then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error',coalesce(v_verif->>'error','Clave incorrecta')));
  end if;
  execute format('update mos.dispositivos set %I = true where id_dispositivo = $1', v_col) using v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','Dispositivo no encontrado'); end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',true,'forzadoPor',coalesce(v_verif->>'nombre','admin')));
end; $fn$;

revoke all on function mos.forzar_dispositivo(jsonb) from public, anon;
grant execute on function mos.forzar_dispositivo(jsonb) to authenticated, service_role;
