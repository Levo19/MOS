-- [997] work_mem por-función a las analíticas que se DERRAMAN a disco (Small tiene work_mem=5MB global).
--  Diagnóstico (pg_stat_statements.temp_blks_written): la base derramó ~6.5 GB a disco; el 97% es UNA función:
--    cierres_caja  → 5.2 MB/llamada × 1302 = 6.7 GB  (además #1 en CPU: 908s)
--    cabina_semanal→ 1.2 MB/llamada × 93   = 112 MB
--    finanzas_dia  → 0.2 MB/llamada        = 20 MB
--    catalogo_pos_rls → 0.1 MB/llamada     = 10 MB
--  work_mem=5MB no alcanza para sus sorts/jsonb_agg → derrame a disco = lento + Disk IO alto.
--  Fix: subir work_mem SOLO en estas funciones (aplica durante su ejecución y revierte al salir). NO cambia
--  lógica ni salida (parámetro de ejecución) — seguro incluso en cierres_caja (dinero). Evita pagar Medium.
--  RAM: Small 2GB, shared_buffers 512MB; estas funciones no son muy concurrentes → 16-32MB ocasional es seguro.
alter function mos.cierres_caja(jsonb)     set work_mem = '32MB';
alter function mos.cabina_semanal(jsonb)   set work_mem = '24MB';
alter function mos.finanzas_dia(text)      set work_mem = '16MB';
alter function mos.catalogo_pos_rls()      set work_mem = '16MB';

select '997 work_mem funciones pesadas listo' as ok;
