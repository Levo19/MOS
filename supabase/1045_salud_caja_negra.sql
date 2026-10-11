-- [1045] "CAJA NEGRA" de carga: foto de pg_stat_activity cuando la base se pone pesada.
--
-- Por qué: el 10-oct a las 13:05 Lima la base se congeló ~66 s (MEMORIA: swap 0,5→1 GB, caché/buffers ~0,
-- conexiones PostgREST 14→40, CPU ≤22 %). Postgres NO guarda qué consultas corrían en ese momento y la
-- pre-alerta 1035 (mos.salud_db_vigilar, cada 5 min) solo guarda CONTEOS en mos.salud_db_muestras.
-- Esta tabla guarda QUÉ corría, QUIÉN y DESDE CUÁNDO vive cada backend.
--
-- Diseño:
--   · mos.salud_db_foto(ts, motivo, conexiones, resumen jsonb, filas jsonb). RLS ON sin policies (deny-all).
--   · mos.salud_db_fotear(p): mide señales baratas y SOLO fotea si hay motivo:
--       conexiones   : backends cliente > 40           (normal ~25; el 10-oct llegó a 45-52)
--       consultas    : alguna consulta activa > 10 s   (authenticated corta a 8 s → >10 s ya es anómalo)
--       bloqueos     : alguna consulta esperando un lock > 5 s
--       idle_tx      : transacción abierta e inmóvil > 60 s (idle_in_transaction_session_timeout=0 aquí)
--       cron         : un job corriendo hace > 15 s, o que terminó en los últimos 2 min tras > 15 s
--                      (excluye los que son lentos por naturaleza; misma lista que 1035 + purga 1038)
--     filas  = cada backend con state <> 'idle' (sin la propia sesión): pid, usename, application_name,
--              client_addr, state, wait_event_type/wait_event, seg desde query_start / xact_start,
--              backend_start + seg de vida, backend_type, bloqueado_por (solo si espera Lock), left(query,300).
--     resumen = por_query (primeros 80 caracteres normalizados), por_app (usename+application_name+state,
--              TODOS los backends cliente, idle incluidos, con vida mín/máx/prom → cuánto vive cada backend
--              de postgrest), por_estado, señales medidas, jobs de cron lentos y control de privilegios.
--   · Cron 'mos-salud-foto' CADA MINUTO: el de 5 min puede perderse un pico de 1 min. Sin motivo cuesta
--     ~1-2 ms (1 pasada por pg_stat_activity en memoria compartida + las últimas 120 filas de
--     cron.job_run_details por PK). statement_timeout 3 s, lock_timeout 500 ms.
--   · Anti-spam: máx 1 foto por minuto (ventana 55 s para tolerar el jitter del cron) + advisory lock
--     no bloqueante contra corridas solapadas. Purga > 14 días una vez por hora (minuto 13), por índice ts.
--   · Interruptor sin redeploy: mos.config 'SALUD_DB_FOTO' = 'OFF' (default ON). Foto manual:
--       select mos.salud_db_fotear('{"forzar":true,"motivo":"manual"}');   -- ignora umbrales y anti-spam
--
-- Privilegios (verificado 10-oct): pg_cron corre los jobs como `postgres` (cron.job.username) y las
-- funciones son de `postgres`; postgres NO es superusuario pero ES miembro de pg_read_all_stats
-- (y pg_monitor) → ve el texto de query de authenticator/authenticated/supabase_admin. Se dejó un control
-- en resumen.sin_privilegio (filas con '<insufficient privilege>'): si algún día sale > 0, perdimos ese rol.
-- Las queries de PostgREST van parametrizadas ($1) → el texto no trae payloads (montos/PIN) — igual la
-- tabla es deny-all.
--
-- Por qué NO se tocó mos.salud_db_vigilar (1035): el cron por minuto ya cubre sus mismas señales con
-- umbrales más sensibles; meter la foto dentro de la pre-alerta mezclaría dos responsabilidades y su
-- cron corre cada 5 min (llegaría tarde). Cero riesgo sobre la pre-alerta viva.
--
-- Costos/efectos a considerar:
--   · pg_cron aquí usa conexiones libpq (cron.use_background_workers=off): +1 conexión corta por minuto.
--   · cron.job_run_details: +1.440 filas/día (purga 1038 la mantiene en 7 días). La ventana de 400 runids
--     que mira 1035 pasa de ~2 h a ~1,5 h; 1035 solo usa 10-30 min → sin efecto.
--   · En un congelamiento TOTAL el propio job puede no arrancar (job startup timeout); la foto sale apenas
--     la base responda y captura lo que siga vivo (transacciones largas, backends recién abiertos). Para la
--     caída total sigue el vigilante externo.

