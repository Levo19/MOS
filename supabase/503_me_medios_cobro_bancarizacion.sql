-- ============================================================================
-- 503_me_medios_cobro_bancarizacion.sql
-- Fase 1 de BANCARIZACIÓN (ver MosExpress/PLAN_BANCARIZACION.md).
-- (1) LIMITE_BANCARIZACION en mos.config (default 2000, editable).
-- (2) me.get_medios_cobro(): RPC de lectura cross-app (molde me.get_tarjeta_config)
--     que expone a ME los medios de cobro de la empresa + el límite + datos fiscales
--     mínimos. security definer, grant anon/authenticated (dato público de cobro).
-- ============================================================================
insert into mos.config (clave, valor, descripcion)
values ('LIMITE_BANCARIZACION','2000','Monto (S/) desde el cual un pago exige bancarización (Ley 28194)')
on conflict (clave) do nothing;

-- semilla vacía de medios (para que la clave exista y config_publico la liste)
insert into mos.config (clave, valor, descripcion)
values ('EMPRESA_MEDIOS_COBRO','[]','Medios de cobro de la empresa (bancos/Yape/Plin) para bancarización · JSON')
on conflict (clave) do nothing;

create or replace function me.get_medios_cobro()
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select jsonb_build_object(
    'ok', true,
    'limite', coalesce((select valor from mos.config where clave='LIMITE_BANCARIZACION'),'2000'),
    -- medios: se guarda como texto JSON; se devuelve ya parseado (o [] si vacío/ inválido)
    'medios', coalesce(
      (select case when btrim(coalesce(valor,''))='' then '[]'::jsonb
                   else valor::jsonb end
         from mos.config where clave='EMPRESA_MEDIOS_COBRO'),
      '[]'::jsonb),
    'empresa', jsonb_build_object(
      'ruc',         (select empresa_ruc from fac.config where id=1),
      'razonSocial', (select empresa_razon_social from fac.config where id=1))
  );
$fn$;
revoke all on function me.get_medios_cobro() from public;
grant execute on function me.get_medios_cobro() to anon, authenticated, service_role;
