-- 104_wh_stock_indice_unico.sql — [FASE 5 · pre-requisito de integridad WH escritura directa]
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- Las RPCs de escritura de stock (crear_guia/cerrar_guia/crear_ajuste) usan `on conflict (cod_producto)
-- do update` para cerrar el residual "producto nuevo creado por 2 guías concurrentes → 2 filas". Eso
-- EXIGE un índice único en wh.stock(cod_producto). Verificado 2026-06-16 (_diag_stock_wh.js): 0 duplicados
-- por cod_producto → el índice se crea sin conflicto.
--
-- Seguro e idempotente. NO cambia datos. Solo BLINDA contra futuros duplicados de stock.
-- Si en el futuro fallara por un duplicado nuevo, correr _diag_stock_wh.js para ubicarlo y consolidar primero.

create unique index if not exists ux_wh_stock_cod_producto on wh.stock (cod_producto);
