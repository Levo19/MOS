-- ============================================================================================================
-- 279_mos_gps_ubicaciones.sql — [CERO-GAS G2] tracking GPS de dispositivos → Supabase (write + 2 reads + purga)
-- ------------------------------------------------------------------------------------------------------------
-- Migra el subsistema GPS anti-robo de GAS (Gps.gs / hoja UBICACIONES_HISTORIAL) a Supabase. WH (_gpsRegistrarWH,
-- cada 5 min) y ME (_gpsRegistrar) escriben lat/lng/accuracy/bateria; el admin master ve última posición + ruta.
--
-- LOCKSTEP por UN flag `GPS_DIRECTO` (mos.config): controla writes Y reads a la vez. OFF (default) → todo por GAS
-- (INERTE, cero cambio). ON → writes y reads por Supabase. Coherente: no hay ventana donde se escriba en un lado
-- y se lea del otro.
--
-- ⚠ PRE-REQUISITO DE ACTIVACIÓN (por eso G2 NO se auto-activa como G1): el trigger GAS `verificarSinSenal` lee la
-- hoja UBICACIONES_HISTORIAL; si los writes se van a Supabase, la hoja deja de crecer → creería que TODOS los
-- equipos están sin señal → spam de push a master. Antes de poner GPS_DIRECTO='1': DESACTIVAR ese trigger GAS
-- (y, si se quiere conservar el alerta, portarlo a Supabase — pendiente, necesita la ruta de push). La purga de
-- 7 días sí queda cubierta acá por pg_cron.
--
-- Shape de salida en camelCase paritario con Gps.gs (_sheetToObjects): {idUbic, deviceId, timestamp, lat, lng,
-- accuracy, bateria, usuarioLogueado}. timestamp como ISO-Z (el front hace new Date(r.timestamp)).
-- ============================================================================================================

create schema if not exists mos;
create extension if not exists pgcrypto;   -- gen_random_uuid (id_ubic único, sin colisión por ms como en GAS)

-- ── Tabla de ubicaciones (TTL 7 días, espeja UBICACIONES_HISTORIAL) ──
create table if not exists mos.dispositivos_ubicaciones (
  id_ubic          text primary key,
  device_id        text not null,
  ts               timestamptz not null default now(),
  lat              double precision not null,
  lng              double precision not null,
  accuracy         numeric,
  bateria          numeric,
  usuario_logueado text
);
create index if not exists ix_disp_ubic_dev_ts on mos.dispositivos_ubicaciones (device_id, ts desc);

-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) WRITE — mos.registrar_ubicacion(p) → registrarUbicacion (Gps.gs). Anon (lo llaman WH/ME pre/post login).
--    Flag-gated: GPS_DIRECTO != '1' → OFF → el front cae al write GAS.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.registrar_ubicacion(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_dev text := btrim(coalesce(p->>'deviceId',''));
  v_lat double precision;
  v_lng double precision;
  v_id  text;
begin
  if coalesce((select valor from mos.config where clave = 'GPS_DIRECTO' limit 1), '0') <> '1' then
    return jsonb_build_object('ok', false, 'error', 'GPS_DIRECTO_OFF');
  end if;
  if v_dev = '' then return jsonb_build_object('ok', false, 'error', 'Requiere deviceId'); end if;
  -- parseo tolerante (paridad: lat/lng obligatorios y numéricos)
  begin v_lat := (p->>'lat')::double precision; exception when others then v_lat := null; end;
  begin v_lng := (p->>'lng')::double precision; exception when others then v_lng := null; end;
  if v_lat is null or v_lng is null then
    return jsonb_build_object('ok', false, 'error', 'Coordenadas inválidas');
  end if;
  v_id := 'UB' || replace(gen_random_uuid()::text, '-', '');
  insert into mos.dispositivos_ubicaciones (id_ubic, device_id, ts, lat, lng, accuracy, bateria, usuario_logueado)
  values (
    v_id, v_dev, now(), v_lat, v_lng,
    nullif(btrim(coalesce(p->>'accuracy','')),'')::numeric,
    nullif(btrim(coalesce(p->>'bateria','')),'')::numeric,
    btrim(coalesce(p->>'usuarioLogueado',''))
  );
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('idUbic', v_id));
exception when others then
  -- accuracy/bateria mal formados no deben tumbar el insert principal → reintento sin esos campos
  begin
    insert into mos.dispositivos_ubicaciones (id_ubic, device_id, ts, lat, lng, usuario_logueado)
    values (v_id, v_dev, now(), v_lat, v_lng, btrim(coalesce(p->>'usuarioLogueado','')))
    on conflict (id_ubic) do nothing;
    return jsonb_build_object('ok', true, 'data', jsonb_build_object('idUbic', v_id));
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'INSERT_FALLO');
  end;
