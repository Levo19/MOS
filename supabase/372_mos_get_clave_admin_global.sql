-- 372 · mos.get_clave_admin_global(p) — NIVEL 3 corte-GAS (MOS). Espejo de
-- Seguridad.gs::getClaveAdminGlobal: valida el pinAdmin del solicitante (admin real)
-- y devuelve el ADMIN_GLOBAL_PIN vigente + fechas. Consumido por el panel admin.
create or replace function mos.get_clave_admin_global(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_pin text := nullif(btrim(coalesce(p->>'pinAdmin','')),'');
  v_por text; v_global text; v_fecha text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_pin is null then return jsonb_build_object('ok',false,'error','Requiere pinAdmin (PIN del solicitante)'); end if;
  -- Validar que el pinAdmin pertenezca a un admin real (rol MASTER/ADMIN activo) — bcrypt o texto legacy.
  select nombre into v_por from mos.personal
   where estado = true and upper(coalesce(rol,'')) in ('MASTER','ADMIN','ADMINISTRADOR')
     and ( (pin_hash is not null and pin_hash = extensions.crypt(v_pin, pin_hash)) or (coalesce(pin,'') = v_pin) )
   limit 1;
  if v_por is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error','PIN no reconocido')); end if;
  select lpad(coalesce(valor,''),4,'0') into v_global from mos.config where clave='ADMIN_GLOBAL_PIN' limit 1;
  select valor into v_fecha from mos.config where clave='ADMIN_GLOBAL_PIN_FECHA' limit 1;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'autorizado', true, 'pin', coalesce(v_global,''), 'validadoPor', v_por,
    'fechaUltimaRotacion', coalesce(v_fecha,''),
    'fechaProximaRotacion', to_char((now() + interval '7 days') at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS')));
end; $fn$;
revoke all on function mos.get_clave_admin_global(jsonb) from public, anon;
grant execute on function mos.get_clave_admin_global(jsonb) to authenticated, service_role;
