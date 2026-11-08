-- [1052] VIGIA "API caida" (PostgREST sin pool) + CAJA NEGRA afinada.  Proyecto rzbzdeipbtqkzjqdchqk.
-- v2 (QA 08-nov: GO CON CAMBIOS): push sin PostgREST, cierre fuera de horario, rachas con huecos,
-- clamp de config, backoff de push fallido, advertencia de filtro sin coincidencias.
--
-- PROPOSITO
--   08-nov 11:09 Lima: al vencer a la vez la vida de las ~30 conexiones del pool de PostgREST
--   (db-pool-max-lifetime ~30 min) PostgREST no logro reabrirlas. Postgres y pg_cron siguieron sanos,
--   pero las apps no cargaban hasta el Restart de ~11:30. Ninguna senal de 1035/1045 lo detecta, porque
--   todas miden PRESION (muchas conexiones/consultas) y aqui paso lo contrario: la base quedo VACIA.
--   mos.salud_db_muestras (conexiones cliente totales) muestra el mismo patron en horario diurno y sin
--   reinicio: 02-nov 13:57-15:02, 03-nov 18:02-19:02, 05-nov 10:02-10:22 y 10:52-11:07 (de ~40 a ~7 en
--   menos de 5 min, con el pool de PostgREST en 30 justo antes). De madrugada el total baja a 5-6
--   legitimamente (pool casi vacio por inactividad) => horario de operacion + demanda reciente.
--
-- QUE CAMBIA
--   * mos.salud_db_fotear (cron por minuto 'mos-salud-foto'; misma firma y grants). mos.salud_db_vigilar NO se toca.
--   * NUEVA mos.salud_api_push(p): push al MASTER que NO depende de PostgREST. mos.emitir_push manda solo la
--     audiencia y la Edge `push` resuelve los tokens llamando a /rest/v1/rpc/push_tokens_para, que es
--     justamente lo caido (y emitir_push devuelve ok:true igual). Aqui los tokens se resuelven en SQL
--     (mos.push_tokens_para) y van en el body. La Edge pasa por el gateway de Functions, no por PostgREST.
--
--   A) Senal 'api_sin_pool' (estado en mos.salud_db_alertas, tipo 'api_sin_pool'):
--      pool = backends usename='authenticator' AND application_name='postgrest' AND backend_type='client backend'
--             AND query NOT ILIKE 'LISTEN%'   (la conexion LISTEN "pgrst" NO es del pool y no se toca).
--      hit       : pool <= api_pool_min (1).
--      activa si : en horario [api_desde_min, api_hasta_min) = [06:30, 19:30) Lima
--                  Y consec_hit >= api_consec_min (3) Y now()-hit_desde >= api_consec_min-1 min
--                  Y el pool tuvo >= api_pico_min (5) conexiones en los ultimos api_pico_ventana_min (15) min.
--      Rachas: si la fila no se actualizo en > 3 min (cron caido/saltado) consec_hit/consec_ok vuelven a 0.
--      Fuera de horario no se acumulan rachas y un episodio activo se CIERRA sin aviso (sin "normalizada"),
--      para que a las 06:30 no salga un recordatorio con "hace ~660 min".
--      Push: al activarse y cada api_rate_min (30, min 5) mientras siga, solo en horario. "Normalizada"
--      tras api_ok_para_normalizar (2) minutos sanos, solo si el episodio aviso.
--      Push fallido (sin tokens / sin secreto / error): no cuenta como enviado, se registra en mos.cron_log
--      y espera 5 min antes de reintentar (no escribe cron_log cada minuto).
--      Horario 19:30 (y no 18:30) elegido con datos de mos.salud_db_muestras (7 dias): p50 de conexiones
--      18:30-19:00 = 29 y 19:00-19:30 = 28 (mas alto que la tarde), y recien 19:30-20:00 baja a 19; las
--      fotos muestran el pool >= 20 hasta 19:00-19:30 casi todos los dias. 06:30-07:00 esta en base (p50 18)
--      pero ahi el filtro de demanda ya evita falsos avisos.
--   B) Caja negra: umbral de conexiones 40 -> 55 parametrizado ('foto_conn', default 55).
--      resumen.pool_api = {n, listen, vida_min/max/prom_s (backend_start), quieto_min/max/prom_s (state_change)}.
--      Foto con motivo 'api_sin_pool' cuando la senal esta activa, o en horario con racha completa aunque el
--      filtro de demanda haya frenado el aviso (datos para recalibrar).
--      Advertencia 'pool_api_filtro_sin_match': en horario, total de conexiones > 20 y CERO backends de
--      authenticator/postgrest (ni siquiera el LISTEN) durante >= 10 min => probable cambio de
--      usename/application_name en Supabase. Va en resumen.advertencias y saca 1 foto por hora.
--      SALUD_DB_FOTO='OFF' ahora solo apaga las fotos; el vigia sigue.
--
-- COMO APAGAR / AJUSTAR (sin redeploy, mos.config)
--   SALUD_API_VIGIA   = 'OFF'  -> no manda push de API caida ni de normalizada; sigue midiendo, llevando el
--                                 estado y sacando fotos con motivo api_sin_pool.
--   SALUD_DB_FOTO     = 'OFF'  -> sin fotos (el vigia sigue).
--   SALUD_DB_UMBRALES (jsonb compartido con 1035, que exige enteros). Claves de 1052 (cada una 1-6 digitos;
--   una invalida vuelve SOLO ella a su default y queda en resumen.errores):
--     foto_conn 55 | api_pool_min 1 | api_consec_min 3 (>=1) | api_desde_min 390 | api_hasta_min 1170
--     (minutos del dia Lima, desde < hasta <= 1440) | api_pico_min 5 | api_pico_ventana_min 15 (>=1)
--     | api_rate_min 30 (>=5) | api_ok_para_normalizar 2 (>=1).
--   Esta migracion agrega las claves con merge (las existentes ganan; no pisa st_alerta ni otras). Si una
--   instalacion previa (v1, nunca aplicada) dejo api_pico_ventana_min=30, se baja a 15.
--
-- PURGA de mos.cron_log: NO se agrega. Ya existe una a 90 dias en mos.cron_health_frescura (cron
--   'mos-health-frescura') y hay lectores que dependen de historia: me.cpe_recon_recoger (reconciliacion
--   CPE) y mos.cron_status (cuenta corridas de cierre nocturno). Bajarla a 30 dias queda para decision.
--
-- COSTO: ~2-8 ms por minuto (misma pasada por pg_stat_activity + UPDATE por PK de 1 fila).
--
-- ROLLBACK: 1052_rollback.sql (definicion VIVA previa de mos.salud_db_fotear, drop de mos.salud_api_push,
--   limpieza de config y de la fila de estado).

