-- ════════════════════════════════════════════════════════════════════
-- 559 — Migración: cargadores guardados en el CAMPO wh.preingresos.cargadores
-- (JSON con carretas LLENA/MEDIA/VACIA) → tabla independiente wh.cargadores_log
-- con NIVEL (termómetro). NO se pierde nada: el campo original queda intacto
-- (reversible). nivel = promedio de las carretas: LLENA=100, MEDIA=50, VACIA=15
-- (piso 10). Idempotente: on conflict do nothing (no pisa lo que el usuario ya
-- puso con la UI nueva). added_by='MIGRACION' para trazar el origen.
-- ════════════════════════════════════════════════════════════════════

insert into wh.cargadores_log (id_log, fecha, id_cargador, nombre, added_by, device_id, ts, estado, nivel, fotos)
with src as (
  select (pi.fecha at time zone 'America/Lima')::date                                as dia,
         to_char(pi.fecha at time zone 'America/Lima','YYYYMMDD')                     as diak,
         cg->>'id'                                                                    as id_cargador,
         nullif(btrim(regexp_replace(coalesce(cg->>'nombre',''),'^cargador\s*','','i')),'') as nombre,
         (select round(avg(case upper(coalesce(e#>>'{}',''))
                             when 'LLENA' then 100 when 'MEDIA' then 50 else 15 end))
            from jsonb_array_elements(coalesce(cg->'estados','[]'::jsonb)) e)          as nivel
    from wh.preingresos pi,
         jsonb_array_elements(coalesce(nullif(pi.cargadores,'')::jsonb,'[]'::jsonb)) cg
   where nullif(btrim(coalesce(pi.cargadores,'')),'') is not null
     and pi.cargadores <> '[]'
     and nullif(btrim(coalesce(cg->>'id','')),'') is not null
),
agg as (
  select dia, diak, id_cargador,
         max(nombre)                                    as nombre,
         greatest(10, least(100, coalesce(max(nivel),50)))::int as nivel
    from src
   group by dia, diak, id_cargador
)
select 'CLGN_'||diak||'_'||id_cargador,
       (dia::text || ' 00:00:00')::timestamp at time zone 'America/Lima',
       id_cargador, coalesce(nombre, id_cargador), 'MIGRACION', '', now(), 'ACTIVO', nivel, '[]'::jsonb
  from agg
on conflict (id_log) do nothing;
