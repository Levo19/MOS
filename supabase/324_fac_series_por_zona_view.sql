-- ============================================================================
-- 324_fac_series_por_zona_view.sql — vista ordenada: serie + correlativo POR ZONA
-- ----------------------------------------------------------------------------
-- Aclaración de modelo (confirmado con el dueño): la SERIE es por ZONA (todas las estaciones de una
-- zona comparten la serie), y el CORRELATIVO vive en fac.series POR SERIE. Como todas las estaciones
-- de una zona usan la misma serie, HEREDAN el mismo correlativo automáticamente (misma fila fac.series).
-- No se necesita una tabla de correlativo por zona: fac.series YA es el contador único por serie/zona.
-- La columna mos.series_documentales.correlativo es DECORATIVA (toda en 1) → ignorar; la verdad es fac.series.
--
-- Este helper devuelve, por zona y tipo: la serie, cuántas estaciones la comparten, y el correlativo
-- ACTUAL + próximo desde fac.series (el contador real). Útil para el go-live: ver de un vistazo qué
-- series faltan sembrar/alinear. Solo lectura. Además, un check de consistencia: series que difieren
-- entre estaciones de una misma zona (no debería pasar; la derivación asume 1 serie por zona/tipo).
-- ============================================================================

create or replace function fac.series_por_zona(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  with zt as (
    select sd.id_zona,
           case when upper(regexp_replace(coalesce(sd.tipo_documento,''),'[\s_]','','g'))='FACTURA' then 'FACTURA'
                when upper(regexp_replace(coalesce(sd.tipo_documento,''),'[\s_]','','g'))='BOLETA'  then 'BOLETA'
                else 'OTRO' end as tipo,
           btrim(sd.serie) as serie,
           sd.id_estacion
    from mos.series_documentales sd
    where coalesce(sd.activo,true) = true and btrim(coalesce(sd.serie,'')) <> ''
      and upper(regexp_replace(coalesce(sd.tipo_documento,''),'[\s_]','','g')) in ('BOLETA','FACTURA')
  ),
  agg as (
    select id_zona, tipo,
           count(distinct serie)      as series_distintas,   -- >1 = inconsistencia (estaciones con serie distinta)
           max(serie)                 as serie,
           count(distinct id_estacion) as estaciones
    from zt group by id_zona, tipo
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'zona', a.id_zona, 'tipo', a.tipo, 'serie', a.serie,
    'estaciones', a.estaciones,
    'consistente', (a.series_distintas = 1),
    'en_fac_series', (s.serie is not null),
    'correlativo', coalesce(s.correlativo, 0),
    'proximo', coalesce(s.correlativo, 0) + 1
  ) order by a.id_zona, a.tipo), '[]'::jsonb)
  from agg a left join fac.series s on s.serie = a.serie;
$fn$;
revoke all on function fac.series_por_zona(jsonb) from public;
grant execute on function fac.series_por_zona(jsonb) to authenticated, service_role;