begin;

insert into mos.config (clave, valor, descripcion) values
  ('SALUD_API_VIGIA', 'ON', '[1052] ON/OFF del push al MASTER cuando la API (PostgREST) se queda sin conexiones a la base. OFF: sin push, sigue midiendo y foteando.')
on conflict (clave) do nothing;

insert into mos.config (clave, valor, descripcion) values
  ('SALUD_DB_UMBRALES', '{}', '[1035] jsonb con overrides de umbrales de mos.salud_db_vigilar (ej {"conn_alerta":65}).')
on conflict (clave) do nothing;

update mos.config
   set valor = (jsonb_build_object(
                  'foto_conn', 55,
                  'api_pool_min', 1, 'api_consec_min', 3,
                  'api_desde_min', 390, 'api_hasta_min', 1170,
                  'api_pico_min', 5, 'api_pico_ventana_min', 15,
                  'api_rate_min', 30, 'api_ok_para_normalizar', 2)
                || coalesce(nullif(btrim(valor), '')::jsonb, '{}'::jsonb))::text
 where clave = 'SALUD_DB_UMBRALES'
   and jsonb_typeof(coalesce(nullif(btrim(valor), '')::jsonb, '{}'::jsonb)) = 'object';

update mos.config
   set valor = jsonb_set(valor::jsonb, '{api_pico_ventana_min}', '15'::jsonb)::text
 where clave = 'SALUD_DB_UMBRALES'
   and jsonb_typeof(valor::jsonb) = 'object'
   and valor::jsonb -> 'api_pico_ventana_min' = '30'::jsonb;

