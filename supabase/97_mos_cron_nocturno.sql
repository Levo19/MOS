-- 97_mos_cron_nocturno.sql — [MIGRACIÓN MOS · FASE E · AUTOMATIZACIÓN SNAPSHOT/CIERRE NOCTURNO · INERTE × 2]
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- OBJETIVO: automatizar la PERSISTENCIA del snapshot nocturno de liquidaciones (el problema histórico
--   documentado: el cierre semanal de jornales en GAS "solo manda push, NO persiste snapshot"; y el sync
--   diario _liqDiaSync/_liqSyncJob vive en triggers time-based de Apps Script que Google desactiva en
--   silencio → la sombra se atrasa). Fase E mueve esa persistencia a pg_cron, REEMPLAZO FUTURO de los
--   triggers GAS nocturnos. Llama a la RPC ya construida en Fase D (96): mos.materializar_liquidacion_semana.
--
-- ⚠️⚠️ NACE DOBLEMENTE INERTE ⚠️⚠️
--   (A) GATE DE FLAG (server-side, fuente de verdad de la inertness): la RPC de Fase D respeta
--       mos.config.MOS_LIQDIA_DIRECTO. Hoy = '0' → la RPC devuelve {ok:false, error:'MOS_LIQDIA_DIRECTO_OFF'}
--       SIN tocar mos.liquidaciones_dia. Por tanto el job, aunque corra, NO escribe datos de negocio.
--   (B) GATE DE JOB (pg_cron): los jobs se crean DESHABILITADOS (cron.alter_job(..., active := false)).
--       pg_cron 1.6 (instalado: 1.6.4) NO ejecuta un job con active=false. Doble candado: ni siquiera corre.
--   Efecto neto con MOS_LIQDIA_DIRECTO='0' Y/O active=false → CERO escritura de negocio. Verificado en pg.
--
-- ── HUSO HORARIO ───────────────────────────────────────────────────────────────────────────────────────
--   pg_cron evalúa el schedule en UTC. Perú = UTC-5 FIJO (no hay horario de verano). Equivalencias:
--     23:30 Lima = 04:30 UTC (siguiente día UTC).  04:00 Lima = 09:00 UTC.
--   El snapshot nocturno se agenda a las 04:30 UTC ('30 4 * * *') = 23:30 Lima — MISMA hora que el GAS
--   _liqDiaCronDiario (Liquidaciones.gs:1656), para que el reemplazo sea 1:1 al activar.
--   El health/heartbeat se agenda a las 09:00 UTC ('0 9 * * *') = 04:00 Lima (madrugada, tras el cierre).
--
-- ── POR QUÉ UN WRAPPER SIN ARGUMENTOS (y no inyectar fechas en el command) ───────────────────────────────
--   El comando del cron es texto fijo. La ventana semanal SE DESPLAZA cada día. Un wrapper sin args calcula
--   en cada corrida el lunes..hoy de la semana Lima EN CURSO y llama a materializar_liquidacion_semana.
--   Así el job nunca se queda con un rango viejo cableado.
--
-- ── IDEMPOTENCIA / NO-SOLAPE ─────────────────────────────────────────────────────────────────────────────
--   materializar_liquidacion_dia hace UPSERT por id_dia (clave determinística idPersonal+fecha) y PRESERVA
--   bon/san/estado/id_pago (PAGADA intacta) → re-correr la MISMA semana N veces NO duplica filas ni infla
--   montos. Dos corridas solapadas serializan por el `for update` de fila → la 2da ve lo de la 1ra. El gate
--   de frescura de un día stale devuelve WH_SESIONES_STALE para ESE día (0 filas escritas, NO error fatal):
--   el resto de la semana se materializa igual. El wrapper nunca lanza excepción no controlada hacia pg_cron.

