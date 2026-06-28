-- ============================================================================================================
-- 285_me_empresa_fiscal.sql — datos fiscales PÚBLICOS de la empresa (para el header del ticket OFFLINE de ME)
-- ------------------------------------------------------------------------------------------------------------
-- El ticket online lo arma la Edge (fac.ticket_comprobante con d.empresa). Offline, ME usa su builder local
-- que NO tiene el header fiscal (RUC/razón social/dirección). Este RPC expone SOLO los campos públicos de la
-- empresa (van impresos en cada comprobante; no son secretos) para que ME los cachee y el ticket offline tenga
-- el mismo header. NUNCA expone tokens/series (lee fac.config pero proyecta solo lo público). `fac` no está en
-- PostgREST → el RPC vive en `me`. security definer para cruzar a fac.config.
-- ============================================================================================================
create schema if not exists me;

create or replace function me.empresa_fiscal(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'ruc',         coalesce(c.empresa_ruc, ''),
    'razonSocial', coalesce(c.empresa_razon_social, ''),
    'direccion',   coalesce(c.empresa_direccion, ''),
    'telefono',    coalesce(c.empresa_telefono, ''),
    'email',       coalesce(c.empresa_email, '')
  ))
  from fac.config c where c.id = 1;
$fn$;
revoke all on function me.empresa_fiscal(jsonb) from public;
grant execute on function me.empresa_fiscal(jsonb) to anon, authenticated, service_role;
