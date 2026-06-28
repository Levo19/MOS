-- ============================================================================================================
-- 281_mos_dispositivos_sin_senal.sql — [CERO-GAS G2 · cierre] sin-señal GPS desde Supabase (para verificarSinSenal)
-- ------------------------------------------------------------------------------------------------------------
-- Al activar GPS_DIRECTO, los reportes GPS dejan de escribir la hoja UBICACIONES_HISTORIAL → el cron GAS
-- verificarSinSenal (que leía la hoja) creería que TODOS los equipos están sin señal → spam de push. Este RPC
-- mueve el CÁLCULO del sin-señal a Supabase: el GAS reescrito llama acá y solo manda el push. Anti-robo intacto,
-- sin falsas alarmas, sin que el dueño toque Apps Script.
--
-- Devuelve dispositivos ACTIVOS cuyo último reporte GPS (mos.dispositivos_ubicaciones) es > N horas (default 24)
-- o nunca. Shape: [{deviceId, nombre, ultima(iso|null)}] — lo que el push de verificarSinSenal necesita.
-- Gate authenticated/service_role (el cron GAS usa service_role → pasa). NO anon.
-- ============================================================================================================

create schema if not exists mos;

create or replace function mos.dispositivos_sin_senal(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_horas int := coalesce(nullif(btrim(coalesce(p->>'horas','')),'')::int, 24);
  v_corte timestamptz;
  v_arr jsonb;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  v_corte := now() - (v_horas || ' hours')::interval;
  with ult as (
    select device_id, max(ts) as last_ts
    from mos.dispositivos_ubicaciones
    group by device_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'deviceId', d.id_dispositivo,
    'nombre',   coalesce(d.nombre_equipo, ''),
    'ultima',   case when u.last_ts is null then null else mos._iso_z(u.last_ts) end
  ) order by d.id_dispositivo), '[]'::jsonb) into v_arr
  from mos.dispositivos d
  left join ult u on u.device_id = d.id_dispositivo
  where upper(coalesce(d.estado, '')) = 'ACTIVO'
    and (u.last_ts is null or u.last_ts < v_corte);
  return jsonb_build_object('ok', true, 'data', v_arr);
end; $fn$;

revoke all on function mos.dispositivos_sin_senal(jsonb) from public;
grant execute on function mos.dispositivos_sin_senal(jsonb) to authenticated, service_role;

-- ── Mapa última-GPS por dispositivo (para el MERGE en el GAS durante la transición Hoja↔Supabase) ──
-- Devuelve { deviceId: isoTs } solo de devices con algún reporte en los últimos N días (default 8 = TTL+1).
-- El GAS reescrito mergea este mapa con su mapa de la Hoja (max de ambos) → un device "sin señal" solo si AMBAS
-- fuentes están viejas. Así NO hay falsa alarma ni en la transición (algunos aún reportan a la Hoja) ni después.
create or replace function mos.gps_ultima_map(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_dias int := coalesce(nullif(btrim(coalesce(p->>'dias','')),'')::int, 8); v_obj jsonb;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  with ult as (
    select device_id, max(ts) as last_ts
    from mos.dispositivos_ubicaciones
    where ts >= now() - (v_dias || ' days')::interval
    group by device_id
  )
  select coalesce(jsonb_object_agg(device_id, mos._iso_z(last_ts)), '{}'::jsonb) into v_obj from ult;
  return jsonb_build_object('ok', true, 'data', v_obj);
end; $fn$;
revoke all on function mos.gps_ultima_map(jsonb) from public;
grant execute on function mos.gps_ultima_map(jsonb) to authenticated, service_role;
