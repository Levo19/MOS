-- [1052] ROLLBACK: deja mos.salud_db_fotear exactamente como estaba VIVA el 08-nov-2026 antes de 1052
-- (pg_get_functiondef, md5 ee919644e769c7ee7639ae1d23647b5c), quita mos.salud_api_push (nueva en 1052)
-- y limpia lo que 1052 agregó en mos.config y mos.salud_db_alertas.
-- mos.salud_db_vigilar no fue reemplazada por 1052 (no requiere rollback).
-- Nota: la versión previa usa umbral fijo de conexiones 40 y SALUD_DB_FOTO=OFF corta toda la función.

begin;

CREATE OR REPLACE FUNCTION mos.salud_db_fotear(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '500ms'
AS $function$
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
$function$
;

revoke all on function mos.salud_db_fotear(jsonb) from public, anon, authenticated, service_role;

update mos.config
   set valor = (valor::jsonb - array['foto_conn','api_pool_min','api_consec_min','api_desde_min','api_hasta_min',
                                     'api_pico_min','api_pico_ventana_min','api_rate_min','api_ok_para_normalizar'])::text
 where clave = 'SALUD_DB_UMBRALES'
   and jsonb_typeof(valor::jsonb) = 'object';

drop function if exists mos.salud_api_push(jsonb);

delete from mos.config where clave = 'SALUD_API_VIGIA';
delete from mos.salud_db_alertas where tipo = 'api_sin_pool';

commit;
