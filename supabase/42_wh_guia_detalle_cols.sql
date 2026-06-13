-- 42_wh_guia_detalle_cols.sql — [PASO 4 · Opción A] Agregar id_detalle + fecha_vencimiento a wh.guia_detalle
-- para que la sombra replique fielmente la hoja GUIA_DETALLE (el frontend referencia líneas por idDetalle;
-- los lotes dependen de fechaVencimiento). Columnas nullable → no rompe nada existente.
alter table wh.guia_detalle add column if not exists id_detalle text;
alter table wh.guia_detalle add column if not exists fecha_vencimiento date;
