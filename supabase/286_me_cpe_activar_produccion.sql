-- ============================================================================================================
-- 286_me_cpe_activar_produccion.sql — [CUTOVER CPE] helper de UN comando para pasar a producción NubeFact
-- ------------------------------------------------------------------------------------------------------------
-- El miércoles, además de pegar los SECRETS de producción (NUBEFACT_TOKEN/RUTA/RUC vía `supabase secrets set`),
-- esto deja TODO lo demás en un solo comando: setea las SERIES reales (las que registraste en SUNAT/NubeFact),
-- RESETEA el correlativo a 1 (el demo NUNCA se envió a SUNAT → producción empieza en 1), y prende el reconciliador.
-- INERTE hasta que se invoque. Idempotente. Solo service_role (se corre desde el SQL editor / DB admin).
--
-- Uso (SQL editor de Supabase o vía DB):
--   select me.cpe_activar_produccion('{"serie_boleta":"B001","serie_factura":"F001"}'::jsonb);
--   -- (reset_correlativo true por defecto; pasar false si NubeFact ya tiene correlativos en esa serie)
-- ============================================================================================================
create schema if not exists me;

create or replace function me.cpe_activar_produccion(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_sb text := nullif(btrim(coalesce(p->>'serie_boleta','')), '');
  v_sf text := nullif(btrim(coalesce(p->>'serie_factura','')), '');
  v_reset boolean := coalesce((p->>'reset_correlativo')::boolean, true);
  v_old_b text[]; v_old_f text[]; v_nb int; v_nf int;
begin
  if v_sb is null or v_sf is null then
    return jsonb_build_object('ok', false, 'error', 'serie_boleta y serie_factura requeridas');
  end if;
  -- series viejas (para resetear su contador también, por si se reusan)
  select array_agg(distinct serie) into v_old_b from mos.series_documentales where upper(replace(tipo_documento,'_','')) = 'BOLETA';
  select array_agg(distinct serie) into v_old_f from mos.series_documentales where upper(replace(tipo_documento,'_','')) = 'FACTURA';

  -- 1) SERIES de producción en mos.series_documentales (todas las zonas/estaciones)
  update mos.series_documentales set serie = v_sb where upper(replace(tipo_documento,'_','')) = 'BOLETA';
  get diagnostics v_nb = row_count;
  update mos.series_documentales set serie = v_sf where upper(replace(tipo_documento,'_','')) = 'FACTURA';
  get diagnostics v_nf = row_count;

  -- 2) RESET de correlativos: producción empieza en 1 (el demo no fue a SUNAT). Resetea series nuevas + viejas.
  if v_reset then
    insert into me.correlativos(serie, siguiente) values (v_sb, 1), (v_sf, 1)
      on conflict (serie) do update set siguiente = 1;
    if v_old_b is not null then update me.correlativos set siguiente = 1 where serie = any(v_old_b); end if;
    if v_old_f is not null then update me.correlativos set siguiente = 1 where serie = any(v_old_f); end if;
  end if;

  -- 3) RECONCILIADOR ON (reintenta los CPE que queden PENDIENTE)
  insert into mos.config(clave, valor) values ('CPE_RECON_ON', '1') on conflict (clave) do update set valor = '1';

  return jsonb_build_object('ok', true,
    'serie_boleta', v_sb, 'serie_factura', v_sf,
    'filas_boleta_actualizadas', v_nb, 'filas_factura_actualizadas', v_nf,
    'correlativo_reseteado', v_reset, 'cpe_recon_on', '1',
    'pendiente', 'Pegar secrets de produccion (NUBEFACT_TOKEN/RUTA/RUC) + 1 venta de prueba para validar EMITIDO');
end; $fn$;
revoke all on function me.cpe_activar_produccion(jsonb) from public, anon, authenticated;
grant execute on function me.cpe_activar_produccion(jsonb) to service_role;
