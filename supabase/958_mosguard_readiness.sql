-- [958] MosGuard · "readiness": el equipo reporta qué permisos/exenciones tiene concedidos y MOS
-- analiza si está LISTO para el anti-robo (arranque con app cerrada, cámara, mic, GPS) o qué le falta,
-- con pistas por fabricante. Los flags los manda el latido (Latido.kt, rama guard).

alter table mos.yape_dispositivos
  add column if not exists perm_cam     boolean,
  add column if not exists perm_mic     boolean,
  add column if not exists perm_ubi     boolean,
  add column if not exists perm_overlay boolean,
  add column if not exists perm_bat     boolean,
  add column if not exists perm_admin   boolean;

-- yape_latido: persistir los flags SIN tocar el resto (inserta en el UPDATE SET, idempotente)
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('mos.yape_latido(jsonb)'::regprocedure);
  if position('perm_cam' in v_def) = 0 then
    v_def := replace(v_def,
      'sim_numero   = coalesce(v_sim_num, sim_numero),',
      'sim_numero   = coalesce(v_sim_num, sim_numero),' || chr(10) ||
      '         perm_cam     = coalesce((p->>''permCam'')::boolean, perm_cam),' || chr(10) ||
      '         perm_mic     = coalesce((p->>''permMic'')::boolean, perm_mic),' || chr(10) ||
      '         perm_ubi     = coalesce((p->>''permUbi'')::boolean, perm_ubi),' || chr(10) ||
      '         perm_overlay = coalesce((p->>''permOverlay'')::boolean, perm_overlay),' || chr(10) ||
      '         perm_bat     = coalesce((p->>''permBat'')::boolean, perm_bat),' || chr(10) ||
      '         perm_admin   = coalesce((p->>''permAdmin'')::boolean, perm_admin),');
    execute v_def;
  end if;
end $$;

-- yape_guard_estado: exponer los flags (MOS hace el análisis + pistas por marca)
CREATE OR REPLACE FUNCTION mos.yape_guard_estado(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      'bateria', d.bateria, 'cargando', d.cargando, 'redTipo', d.red, 'senal', d.senal,
      'teleHaceMin', case when d.tele_ts is null then null else round(extract(epoch from (now()-d.tele_ts))/60)::int end,
      'simOperador', coalesce(d.sim_operador,''), 'simNumero', coalesce(d.sim_numero,''),
      'simAlertaHaceMin', case when d.sim_alerta_ts is null then null else round(extract(epoch from (now()-d.sim_alerta_ts))/60)::int end,
      'alarmaSeg', case when d.alarma_hasta is not null and d.alarma_hasta > now() then round(extract(epoch from (d.alarma_hasta-now())))::int else 0 end,
      'audioSeg', case when d.audio_live_hasta is not null and d.audio_live_hasta > now() then round(extract(epoch from (d.audio_live_hasta-now())))::int else 0 end,
      -- [958] readiness: permisos concedidos en el equipo (null = equipo viejo que aún no reporta)
      'permCam', d.perm_cam, 'permMic', d.perm_mic, 'permUbi', d.perm_ubi,
      'permOverlay', d.perm_overlay, 'permBat', d.perm_bat, 'permAdmin', d.perm_admin,
      'permNotif', coalesce(d.permiso_ok,false)
    ) order by d.guard_estado desc, d.activo desc, d.nombre), '[]'::jsonb) into v_out
    from mos.yape_dispositivos d;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('equipos', v_out));
end $function$;

select '958 readiness listo' as ok;
