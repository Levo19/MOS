-- [944b] Escucha SOLO-AUDIO (ambiental): reusa la sesión de espía pero el equipo manda solo micrófono
-- (más liviano, no necesita cámara). El master pide con soloAudio=true; el latido se lo dice al equipo.
alter table mos.yape_dispositivos add column if not exists guard_espia_audio boolean default false;

create or replace function mos.yape_guard_espia_set(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_nombre text := nullif(btrim(coalesce(p->>'nombre','')),''); v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),'');
        v_audio boolean := coalesce((p->>'soloAudio')::boolean, false); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nombre is null then return jsonb_build_object('ok',false,'error','falta nombre'); end if;
  update mos.yape_dispositivos
     set guard_espia_sesion = v_sid,
         guard_espia_ts = case when v_sid is null then null else now() end,
         guard_espia_audio = case when v_sid is null then false else v_audio end
   where nombre = v_nombre;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','equipo no encontrado'); end if;
  return jsonb_build_object('ok',true);
end $function$;

-- el latido devuelve espiaAudio (solo-audio) junto a la sesión, sin tocar el resto de la lógica
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('mos.yape_latido(jsonb)'::regprocedure);
  -- 1) declarar la variable
  v_def := replace(v_def,
    'v_alarma timestamptz; v_msg_txt text; v_msg_hasta timestamptz; v_audio timestamptz;',
    'v_alarma timestamptz; v_msg_txt text; v_msg_hasta timestamptz; v_audio timestamptz; v_esp_audio boolean;');
  -- 2) traerla en el RETURNING
  v_def := replace(v_def,
    'alarma_hasta, mensaje_texto, mensaje_hasta, audio_live_hasta',
    'alarma_hasta, mensaje_texto, mensaje_hasta, audio_live_hasta, guard_espia_audio');
  v_def := replace(v_def,
    'v_alarma, v_msg_txt, v_msg_hasta, v_audio;',
    'v_alarma, v_msg_txt, v_msg_hasta, v_audio, v_esp_audio;');
  -- 3) exponerla en el JSON de salida (junto a espiaSesion)
  v_def := replace(v_def,
    E'''espiaSesion'', case when v_esp is not null and v_esp_ts is not null and v_esp_ts > now() - interval ''3 minutes'' then v_esp else '''' end,',
    E'''espiaSesion'', case when v_esp is not null and v_esp_ts is not null and v_esp_ts > now() - interval ''3 minutes'' then v_esp else '''' end,\n    ''espiaAudio'', case when v_esp is not null and v_esp_ts is not null and v_esp_ts > now() - interval ''3 minutes'' then coalesce(v_esp_audio,false) else false end,');
  execute v_def;
end $$;

select 'espia audio 944b listo' as ok;
