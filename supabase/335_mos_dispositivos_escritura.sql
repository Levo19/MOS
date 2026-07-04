-- 335_mos_dispositivos_escritura.sql
-- [CERO-GAS] Reemplaza 5 handlers GAS de escritura de dispositivos:
--   registrarPermisosDispositivo / marcarWizardMostrado / reportarQuotaDispositivo
--   (fire-and-forget, anon)  +  forzarWizardDispositivo / forzarPushDispositivo
--   (acción admin del panel MOS, clave 8 díg vía _validar_clave_admin_core).
-- Sombra mos.dispositivos autoritativa (MOS_DISPOSITIVOS_DIRECTO=1). Tipos verificados:
-- forzar_wizard/forzar_push=boolean, permisos_json=jsonb, permisos_lastupdate=timestamptz.

create table if not exists mos.quota_dispositivos_log (
  id bigserial primary key, ts timestamptz not null default now(),
  device_id text, vendedor text, pending_sales int, total_keys int, accion text
);

-- 1) registrar_permisos_dispositivo (device self-report, anon)
create or replace function mos.registrar_permisos_dispositivo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_dev text := nullif(btrim(coalesce(p->>'deviceId','')), '');
  v_perm jsonb := p->'permisos'; v_n int;
begin
  if v_claim not in ('mosExpress','MOS','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_dev is null then return jsonb_build_object('ok',false,'error','Requiere deviceId'); end if;
  if v_perm is null or jsonb_typeof(v_perm) <> 'object' then
    return jsonb_build_object('ok',false,'error','Requiere permisos:{notif,cam,mic,geo,audio,install}'); end if;
  update mos.dispositivos set permisos_json = v_perm, permisos_lastupdate = now() where id_dispositivo = v_dev;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','Dispositivo no encontrado: '||v_dev); end if;
  return jsonb_build_object('ok', true);
end; $fn$;
revoke all on function mos.registrar_permisos_dispositivo(jsonb) from public;
grant execute on function mos.registrar_permisos_dispositivo(jsonb) to anon, authenticated, service_role;

-- 2) marcar_wizard_mostrado (device apaga su flag, anon)
create or replace function mos.marcar_wizard_mostrado(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_dev text := nullif(btrim(coalesce(p->>'deviceId','')), ''); v_n int;
begin
  if v_claim not in ('mosExpress','MOS','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_dev is null then return jsonb_build_object('ok',false,'error','Requiere deviceId'); end if;
  update mos.dispositivos set forzar_wizard = false where id_dispositivo = v_dev;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','Dispositivo no encontrado'); end if;
  return jsonb_build_object('ok', true);
end; $fn$;
revoke all on function mos.marcar_wizard_mostrado(jsonb) from public;
grant execute on function mos.marcar_wizard_mostrado(jsonb) to anon, authenticated, service_role;

-- 3) reportar_quota_dispositivo (telemetría append-only, anon)
create or replace function mos.reportar_quota_dispositivo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
begin
  if v_claim not in ('mosExpress','MOS','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  insert into mos.quota_dispositivos_log (ts, device_id, vendedor, pending_sales, total_keys, accion)
  values (now(), coalesce(p->>'deviceId',''), coalesce(p->>'vendedor',''),
    coalesce(nullif(btrim(coalesce(p->>'pendingSales','')),'')::int,0),
    coalesce(nullif(btrim(coalesce(p->>'totalKeys','')),'')::int,0), 'QUOTA_FULL');
  return jsonb_build_object('ok', true);
end; $fn$;
revoke all on function mos.reportar_quota_dispositivo(jsonb) from public;
grant execute on function mos.reportar_quota_dispositivo(jsonb) to anon, authenticated, service_role;

-- 4) forzar_wizard_dispositivo (ADMIN, clave 8 díg)
create or replace function mos.forzar_wizard_dispositivo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_dev text := nullif(btrim(coalesce(p->>'deviceId','')), '');
  v_cla text := coalesce(p->>'claveAdmin',''); v_app text := coalesce(p->>'app','');
  v_auth jsonb; v_n int;
begin
  if v_dev is null then return jsonb_build_object('ok',false,'error','Requiere deviceId'); end if;
  if btrim(v_cla)='' then return jsonb_build_object('ok',false,'error','Requiere claveAdmin'); end if;
  perform pg_advisory_xact_lock(hashtext('fwizard:'||v_dev));
  perform 1 from mos.dispositivos where id_dispositivo = v_dev;
  if not found then return jsonb_build_object('ok',false,'error','Dispositivo no encontrado'); end if;
  v_auth := mos._validar_clave_admin_core(v_cla,'FORZAR_WIZARD',v_dev,v_app,v_dev,'Forzar re-wizard remoto',2);
  if coalesce((v_auth->>'ok')::boolean,false) is not true then return v_auth; end if;
  if coalesce((v_auth->>'autorizado')::boolean,false) is not true then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error',coalesce(v_auth->>'error','Clave incorrecta'))); end if;
  update mos.dispositivos set forzar_wizard = true where id_dispositivo = v_dev;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',true,'forzadoPor',coalesce(nullif(v_auth->>'nombre',''),'admin')));
end; $fn$;
revoke all on function mos.forzar_wizard_dispositivo(jsonb) from public;
grant execute on function mos.forzar_wizard_dispositivo(jsonb) to authenticated, service_role;

-- 5) forzar_push_dispositivo (ADMIN, clave 8 díg)
create or replace function mos.forzar_push_dispositivo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_dev text := nullif(btrim(coalesce(p->>'deviceId','')), '');
  v_cla text := coalesce(p->>'claveAdmin',''); v_app text := coalesce(p->>'app','');
  v_auth jsonb;
begin
  if v_dev is null then return jsonb_build_object('ok',false,'error','Requiere deviceId'); end if;
  if btrim(v_cla)='' then return jsonb_build_object('ok',false,'error','Requiere claveAdmin'); end if;
  perform pg_advisory_xact_lock(hashtext('fpush:'||v_dev));
  perform 1 from mos.dispositivos where id_dispositivo = v_dev;
  if not found then return jsonb_build_object('ok',false,'error','Dispositivo no encontrado'); end if;
  v_auth := mos._validar_clave_admin_core(v_cla,'FORZAR_PUSH',v_dev,v_app,v_dev,'Forzar re-registro del FCM token',2);
  if coalesce((v_auth->>'ok')::boolean,false) is not true then return v_auth; end if;
  if coalesce((v_auth->>'autorizado')::boolean,false) is not true then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error',coalesce(v_auth->>'error','Clave incorrecta'))); end if;
  update mos.dispositivos set forzar_push = true where id_dispositivo = v_dev;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',true,'forzadoPor',coalesce(nullif(v_auth->>'nombre',''),'admin')));
end; $fn$;
revoke all on function mos.forzar_push_dispositivo(jsonb) from public;
grant execute on function mos.forzar_push_dispositivo(jsonb) to authenticated, service_role;
