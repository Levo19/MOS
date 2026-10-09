-- 1038 · Purga diaria de cron.job_run_details (2026-10-09)
-- 52 jobs activos generan ~10k filas/día y nunca se purgaban: 368k filas / 67 MB desde junio.
-- Se queda con 7 días (suficiente para diagnosticar). Corre 04:15 Lima (09:15 UTC), fuera de horario de venta;
-- la primera corrida borra el acumulado (~340k filas) de una vez; autovacuum recupera el espacio después.
begin;
select cron.schedule('cron-purga-historial', '15 9 * * *',
  $cron$set statement_timeout = '120s'; delete from cron.job_run_details where start_time < now() - interval '7 days';$cron$);
commit;

-- ROLLBACK: select cron.unschedule('cron-purga-historial');
