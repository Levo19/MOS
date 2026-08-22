-- [944] MosGuard NATIVO · backbone. Capacidades que solo el APK nativo puede dar (la web no):
--   TELEMETRÍA (batería/carga/red/señal), SIM (detecta cambio de chip = robo), y COMANDOS remotos
--   (alarma+linterna, mensaje a pantalla, bloqueo, escucha solo-audio). El equipo REPORTA telemetría/SIM
--   en su latido y RECIBE los comandos por el mismo latido (no hay FCM). Los comandos se piden desde MOS.
-- Aditivo y money-safe: no toca captura de Yapes ni producción.

-- ── columnas ──
alter table mos.yape_dispositivos
  add column if not exists bateria       smallint,     -- 0-100
  add column if not exists cargando      boolean,
  add column if not exists red           text,         -- 'wifi' | 'movil' | 'sin'
  add column if not exists senal         smallint,     -- 0-4
  add column if not exists tele_ts       timestamptz,
  add column if not exists sim_serial    text,         -- ICCID/estable del chip
  add column if not exists sim_operador  text,
  add column if not exists sim_numero    text,
  add column if not exists sim_alerta_ts timestamptz,  -- última vez que se detectó cambio de chip
  add column if not exists alarma_hasta  timestamptz,  -- comando: sirena+linterna hasta este epoch
  add column if not exists mensaje_texto text,          -- comando: texto a pantalla completa
  add column if not exists mensaje_hasta timestamptz,
  add column if not exists bloquear_pedido boolean default false,  -- comando one-shot: lockear pantalla
  add column if not exists audio_live_hasta timestamptz;           -- comando: escucha solo-audio

-- ── RPCs de comando (master pide; el equipo lo recoge en su latido) ──
create or replace function mos.yape_guard_alarma(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_nom text := nullif(btrim(coalesce(p->>'nombre','')),''); v_seg int := coalesce(nullif(p->>'seg','')::int, 60); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','falta nombre'); end if;
  update mos.yape_dispositivos
     set alarma_hasta = case when v_seg <= 0 then null else now() + make_interval(secs => least(v_seg, 300)) end
   where nombre = v_nom;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0, 'seg', greatest(v_seg,0));
end $function$;

create or replace function mos.yape_guard_mensaje(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_nom text := nullif(btrim(coalesce(p->>'nombre','')),''); v_txt text := left(btrim(coalesce(p->>'texto','')), 240); v_seg int := coalesce(nullif(p->>'seg','')::int, 120); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null or v_txt = '' then return jsonb_build_object('ok',false,'error','falta nombre o texto'); end if;
  update mos.yape_dispositivos
     set mensaje_texto = v_txt, mensaje_hasta = now() + make_interval(secs => least(greatest(v_seg,10), 600))
   where nombre = v_nom;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0);
end $function$;