insert into mos.salud_db_alertas (tipo) values ('api_sin_pool') on conflict (tipo) do nothing;

-- ── push al MASTER sin pasar por PostgREST ──
create or replace function mos.salud_api_push(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_url  constant text := 'https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/push';
  v_anon constant text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6YnpkZWlwYnRxa3pqcWRjaHFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4NzYwMDQsImV4cCI6MjA5NjQ1MjAwNH0.MAlSdz_ugGUZoaU5st6dA_gb_x_IiUL0TXxH176kY9k';
  v_tok jsonb;
  v_n int;
  v_sec text;
  v_req bigint;
begin
  if nullif(btrim(coalesce(p->>'titulo','')),'') is null then
    return jsonb_build_object('ok', false, 'error', 'titulo requerido');
  end if;
  v_tok := mos.push_tokens_para(jsonb_build_object('roles', jsonb_build_array('MASTER'))) -> 'tokens';
  v_n := case when jsonb_typeof(v_tok) = 'array' then jsonb_array_length(v_tok) else 0 end;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'sin tokens MASTER');
  end if;
  select decrypted_secret into v_sec from vault.decrypted_secrets where name = 'push_cron_secret' limit 1;
  if v_sec is null then
    return jsonb_build_object('ok', false, 'error', 'push_cron_secret no configurado');
  end if;
  select net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_anon,'x-push-cron', v_sec),
    body    := jsonb_build_object('op','send', 'tokens', v_tok, 'app', 'MOS',
                                  'title', p->>'titulo', 'body', coalesce(p->>'cuerpo',''), 'data', p->'data')
  ) into v_req;
  return jsonb_build_object('ok', true, 'request_id', v_req, 'tokens', v_n);
end;
$function$;

revoke all on function mos.salud_api_push(jsonb) from public, anon, authenticated, service_role;

