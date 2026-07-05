-- 386 · kill-GAS lecturas MOS (bloque 1). Reemplazan getAuthCatalogo / getPromociones / getCronStatus.
-- (meHistorialCliente=me.historial_cliente 276 ya existe; meHistorialExtra=mos.me_historial_extra 118 ya existe;
--  getLiquidacionesPendientesSemana=mos.liquidaciones_pendientes 114 ya existe → solo se cablean los intercepts.)

-- ── catálogo de acciones auth (tier+label por acción) desde mos.permisos_accion (37 filas sembradas) ──
create or replace function mos.auth_catalogo(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_map jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_object_agg(accion, jsonb_build_object(
           'tier', coalesce(tier, nivel_minimo, 1), 'label', coalesce(label, accion))), '{}'::jsonb)
    into v_map from mos.permisos_accion where coalesce(nullif(btrim(accion),''),'') <> '';
  return jsonb_build_object('ok',true,'data', v_map);
end; $fn$;

-- ── promociones (lista) desde mos.promociones ──
create or replace function mos.promociones_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_solo_act boolean := coalesce(nullif(btrim(coalesce(p->>'activa','')),'')::boolean, false); v_data jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'idPromo', id_promo, 'skuBase', sku_base, 'tipo', tipo_promo, 'cantMin', cant_min,
      'valorPromo', valor_promo, 'valorModo', valor_modo,
      'items', coalesce(items_json, '[]'::jsonb),
      'descripcion', descripcion, 'vigenciaDesde', vigencia_desde, 'vigenciaHasta', vigencia_hasta,
      'activa', coalesce(activa, true), 'notas', notas) order by id_promo), '[]'::jsonb)
    into v_data from mos.promociones
   where (not v_solo_act) or coalesce(activa, true) = true;
  return jsonb_build_object('ok',true,'data', v_data);
end; $fn$;

-- ── estado de crons (reemplaza getCronStatus: pg_cron + mos.cron_log en vez de triggers GAS + Sheet) ──
create or replace function mos.cron_status(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_job record; v_total int; v_ult jsonb; v_last jsonb; v_ahora text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_ahora := to_char(now() at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI:SS');
  select j.schedule, j.active into v_job
    from cron.job j where j.jobname ilike '%cierre%noct%' or j.jobname ilike '%nocturn%' limit 1;
  select count(*) into v_total from mos.cron_log where job ilike '%cierre%' or job ilike '%noct%';
  -- últimas 5 corridas (moldea el jsonb resultado a las llaves que el front lee, con fallback null)
  select coalesce(jsonb_agg(row order by ts desc), '[]'::jsonb) into v_ult from (
    select jsonb_build_object(
      'ts_inicio', to_char(ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
      'ts_fin', coalesce(resultado->>'ts_fin', to_char(ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS')),
      'duracion_ms', coalesce((resultado->>'duracion_ms')::int, 0),
      'wh_cerradas', coalesce((resultado->>'wh_cerradas')::int, 0),
      'wh_omitidas', coalesce((resultado->>'wh_omitidas')::int, 0),
      'wh_errores', coalesce((resultado->>'wh_errores')::int, 0),
      'me_cerradas', coalesce((resultado->>'me_cerradas')::int, 0),
      'me_errores', coalesce((resultado->>'me_errores')::int, 0),
      'dev_marcados', coalesce((resultado->>'dev_marcados')::int, 0),
      'dev_omitidos', coalesce((resultado->>'dev_omitidos')::int, 0),
      'dev_errores', coalesce((resultado->>'dev_errores')::int, 0),
      'ok', coalesce(ok, false),
      'detalles_json', coalesce(resultado::text, '{}')) as row, ts
    from mos.cron_log where job ilike '%cierre%' or job ilike '%noct%' order by ts desc limit 5
  ) q;
  v_last := v_ult->0;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('cierreNocturno', jsonb_build_object(
    'trigger_instalado', (v_job.schedule is not null),
    'hora_programada', coalesce(v_job.schedule, 'pg_cron'),
    'tz_script', 'America/Lima', 'ahora_script', v_ahora,
    'total_corridas', coalesce(v_total,0),
    'ultima_corrida', case when v_last is null then null else v_last->>'ts_inicio' end,
    'ultimas_5', v_ult)));
end; $fn$;

revoke all on function mos.auth_catalogo(jsonb), mos.promociones_lista(jsonb), mos.cron_status(jsonb) from public, anon;
grant execute on function mos.auth_catalogo(jsonb), mos.promociones_lista(jsonb) to authenticated, service_role;
grant execute on function mos.cron_status(jsonb) to authenticated, service_role;
