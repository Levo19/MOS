-- 225_espia_signaling.sql — Señalización WebRTC del Espía 100% Supabase (cero GAS). Port fiel de
-- gas/EspiaWebRTC.gs (RTC_SIGNALING + 13 endpoints). FSM PENDIENTE→CONECTANDO→EN_VIVO→CERRADA, ICE incremental
-- por ts, expiración 10min, autocierre de zombies. Gating: app JWT del ecosistema (me.jwt_app()); crear exige
-- MASTER (mos.verificar_clave_admin). El sesionId actúa de capacidad (igual que el token GAS). El despertar del
-- device se hace por la Edge `push` (data-only) + Realtime — fuera de esta capa.

create table if not exists mos.espia_sesiones (
  sesion_id          text primary key,
  fecha              timestamptz default now(),
  master_id          text not null,
  device_id          text not null,
  estado             text default 'PENDIENTE',  -- PENDIENTE|CONECTANDO|EN_VIVO|CERRADA
  sdp_oferta         text default '',
  sdp_respuesta      text default '',
  ice_master         jsonb default '[]'::jsonb,
  ice_device         jsonb default '[]'::jsonb,
  streams_activos    jsonb,
  detalle_fin        jsonb,
  sdp_reneg_oferta   text default '',
  sdp_reneg_respuesta text default ''
);
create index if not exists espia_sesiones_device_idx on mos.espia_sesiones (device_id, estado);

-- Límites (réplica de las constantes GAS)
--   TTL 10 min · SDP máx 45000 chars · ICE máx 300 ítems/lado
create or replace function mos._espia_app_ok()
returns boolean language sql stable set search_path = '' as $$
  select coalesce(me.jwt_app(),'') <> '';
$$;

create or replace function mos._espia_expiro(p_fecha timestamptz)
returns boolean language sql immutable set search_path = '' as $$
  select (now() - p_fecha) >= interval '10 minutes';
$$;

-- FSM válida + idempotencia (a==n permitido). Réplica _validarTransicionEstado.
create or replace function mos._espia_trans_ok(p_actual text, p_nuevo text)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when upper(coalesce(p_actual,'')) = upper(coalesce(p_nuevo,'')) then true
    when upper(coalesce(p_actual,'')) = 'PENDIENTE'  and upper(p_nuevo) in ('CONECTANDO','EN_VIVO','CERRADA') then true
    when upper(coalesce(p_actual,'')) = 'CONECTANDO' and upper(p_nuevo) in ('EN_VIVO','CERRADA') then true
    when upper(coalesce(p_actual,'')) = 'EN_VIVO'    and upper(p_nuevo) = 'CERRADA' then true
    else false end;
$$;

-- ── 1. Crear sesión (master, requiere MASTER) ──────────────────────────────────────────────
create or replace function mos.espia_crear_sesion(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_master text := nullif(btrim(coalesce(p->>'masterId','')), '');
  v_device text := nullif(btrim(coalesce(p->>'deviceId','')), '');
  v_clave  text := nullif(btrim(coalesce(p->>'claveAdmin','')), '');
  v_auth   jsonb; v_sid text; v_zomb record;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_master is null then return jsonb_build_object('ok',false,'error','masterId requerido'); end if;
  if v_device is null then return jsonb_build_object('ok',false,'error','deviceId requerido'); end if;
  if v_clave is null then return jsonb_build_object('ok',false,'error','claveAdmin (8 dígitos) requerida'); end if;
  v_auth := mos.verificar_clave_admin(v_clave, 'ESPIA_INICIAR', v_device, 'MOS', null, null, 3, null);
  if coalesce((v_auth->>'autorizado')::boolean,false) <> true then
    return jsonb_build_object('ok',false,'error', coalesce(v_auth->>'error','Clave incorrecta')); end if;
  if upper(coalesce(v_auth->>'rol','')) <> 'MASTER' then
    return jsonb_build_object('ok',false,'error','Solo MASTER puede iniciar espía. Tu rol: '||coalesce(v_auth->>'rol','')); end if;

  -- Autocerrar zombies del device (PENDIENTE/CONECTANDO o mismo master); bloquear si EN_VIVO de OTRO master.
  for v_zomb in
    select sesion_id, estado, master_id, fecha from mos.espia_sesiones
     where device_id = v_device and upper(coalesce(estado,'')) <> 'CERRADA' and not mos._espia_expiro(fecha)
  loop
    if upper(v_zomb.estado) = 'EN_VIVO' and v_zomb.master_id <> v_master then
      return jsonb_build_object('ok',false,'error','Hay una sesión EN VIVO con este dispositivo (otro master). Cierra la anterior o espera.');
    end if;
    update mos.espia_sesiones set estado='CERRADA',
      detalle_fin = jsonb_build_object('motivo','autocerrada_zombie','lado','crear_sesion','estadoAnterior',v_zomb.estado)
     where sesion_id = v_zomb.sesion_id;
  end loop;

  v_sid := 'ESP-' || (extract(epoch from now())*1000)::bigint || '-' || substr(md5(random()::text||v_device),1,9);
  insert into mos.espia_sesiones (sesion_id, master_id, device_id, estado) values (v_sid, v_master, v_device, 'PENDIENTE');
  return jsonb_build_object('ok',true,'data', jsonb_build_object('sesionId', v_sid, 'ttl', 600000, 'ahora', to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')));
end;
$fn$;

-- ── 2-3. Oferta / Respuesta SDP ──────────────────────────────────────────────────────────
create or replace function mos.espia_subir_oferta(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),''); v_sdp text := coalesce(p->>'sdp','');
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sid is null or v_sdp='' then return jsonb_build_object('ok',false,'error','Requiere sesionId y sdp'); end if;
  if length(v_sdp) > 45000 then return jsonb_build_object('ok',false,'error','SDP demasiado grande'); end if;
  update mos.espia_sesiones set sdp_oferta = v_sdp where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

create or replace function mos.espia_leer_oferta(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),''); v_r mos.espia_sesiones%rowtype;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select * into v_r from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if mos._espia_expiro(v_r.fecha) then return jsonb_build_object('ok',false,'error','Sesión expirada','codigo','EXPIRADO'); end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('sdpOferta', v_r.sdp_oferta, 'estado', v_r.estado));
end;
$fn$;

