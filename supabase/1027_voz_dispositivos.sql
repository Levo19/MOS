-- 1027 · mos.voz_dispositivos: lista de equipos ACTIVOS (ME+WH) para el modal de mensaje de voz (12-sep-2026).
-- Devuelve NOMBRES (usuario del día + equipo + zona), no UUIDs, para que el admin sepa a quién le habla.

create or replace function mos.voz_dispositivos(p jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare v_arr jsonb;
begin
  if coalesce(me.jwt_app(),'') <> 'MOS' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_agg(
           jsonb_build_object('deviceId',id_dispositivo,'app',app_lbl,'usuario',usuario,'equipo',equipo,
                              'zona',zona,'estacion',estacion,'ultconx',ultconx,'mins',mins)
           order by app_lbl, ultima_conexion desc), '[]'::jsonb)
    into v_arr
  from (
    select d.id_dispositivo,
           case when d.app='warehouseMos' then 'WH' else 'ME' end                              as app_lbl,
           coalesce((select ld.nombre from mos.liquidaciones_dia ld
                       where ld.device_id = d.id_dispositivo
                         and ld.ts_creado::date = (now() at time zone 'America/Lima')::date
                       order by ld.ts_creado desc limit 1), '')                                 as usuario,
           coalesce(nullif(btrim(d.nombre_equipo),''), left(d.id_dispositivo,8))                 as equipo,
           coalesce(d.ultima_zona,'')                                                            as zona,
           coalesce(d.ultima_estacion,'')                                                        as estacion,
           to_char(d.ultima_conexion at time zone 'America/Lima','MM-DD HH24:MI')                as ultconx,
           floor(extract(epoch from (now() - d.ultima_conexion))/60)::int                        as mins,
           d.ultima_conexion
    from mos.dispositivos d
    where upper(coalesce(d.estado,'')) = 'ACTIVO'
      and d.app in ('mosExpress','warehouseMos')
      and d.ultima_conexion > now() - interval '2 days'
  ) s;
  return jsonb_build_object('ok',true,'data',v_arr);
end;
$function$;

grant execute on function mos.voz_dispositivos(jsonb) to authenticated;
select '1027 voz_dispositivos listo' ok;
