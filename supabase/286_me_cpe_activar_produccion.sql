-- ============================================================================================================
-- 286_me_cpe_activar_produccion.sql — [CUTOVER CPE] helper de producción (correlativo + flags; series van por UI)
-- ------------------------------------------------------------------------------------------------------------
-- Las SERIES se manejan en MOS → Configuración (escribe mos.series_documentales, SQL 269). La emisión
-- (me.crear_cpe_directo, 270) y las cajas (overlay mos.series_documentales_app, 283/284) las leen de ahí
-- AUTOMÁTICAMENTE (el trigger bumpea catalogo_version → cajas refrescan solas). Single-source verificado.
--
-- Por eso este helper NO toca series. Solo hace lo MECÁNICO del cutover: resetea el correlativo de las series B/F
-- vigentes a 1 (producción empieza en 1; el demo NUNCA se envió a SUNAT) y prende el reconciliador.
--
-- ORDEN del miércoles: (1) setear series reales en MOS Configuración → (2) correr este helper → (3) pegar secrets
-- de producción → (4) 1 venta de prueba. Idempotente. Solo service_role.
--
-- Uso:  select me.cpe_activar_produccion();
--       select me.cpe_activar_produccion('{"reset_correlativo":false}'::jsonb);  -- si NubeFact ya tiene correlativos
-- ============================================================================================================
create schema if not exists me;

create or replace function me.cpe_activar_produccion(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_reset boolean := coalesce((p->>'reset_correlativo')::boolean, true);
  v_series text[];
  s text;
begin
  -- Series B/F VIGENTES (las que el dueño seteó en MOS Configuración).
  select array_agg(distinct serie) into v_series
  from mos.series_documentales
  where activo and upper(replace(tipo_documento, '_', '')) in ('BOLETA', 'FACTURA')
    and coalesce(serie, '') <> '';

  -- Reset de correlativos a 1 (producción empieza en 1; el demo no fue a SUNAT). Crea la serie si no existía.
  if v_reset and v_series is not null then
    foreach s in array v_series loop
      insert into me.correlativos(serie, siguiente) values (s, 1)
        on conflict (serie) do update set siguiente = 1;
    end loop;
  end if;

  -- Reconciliador ON (reintenta los CPE que queden PENDIENTE).
  insert into mos.config(clave, valor) values ('CPE_RECON_ON', '1') on conflict (clave) do update set valor = '1';

  return jsonb_build_object('ok', true,
    'series_vigentes', coalesce(to_jsonb(v_series), '[]'::jsonb),
    'correlativo_reseteado', v_reset, 'cpe_recon_on', '1',
    'recordatorio', 'Las series se setean en MOS Configuracion. Falta: pegar secrets de produccion + 1 venta de prueba.');
end; $fn$;
revoke all on function me.cpe_activar_produccion(jsonb) from public, anon, authenticated;
grant execute on function me.cpe_activar_produccion(jsonb) to service_role;