create or replace function mos.espia_subir_respuesta(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),''); v_sdp text := coalesce(p->>'sdp',''); v_r mos.espia_sesiones%rowtype;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sid is null or v_sdp='' then return jsonb_build_object('ok',false,'error','Requiere sesionId y sdp'); end if;
  if length(v_sdp) > 45000 then return jsonb_build_object('ok',false,'error','SDP demasiado grande'); end if;
  select * into v_r from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if not mos._espia_trans_ok(v_r.estado,'CONECTANDO') then
    return jsonb_build_object('ok',false,'error','Transición inválida: '||v_r.estado||'→CONECTANDO'); end if;
  update mos.espia_sesiones set sdp_respuesta = v_sdp, estado = 'CONECTANDO' where sesion_id = v_sid;
  return jsonb_build_object('ok',true);
end;
$fn$;

create or replace function mos.espia_leer_respuesta(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),''); v_r mos.espia_sesiones%rowtype;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select * into v_r from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if mos._espia_expiro(v_r.fecha) then return jsonb_build_object('ok',false,'error','Sesión expirada','codigo','EXPIRADO'); end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('sdpRespuesta', v_r.sdp_respuesta, 'estado', v_r.estado));
end;
$fn$;

-- ── 4. ICE candidates (append + lectura incremental por ts) ──────────────────────────────
create or replace function mos.espia_agregar_ice(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),'');
  v_lado text := lower(coalesce(p->>'lado',''));
  v_ice jsonb := p->'ice';
  v_item jsonb;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sid is null or v_lado not in ('master','device') or v_ice is null then
    return jsonb_build_object('ok',false,'error','Requiere sesionId, lado(master|device), ice'); end if;
  v_item := jsonb_build_object('ts', (extract(epoch from clock_timestamp())*1000)::bigint, 'ice', v_ice);
  if v_lado = 'master' then
    update mos.espia_sesiones
       set ice_master = (case when jsonb_array_length(coalesce(ice_master,'[]'::jsonb)) >= 300
                              then (ice_master - 0) else coalesce(ice_master,'[]'::jsonb) end) || v_item
     where sesion_id = v_sid;
  else
    update mos.espia_sesiones
       set ice_device = (case when jsonb_array_length(coalesce(ice_device,'[]'::jsonb)) >= 300
                              then (ice_device - 0) else coalesce(ice_device,'[]'::jsonb) end) || v_item
     where sesion_id = v_sid;
  end if;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

create or replace function mos.espia_leer_ice(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),'');
  v_lado text := lower(coalesce(p->>'lado',''));
  v_desde bigint := coalesce((p->>'desde')::bigint, 0);
  v_r mos.espia_sesiones%rowtype; v_arr jsonb; v_nuevos jsonb; v_tsmax bigint;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select * into v_r from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if mos._espia_expiro(v_r.fecha) then return jsonb_build_object('ok',false,'error','Sesión expirada','codigo','EXPIRADO'); end if;
  v_arr := case when v_lado='master' then coalesce(v_r.ice_master,'[]'::jsonb) else coalesce(v_r.ice_device,'[]'::jsonb) end;
  select coalesce(jsonb_agg(e order by (e->>'ts')::bigint), '[]'::jsonb) into v_nuevos
    from jsonb_array_elements(v_arr) e where (e->>'ts')::bigint > v_desde;
  select coalesce(max((e->>'ts')::bigint), v_desde) into v_tsmax from jsonb_array_elements(v_arr) e;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('ice', v_nuevos, 'tsMax', v_tsmax));
end;
$fn$;

-- ── 5. Estado · 6. Streams · 7. Cerrar ───────────────────────────────────────────────────
create or replace function mos.espia_estado(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),''); v_r mos.espia_sesiones%rowtype; v_exp int;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select * into v_r from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  v_exp := greatest(0, 600 - floor(extract(epoch from (now() - v_r.fecha)))::int) * 1000;
  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'sesionId', v_sid, 'estado', v_r.estado, 'streamsActivos', v_r.streams_activos,
    'iniciada', v_r.fecha, 'expiraEn', v_exp));
