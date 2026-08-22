-- [890b] El panel MOS ahora muestra marca + versión de Android del equipo (specs que manda el APK
-- en el auto-registro, SQL 890). Solo agrega 'marca' y 'so' al JSON de yape_guard_estado. Idéntico
-- al resto — no toca nada más.
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
      'version', coalesce(d.version_name,'')
    ) order by d.guard_estado desc, d.activo desc, d.nombre), '[]'::jsonb) into v_out
    from mos.yape_dispositivos d;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('equipos', v_out));
end $function$;

select 'yape_guard_estado +marca/so listo' as ok;