begin;

-- ── 1. Tabla ──
create table if not exists mos.salud_db_foto (
  id         bigint generated always as identity primary key,
  ts         timestamptz not null default now(),
  motivo     text        not null,
  conexiones int,
  resumen    jsonb       not null default '{}'::jsonb,
  filas      jsonb       not null default '[]'::jsonb
);
create index if not exists ix_salud_db_foto_ts on mos.salud_db_foto (ts desc);
alter table mos.salud_db_foto enable row level security;   -- deny-all: sin políticas
revoke all on mos.salud_db_foto from public, anon, authenticated;

-- ── 2. Función ──
create or replace function mos.salud_db_fotear(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
set lock_timeout to '500ms'
as $function$
declare
  c_conn      constant int := 40;
  c_act_seg   constant int := 10;
  c_bloq_seg  constant int := 5;
  c_idle_seg  constant int := 60;
  c_cron_seg  constant int := 15;
  v_forzar boolean := lower(coalesce(p->>'forzar','')) in ('true','1','si','sí');
  v_motivo_manual text := nullif(btrim(coalesce(p->>'motivo','')), '');
  v_txt text;
  v_excl text[] := array['mos-considerados-avisar','riz-reconciliar-stock','nightly-analyze',
                         'cron-purga-historial','mos-salud-foto','mos-salud-db'];
  v_conn int; v_act int; v_act_max numeric; v_bloq int; v_idle int;
  v_cron jsonb;
  v_motivos text[] := '{}';
  v_filas jsonb; v_resumen jsonb; v_id bigint;
  v_t0 timestamptz := clock_timestamp();
begin
  -- interruptor + exclusiones de cron de 1035 (si están configuradas)
  begin
    select upper(btrim(valor)) into v_txt from mos.config where clave = 'SALUD_DB_FOTO';
    if coalesce(v_txt, 'ON') = 'OFF' and not v_forzar then
      return jsonb_build_object('ok', true, 'on', false);
    end if;
    v_txt := null;
    select valor into v_txt from mos.config where clave = 'SALUD_DB_UMBRALES';
    if nullif(btrim(coalesce(v_txt,'')),'') is not null
       and jsonb_typeof(v_txt::jsonb -> 'cron_lento_excluir') = 'array' then
      v_excl := v_excl || array(select jsonb_array_elements_text(v_txt::jsonb -> 'cron_lento_excluir'));
    end if;
  exception when others then null;   -- config rota no debe tumbar la caja negra
  end;

  -- ── señales: 1 pasada por pg_stat_activity (memoria compartida) ──
  select count(*) filter (where a.backend_type = 'client backend'),
         count(*) filter (where x.ext and a.state = 'active'
                            and a.application_name is distinct from 'pg_cron'   -- [QA] crons lentos por diseño: los cubre la señal de cron
                            and a.query_start < now() - make_interval(secs => c_act_seg)),
         max(extract(epoch from now() - a.query_start)) filter (where x.ext and a.state = 'active'),
         count(*) filter (where x.ext and a.wait_event_type = 'Lock'
                            and a.query_start < now() - make_interval(secs => c_bloq_seg)),
         count(*) filter (where x.ext and a.state in ('idle in transaction','idle in transaction (aborted)')
                            and a.state_change < now() - make_interval(secs => c_idle_seg))
    into v_conn, v_act, v_act_max, v_bloq, v_idle
    from pg_catalog.pg_stat_activity a
    cross join lateral (select (a.backend_type = 'client backend'
                                and a.pid <> pg_catalog.pg_backend_pid()
                                and coalesce(a.usename::text,'') not in ('supabase_admin','supabase_realtime_admin','supabase_replication_admin')
                                and coalesce(a.application_name,'') not ilike 'pg\_dump%') as ext) x;

  -- ── señal: cron lento (últimas 120 corridas por PK desc, nunca seq scan) ──
  begin
    with rr as (
      select d.jobid, d.status, d.start_time, d.end_time
        from cron.job_run_details d
       order by d.runid desc
       limit 120
    )
    select jsonb_agg(jsonb_build_object(
             'job', coalesce(j.jobname, rr.jobid::text), 'estado', rr.status,
             'seg', round(extract(epoch from coalesce(rr.end_time, now()) - rr.start_time)),
             'inicio', rr.start_time) order by rr.start_time)
      into v_cron
      from rr
      left join cron.job j on j.jobid = rr.jobid
     where rr.start_time is not null
       and not (coalesce(j.jobname,'') = any(v_excl))
       and (   (rr.status = 'running'
                and rr.start_time < now() - make_interval(secs => c_cron_seg))
            or (rr.status in ('succeeded','failed')
                and rr.end_time > now() - interval '2 minutes'
                and rr.end_time - rr.start_time > make_interval(secs => c_cron_seg)));
  exception when others then
    v_cron := jsonb_build_array(jsonb_build_object('error', sqlerrm));
  end;

  if v_conn > c_conn then v_motivos := v_motivos || format('conexiones %s>%s', v_conn, c_conn); end if;
  if v_act  > 0      then v_motivos := v_motivos || format('consultas>%ss: %s (máx %ss)', c_act_seg, v_act, round(v_act_max)); end if;
  if v_bloq > 0      then v_motivos := v_motivos || format('bloqueos>%ss: %s', c_bloq_seg, v_bloq); end if;
  if v_idle > 0      then v_motivos := v_motivos || format('idle_tx>%ss: %s', c_idle_seg, v_idle); end if;
  if jsonb_typeof(v_cron) = 'array' and jsonb_array_length(v_cron) > 0
                     then v_motivos := v_motivos || format('cron lento: %s', jsonb_array_length(v_cron)); end if;
  if v_forzar        then v_motivos := v_motivos || ('forzado' || coalesce(': ' || v_motivo_manual, '')); end if;

  if cardinality(v_motivos) = 0 then
    return jsonb_build_object('ok', true, 'foto', false, 'conexiones', v_conn);
  end if;

  -- ── anti-spam: 1 foto/min + nada de corridas solapadas ──
  if not pg_catalog.pg_try_advisory_xact_lock(hashtext('mos.salud_db_foto')) then
    return jsonb_build_object('ok', true, 'foto', false, 'razon', 'otra corrida en curso');
  end if;
  if not v_forzar and exists (select 1 from mos.salud_db_foto f where f.ts > now() - interval '55 seconds') then
    return jsonb_build_object('ok', true, 'foto', false, 'razon', 'anti-spam 1/min', 'motivos', to_jsonb(v_motivos));
  end if;

  -- ── foto: backends no-idle (sin la propia sesión) ──
  select coalesce(jsonb_agg(jsonb_build_object(
           'pid',           a.pid,
           'usename',       a.usename,
           'app',           a.application_name,
           'client_addr',   host(a.client_addr),
           'state',         a.state,
           'wait_type',     a.wait_event_type,
           'wait',          a.wait_event,
           'seg_query',     round(extract(epoch from now() - a.query_start)::numeric, 1),
           'seg_xact',      round(extract(epoch from now() - a.xact_start)::numeric, 1),
           'backend_start', a.backend_start,
           'seg_vida',      round(extract(epoch from now() - a.backend_start)),
           'backend_type',  a.backend_type,
           'bloqueado_por', case when a.wait_event_type = 'Lock' then to_jsonb(pg_catalog.pg_blocking_pids(a.pid)) end,
           'query',         left(regexp_replace(a.query, '(x-cron-secret|apikey|authorization|bearer)[^,)]*', ' ***', 'gi'), 300))   -- [QA] sin secretos
         order by coalesce(a.xact_start, a.query_start) nulls last), '[]'::jsonb)
    into v_filas
    from (select * from pg_catalog.pg_stat_activity s
           where s.pid <> pg_catalog.pg_backend_pid()
             and s.state is not null and s.state <> 'idle'
           order by coalesce(s.xact_start, s.query_start) nulls last
           limit 150) a;

  select jsonb_build_object(
    'senales', jsonb_build_object('conexiones', v_conn, 'activas_10s', v_act, 'activa_max_s', round(coalesce(v_act_max,0)),
                                  'bloqueos_5s', v_bloq, 'idle_tx_60s', v_idle,
                                  'max_connections', current_setting('max_connections')::int),
    'cron', coalesce(v_cron, '[]'::jsonb),
    'por_query', coalesce((
        select jsonb_agg(jsonb_build_object('q', q.q, 'n', q.n, 'max_s', q.max_s, 'estados', q.estados) order by q.n desc, q.max_s desc)
          from (select left(regexp_replace(s.query, '\s+', ' ', 'g'), 80) as q, count(*) as n,
                       round(max(extract(epoch from now() - s.query_start))) as max_s,
                       jsonb_agg(distinct s.state) as estados
                  from pg_catalog.pg_stat_activity s
                 where s.pid <> pg_catalog.pg_backend_pid()
                   and s.state is not null and s.state <> 'idle'
                 group by 1
                 order by 2 desc
                 limit 40) q), '[]'::jsonb),
    'por_app', coalesce((
        select jsonb_agg(jsonb_build_object('usename', g.usename, 'app', g.app, 'state', g.state, 'n', g.n,
                                            'vida_min_s', g.vmin, 'vida_max_s', g.vmax, 'vida_prom_s', g.vavg)
                         order by g.n desc)
          from (select s.usename::text as usename, s.application_name as app, coalesce(s.state, '-') as state, count(*) as n,
                       round(min(extract(epoch from now() - s.backend_start))) as vmin,
                       round(max(extract(epoch from now() - s.backend_start))) as vmax,
                       round(avg(extract(epoch from now() - s.backend_start))) as vavg
                  from pg_catalog.pg_stat_activity s
                 where s.backend_type = 'client backend'
                 group by 1, 2, 3) g), '[]'::jsonb),
    'por_estado', coalesce((
        select jsonb_object_agg(e.state, e.n)
          from (select coalesce(s.state, '-') as state, count(*) as n
                  from pg_catalog.pg_stat_activity s
                 where s.backend_type = 'client backend'
                 group by 1) e), '{}'::jsonb),
    'sin_privilegio', (select count(*) from pg_catalog.pg_stat_activity s where s.query = '<insufficient privilege>'),
    'uptime_min', round(extract(epoch from now() - pg_catalog.pg_postmaster_start_time()) / 60.0),
    'ms', null)
    into v_resumen;

  v_resumen := jsonb_set(v_resumen, '{ms}', to_jsonb(round(extract(epoch from clock_timestamp() - v_t0) * 1000)));

  insert into mos.salud_db_foto (motivo, conexiones, resumen, filas)
  values (array_to_string(v_motivos, ' · '), v_conn, v_resumen, v_filas)
  returning id into v_id;


  return jsonb_build_object('ok', true, 'foto', true, 'id', v_id, 'motivos', to_jsonb(v_motivos),
                            'filas', jsonb_array_length(v_filas), 'ms', v_resumen->'ms');
end;
$function$;

revoke all on function mos.salud_db_fotear(jsonb) from public, anon, authenticated, service_role;

-- ── 3. Cron cada minuto, timeout corto. cron.schedule con el mismo nombre = upsert. ──
select cron.schedule('mos-salud-foto', '* * * * *',
  $cron$set statement_timeout = '3s'; select mos.salud_db_fotear();$cron$);
-- [QA M1] purga propia (antes dependía de que una foto cayera en el minuto :13)
select cron.schedule('mos-salud-foto-purga', '13 * * * *',
  $cron$set statement_timeout = '30s'; delete from mos.salud_db_foto where ts < now() - interval '14 days';$cron$);

commit;

-- ── Consultas útiles ──
--   select id, ts at time zone 'America/Lima' lima, motivo, conexiones, resumen->'por_estado', resumen->'senales'
--     from mos.salud_db_foto order by ts desc limit 20;
--   select f.ts at time zone 'America/Lima', r->>'app', r->>'state', r->>'seg_query', r->>'seg_vida', r->>'query'
--     from mos.salud_db_foto f, jsonb_array_elements(f.filas) r where f.id = <id> order by (r->>'seg_query')::numeric desc nulls last;
--   select jsonb_pretty(resumen->'por_app') from mos.salud_db_foto where id = <id>;
--   -- salud del propio cron (debe ir en ms):
--   select status, end_time - start_time dur from cron.job_run_details
--    where jobid = (select jobid from cron.job where jobname='mos-salud-foto') order by runid desc limit 10;

-- ── ROLLBACK ──
-- begin;
-- select cron.unschedule('mos-salud-foto'); select cron.unschedule('mos-salud-foto-purga');
-- drop function if exists mos.salud_db_fotear(jsonb);
-- drop table if exists mos.salud_db_foto;        -- ⚠ borra las fotos acumuladas; exportar antes si sirven
-- commit;
