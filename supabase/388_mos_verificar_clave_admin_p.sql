-- 388 · wrapper jsonb de mos.verificar_clave_admin para llamarlo vía DeviceAuth.rpc (que envía {p:{...}}).
-- El original tiene params nombrados (p_clave,p_accion,...) → PostgREST no lo alcanza con {p:{...}}.
create or replace function mos.verificar_clave_admin_p(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
begin
  return mos.verificar_clave_admin(
    coalesce(p->>'clave',''),
    coalesce(nullif(btrim(coalesce(p->>'accion','')),''),'GENERICA'),
    coalesce(p->>'ref',''),
    coalesce(nullif(btrim(coalesce(p->>'app','')),''),''),
    coalesce(p->>'device',''),
    coalesce(p->>'detalle',''),
    nullif(btrim(coalesce(p->>'tier','')),'')::int,
    null);
end; $fn$;

revoke all on function mos.verificar_clave_admin_p(jsonb) from public;
grant execute on function mos.verificar_clave_admin_p(jsonb) to anon, authenticated, service_role;
