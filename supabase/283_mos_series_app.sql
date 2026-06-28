-- ============================================================================================================
-- 283_mos_series_app.sql — [series single-source] series documentales por zona para que ME las lea de Supabase
-- ------------------------------------------------------------------------------------------------------------
-- Raíz del "bug del cajero con serie": la EMISIÓN ya resuelve la serie desde mos.series_documentales (BBB1/FFF1),
-- pero las cajas descargan sus Serie_Nota/Boleta/Factura del catálogo GAS (Hoja SERIES_DOCUMENTALES, B001/F001)
-- → el filtro de la lista (prefijos) no matchea la serie emitida. Este RPC expone las series VIGENTES por zona
-- desde la tabla Supabase (la que se edita en MOS) para que el front las superponga → UNA sola fuente de verdad.
-- Shape: { "<id_zona>": { "Serie_Nota":..., "Serie_Boleta":..., "Serie_Factura":... }, ... } dentro de data.
-- Series NO son secreto (van en cada comprobante) → anon, sin gate _claim_ok (parity con el catálogo público).
-- ============================================================================================================
create schema if not exists mos;

create or replace function mos.series_documentales_app(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select jsonb_build_object('ok', true, 'data', coalesce((
    select jsonb_object_agg(zona, series)
    from (
      select id_zona as zona,
             jsonb_strip_nulls(jsonb_build_object(
               'Serie_Nota',    max(serie) filter (where t in ('NOTAVENTA','NV','NOTADEVENTA')),
               'Serie_Boleta',  max(serie) filter (where t = 'BOLETA'),
               'Serie_Factura', max(serie) filter (where t = 'FACTURA')
             )) as series
      from (
        select id_zona,
               btrim(coalesce(serie,'')) as serie,
               upper(regexp_replace(coalesce(tipo_documento,''), '[\s_]', '', 'g')) as t
        from mos.series_documentales
        where coalesce(activo, true) = true
          and btrim(coalesce(serie,'')) <> ''
          and btrim(coalesce(id_zona,'')) <> ''
      ) x
      group by id_zona
    ) y
  ), '{}'::jsonb));
$fn$;
revoke all on function mos.series_documentales_app(jsonb) from public;
grant execute on function mos.series_documentales_app(jsonb) to anon, authenticated, service_role;