create or replace function mos.salud_db_fotear(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
set lock_timeout to '500ms'
as $function$
declare
  c_act_seg   constant int := 10;
  c_bloq_seg  constant int := 5;
  c_idle_seg  constant int := 60;
  c_cron_seg  constant int := 15;
  c_hueco_min constant int := 3;
  c_backoff_min constant int := 5;
  c_sinmatch_min constant int := 10;
  c_sinmatch_conn constant int := 20;
  u jsonb := jsonb_build_object(
    'foto_conn', 55,
    'api_pool_min', 1, 'api_consec_min', 3,
    'api_desde_min', 390, 'api_hasta_min', 1170,
    'api_pico_min', 5, 'api_pico_ventana_min', 15,
    'api_rate_min', 30, 'api_ok_para_normalizar', 2);
  u0 jsonb;
  v_k text;
  v_cfg jsonb;
  v_i int;
  c_conn int;
  v_forzar boolean := lower(coalesce(p->>'forzar','')) in ('true','1','si','sí');
  v_motivo_manual text := nullif(btrim(coalesce(p->>'motivo','')), '');
  v_txt text;
  v_foto_on boolean := true;
  v_api_on boolean := true;
  v_excl text[] := array['mos-considerados-avisar','riz-reconciliar-stock','nightly-analyze',
                         'cron-purga-historial','mos-salud-foto','mos-salud-db'];
  v_conn int; v_act int; v_act_max numeric; v_bloq int; v_idle int;
  v_pool_n int; v_listen boolean; v_pgrst_total int;
  v_pool_vmin numeric; v_pool_vmax numeric; v_pool_vavg numeric;
  v_pool_qmin numeric; v_pool_qmax numeric; v_pool_qavg numeric;
  v_pool jsonb;
  v_cron jsonb;
  v_motivos text[] := '{}';
  v_errs text[] := '{}';
  v_adv text[] := '{}';
  v_filas jsonb; v_resumen jsonb; v_id bigint;
  v_t0 timestamptz := clock_timestamp();
  v_lock boolean;
  v_dash constant text := 'https://supabase.com/dashboard/project/rzbzdeipbtqkzjqdchqk';
  r mos.salud_db_alertas%rowtype;
  v_val jsonb;
  v_lima timestamp;
  v_min_dia int;
  v_horario boolean;
  v_hit boolean;
  v_pico_prev int; v_pico int; v_pico_ts timestamptz;
  v_hit_desde timestamptz;
  v_push_fail_ts timestamptz;
  v_sm_desde timestamptz; v_sm_foto_ts timestamptz;
  v_min_caida int;
  v_api_motivo text;
  v_cierre_horario boolean := false;
  v_push jsonb; v_push_ok jsonb;
  v_api jsonb;
begin
  u0 := u;

  -- ── interruptores ──
  begin
    select upper(btrim(valor)) into v_txt from mos.config where clave = 'SALUD_DB_FOTO';
    v_foto_on := coalesce(v_txt, 'ON') <> 'OFF';
    v_txt := null;
    select upper(btrim(valor)) into v_txt from mos.config where clave = 'SALUD_API_VIGIA';
    v_api_on := coalesce(v_txt, 'ON') <> 'OFF';
  exception when others then
    v_errs := v_errs || ('interruptores: ' || sqlerrm);
  end;

  -- ── umbrales: cada parte por separado; un valor malo no revierte el resto ──
  begin
    v_txt := null;
    select valor into v_txt from mos.config where clave = 'SALUD_DB_UMBRALES';
    if nullif(btrim(coalesce(v_txt,'')),'') is not null then
      v_cfg := v_txt::jsonb;
    end if;
  exception when others then
    v_cfg := null;
    v_errs := v_errs || ('SALUD_DB_UMBRALES no es JSON: ' || sqlerrm);
  end;
  if jsonb_typeof(v_cfg) = 'object' then
    begin
      if jsonb_typeof(v_cfg -> 'cron_lento_excluir') = 'array' then
        v_excl := v_excl || array(select jsonb_array_elements_text(v_cfg -> 'cron_lento_excluir'));
      end if;
    exception when others then
      v_errs := v_errs || ('cron_lento_excluir: ' || sqlerrm);
    end;
    for v_k in select k from jsonb_object_keys(u0) k loop
      continue when not (v_cfg ? v_k);
      if coalesce(v_cfg #>> array[v_k], '') ~ '^[0-9]{1,6}$' then
        v_i := (v_cfg #>> array[v_k])::int;
        if (v_k = 'api_rate_min' and v_i < 5)
           or (v_k in ('api_consec_min','api_ok_para_normalizar','api_pico_ventana_min') and v_i < 1)
           or (v_k in ('api_desde_min','api_hasta_min') and v_i > 1440) then
          v_errs := v_errs || format('umbral fuera de rango ignorado: %s=%s', v_k, v_i);
        else
          u := jsonb_set(u, array[v_k], to_jsonb(v_i));
        end if;
      else
        v_errs := v_errs || ('umbral inválido ignorado: ' || v_k);
      end if;
    end loop;
    if (u->>'api_desde_min')::int >= (u->>'api_hasta_min')::int then
      v_errs := v_errs || format('horario inválido (%s >= %s): se usan los defaults', u->>'api_desde_min', u->>'api_hasta_min');
      u := jsonb_set(jsonb_set(u, '{api_desde_min}', u0->'api_desde_min'), '{api_hasta_min}', u0->'api_hasta_min');
    end if;
  end if;
  c_conn := (u->>'foto_conn')::int;

  if not v_foto_on and not v_api_on and not v_forzar then
    return jsonb_build_object('ok', true, 'on', false);
  end if;

  -- ── señales: 1 pasada por pg_stat_activity (memoria compartida) ──
  -- [QA 1045] activas>10s excluye pg_cron: los crons lentos por diseño los cubre la señal de cron.
  select count(*) filter (where a.backend_type = 'client backend'),
         count(*) filter (where x.ext and a.state = 'active'
                            and a.application_name is distinct from 'pg_cron'
                            and a.query_start < now() - make_interval(secs => c_act_seg)),
         max(extract(epoch from now() - a.query_start)) filter (where x.ext and a.state = 'active'),
         count(*) filter (where x.ext and a.wait_event_type = 'Lock'
                            and a.query_start < now() - make_interval(secs => c_bloq_seg)),
         count(*) filter (where x.ext and a.state in ('idle in transaction','idle in transaction (aborted)')
                            and a.state_change < now() - make_interval(secs => c_idle_seg)),
         count(*) filter (where y.pgrst and not y.listen),
         coalesce(bool_or(y.pgrst and y.listen), false),
         count(*) filter (where y.pgrst),
         min(extract(epoch from now() - a.backend_start)) filter (where y.pgrst and not y.listen),
         max(extract(epoch from now() - a.backend_start)) filter (where y.pgrst and not y.listen),
         avg(extract(epoch from now() - a.backend_start)) filter (where y.pgrst and not y.listen),
         min(extract(epoch from now() - a.state_change))  filter (where y.pgrst and not y.listen),
         max(extract(epoch from now() - a.state_change))  filter (where y.pgrst and not y.listen),
         avg(extract(epoch from now() - a.state_change))  filter (where y.pgrst and not y.listen)
    into v_conn, v_act, v_act_max, v_bloq, v_idle,
         v_pool_n, v_listen, v_pgrst_total,
         v_pool_vmin, v_pool_vmax, v_pool_vavg, v_pool_qmin, v_pool_qmax, v_pool_qavg
    from pg_catalog.pg_stat_activity a
    cross join lateral (select (a.backend_type = 'client backend'
                                and a.pid <> pg_catalog.pg_backend_pid()
                                and coalesce(a.usename::text,'') not in ('supabase_admin','supabase_realtime_admin','supabase_replication_admin')
                                and coalesce(a.application_name,'') not ilike 'pg\_dump%') as ext) x
    cross join lateral (select (a.backend_type = 'client backend'
                                and a.usename::text = 'authenticator'
                                and a.application_name = 'postgrest') as pgrst,
                               (coalesce(a.query,'') ilike 'LISTEN%') as listen) y;

  v_pool := jsonb_build_object(
    'n', v_pool_n, 'listen', v_listen,
    'vida_min_s', round(v_pool_vmin), 'vida_max_s', round(v_pool_vmax), 'vida_prom_s', round(v_pool_vavg),
    'quieto_min_s', greatest(0, round(v_pool_qmin)), 'quieto_max_s', greatest(0, round(v_pool_qmax)),
    'quieto_prom_s', greatest(0, round(v_pool_qavg)));

  -- anti-solape: una sola corrida a la vez lleva el estado del vigia y fotea
  v_lock := pg_catalog.pg_try_advisory_xact_lock(hashtext('mos.salud_db_foto'));

  -- ── vigia API caida (estado en mos.salud_db_alertas, tipo 'api_sin_pool') ──
  if v_lock then
    begin
      v_lima := now() at time zone 'America/Lima';
      v_min_dia := extract(hour from v_lima)::int * 60 + extract(minute from v_lima)::int;
      v_horario := v_min_dia >= (u->>'api_desde_min')::int and v_min_dia < (u->>'api_hasta_min')::int;
      v_hit := v_pool_n <= (u->>'api_pool_min')::int;

      insert into mos.salud_db_alertas (tipo) values ('api_sin_pool') on conflict (tipo) do nothing;
      select * into r from mos.salud_db_alertas where tipo = 'api_sin_pool' for update;
      v_val := coalesce(r.ultimo_valor, '{}'::jsonb);
      v_hit_desde := (v_val->>'hit_desde')::timestamptz;
      v_push_fail_ts := (v_val->>'push_fail_ts')::timestamptz;
      v_sm_desde := (v_val->>'sin_match_desde')::timestamptz;
      v_sm_foto_ts := (v_val->>'sin_match_foto_ts')::timestamptz;

      -- huecos: si el cron no corrió en > 3 min la racha ya no es consecutiva
      if r.actualizado < now() - make_interval(mins => c_hueco_min) then
        r.consec_hit := 0;
        r.consec_ok := 0;
        v_hit_desde := null;
        v_sm_desde := null;
      end if;

      -- pico del pool en la ventana reciente (demanda previa); vencido = 0
      v_pico_ts := (v_val->>'pico_ts')::timestamptz;
      v_pico_prev := case when v_pico_ts is not null
                           and v_pico_ts >= now() - make_interval(mins => (u->>'api_pico_ventana_min')::int)
                          then coalesce((v_val->>'pico')::int, 0) else 0 end;
      if v_pool_n >= v_pico_prev then
        v_pico := v_pool_n;
        v_pico_ts := now();
      else
        v_pico := v_pico_prev;
      end if;

      -- advertencia: el filtro no ve NINGÚN backend de PostgREST con la base ocupada
      if v_horario and v_pgrst_total = 0 and v_conn > c_sinmatch_conn then
        v_sm_desde := coalesce(v_sm_desde, now());
        if now() - v_sm_desde >= make_interval(mins => c_sinmatch_min) then
          v_adv := v_adv || format('pool_api_filtro_sin_match: %s conexiones y 0 de authenticator/postgrest hace %s min',
                                   v_conn, round(extract(epoch from now() - v_sm_desde) / 60.0)::int);
          if v_sm_foto_ts is null or v_sm_foto_ts < now() - interval '60 minutes' then
            v_motivos := v_motivos || 'pool_api_filtro_sin_match'::text;
            v_sm_foto_ts := now();
          end if;
        end if;
      else
        v_sm_desde := null;
      end if;

      if not v_horario then
        -- fuera de horario: sin rachas; un episodio abierto se cierra en silencio
        if r.activa then
          v_cierre_horario := true;
        end if;
        r.activa := false; r.desde := null; r.pushes_episodio := 0;
        r.consec_hit := 0; r.consec_ok := 0;
        v_hit_desde := null;
      elsif v_hit then
        r.consec_hit := r.consec_hit + 1;
        r.consec_ok := 0;
        if r.consec_hit = 1 or v_hit_desde is null then
          v_hit_desde := now();
        end if;
        v_min_caida := greatest(1, round(extract(epoch from now() - v_hit_desde) / 60.0)::int);

        if not r.activa
           and r.consec_hit >= (u->>'api_consec_min')::int
           and now() - v_hit_desde >= make_interval(mins => (u->>'api_consec_min')::int - 1)
           and v_pico_prev >= (u->>'api_pico_min')::int then
          r.activa := true;
          r.desde := v_hit_desde;
          r.pushes_episodio := 0;
          r.ultimo_push_ts := null;
        end if;

        if r.activa then
          v_min_caida := greatest(1, round(extract(epoch from now() - coalesce(r.desde, v_hit_desde)) / 60.0)::int);
          r.ultimo_motivo := format('API sin conexiones a la base hace %s min (pool=%s, LISTEN=%s)',
                                    v_min_caida, v_pool_n, case when v_listen then 'sí' else 'no' end);
          if v_api_on
             and (r.ultimo_push_ts is null
                  or r.ultimo_push_ts < now() - make_interval(mins => (u->>'api_rate_min')::int))
             and (v_push_fail_ts is null or v_push_fail_ts <= now() - make_interval(mins => c_backoff_min)) then
            begin
              v_push := mos.salud_api_push(jsonb_build_object(
                'titulo', '⚠️ API de MOS sin conexiones',
                'cuerpo', format('La API de MOS no tiene conexiones a la base hace %s min (la base responde). '
                                 || 'Si las apps no cargan, reinicia el proyecto en Supabase.', v_min_caida),
                'data',   jsonb_build_object('tipo','salud_api', 'alertas','api_sin_pool', 'url', v_dash)));
            exception when others then v_push := jsonb_build_object('ok', false, 'error', sqlerrm);
            end;
            if coalesce((v_push->>'ok')::boolean, false) then
              r.ultimo_push_ts := now();
              r.pushes_episodio := r.pushes_episodio + 1;
              v_push_fail_ts := null;
            else
              v_push_fail_ts := now();
              v_errs := v_errs || ('push api: ' || coalesce(v_push->>'error', '?'));
            end if;
          end if;
          v_api_motivo := format('api_sin_pool: pool=%s hace %s min', v_pool_n, v_min_caida);
        elsif r.consec_hit >= (u->>'api_consec_min')::int then
          v_api_motivo := format('api_sin_pool (sin alerta: %s): pool=%s hace %s min',
                                 case when v_pico_prev < (u->>'api_pico_min')::int
                                      then format('sin demanda previa, pico %s < %s', v_pico_prev, u->>'api_pico_min')
                                      else format('racha de %s min < %s', v_min_caida, (u->>'api_consec_min')::int - 1) end,
                                 v_pool_n, v_min_caida);
        end if;
      else
        r.consec_hit := 0;
        v_hit_desde := null;
        if r.activa then
          r.consec_ok := r.consec_ok + 1;
          if r.consec_ok >= (u->>'api_ok_para_normalizar')::int then
            if v_api_on and r.pushes_episodio > 0 then
              begin
                v_push_ok := mos.salud_api_push(jsonb_build_object(
                  'titulo', '✅ API de MOS normalizada',
                  'cuerpo', format('La API volvió a tener conexiones a la base (pool=%s). Estuvo caída ~%s min.',
                                   v_pool_n,
                                   greatest(1, round(extract(epoch from now() - coalesce(r.desde, now())) / 60.0)::int)),
                  'data',   jsonb_build_object('tipo','salud_api_ok', 'alertas','api_sin_pool', 'url', v_dash)));
              exception when others then v_push_ok := jsonb_build_object('ok', false, 'error', sqlerrm);
              end;
              if not coalesce((v_push_ok->>'ok')::boolean, false) then
                v_errs := v_errs || ('push api normalizada: ' || coalesce(v_push_ok->>'error', '?'));
              end if;
            end if;
            r.activa := false; r.consec_ok := 0; r.pushes_episodio := 0; r.desde := null;
            v_push_fail_ts := null;
          end if;
        else
          r.consec_ok := 0;
        end if;
      end if;

      update mos.salud_db_alertas
         set activa = r.activa, desde = r.desde, consec_hit = r.consec_hit, consec_ok = r.consec_ok,
             ultimo_push_ts = r.ultimo_push_ts, pushes_episodio = r.pushes_episodio,
             ultimo_motivo = r.ultimo_motivo,
             ultimo_valor = jsonb_build_object('n', v_pool_n, 'listen', v_listen, 'horario', v_horario,
                                               'pico', v_pico, 'pico_ts', v_pico_ts, 'hit_desde', v_hit_desde,
                                               'push_fail_ts', v_push_fail_ts,
                                               'sin_match_desde', v_sm_desde, 'sin_match_foto_ts', v_sm_foto_ts),
             actualizado = now()
       where tipo = 'api_sin_pool';

      if v_push is not null or v_push_ok is not null or v_cierre_horario then
        insert into mos.cron_log (job, ok, resultado)
        values ('salud_api',
                case when v_cierre_horario and v_push is null and v_push_ok is null then true
                     else coalesce((coalesce(v_push, v_push_ok)->>'ok')::boolean, false) end,
                jsonb_build_object('pool_api', v_pool, 'activa', r.activa, 'push', v_push, 'push_ok', v_push_ok,
                                   'cierre_fuera_de_horario', v_cierre_horario));
      end if;

      v_api := jsonb_build_object('n', v_pool_n, 'listen', v_listen, 'hit', v_hit, 'consec_hit', r.consec_hit,
                                  'consec_ok', r.consec_ok, 'activa', r.activa, 'horario', v_horario,
                                  'pico_prev', v_pico_prev, 'push', v_push, 'push_ok', v_push_ok,
                                  'cierre_horario', v_cierre_horario);
    exception when others then
      v_errs := v_errs || ('vigia api: ' || sqlerrm);
      v_api := jsonb_build_object('n', v_pool_n, 'error', sqlerrm);
    end;
  else
    v_api := jsonb_build_object('n', v_pool_n, 'razon', 'otra corrida en curso');
  end if;

  if not v_foto_on and not v_forzar then
    return jsonb_build_object('ok', true, 'on', false, 'api', v_api, 'advertencias', to_jsonb(v_adv),
                              'errores', to_jsonb(v_errs));
  end if;

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
  if v_api_motivo is not null then v_motivos := v_motivos || v_api_motivo; end if;
  if v_forzar        then v_motivos := v_motivos || ('forzado' || coalesce(': ' || v_motivo_manual, '')); end if;

  if cardinality(v_motivos) = 0 then
    return jsonb_build_object('ok', true, 'foto', false, 'conexiones', v_conn, 'api', v_api,
                              'advertencias', to_jsonb(v_adv), 'errores', to_jsonb(v_errs));
  end if;

  -- ── anti-spam: 1 foto/min + nada de corridas solapadas ──
  if not v_lock then
    return jsonb_build_object('ok', true, 'foto', false, 'razon', 'otra corrida en curso');
  end if;
  if not v_forzar and exists (select 1 from mos.salud_db_foto f where f.ts > now() - interval '55 seconds') then
    return jsonb_build_object('ok', true, 'foto', false, 'razon', 'anti-spam 1/min', 'motivos', to_jsonb(v_motivos),
                              'api', v_api);
  end if;

  -- ── foto: backends no-idle (sin la propia sesión) ──
  -- [QA 1045] el texto de query pasa por un regex que tapa secretos (x-cron-secret/apikey/authorization/bearer).
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
           'query',         left(regexp_replace(a.query, '(x-cron-secret|apikey|authorization|bearer)[^,)]*', ' ***', 'gi'), 300))
         order by coalesce(a.xact_start, a.query_start) nulls last), '[]'::jsonb)
    into v_filas
    from (select * from pg_catalog.pg_stat_activity s
           where s.pid <> pg_catalog.pg_backend_pid()
             and s.state is not null and s.state <> 'idle'
           order by coalesce(s.xact_start, s.query_start) nulls last
           limit 150) a;

  select jsonb_build_object(
    'senales', jsonb_build_object('conexiones', v_conn, 'foto_conn', c_conn, 'activas_10s', v_act,
                                  'activa_max_s', round(coalesce(v_act_max,0)),
                                  'bloqueos_5s', v_bloq, 'idle_tx_60s', v_idle,
                                  'max_connections', current_setting('max_connections')::int),
    'pool_api', v_pool,
    'api', v_api,
    'advertencias', to_jsonb(v_adv),
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
    'errores', to_jsonb(v_errs),
    'ms', null)
    into v_resumen;

  v_resumen := jsonb_set(v_resumen, '{ms}', to_jsonb(round(extract(epoch from clock_timestamp() - v_t0) * 1000)));

  insert into mos.salud_db_foto (motivo, conexiones, resumen, filas)
  values (array_to_string(v_motivos, ' · '), v_conn, v_resumen, v_filas)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'foto', true, 'id', v_id, 'motivos', to_jsonb(v_motivos),
                            'filas', jsonb_array_length(v_filas), 'ms', v_resumen->'ms', 'api', v_api);
