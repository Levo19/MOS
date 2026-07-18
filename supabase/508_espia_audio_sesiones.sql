-- 508 · Monitoreo de audio del local (ciclo de SESIÓN) 100% Supabase (cero-GAS).
-- ┌─ QUÉ ES (leer antes de tocar / no malinterpretar) ────────────────────────────────────────────────────┐
-- │ Módulo de MONITOREO DE SEGURIDAD del local. Graba audio de los EQUIPOS PROPIEDAD DE LA EMPRESA que      │
-- │ fueron APROBADOS por la empresa (mismo UUID de `aprobar_dispositivo` que controla quién entra a la app), │
-- │ DENTRO del local. Es el complemento LIVIANO del CCTV de la tienda (que tiene hosting propio y streaming  │
-- │ continuo); acá va en FRAGMENTOS porque Supabase no es para streaming siempre-conectado. El push          │
-- │ "silencioso" es UX — no marear al operador (poco técnico) con modales/formularios — NO ocultamiento.     │
-- │ "espía" es el CODENAME INTERNO LEGACY del subsistema, NO vigilancia encubierta de personas. No se dirige  │
-- │ a individuos fuera del local ni a equipos personales.                                                    │
-- └──────────────────────────────────────────────────────────────────────────────────────────────────────┘
-- Reemplaza Audio.gs (AUDIO_SESIONES sheet + iniciar/detener/estado/getSesiones/getChunks/getContent → Drive).
-- Los CHUNKS ya viven en mos.espia_chunks (SQL 413, Storage `espia` con URL pública, subidos por la Edge
-- espia-chunk desde WH/ME). Acá va el ciclo de sesión + las lecturas del controlador MOS. Push audio_start/stop
-- lo manda el front por Edge `push`. NO es dinero. La verdad del device sale de la sombra mos.dispositivos.

create table if not exists mos.espia_audio_sesiones (
  id_sesion      text primary key,
  device_id      text not null default '',
  autorizado_por text not null default '',
  inicio         timestamptz not null default now(),
  fin            timestamptz,
  duracion_seg   int  not null default 0,
  estado         text not null default 'ACTIVA',   -- ACTIVA | CERRADA | CANCELADA
  motivo         text not null default '',
  created_at     timestamptz not null default now()
);
create index if not exists ix_espia_audio_ses_dev on mos.espia_audio_sesiones (device_id, inicio desc);
alter table mos.espia_audio_sesiones enable row level security;

-- Gate: acción de admin (controlador MOS). service_role permitido (backend/tests). detener acepta también el
-- device (mosExpress/warehouseMos) porque el propio dispositivo cierra su sesión al auto-detenerse.
create or replace function mos._espia_audio_app_ok(solo_mos boolean)
returns boolean language plpgsql stable security definer set search_path='' as $fn$
declare a text := coalesce(me.jwt_app(),'');
begin
  if coalesce(auth.role(),'') = 'service_role' then return true; end if;
  if solo_mos then return a = 'MOS'; end if;
  return a in ('MOS','mosExpress','warehouseMos');
end; $fn$;