create schema if not exists mos;
create extension if not exists pg_cron;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 0) TABLA DE LOG — observabilidad mínima de las corridas del cron (no es dato de negocio; solo bitácora).
--    Permite ver "¿corrió anoche? ¿qué devolvió? ¿algún día stale?" sin abrir los logs internos de pg_cron.
--    Retención: las corridas viejas se purgan dentro del propio health job (mantiene ~90 días).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create table if not exists mos.cron_log (
  id          bigint generated always as identity primary key,
  ts          timestamptz not null default now(),
  job         text        not null,           -- 'snapshot_liq_semana' | 'health_frescura'
  ok          boolean,
  resultado   jsonb                            -- payload devuelto por la RPC / diagnóstico
);
create index if not exists cron_log_ts_idx  on mos.cron_log (ts desc);
create index if not exists cron_log_job_idx on mos.cron_log (job, ts desc);
alter table mos.cron_log enable row level security;  -- sin policies → nadie por PostgREST; solo SECURITY DEFINER.
revoke all on table mos.cron_log from anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) WRAPPER NOCTURNO — mos.cron_snapshot_liquidacion_semana()
--    Sin args. Calcula la semana Lima EN CURSO (lunes..hoy, ISO/Monday = date_trunc('week')) y llama a
--    mos.materializar_liquidacion_semana. Respeta el flag MOS_LIQDIA_DIRECTO vía la RPC (no lo re-chequea).
--    NUNCA propaga excepción a pg_cron: envuelve todo en begin/exception y loguea.
--    SECURITY DEFINER + search_path='' (el cron corre como owner; me.jwt_app() = NULL → mos._claim_ok() pasa
--    igual que service_role/GAS, así que el único candado real de escritura es el flag).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.cron_snapshot_liquidacion_semana()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_hoy   date := (now() at time zone 'America/Lima')::date;       -- "hoy" en hora de negocio (Lima)
  v_lunes date := (date_trunc('week', (now() at time zone 'America/Lima'))::date);  -- lunes ISO de la semana
  v_res   jsonb;
begin
  -- Llama a la RPC de Fase D. forzar=false → respeta el gate de frescura por día (no paga de menos).
  v_res := mos.materializar_liquidacion_semana(
    jsonb_build_object('desde', to_char(v_lunes,'YYYY-MM-DD'),
                       'hasta', to_char(v_hoy,'YYYY-MM-DD'),
                       'forzar', false));

  insert into mos.cron_log(job, ok, resultado)
    values ('snapshot_liq_semana',
            coalesce((v_res->>'ok')::boolean, false),
            jsonb_build_object('desde', to_char(v_lunes,'YYYY-MM-DD'),
                               'hasta', to_char(v_hoy,'YYYY-MM-DD'),
                               'rpc', v_res));
  return v_res;
exception when others then
  -- jamás dejar que el job muera con error no controlado: log + retorno suave.
  insert into mos.cron_log(job, ok, resultado)
    values ('snapshot_liq_semana', false,
            jsonb_build_object('excepcion', SQLERRM,
                               'desde', to_char(v_lunes,'YYYY-MM-DD'),
                               'hasta', to_char(v_hoy,'YYYY-MM-DD')));
  return jsonb_build_object('ok', false, 'error', 'excepcion', 'detalle', SQLERRM);
end;
$fn$;
revoke all on function mos.cron_snapshot_liquidacion_semana() from public, anon, authenticated;
grant execute on function mos.cron_snapshot_liquidacion_semana() to service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) HEALTH / HEARTBEAT DE FRESCURA — mos.cron_health_frescura()
--    SOLO LECTURA + LOG. NO escribe datos de negocio (jamás toca liquidaciones_dia ni nada operativo).
--    Mide si las sombras críticas reflejan el día de negocio Lima de AYER (el último día completo):
--      • wh.sesiones  (necesaria para pagar envasadores/almaceneros → el gate de frescura de 96 depende de ella)
--      • me.ventas    (necesaria para el recompute de cajas/ventas del resumen del día)
--    Registra un veredicto en mos.cron_log para ALERTAR antes de activar lecturas/escrituras directas.
--    También PURGA mos.cron_log > 90 días (mantenimiento; cron_log NO es dato de negocio).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.cron_health_frescura()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_ayer   date := ((now() at time zone 'America/Lima')::date) - 1;
  v_ses    int;
  v_ventas int;
  v_gate   jsonb;
  v_diag   jsonb;