end;
$function$;

revoke all on function mos.salud_db_fotear(jsonb) from public, anon, authenticated, service_role;

-- El cron 'mos-salud-foto' (* * * * *, statement_timeout 3s) y la purga de fotos no cambian: no se re-agendan.

commit;

-- ── Pruebas tras aplicar ──
--   select mos.salud_db_fotear();                                  -- api.n ~ tamaño del pool, api.hit=false
--   select * from mos.salud_db_alertas where tipo = 'api_sin_pool';
--   select id, ts at time zone 'America/Lima', motivo, resumen->'pool_api' from mos.salud_db_foto order by ts desc limit 5;
--   select valor from mos.config where clave = 'SALUD_DB_UMBRALES';  -- conserva st_alerta y suma foto_conn/api_*
--   select mos.salud_db_vigilar()->'errores';                      -- debe ser [] (1035 acepta las claves nuevas)
--   select ts, ok, resultado from mos.cron_log where job = 'salud_api' order by ts desc limit 10;
-- Prueba de push real (en horario; manda 1 push al MASTER y luego "normalizada"):
--   update mos.config set valor = (valor::jsonb || '{"api_pool_min":99,"api_pico_min":0}')::text where clave = 'SALUD_DB_UMBRALES';
--   -- esperar ~3 corridas del cron -> push "La API de MOS no tiene conexiones a la base hace 2 min (la base responde)..."
--   update mos.config set valor = (valor::jsonb || '{"api_pool_min":1,"api_pico_min":5}')::text where clave = 'SALUD_DB_UMBRALES';
--   -- 2 corridas después -> push "API de MOS normalizada"
--   -- confirmar entrega: select id, status_code, left(content,200) from net._http_response order by id desc limit 3;