end;
$fn$;

create or replace function mos.espia_reportar_streams(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),''); v_st jsonb := coalesce(p->'streams','{}'::jsonb); v_est text;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select estado into v_est from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if upper(coalesce(v_est,'')) = 'CERRADA' then return jsonb_build_object('ok',false,'error','Sesión ya cerrada · no se reportan streams'); end if;
  update mos.espia_sesiones set streams_activos = v_st, estado = 'EN_VIVO' where sesion_id = v_sid;
  return jsonb_build_object('ok',true);
end;
$fn$;

create or replace function mos.espia_cerrar_sesion(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),'');
  v_motivo text := coalesce(p->>'motivo','manual'); v_lado text := coalesce(p->>'lado','desconocido');
  v_r mos.espia_sesiones%rowtype; v_dur int;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select * into v_r from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if upper(coalesce(v_r.estado,'')) = 'CERRADA' then return jsonb_build_object('ok',true,'data', jsonb_build_object('yaCerrada', true)); end if;
  v_dur := round(extract(epoch from (now() - v_r.fecha)))::int;
  update mos.espia_sesiones set estado='CERRADA',
    detalle_fin = jsonb_build_object('motivo',v_motivo,'lado',v_lado,'duracionSeg',v_dur) where sesion_id = v_sid;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('duracionSeg', v_dur));
end;
$fn$;

-- ── 8. Renegociación SDP (cuando el device agrega pantalla luego del PC inicial) ─────────
create or replace function mos.espia_subir_reneg_oferta(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),''); v_sdp text := coalesce(p->>'sdp',''); v_r mos.espia_sesiones%rowtype;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sid is null or v_sdp='' then return jsonb_build_object('ok',false,'error','Requiere sesionId y sdp'); end if;
  if length(v_sdp) > 45000 then return jsonb_build_object('ok',false,'error','SDP demasiado grande'); end if;
  select * into v_r from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if upper(coalesce(v_r.estado,'')) = 'CERRADA' then return jsonb_build_object('ok',false,'error','Sesión cerrada · no se acepta reneg'); end if;
  if mos._espia_expiro(v_r.fecha) then return jsonb_build_object('ok',false,'error','Sesión expirada','codigo','EXPIRADO'); end if;
  update mos.espia_sesiones set sdp_reneg_oferta = v_sdp, sdp_reneg_respuesta = '' where sesion_id = v_sid;
  return jsonb_build_object('ok',true);
end;
$fn$;

create or replace function mos.espia_leer_reneg_oferta(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),''); v_v text;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select sdp_reneg_oferta into v_v from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('sdpRenegOferta', coalesce(v_v,'')));
end;
$fn$;

create or replace function mos.espia_subir_reneg_respuesta(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),''); v_sdp text := coalesce(p->>'sdp',''); v_est text;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sid is null or v_sdp='' then return jsonb_build_object('ok',false,'error','Requiere sesionId y sdp'); end if;
  if length(v_sdp) > 45000 then return jsonb_build_object('ok',false,'error','SDP demasiado grande'); end if;
  select estado into v_est from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if upper(coalesce(v_est,'')) = 'CERRADA' then return jsonb_build_object('ok',false,'error','Sesión cerrada'); end if;
  update mos.espia_sesiones set sdp_reneg_respuesta = v_sdp, sdp_reneg_oferta = '' where sesion_id = v_sid;
  return jsonb_build_object('ok',true);
end;
$fn$;

create or replace function mos.espia_leer_reneg_respuesta(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),''); v_v text;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select sdp_reneg_respuesta into v_v from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('sdpRenegRespuesta', coalesce(v_v,'')));
end;
$fn$;

-- ── Purga (cron): cerradas >2h o expiradas/orfanas >24h ──────────────────────────────────
create or replace function mos.espia_purgar()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_n int;
begin
  delete from mos.espia_sesiones
   where (now() - fecha) > interval '24 hours'
      or (upper(coalesce(estado,'')) = 'CERRADA' and (now() - fecha) > interval '2 hours');
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('borradas', v_n));
end;
$fn$;

do $$ declare f text; begin
  foreach f in array array['espia_crear_sesion(jsonb)','espia_subir_oferta(jsonb)','espia_leer_oferta(jsonb)',
    'espia_subir_respuesta(jsonb)','espia_leer_respuesta(jsonb)','espia_agregar_ice(jsonb)','espia_leer_ice(jsonb)',
    'espia_estado(jsonb)','espia_reportar_streams(jsonb)','espia_cerrar_sesion(jsonb)','espia_subir_reneg_oferta(jsonb)',
    'espia_leer_reneg_oferta(jsonb)','espia_subir_reneg_respuesta(jsonb)','espia_leer_reneg_respuesta(jsonb)']
  loop
    execute 'revoke all on function mos.'||f||' from public';
    execute 'grant execute on function mos.'||f||' to authenticated';
  end loop;
  execute 'grant execute on function mos.espia_purgar() to service_role';
end $$;
