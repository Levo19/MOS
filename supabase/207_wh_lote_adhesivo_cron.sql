-- 207_wh_lote_adhesivo_cron.sql
-- FASE 3 — Red de seguridad "fire-and-forget" para la impresión de adhesivos en Supabase.
--
-- El frontend dispara la Edge `print-adhesivo` en mode:'lote' (instantáneo; la Edge completa
-- el lote entero server-side dentro de su presupuesto). Este pg_cron es la RED DE SEGURIDAD:
-- cada minuto invoca la Edge en mode:'pending' para retomar lotes grandes / pausados /
-- abandonados (operador cerró la app a media impresión). Reemplaza al trigger GAS
-- procesarLotesPendientes (LotesTrigger.gs, cada 1 min).
--
-- INERTE doble: (a) si el flag WH_LOTE_ADHESIVO_DIRECTO != '1' → no-op; (b) si no está la
-- service key en vault → no-op. Con cualquiera de las dos el tick no hace NADA → seguro aplicar ya.
--
-- SETUP DEL DUEÑO (1 vez, al cutover): guardar la service_role key en vault para que el cron
-- pueda autenticarse contra la Edge:
--   select vault.create_secret('<SUPABASE_SERVICE_ROLE_KEY>', 'wh_edge_service_key',
--                              'Service key cron→Edge print-adhesivo');

create extension if not exists pg_net;

create or replace function wh._lote_adhesivo_cron_tick()
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  v_key text;
  v_url text := 'https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/print-adhesivo';
begin
  -- (a) Gate por flag: si la escritura directa no está activa, no hacemos nada.
  if coalesce((select valor from mos.config where clave='WH_LOTE_ADHESIVO_DIRECTO' limit 1),'0') <> '1' then
    return;
  end if;
  -- ¿Hay algo pendiente? (evita invocar la Edge sin trabajo)
  if not exists (
    select 1 from wh.lotes_adhesivo
     where completadas < total_etq
       and ( status in ('ENCOLADO','CREADO')
             or ( status in ('IMPRIMIENDO','CALIBRANDO')
                  and fecha_ultimo_update < now() - interval '90 seconds' ) )
  ) then
    return;
  end if;
  -- (b) Service key desde vault. Si no está configurada → no-op (no rompe).
  begin
    select decrypted_secret into v_key from vault.decrypted_secrets where name='wh_edge_service_key' limit 1;
  exception when others then v_key := null;
  end;
  if v_key is null then return; end if;

  -- Disparo asíncrono a la Edge (mode:'pending'). pg_net no bloquea el cron.
  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Authorization','Bearer '||v_key, 'Content-Type','application/json'),
    body    := jsonb_build_object('mode','pending','limit',8)
  );
end;
$fn$;

revoke all on function wh._lote_adhesivo_cron_tick() from public;
grant execute on function wh._lote_adhesivo_cron_tick() to service_role;

-- Schedule cada minuto (idempotente: desprograma el previo si existe).
do $$
begin
  if exists (select 1 from cron.job where jobname='wh-lote-adhesivo-procesar') then
    perform cron.unschedule('wh-lote-adhesivo-procesar');
  end if;
  perform cron.schedule('wh-lote-adhesivo-procesar', '* * * * *', $cron$ select wh._lote_adhesivo_cron_tick(); $cron$);
end $$;
