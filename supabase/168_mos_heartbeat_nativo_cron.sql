-- ============================================================================================================
-- 168_mos_heartbeat_nativo_cron.sql — [MIGRACIÓN MOS · LATIDO NATIVO · pg_cron]
-- ------------------------------------------------------------------------------------------------------------
-- Agenda mos.cron_heartbeat_nativo() cada ~10 min. Estampa MOS_SYNC_HEARTBEAT + CATALOGO_SYNC_HEARTBEAT en
-- mos.config para que el gate _fresh (mos._frescura_sombra / productos_master_rls) se mantenga true SIN depender
-- del sync GAS-que-lee-Sheet. En directo-puro la sombra ES la verdad → es correcto y NO enmascara staleness real
-- (ya no hay origen externo que pueda atrasarse; las escrituras van directo a la sombra).
--
-- TTL de frescura = 30 min (MOS_SYNC_TTL_MIN) / 180 min (catálogo). Un latido cada 10 min deja MUCHO margen
-- (3 latidos por ventana de 30 min) → un par de corridas perdidas NO marca stale. NACE ACTIVO (a diferencia del
-- snapshot/health, que son escritura/diagnóstico): el latido es SOLO un timestamp, sin dinero, e indispensable
-- para que las lecturas directas no caigan a una Hoja que ya no existe. Idempotente: re-agenda sin duplicar.
-- ============================================================================================================
create extension if not exists pg_cron;

select cron.unschedule('mos-heartbeat-nativo') where exists (select 1 from cron.job where jobname='mos-heartbeat-nativo');

-- cada 10 min, todos los días.
select cron.schedule('mos-heartbeat-nativo', '*/10 * * * *', $$ select mos.cron_heartbeat_nativo(); $$);

-- ACTIVO (active=true es el default de cron.schedule; explícito por claridad/idempotencia).
select cron.alter_job((select jobid from cron.job where jobname='mos-heartbeat-nativo'), active := true);

-- Estampar UN latido AHORA para que el gate no quede stale entre el deploy y la 1ra corrida del cron.
select mos.cron_heartbeat_nativo();
