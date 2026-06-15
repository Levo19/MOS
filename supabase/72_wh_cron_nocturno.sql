-- 72_wh_cron_nocturno.sql
-- Agenda las 2 rutinas nocturnas WH con pg_cron (reemplaza los triggers GAS apagados en el cutover).
-- Lima = UTC-5 fijo (sin horario de verano):  21:00 Lima = 02:00 UTC  ·  22:00 Lima = 03:00 UTC.
-- pg_cron corre en la BD postgres sin JWT -> las RPCs estan grantadas a service_role (el rol del cron).

create extension if not exists pg_cron;

-- idempotente: desagenda si ya existian (evita duplicar al re-aplicar)
select cron.unschedule('wh-autocierre')      where exists (select 1 from cron.job where jobname='wh-autocierre');
select cron.unschedule('wh-auditar-cuadre')  where exists (select 1 from cron.job where jobname='wh-auditar-cuadre');

-- 21:00 Lima (02:00 UTC) -> autocierre de guias ABIERTA de dias anteriores
select cron.schedule('wh-autocierre', '0 2 * * *', $$ select wh.autocerrar_guias_viejas(); $$);

-- 22:00 Lima (03:00 UTC) -> auditoria de cuadre stock (despues del autocierre)
-- NOTA: la RPC wh.auditar_cuadre_stock() vigente es la de 73_wh_cuadre_corte_delta.sql
--       (modelo snapshot de corte + delta por wh.stock_movimientos). 71 quedo superado.
select cron.schedule('wh-auditar-cuadre', '0 3 * * *', $$ select wh.auditar_cuadre_stock(); $$);
