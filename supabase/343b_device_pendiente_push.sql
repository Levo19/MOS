-- 343b: push best-effort a master en device nuevo (registrar_dispositivo #12). Cero-GAS.
CREATE OR REPLACE FUNCTION mos.registrar_dispositivo(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id      text := btrim(coalesce(p->>'id_dispositivo',''));
  v_app     text := btrim(coalesce(p->>'app',''));
  v_ua      text := coalesce(p->>'user_agent','');
  v_nombre  text := coalesce(p->>'nombre_equipo', null);
  v_es_mos  boolean;
  v_existe  text;          -- estado actual si la fila ya existe
  v_pend    int;
  c_cuota_pend constant int := 20;     -- máx. PENDIENTES nuevos por hora (anti-DoS de almacenamiento)
begin
  -- (1) validación estricta del id (UUID v-cualquiera de 36 chars con guiones) → rechaza basura/enumeración.
  if v_id !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false);  -- respuesta genérica
  end if;
  -- 'MOS' || '' se tratan como MOS (igual que Config.gs:2283); el master MOS no se auto-crea PENDIENTE.
  v_es_mos := upper(v_app) in ('MOS','');

  -- (2) ¿ya existe? Solo refresca heartbeat; NUNCA re-pendientea un device ACTIVO/INACTIVO/SUSPENDIDO por
  -- reconectar (esos son decisión del master). EXCEPCIÓN: CANCELADO_AUTO = un PENDIENTE que el cron caducó
  -- por >20h sin aprobar; al reconectar el device se REABRE a PENDIENTE_APROBACION (paridad con GAS
  -- Config.gs:957/1083). Sin esto, un device que pidió acceso el viernes y se aprueba el lunes quedaría
  -- atascado al activar el cutover (bug de disponibilidad cazado por la revisión 40x de Fase 3a).
  select estado into v_existe from mos.dispositivos where id_dispositivo = v_id;
  if v_existe is not null then
    if v_existe = 'CANCELADO_AUTO' then
      update mos.dispositivos
         set estado = 'PENDIENTE_APROBACION', ultima_conexion = now(),
             user_agent = coalesce(nullif(v_ua,''), user_agent),
             app        = coalesce(nullif(v_app,''), app)
       where id_dispositivo = v_id;
      return jsonb_build_object('ok', true, 'estado', 'PENDIENTE_APROBACION',
        'autorizado', false, 'nuevo', false, 'reabierto', true);
    end if;
    update mos.dispositivos
       set ultima_conexion = now(),
           user_agent      = coalesce(nullif(v_ua,''), user_agent),
           app             = coalesce(nullif(v_app,''), app),
           suspendido_desde = case when estado='ACTIVO' then null else suspendido_desde end
     where id_dispositivo = v_id;
    return jsonb_build_object('ok', true, 'estado', v_existe,
      'autorizado', (v_existe='ACTIVO'), 'nuevo', false);
  end if;

  -- (3) device nuevo. MOS: NO se auto-crea PENDIENTE (el master se aprueba in-situ) → devolver genérico sin insertar.
  if v_es_mos then
    return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false, 'nuevo', false);
  end if;

  -- (4) ANTI-SPAM: cuota de PENDIENTES creados en la última hora. Si se supera → respuesta genérica SIN crear más.
  select count(*) into v_pend from mos.dispositivos
   where estado = 'PENDIENTE_APROBACION' and ultima_conexion > now() - interval '1 hour';
  if v_pend >= c_cuota_pend then
    return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false, 'nuevo', false);
  end if;

  -- (5) insert idempotente. on conflict: si otra tx lo creó en la carrera, solo refresca (no duplica, no re-pendientea).
  insert into mos.dispositivos (id_dispositivo, nombre_equipo, app, estado, ultima_conexion, user_agent)
  values (v_id, v_nombre, v_app, 'PENDIENTE_APROBACION', now(), nullif(v_ua,''))
  on conflict (id_dispositivo) do update
     set ultima_conexion = now(),
         user_agent      = coalesce(nullif(excluded.user_agent,''), mos.dispositivos.user_agent);

  -- [CERO-GAS push #12] aviso a MASTER de dispositivo NUEVO pidiendo acceso. Best-effort, solo en device nuevo.
  begin
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
      'titulo', '🔓 Dispositivo nuevo pide acceso',
      'cuerpo', coalesce(v_app,'app') || ' · ' || coalesce(nullif(v_nombre,''),'equipo') || ' · aprueba o rechaza en el panel',
      'data', jsonb_build_object('tipo','device_pendiente','deviceId',v_id)));
  exception when others then null;
  end;
  return jsonb_build_object('ok', true, 'estado', 'PENDIENTE_APROBACION', 'autorizado', false, 'nuevo', true);
exception when others then
  -- fail-closed + anti-enumeración: cualquier error → respuesta genérica (no revela el motivo).
  return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false);
end;
$function$
;
