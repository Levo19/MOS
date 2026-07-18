-- 513_fase0_limpieza_series.sql — FASE 0 del rediseño Config: limpieza de mos.series_documentales.
-- (1) ALMACÉN NO factura → borrar sus filas (SER_ALM_BOL/FAC). (2) deduplicar (id_zona,tipo_documento)
-- dejando 1 fila por grupo (la de menor id_serie; todos tienen correlativo=1 → sin pérdida de numeración).
-- El correlativo REAL vive en me.correlativos (por serie) → NO se toca. Money-safe (config, no dinero).
-- Idempotente. NO afecta a fac.serie_de_zona (que lee la fila vigente por zona).

-- (1) Almacén no factura
delete from mos.series_documentales where upper(btrim(id_zona)) = 'ALMACEN';

-- (2) dedup: conservar la fila de menor id_serie por (zona, tipo)
delete from mos.series_documentales s
 using (
   select id_zona, tipo_documento, min(id_serie) as keep_id
     from mos.series_documentales
    group by id_zona, tipo_documento
 ) k
 where s.id_zona = k.id_zona
   and s.tipo_documento = k.tipo_documento
   and s.id_serie <> k.keep_id;
