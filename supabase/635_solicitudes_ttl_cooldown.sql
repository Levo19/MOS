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

  -- [635] cooldown 5 MIN (decisión dueño: nada de bombardeo). El reenvío tras el
  -- cooldown PISA la solicitud anterior (misma fila, pendiente_desde nuevo).
  if found and upper(coalesce(d.estado,''))='PENDIENTE_APROBACION' and d.pendiente_desde is not null then
    v_age := extract(epoch from (now() - d.pendiente_desde));
    if v_age < 300 then
      return jsonb_build_object('ok', true, 'estado', 'PENDIENTE_APROBACION', 'autorizado', false,
        'cooldown', true, 'retry_seg', greatest(1, ceil(300 - v_age))::int);
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


CREATE OR REPLACE FUNCTION mos.solicitar_extension_horario(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_id   text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_dev  text := nullif(btrim(coalesce(p->>'deviceId', p->>'device_id','')),'');
  v_app  text := nullif(btrim(coalesce(p->>'app','')),'');
  v_min  int  := 60;                         -- [511] 1 HORA fija (ignora el minutos del cliente)
  v_mot  text := left(btrim(coalesce(p->>'motivo','Sin motivo')), 200);
  v_alerta text;
  -- [534] identidad + estado de sesión del equipo
  v_quien   text := '';
  v_sestado text := 'SIN_SESION';
  v_sdetalle text := '';
  v_caja    record;
  v_disp    record;
begin
  if v_claim not in ('mosExpress','MOS','warehouseMos','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null and v_dev is null then
    return jsonb_build_object('ok',false,'error','Requiere deviceId o idPersonal');
  end if;

  -- [534] contexto del equipo: última caja ME del device (ABIERTA primero) + registro del dispositivo
  if v_dev is not null then
    select c.vendedor, upper(coalesce(c.estado,'')) as estado, c.fecha_apertura, c.fecha_cierre
      into v_caja
      from me.cajas c
     where c.dispositivo_id = v_dev
     order by (upper(coalesce(c.estado,'')) = 'ABIERTA') desc, c.fecha_apertura desc
     limit 1;
    select nombre_equipo, nullif(btrim(coalesce(ultima_sesion,'')),'') as ultima_sesion, ultima_conexion
      into v_disp
      from mos.dispositivos where id_dispositivo = v_dev limit 1;

    if v_caja.vendedor is not null then
      v_quien := v_caja.vendedor;
      if v_caja.estado = 'ABIERTA' then
        v_sestado  := 'ABIERTA';
        v_sdetalle := 'sesión ABIERTA · últ. actividad '
          || coalesce(to_char(coalesce(v_disp.ultima_conexion, v_caja.fecha_apertura) at time zone 'America/Lima','HH24:MI'),'—');
      else
        v_sestado  := 'CERRADA';
        v_sdetalle := 'sesión CERRADA (cerró '
          || coalesce(to_char(v_caja.fecha_cierre at time zone 'America/Lima','DD-Mon HH24:MI'),'—') || ')';
      end if;
    elsif v_disp.ultima_sesion is not null then
      v_quien    := v_disp.ultima_sesion || ' (último logeo)';
      v_sdetalle := 'sin sesión · últ. conexión '
        || coalesce(to_char(v_disp.ultima_conexion at time zone 'America/Lima','DD-Mon HH24:MI'),'—');
    else
      v_quien    := coalesce(v_disp.nombre_equipo, 'equipo sin registro');
      v_sdetalle := 'sin sesión previa en este equipo';
    end if;
  end if;

  -- [534] id_personal: el que venga → o mapear el nombre resuelto → o DEV:<uuid> (trazable;
  -- el desbloqueo ES por UUID, la identidad es informativa para el admin)
  if v_id is null then
    select p2.id_personal into v_id from mos.personal p2
     where lower(btrim(p2.nombre || ' ' || coalesce(p2.apellido,''))) = lower(btrim(coalesce(v_caja.vendedor,'')))
        or lower(btrim(p2.nombre)) = lower(btrim(coalesce(v_caja.vendedor, v_disp.ultima_sesion, '')))
     limit 1;
    if v_id is null then v_id := 'DEV:' || v_dev; end if;
  end if;

  -- [635] Anti-bombardeo con reemplazo (decisión dueño):
  --   · < 5 min de la anterior PENDIENTE → cooldown (segundos restantes al cliente)
  --   · ≥ 5 min → la nueva PISA a la anterior (REEMPLAZADA) — el admin ve solo la fresca
  declare v_prev record; v_age2 numeric;
  begin
    select id_alerta, fecha into v_prev from mos.seguridad_alertas
     where tipo='EXTENSION_HORARIO_PENDIENTE' and upper(coalesce(estado,''))='PENDIENTE'
       and (id_personal = v_id or (v_dev is not null and id_dispositivo = v_dev))
     order by fecha desc limit 1;
    if v_prev.id_alerta is not null then
      v_age2 := extract(epoch from (now() - v_prev.fecha));
      if v_age2 < 300 then
        return jsonb_build_object('ok',true,'data',jsonb_build_object('yaExistia',true,
          'cooldown',true,'retrySeg', greatest(1, ceil(300 - v_age2))::int));
      end if;
      update mos.seguridad_alertas set estado='REEMPLAZADA' where id_alerta = v_prev.id_alerta;
    end if;
  end;

  v_alerta := 'SEG' || (extract(epoch from clock_timestamp())*1000)::bigint::text || upper(substr(md5(random()::text),1,4));
  insert into mos.seguridad_alertas(id_alerta, tipo, id_dispositivo, id_personal, fecha, descripcion, prioridad, estado, datos_extra_json)
  values (v_alerta, 'EXTENSION_HORARIO_PENDIENTE', v_dev, v_id, now(),
          'Solicita extensión 1h · ' || v_mot
            || case when v_quien <> '' then ' · 👤 ' || v_quien || ' · ' || v_sdetalle else '' end,
          'MEDIA', 'PENDIENTE',
          jsonb_build_object('minutos', v_min, 'motivo', v_mot, 'deviceId', coalesce(v_dev,''),
                             'app', coalesce(v_app,''),
                             'solicitante', v_quien, 'sesionEstado', v_sestado, 'sesionDetalle', v_sdetalle,
                             'solicitadoEn', to_char(now(),'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idAlerta', v_alerta, 'pendiente', true, 'minutos', v_min,
           'solicitante', v_quien, 'sesion', v_sdetalle));
end; $function$


CREATE OR REPLACE FUNCTION mos.vencer_extensiones_horario()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_n int;
begin
  update mos.seguridad_alertas
     set estado = 'VENCIDA'
   where tipo = 'EXTENSION_HORARIO_PENDIENTE'
     and estado = 'PENDIENTE'
     and fecha < now() - interval '1 hour';   -- [635] TTL 1 HORA (decisión dueño)
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'vencidas', v_n);
end;
$function$


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
      'Pendiente_Desde', case when d.pendiente_desde is null then '' else to_char(d.pendiente_desde at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') end,
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