create or replace function mos.yape_guard_bloquear(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_nom text := nullif(btrim(coalesce(p->>'nombre','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','falta nombre'); end if;
  update mos.yape_dispositivos set bloquear_pedido = true where nombre = v_nom;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0);
end $function$;

create or replace function mos.yape_guard_audio(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_nom text := nullif(btrim(coalesce(p->>'nombre','')),''); v_seg int := coalesce(nullif(p->>'seg','')::int, 120); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','falta nombre'); end if;
  update mos.yape_dispositivos
     set audio_live_hasta = case when v_seg <= 0 then null else now() + make_interval(secs => least(v_seg, 600)) end
   where nombre = v_nom;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0, 'seg', greatest(v_seg,0));
end $function$;

grant execute on function mos.yape_guard_alarma(jsonb), mos.yape_guard_mensaje(jsonb), mos.yape_guard_bloquear(jsonb), mos.yape_guard_audio(jsonb) to authenticated, anon, service_role;

-- ── latido: reporta telemetría/SIM y devuelve comandos ──
create or replace function mos.yape_latido(p jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_sec text := coalesce(p->>'secreto',''); v_id bigint; v_estado text; v_foto boolean; v_live timestamptz; v_cap boolean; v_esp text; v_esp_ts timestamptz;
        v_lat double precision; v_lon double precision;
        v_bat smallint; v_carg boolean; v_red text; v_senal smallint;
        v_sim text; v_sim_op text; v_sim_num text; v_sim_old text; v_nom text; v_zona text;
        v_bloq_prev boolean;
        v_alarma timestamptz; v_msg_txt text; v_msg_hasta timestamptz; v_audio timestamptz;
begin
  if v_sec = '' then return jsonb_build_object('ok',false,'error','sin secreto'); end if;
  begin v_lat := nullif(p->>'lat','')::double precision; v_lon := nullif(p->>'lon','')::double precision; exception when others then v_lat:=null; v_lon:=null; end;
  begin v_bat := nullif(p->>'bateria','')::smallint; exception when others then v_bat:=null; end;
  begin v_senal := nullif(p->>'senal','')::smallint; exception when others then v_senal:=null; end;
  v_carg := case when p ? 'cargando' then (p->>'cargando')::boolean else null end;
  v_red  := left(nullif(btrim(coalesce(p->>'red','')),''), 8);
  v_sim  := left(nullif(btrim(coalesce(p->>'simSerial','')),''), 40);
  v_sim_op := left(nullif(btrim(coalesce(p->>'simOperador','')),''), 40);
  v_sim_num := left(nullif(btrim(coalesce(p->>'simNumero','')),''), 24);

  -- estado PREVIO (SIM anterior para detectar cambio de chip + pedido de bloqueo pendiente, one-shot)
  select sim_serial, nombre, zona, coalesce(bloquear_pedido,false)
    into v_sim_old, v_nom, v_zona, v_bloq_prev
    from mos.yape_dispositivos where activo and secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex');

  update mos.yape_dispositivos
     set ultimo_latido = now(),
         ultima_señal  = greatest(coalesce(ultima_señal, now()), now()),
         permiso_ok    = coalesce((p->>'permiso')::boolean, permiso_ok),
         pendientes    = coalesce(nullif(p->>'pendientes','')::int, pendientes),
         modelo        = coalesce(nullif(btrim(coalesce(p->>'equipo','')),''), modelo),
         marca         = coalesce(nullif(btrim(coalesce(p->>'marca','')),''), marca),
         so_ver        = coalesce(nullif(btrim(coalesce(p->>'so','')),''), so_ver),
         version_code  = coalesce(nullif(p->>'versionCode','')::int, version_code),
         version_name  = coalesce(nullif(btrim(coalesce(p->>'versionName','')),''), version_name),
         aviso_caido_ts = case when coalesce((p->>'permiso')::boolean, true) then null else aviso_caido_ts end,
         lat        = case when v_lat is not null then v_lat else lat end,
         lon        = case when v_lon is not null then v_lon else lon end,
         ubic_prec_m= case when v_lat is not null then nullif(p->>'precM','')::double precision else ubic_prec_m end,
         ubic_ts    = case when v_lat is not null then now() else ubic_ts end,
         -- telemetría
         bateria    = coalesce(v_bat, bateria),
         cargando   = coalesce(v_carg, cargando),
         red        = coalesce(v_red, red),
         senal      = coalesce(v_senal, senal),
         tele_ts    = case when v_bat is not null or v_red is not null then now() else tele_ts end,
         -- SIM (se guarda siempre; la alerta se calcula con el valor previo)
         sim_serial   = coalesce(v_sim, sim_serial),
         sim_operador = coalesce(v_sim_op, sim_operador),
         sim_numero   = coalesce(v_sim_num, sim_numero),
         sim_alerta_ts = case when v_sim is not null and v_sim_old is not null and v_sim <> v_sim_old then now() else sim_alerta_ts end,
         -- el bloqueo es one-shot: se entrega (v_bloq_prev) y se apaga
         bloquear_pedido = false
   where activo and secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex')
   returning id, guard_estado, guard_foto_pedida, guard_live_hasta, captura_yapes, guard_espia_sesion, guard_espia_ts,
             alarma_hasta, mensaje_texto, mensaje_hasta, audio_live_hasta
        into v_id, v_estado, v_foto, v_live, v_cap, v_esp, v_esp_ts,
             v_alarma, v_msg_txt, v_msg_hasta, v_audio;
  if v_id is null then return jsonb_build_object('ok',false,'error','DISPOSITIVO_NO_AUTORIZADO'); end if;

  -- alerta de cambio de SIM → push SOLO al master (posible robo)
  if v_sim is not null and v_sim_old is not null and v_sim <> v_sim_old then
    begin
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
        'titulo', '📵 Cambiaron el chip de ' || coalesce(v_nom,'un equipo'),
        'cuerpo', 'Nuevo chip' || coalesce(' · ' || v_sim_op, '') || coalesce(' · ' || v_sim_num, '') ||
                  coalesce(' · ' || v_zona, '') || '. Puede ser robo — revisá MosGuard.',
        'data', jsonb_build_object('tipo','sim_cambiada','equipo',v_nom)));
    exception when others then null; end;
  end if;

  return jsonb_build_object('ok',true,
    'capturaYapes', coalesce(v_cap,true),
    'guard', coalesce(v_estado,'NORMAL'),
    'foto',  coalesce(v_foto,false),
    'liveHasta', case when v_live is not null and v_live > now() then extract(epoch from v_live)::bigint else 0 end,
    'espiaSesion', case when v_esp is not null and v_esp_ts is not null and v_esp_ts > now() - interval '3 minutes' then v_esp else '' end,
    -- comandos nativos
    'alarmaSeg', case when v_alarma is not null and v_alarma > now() then extract(epoch from (v_alarma-now()))::int else 0 end,
    'mensaje', case when v_msg_hasta is not null and v_msg_hasta > now() then coalesce(v_msg_txt,'') else '' end,
    'bloquear', coalesce(v_bloq_prev, false),
    'audioSeg', case when v_audio is not null and v_audio > now() then extract(epoch from (v_audio-now()))::int else 0 end);
end $function$;

-- ── panel: exponer telemetría + SIM ──
create or replace function mos.yape_guard_estado(p jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_out jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'nombre', d.nombre, 'zona', coalesce(d.zona,''), 'modelo', coalesce(d.modelo,''),
      'marca', coalesce(d.marca,''), 'so', coalesce(d.so_ver,''),
      'guardEstado', coalesce(d.guard_estado,'NORMAL'), 'capturaYapes', coalesce(d.captura_yapes,true),
      'guardDesde', to_char(d.guard_desde at time zone 'America/Lima','YYYY-MM-DD HH24:MI'),
      'lat', d.lat, 'lon', d.lon, 'precM', d.ubic_prec_m,
      'ubicHace', case when d.ubic_ts is null then null else round(extract(epoch from (now()-d.ubic_ts))/60)::int end,
      'ultimoLatidoHace', case when d.ultimo_latido is null then null else round(extract(epoch from (now()-d.ultimo_latido))/60)::int end,
      'latidoEstado', case when not d.activo then 'REVOCADO' when d.ultimo_latido is null then 'NUNCA'
                          when d.ultimo_latido > now() - interval '30 minutes' then 'VIVO' else 'CAIDO' end,
      'fotoPedida', coalesce(d.guard_foto_pedida,false),
      'liveSeg', case when d.guard_live_hasta is not null and d.guard_live_hasta > now() then round(extract(epoch from (d.guard_live_hasta-now())))::int else 0 end,
      'mediaPath', d.guard_media_path,
      'mediaHaceSeg', case when d.guard_media_ts is null then null else round(extract(epoch from (now()-d.guard_media_ts)))::int end,
      'version', coalesce(d.version_name,''),
      -- telemetría + SIM
      'bateria', d.bateria, 'cargando', d.cargando, 'redTipo', d.red, 'senal', d.senal,
      'teleHaceMin', case when d.tele_ts is null then null else round(extract(epoch from (now()-d.tele_ts))/60)::int end,
      'simOperador', coalesce(d.sim_operador,''), 'simNumero', coalesce(d.sim_numero,''),
      'simAlertaHaceMin', case when d.sim_alerta_ts is null then null else round(extract(epoch from (now()-d.sim_alerta_ts))/60)::int end,
      'alarmaSeg', case when d.alarma_hasta is not null and d.alarma_hasta > now() then round(extract(epoch from (d.alarma_hasta-now())))::int else 0 end,
      'audioSeg', case when d.audio_live_hasta is not null and d.audio_live_hasta > now() then round(extract(epoch from (d.audio_live_hasta-now())))::int else 0 end
    ) order by d.guard_estado desc, d.activo desc, d.nombre), '[]'::jsonb) into v_out
    from mos.yape_dispositivos d;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('equipos', v_out));
end $function$;

select 'backbone nativo 944 listo' as ok;
