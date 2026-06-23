-- 219_verificar_clave_admin_mosexpress.sql — AUTH 100% Supabase: permitir que ME (mosExpress) valide la
-- clave admin por la RPC central (bcrypt + cascada de rol + auditoría), igual que WH y MOS.
-- Hoy el wrapper acepta solo wh._claim_ok (warehouseMos) o mos._claim_ok (MOS) → ME quedaba afuera y
-- seguía validando el PIN por GAS. Esto agrega 'mosExpress' al gate. Mínimo y aditivo; el core
-- (mos._validar_clave_admin_core) no cambia. Las 3 apps quedan cableables a esta RPC (Supabase-first).
create or replace function mos.verificar_clave_admin(
  p_clave text, p_accion text default 'GENERICA', p_ref text default '', p_app text default '',
  p_device text default '', p_detalle text default '', p_tier integer default null, p_cliente_meta jsonb default null)
returns jsonb language plpgsql security definer set search_path to '' as $function$
begin
  if coalesce(me.jwt_app(), '') not in ('', 'warehouseMos', 'MOS', 'mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  return mos._validar_clave_admin_core(p_clave, p_accion, p_ref, p_app, p_device, p_detalle, p_tier, p_cliente_meta);
end;
$function$;
