-- ════════════════════════════════════════════════════════════════════════════
-- 213 · pg_cron nocturno — consolidar lo no despachado en la lista acumulada semanal
-- ════════════════════════════════════════════════════════════════════════════
-- Corre todas las noches 02:10 hora Lima (07:10 UTC). Llama
-- wh.consolidar_pickups_semana, que es NO-OP mientras WH_PICKUP_ACUMULADO='0'
-- (INERTE hasta el cutover). Idempotente (desprograma el job previo si existe).
-- ════════════════════════════════════════════════════════════════════════════
do $$
begin
  if exists (select 1 from cron.job where jobname='wh-pickup-acumular') then
    perform cron.unschedule('wh-pickup-acumular');
  end if;
  perform cron.schedule('wh-pickup-acumular', '10 7 * * *',
    $cron$ select wh.consolidar_pickups_semana('{}'::jsonb); $cron$);
end $$;
