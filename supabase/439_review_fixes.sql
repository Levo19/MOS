-- 439 · Fixes del review senior SQL (432-438). Anti-DoS + dedup auditoría + guard DELETE.

-- FIX #1: rotar_clave_admin_si_vence NO ejecutable por public/anon/authenticated (solo cron service_role).
revoke all on function mos.rotar_clave_admin_si_vence() from public;
grant execute on function mos.rotar_clave_admin_si_vence() to service_role;

-- FIX #2: anular_venta_directo YA NO re-verifica (el me.anular_venta interno lo hace 1 vez).
-- Evita doble bcrypt + doble fila mos.auditoria_admin por anulación desde el POS ME.
CREATE OR REPLACE FUNCTION me.anular_venta_directo(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_app    text := me.jwt_app();
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_res    jsonb;
begin
  -- Gate del POS ME: token mosExpress (o MOS). Mismo criterio que cobrar/creditar_venta_directo.
  if v_app not in ('mosExpress', 'MOS') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- Kill-switch (paridad con COBRO_OFF): OFF → el front NO cae a GAS, reporta no-disponible.
  if coalesce((select valor from mos.config where clave = 'ME_ANULAR_DIRECTO' limit 1), '0') <> '1' then
    return jsonb_build_object('ok', false, 'error', 'ME_ANULAR_DIRECTO_OFF');
  end if;

  -- Elevar el claim a MOS (transaction-local) para que el reposo anidado autorice; reusar me.anular_venta
  -- ÍNTEGRO (atómico/idempotente). Restaurar el claim al final (el rollback lo revierte igual si algo lanza).
  perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app', 'MOS'))::text, true);
  v_res := me.anular_venta(p);
  perform set_config('request.jwt.claims', v_claims::text, true);
  return v_res;
end;
$function$
;

-- FIX #3: el guard del PIN global ahora cubre DELETE (evita DoS por borrar el hash).
create or replace function mos._guard_global_pin()
returns trigger language plpgsql set search_path = '' as $fn$
declare v_clave text := coalesce(NEW.clave, OLD.clave);
begin
  if v_clave in ('ADMIN_GLOBAL_PIN','ADMIN_GLOBAL_PIN_HASH','ADMIN_GLOBAL_PIN_FECHA')
     and coalesce(current_setting('mos.allow_global_pin_write', true), '') <> '1' then
    if TG_OP = 'DELETE' then return null; end if;  -- bloquea el DELETE (fila intacta)
    return null;                                    -- bloquea INSERT/UPDATE
  end if;
  if TG_OP = 'DELETE' then return OLD; end if;
  return NEW;
end; $fn$;
drop trigger if exists _guard_global_pin_biu on mos.config;
create trigger _guard_global_pin_biu before insert or update or delete on mos.config
  for each row execute function mos._guard_global_pin();