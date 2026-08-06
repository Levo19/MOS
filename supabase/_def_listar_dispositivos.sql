CREATE OR REPLACE FUNCTION mos.listar_dispositivos(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_app text := nullif(btrim(coalesce(p->>'app','')), '');
  v_est text := nullif(btrim(coalesce(p->>'estado','')), '');
  v_arr jsonb;
begin
  select coalesce(jsonb_agg(obj order by obj->>'Ultima_Conexion' desc nulls last), '[]'::jsonb)
    into v_arr
  from (
    select jsonb_build_object(
      'ID_Dispositivo',            d.id_dispositivo,
      'Nombre_Equipo',             coalesce(d.nombre_equipo,''),
      'App',                       coalesce(d.app,''),
      'Estado',                    coalesce(d.estado,''),
      'Ultima_Conexion',           mos._iso_z(d.ultima_conexion),
      'Ultima_Zona',               coalesce(d.ultima_zona,''),
      'Ultima_Estacion',           coalesce(d.ultima_estacion,''),
      'Ultima_Sesion',             coalesce(d.ultima_sesion,''),
      'Permisos_JSON',             coalesce(d.permisos_json::text,''),
      'Permisos_LastUpdate',       mos._iso_z(d.permisos_lastupdate),
      'Forzar_Wizard',             coalesce(d.forzar_wizard,false),
      'Suspendido_Desde',          mos._iso_z(d.suspendido_desde),
      'Forzar_Logout',             coalesce(d.forzar_logout,false),
      'Logout_Auto_Ts',            mos._iso_z(d.logout_auto_ts),
      'Forzar_Push',               coalesce(d.forzar_push,false),
      'Forzar_ReVerify',           coalesce(d.forzar_reverify,false),
      'Inactivo_Alerta_Ts',        mos._iso_z(d.inactivo_alerta_ts),
      'Cancelado_Auto_Ts',         mos._iso_z(d.cancelado_auto_ts),
      'User_Agent',                coalesce(d.user_agent,''),
      'Fecha_Caducidad',           mos._iso_z(d.fecha_caducidad),
      'Desbloqueo_Temporal_Hasta', mos._iso_z(d.desbloqueo_temporal_hasta),
      'FCM_Token',                 coalesce(d.fcm_token,''),
      'Alerta_Seguridad',          coalesce(d.alerta_seguridad,''),
      'Alerta_Seguridad_Revisada', coalesce(d.alerta_seguridad_revisada,false),
      'Forzar_Horario_Hasta',      mos._iso_z(d.forzar_horario_hasta),
      'Razon_Bloqueo',             coalesce(d.razon_bloqueo,''),
      'Bloqueado_Desde',           mos._iso_z(d.bloqueado_desde)
    ) as obj
    from mos.dispositivos d
    where (v_app is null or d.app = v_app)
      and (v_est is null or d.estado = v_est)
  ) s;
  -- [170] mergear frescura → el gate del frontend (_fresh===true) pasa y la lista se queda 100% en Supabase.
  return jsonb_build_object('ok',true,'data', v_arr) || mos._frescura_sombra();
end;
$function$
