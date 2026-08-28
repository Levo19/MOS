-- [957] MosGuard · la sesión de espía se ENTREGA de forma fiable.
-- Bug: `yape_latido` devolvía espiaSesion solo si `guard_espia_ts > now() - 3 min`, pero el equipo
-- late cada ~10 min → la orden EXPIRABA casi siempre antes de que el celular la recibiera (quedaba en
-- "CONECTANDO" para siempre). Diagnóstico real del Celular LEVO: master_cerro con cand=0 porque el
-- equipo nunca llegó a unirse a una sesión abierta.
-- Cura: espiaSesion es ONE-SHOT (se lee el valor PREVIO y se apaga en el mismo UPDATE, igual que
-- bloquear_pedido) con ventana de respaldo de 15 min → el primer latido tras el pedido la entrega
-- UNA vez y no se re-dispara en latidos siguientes. Todo lo demás (dinero/Yapes/telemetría) intacto.
CREATE OR REPLACE FUNCTION mos.yape_latido(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_sec text := coalesce(p->>'secreto',''); v_id bigint; v_estado text; v_foto boolean; v_live timestamptz; v_cap boolean; v_esp text; v_esp_ts timestamptz;
        v_lat double precision; v_lon double precision;
        v_bat smallint; v_carg boolean; v_red text; v_senal smallint;
        v_sim text; v_sim_op text; v_sim_num text; v_sim_old text; v_nom text; v_zona text;
        v_bloq_prev boolean;
        v_alarma timestamptz; v_msg_txt text; v_msg_hasta timestamptz; v_audio timestamptz; v_esp_audio boolean;
        v_esp_fresca boolean;
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

  -- estado PREVIO (SIM anterior para detectar cambio de chip + pedidos one-shot: bloqueo y ESPÍA)
  select sim_serial, nombre, zona, coalesce(bloquear_pedido,false),
         guard_espia_sesion, guard_espia_ts, coalesce(guard_espia_audio,false)
    into v_sim_old, v_nom, v_zona, v_bloq_prev,
         v_esp, v_esp_ts, v_esp_audio
    from mos.yape_dispositivos where activo and secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex');

  -- ¿hay una sesión de espía pendiente y aún vigente (respaldo 15 min)?
  v_esp_fresca := v_esp is not null and v_esp_ts is not null and v_esp_ts > now() - interval '15 minutes';

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
         bloquear_pedido = false,
         -- la sesión de espía es one-shot: si es fresca, se entrega (v_esp) y se apaga para no re-dispararse
         guard_espia_sesion = case when v_esp_fresca then null else guard_espia_sesion end,
         guard_espia_ts     = case when v_esp_fresca then null else guard_espia_ts end,
         guard_espia_audio  = case when v_esp_fresca then false else guard_espia_audio end
   where activo and secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex')
   returning id, guard_estado, guard_foto_pedida, guard_live_hasta, captura_yapes,
             alarma_hasta, mensaje_texto, mensaje_hasta, audio_live_hasta
        into v_id, v_estado, v_foto, v_live, v_cap,
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
    'espiaSesion', case when v_esp_fresca then v_esp else '' end,
    'espiaAudio', case when v_esp_fresca then coalesce(v_esp_audio,false) else false end,
    -- comandos nativos
    'alarmaSeg', case when v_alarma is not null and v_alarma > now() then extract(epoch from (v_alarma-now()))::int else 0 end,
    'mensaje', case when v_msg_hasta is not null and v_msg_hasta > now() then coalesce(v_msg_txt,'') else '' end,
    'bloquear', coalesce(v_bloq_prev, false),
    'audioSeg', case when v_audio is not null and v_audio > now() then extract(epoch from (v_audio-now()))::int else 0 end);
end $function$;

select 'yape_latido espia one-shot 15min · 957 listo' as ok;
