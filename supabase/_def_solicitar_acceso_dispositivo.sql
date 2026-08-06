CREATE OR REPLACE FUNCTION mos.solicitar_acceso_dispositivo(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id text := btrim(coalesce(p->>'id_dispositivo',''));
  v_app text := btrim(coalesce(p->>'app',''));
  v_ua text := coalesce(p->>'user_agent','');
  v_nombre text := coalesce(p->>'nombre_equipo', null);
  d mos.dispositivos%rowtype; v_age numeric; v_pend int;
  c_cuota constant int := 20;
begin
  if v_id !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false);
  end if;
  select * into d from mos.dispositivos where id_dispositivo = v_id for update;

  if found and upper(coalesce(d.estado,''))='ACTIVO' then
    update mos.dispositivos set ultima_conexion=now() where id_dispositivo=v_id;
    return jsonb_build_object('ok', true, 'estado', 'ACTIVO', 'autorizado', true);
  end if;

  -- cooldown 60s: si ya hay una solicitud reciente, NO re-enviar (anti-spam)
  if found and upper(coalesce(d.estado,''))='PENDIENTE_APROBACION' and d.pendiente_desde is not null then
    v_age := extract(epoch from (now() - d.pendiente_desde));
    if v_age < 60 then
      return jsonb_build_object('ok', true, 'estado', 'PENDIENTE_APROBACION', 'autorizado', false,
        'cooldown', true, 'retry_seg', greatest(1, ceil(60 - v_age))::int);
    end if;
  end if;

  -- cuota anti-DoS: máx. solicitudes nuevas por hora (no aplica si SOLO refresca una PENDIENTE propia)
  if (not found) or upper(coalesce(d.estado,'')) <> 'PENDIENTE_APROBACION' then
    select count(*) into v_pend from mos.dispositivos
     where estado='PENDIENTE_APROBACION' and pendiente_desde > now() - interval '1 hour';
    if v_pend >= c_cuota then
      return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false);
    end if;
  end if;

  -- crear/refrescar la solicitud: misma fila/equipo, nuevo pendiente_desde (la anterior se reemplaza)
  insert into mos.dispositivos (id_dispositivo, nombre_equipo, app, estado, ultima_conexion, pendiente_desde, user_agent)
  values (v_id, v_nombre, nullif(v_app,''), 'PENDIENTE_APROBACION', now(), now(), nullif(v_ua,''))
  on conflict (id_dispositivo) do update
     set estado='PENDIENTE_APROBACION', ultima_conexion=now(), pendiente_desde=now(),
         user_agent=coalesce(nullif(excluded.user_agent,''), mos.dispositivos.user_agent),
         app=coalesce(nullif(excluded.app,''), mos.dispositivos.app),
         nombre_equipo=coalesce(nullif(excluded.nombre_equipo,''), mos.dispositivos.nombre_equipo);

  begin
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('roles', case when upper(coalesce(v_app,'')) in ('MOS','')
                     then jsonb_build_array('MASTER') else jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN') end),
      'titulo', '🔓 Dispositivo pide acceso',
      'cuerpo', coalesce(nullif(v_app,''),'app') || ' · ' || coalesce(nullif(v_nombre,''),'equipo') || ' · aprueba en el panel',
      'data', jsonb_build_object('tipo','device_pendiente','deviceId',v_id)));
  exception when others then null; end;

  return jsonb_build_object('ok', true, 'estado', 'PENDIENTE_APROBACION', 'autorizado', false, 'enviado', true);
exception when others then
  return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false);
end; $function$