begin
  select count(*) into v_ses
    from wh.sesiones s
   where (s.fecha_inicio at time zone 'America/Lima')::date = v_ayer;

  -- me.ventas: contar las del día de negocio de ayer. `fecha` = timestamp de la venta (día de negocio);
  -- coalesce a created_at por si alguna fila legacy llegó sin `fecha`. Tolerante: si el esquema cambiara → -1.
  begin
    select count(*) into v_ventas
      from me.ventas v
     where (coalesce(v.fecha, v.created_at) at time zone 'America/Lima')::date = v_ayer;
  exception when others then v_ventas := -1;  -- columna distinta / no disponible → marcar como "no medible"
  end;

  v_gate := mos._liq_gate_frescura(v_ayer);

  v_diag := jsonb_build_object(
    'diaNegocio', to_char(v_ayer,'YYYY-MM-DD'),
    'whSesionesAyer', v_ses,
    'meVentasAyer', v_ventas,
    'gateLiq', v_gate,
    'whFresco', coalesce((v_gate->>'fresco')::boolean, false),
    'alerta', case when coalesce((v_gate->>'fresco')::boolean,false) then 'OK'
                   else 'WH_SESIONES_STALE — sombra WH atrasada para el día de negocio' end
  );

  insert into mos.cron_log(job, ok, resultado)
    values ('health_frescura', coalesce((v_gate->>'fresco')::boolean,false), v_diag);

  -- mantenimiento: purga bitácora > 90 días (no es dato de negocio).
  delete from mos.cron_log where ts < now() - interval '90 days';

  return v_diag;
exception when others then
  insert into mos.cron_log(job, ok, resultado)
    values ('health_frescura', false, jsonb_build_object('excepcion', SQLERRM));
  return jsonb_build_object('ok', false, 'error', 'excepcion', 'detalle', SQLERRM);
end;
$fn$;
revoke all on function mos.cron_health_frescura() from public, anon, authenticated;
grant execute on function mos.cron_health_frescura() to service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) AGENDA pg_cron — jobs creados DESHABILITADOS (active=false). Doble candado con el flag de la RPC.
--    Idempotente: desagenda si ya existían (evita duplicar al re-aplicar).
--    NOTA: el database del job es 'postgres' (igual que los WH ya activos), donde viven los schemas.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
select cron.unschedule('mos-snapshot-liq-semana') where exists (select 1 from cron.job where jobname='mos-snapshot-liq-semana');
select cron.unschedule('mos-health-frescura')     where exists (select 1 from cron.job where jobname='mos-health-frescura');

-- 23:30 Lima (04:30 UTC) → snapshot de la semana Lima en curso (lunes..hoy). REEMPLAZA a GAS _liqDiaCronDiario.
select cron.schedule('mos-snapshot-liq-semana', '30 4 * * *', $$ select mos.cron_snapshot_liquidacion_semana(); $$);

-- 04:00 Lima (09:00 UTC) → health/heartbeat de frescura de sombras (solo lectura + log + purga bitácora).
select cron.schedule('mos-health-frescura', '0 9 * * *', $$ select mos.cron_health_frescura(); $$);

-- 🔒 DESHABILITAR ambos jobs (Fase E nace INERTE). pg_cron 1.6 honra active=false → el job NO corre.
--    Para ACTIVAR Fase E (decisión del usuario): cron.alter_job(jobid, active := true) + flag en '1'.
select cron.alter_job((select jobid from cron.job where jobname='mos-snapshot-liq-semana'), active := false);
select cron.alter_job((select jobid from cron.job where jobname='mos-health-frescura'),     active := false);
