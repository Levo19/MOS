-- ════════════════════════════════════════════════════════════════════════════
-- 434 · HELPER de re-verificación server-side de clave admin — 100% Supabase, cero-GAS.
--
-- Audit 2026-07-13: las RPCs de dinero (cobrar/creditar/anular venta, convertir NV→CPE,
-- reabrir guía, bloquear vendedor) NO re-verifican la clave admin server-side — confían en
-- que el frontend validó el PIN y en una etiqueta `adminAuth`/`usuario` del cliente. Con un
-- token de dispositivo válido se podía invocar la mutación SIN PIN.
--
-- FIX: cada RPC de dinero pasa a llamar mos.reverificar_clave_admin(clave, accion, ...) que
-- valida contra el bcrypt sincronizado (mismo hash + cascada de nivel admin/master + lockout).
-- Se usa el CORE _validar_clave_admin_core (SIN gate de claim) porque las RPCs me.* corren con
-- claim jwt app='mosExpress' y el wrapper verificar_clave_admin lo rechazaría.
--
-- ROLLOUT SEGURO (cero downtime):
--   1) Deploy de este helper + wiring en las RPCs con el flag MOS_STRICT_ADMIN_REVERIFY = '0'
--      (default). Con clave presente → se re-verifica (rechaza si mala). Con clave AUSENTE →
--      se permite (comportamiento legacy) → NO rompe clientes cacheados que aún no la mandan.
--   2) Deploy de los frontends: pasan claveAdmin a cada mutación.
--   3) Flip MOS_STRICT_ADMIN_REVERIFY = '1' → clave OBLIGATORIA siempre (cero-caída real).
--
-- Contrato: devuelve NULL si OK (autorizado, o legacy-permitido con flag OFF).
--           Devuelve un jsonb {ok:false, autorizado:false, error} si debe RECHAZAR.
-- ════════════════════════════════════════════════════════════════════════════

insert into mos.config (clave, valor, descripcion) values
  ('MOS_STRICT_ADMIN_REVERIFY','0','Cuando 1, las RPCs de dinero EXIGEN claveAdmin re-verificada server-side (cero-caída). 0 = transición (permite ausencia).')
on conflict (clave) do nothing;

create or replace function mos.reverificar_clave_admin(
  p_clave  text,
  p_accion text default 'GENERICA',
  p_ref    text default '',
  p_app    text default 'MOS'
) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare v_res jsonb;
begin
  -- Sin clave: en transición (flag 0) se permite; en estricto (flag 1) se exige.
  if p_clave is null or btrim(p_clave) = '' then
    if coalesce((select valor from mos.config where clave='MOS_STRICT_ADMIN_REVERIFY' limit 1),'0') = '1' then
      return jsonb_build_object('ok',false,'autorizado',false,'error','Requiere clave admin (8 dígitos)');
    end if;
    return null;  -- transición: el frontend ya validó el PIN
  end if;
  -- Con clave: bcrypt + cascada de nivel (accion → nivel_minimo) + lockout + auditoría, SIN gate de claim.
  v_res := mos._validar_clave_admin_core(
    btrim(p_clave),
    coalesce(nullif(btrim(p_accion),''),'GENERICA'),
    coalesce(p_ref,''),
    coalesce(nullif(p_app,''),'MOS'));
  if coalesce((v_res->>'autorizado')::boolean, false) then
    return null;  -- autorizado
  end if;
  return jsonb_build_object('ok',false,'autorizado',false,
    'error', coalesce(v_res->>'error','Clave incorrecta o rol insuficiente'));
end; $fn$;

revoke all on function mos.reverificar_clave_admin(text,text,text,text) from public, anon;
grant execute on function mos.reverificar_clave_admin(text,text,text,text) to authenticated, service_role;