-- INICIAR: {deviceId, autorizadoPor, motivo?}. Cancela la ACTIVA previa del device, crea sesión nueva. Solo MOS.
create or replace function mos.espia_audio_iniciar(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_dev text := btrim(coalesce(p->>'deviceId','')); v_by text := btrim(coalesce(p->>'autorizadoPor','')); v_id text;
begin
  if not mos._espia_audio_app_ok(true) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_dev = '' then return jsonb_build_object('ok',false,'error','Requiere deviceId'); end if;
  if v_by  = '' then return jsonb_build_object('ok',false,'error','Requiere autorizadoPor'); end if;
  update mos.espia_audio_sesiones set estado='CANCELADA', fin=now(),
         duracion_seg = greatest(0, extract(epoch from (now()-inicio))::int)
   where device_id = v_dev and estado='ACTIVA';
  v_id := 'AS' || (extract(epoch from clock_timestamp())*1000)::bigint::text;
  insert into mos.espia_audio_sesiones (id_sesion, device_id, autorizado_por, motivo)
  values (v_id, v_dev, v_by, coalesce(p->>'motivo',''));
  return jsonb_build_object('ok',true,'data', jsonb_build_object('idSesion', v_id));
end; $fn$;

-- DETENER: {idSesion? , deviceId?}. Cierra la sesión (por id, o la ACTIVA del device). Devuelve deviceId para
-- que el front mande el push audio_stop. MOS o el propio device.
create or replace function mos.espia_audio_detener(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id text := btrim(coalesce(p->>'idSesion','')); v_dev text := btrim(coalesce(p->>'deviceId','')); v_row mos.espia_audio_sesiones;
begin
  if not mos._espia_audio_app_ok(false) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' and v_dev = '' then return jsonb_build_object('ok',false,'error','Requiere idSesion o deviceId'); end if;
  if v_id <> '' then
    select * into v_row from mos.espia_audio_sesiones where id_sesion = v_id;
  else
    select * into v_row from mos.espia_audio_sesiones where device_id = v_dev and estado='ACTIVA' order by inicio desc limit 1;
  end if;
  if v_row.id_sesion is null then return jsonb_build_object('ok',true,'data', jsonb_build_object('deviceId', nullif(v_dev,''))); end if;
  if v_row.estado = 'ACTIVA' then
    update mos.espia_audio_sesiones set estado='CERRADA', fin=now(),
           duracion_seg = greatest(0, extract(epoch from (now()-inicio))::int)
     where id_sesion = v_row.id_sesion;
  end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('deviceId', v_row.device_id));
end; $fn$;

-- ESTADO: {deviceId} → ¿hay ACTIVA? Solo MOS.
create or replace function mos.espia_audio_estado(p jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_dev text := btrim(coalesce(p->>'deviceId','')); v_row mos.espia_audio_sesiones;
begin
  if not mos._espia_audio_app_ok(true) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_dev = '' then return jsonb_build_object('ok',false,'error','Requiere deviceId'); end if;
  select * into v_row from mos.espia_audio_sesiones where device_id = v_dev and estado='ACTIVA' order by inicio desc limit 1;
  if v_row.id_sesion is null then return jsonb_build_object('ok',true,'data', jsonb_build_object('activa', false)); end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('activa', true, 'sesion', jsonb_build_object(
    'idSesion', v_row.id_sesion, 'deviceId', v_row.device_id, 'autorizadoPor', v_row.autorizado_por,
    'inicio', v_row.inicio, 'estado', v_row.estado, 'motivo', v_row.motivo)));
end; $fn$;

-- LISTAR sesiones: {deviceId?, limit?}. Solo MOS.
create or replace function mos.espia_audio_sesiones_listar(p jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_dev text := btrim(coalesce(p->>'deviceId','')); v_lim int := coalesce((p->>'limit')::int, 30);
begin
  if not mos._espia_audio_app_ok(true) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return jsonb_build_object('ok',true,'data', coalesce((
    select jsonb_agg(jsonb_build_object(
      'idSesion', s.id_sesion, 'deviceId', s.device_id, 'autorizadoPor', s.autorizado_por,
      'inicio', s.inicio, 'fin', s.fin, 'duracionSeg', s.duracion_seg, 'estado', s.estado, 'motivo', s.motivo)
      order by s.inicio desc)
    from (select * from mos.espia_audio_sesiones
          where (v_dev = '' or device_id = v_dev) order by inicio desc limit greatest(1, least(v_lim, 200))) s
  ), '[]'::jsonb));
end; $fn$;

-- CHUNKS de una sesión: {idSesion} → chunks de audio (mos.espia_chunks, tipo=audio) con URL pública de Storage.
-- Reemplaza getChunksAudioSesion + getChunkAudioContent (el url es público → el front reproduce directo). Solo MOS.
create or replace function mos.espia_audio_chunks(p jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_ses text := btrim(coalesce(p->>'idSesion',''));
begin
  if not mos._espia_audio_app_ok(true) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_ses = '' then return jsonb_build_object('ok',false,'error','Requiere idSesion'); end if;
  return jsonb_build_object('ok',true,'data', coalesce((
    select jsonb_agg(jsonb_build_object(
      'idChunk', ch.id_chunk, 'idSesion', ch.id_sesion, 'idx', ch.idx, 'ts', ch.ts,
      'url', ch.url, 'mime', ch.mime, 'tamBytes', ch.tam_bytes) order by ch.idx asc, ch.ts asc)
    from mos.espia_chunks ch where ch.id_sesion = v_ses and ch.tipo = 'audio'
  ), '[]'::jsonb));
end; $fn$;

-- PURGA: sesiones + chunks (metadata) > 7 días. Los blobs en Storage los barre el purge de espía. pg_cron/manual.
create or replace function mos.espia_audio_purgar()
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_ses int; v_ch int;
begin
  with d as (delete from mos.espia_audio_sesiones where inicio < now() - interval '7 days' returning 1)
    select count(*) into v_ses from d;
  with d as (delete from mos.espia_chunks where tipo='audio' and created_at < now() - interval '7 days' returning 1)
    select count(*) into v_ch from d;
  return jsonb_build_object('ok',true,'sesiones', v_ses, 'chunks', v_ch);
end; $fn$;

comment on table mos.espia_audio_sesiones is 'Monitoreo de seguridad del local (audio) sobre equipos propiedad+aprobados por la empresa, dentro del local. Complemento liviano del CCTV. "espia" = codename legacy, NO vigilancia encubierta de personas.';
comment on function mos.espia_audio_iniciar(jsonb) is 'Abre una sesión de monitoreo de audio de un equipo aprobado de la empresa (módulo de seguridad del local). Ver comentario de la tabla.';

grant execute on function mos._espia_audio_app_ok(boolean)        to authenticated, anon, service_role;
grant execute on function mos.espia_audio_iniciar(jsonb)          to authenticated, anon, service_role;
grant execute on function mos.espia_audio_detener(jsonb)          to authenticated, anon, service_role;
grant execute on function mos.espia_audio_estado(jsonb)           to authenticated, anon, service_role;
grant execute on function mos.espia_audio_sesiones_listar(jsonb)  to authenticated, anon, service_role;
grant execute on function mos.espia_audio_chunks(jsonb)           to authenticated, anon, service_role;
grant execute on function mos.espia_audio_purgar()                to service_role;