end; $fn$;
revoke all on function mos.registrar_ubicacion(jsonb) from public;
grant execute on function mos.registrar_ubicacion(jsonb) to anon, authenticated, service_role;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) READ última — mos.ultima_ubicacion_dispositivo(p) → getUltimaUbicacionDispositivo. Admin (authenticated).
--    Flag-gated: OFF → el directo del front retorna null → cae a GAS (coherente con el write).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.ultima_ubicacion_dispositivo(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_dev text := btrim(coalesce(p->>'deviceId','')); v_row jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave = 'GPS_DIRECTO' limit 1), '0') <> '1' then
    return jsonb_build_object('ok', false, 'error', 'GPS_DIRECTO_OFF');
  end if;
  if v_dev = '' then return jsonb_build_object('ok', false, 'error', 'Requiere deviceId'); end if;
  select jsonb_build_object(
    'idUbic', u.id_ubic, 'deviceId', u.device_id, 'timestamp', mos._iso_z(u.ts),
    'lat', u.lat, 'lng', u.lng, 'accuracy', coalesce(u.accuracy, 0),
    'bateria', case when u.bateria is null then '' else u.bateria::text end,
    'usuarioLogueado', coalesce(u.usuario_logueado, '')
  ) into v_row
  from mos.dispositivos_ubicaciones u
  where u.device_id = v_dev
  order by u.ts desc
  limit 1;
  -- data:null cuando no hay filas (paridad con GAS: { ok:true, data:null })
  return jsonb_build_object('ok', true, 'data', coalesce(v_row, 'null'::jsonb));
end; $fn$;
revoke all on function mos.ultima_ubicacion_dispositivo(jsonb) from public;
grant execute on function mos.ultima_ubicacion_dispositivo(jsonb) to authenticated, service_role;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) READ historial — mos.ubicaciones_dispositivo(p) → getUbicacionesDispositivo (ruta del mapa, últimas N horas).
--    Flag-gated. Orden ascendente por ts (paridad GAS). horas default 24.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.ubicaciones_dispositivo(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_dev text := btrim(coalesce(p->>'deviceId',''));
  v_horas int := coalesce(nullif(btrim(coalesce(p->>'horas','')),'')::int, 24);
  v_arr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave = 'GPS_DIRECTO' limit 1), '0') <> '1' then
    return jsonb_build_object('ok', false, 'error', 'GPS_DIRECTO_OFF');
  end if;
  if v_dev = '' then return jsonb_build_object('ok', false, 'error', 'Requiere deviceId'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'idUbic', u.id_ubic, 'deviceId', u.device_id, 'timestamp', mos._iso_z(u.ts),
    'lat', u.lat, 'lng', u.lng, 'accuracy', coalesce(u.accuracy, 0),
    'bateria', case when u.bateria is null then '' else u.bateria::text end,
    'usuarioLogueado', coalesce(u.usuario_logueado, '')
  ) order by u.ts asc), '[]'::jsonb) into v_arr
  from mos.dispositivos_ubicaciones u
  where u.device_id = v_dev
    and u.ts >= now() - (v_horas || ' hours')::interval;
  return jsonb_build_object('ok', true, 'data', v_arr);
end; $fn$;
revoke all on function mos.ubicaciones_dispositivo(jsonb) from public;
grant execute on function mos.ubicaciones_dispositivo(jsonb) to authenticated, service_role;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) PURGA TTL 7 días (reemplaza limpiarUbicacionesViejas de GAS). pg_cron diario. Idempotente.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.cron_gps_purga()
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  delete from mos.dispositivos_ubicaciones where ts < now() - interval '7 days';
end; $fn$;
revoke all on function mos.cron_gps_purga() from public;
grant execute on function mos.cron_gps_purga() to service_role;

create extension if not exists pg_cron;
select cron.unschedule('mos-gps-purga') where exists (select 1 from cron.job where jobname = 'mos-gps-purga');
-- 03:30 todos los días (hora servidor). NACE ACTIVO: solo borra filas >7d de una tabla que está vacía mientras
-- GPS_DIRECTO=OFF → no-op inofensivo hasta el cutover.
select cron.schedule('mos-gps-purga', '30 3 * * *', $$ select mos.cron_gps_purga(); $$);
