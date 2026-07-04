-- 343d: push best-effort device-aprobado (#13 -> admins). Cero-GAS.
CREATE OR REPLACE FUNCTION mos.aprobar_dispositivo(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id       text    := btrim(coalesce(p->>'id_dispositivo',''));
  v_clave    text    := coalesce(p->>'clave_admin','');
  v_app      text    := btrim(coalesce(p->>'app',''));
  v_nombre   text    := coalesce(p->>'nombre_equipo', null);
  v_react    boolean := coalesce((p->>'es_reactivar')::boolean, false);
  v_es_mos   boolean;
  v_accion   text;
  v_lock     jsonb;
  v_estado   text;
  v_val      jsonb;
begin
  -- (0) formato del id (anti-basura/enumeración)
  if v_id !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Solicitud inválida');
  end if;

  -- (1) LOCKOUT: si el device está bloqueado por fuerza bruta → rechazo SIN evaluar bcrypt (corta el ataque).
  v_lock := mos._auth_lockout_estado(v_id);
  if (v_lock->>'locked')::boolean then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'DEMASIADOS_INTENTOS',
      'retry_seg', (v_lock->>'retry_seg')::int);
  end if;

  -- (2) el device debe EXISTIR y estar en un estado aprobable (reduce el espacio: no se aprueban ids inventados).
  select estado into v_estado from mos.dispositivos where id_dispositivo = v_id;
  if v_estado is null or v_estado not in ('PENDIENTE_APROBACION','SUSPENDIDO','CANCELADO_AUTO','INACTIVO') then
    -- contamos como intento fallido (un atacante probando ids+claves no debe distinguir "id malo" de "clave mala").
    perform mos._auth_registrar_intento(v_id, 'APROBAR_DISPOSITIVO', false);
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Solicitud inválida');
  end if;

  -- (3) acción/nivel: MOS in-situ = master-only; WH/ME = admin. Reactivar = admin.
  v_es_mos := upper(coalesce(v_app,'')) in ('MOS','');
  if v_react then
    v_accion := 'REACTIVAR_DISPOSITIVO_SUSPENDIDO';
  elsif v_es_mos then
    v_accion := 'APROBAR_DISPOSITIVO_INSITU_MOS';     -- master-only (catálogo 50)
  else
    v_accion := 'APROBAR_DISPOSITIVO_INSITU';          -- admin (WH/ME)
  end if;

  -- (4) validar clave admin (bcrypt + niveles + auditoría única) vía la CORE (sin gate de claim).
  v_val := mos._validar_clave_admin_core(v_clave, v_accion, v_id, v_app, v_id,
             'Aprobación de dispositivo' || case when v_react then ' (reactivar)' else '' end, null, null);

  if coalesce((v_val->>'autorizado')::boolean, false) <> true then
    perform mos._auth_registrar_intento(v_id, 'APROBAR_DISPOSITIVO', false);   -- cuenta para el lockout
    -- eco del error de la core (NIVEL_INSUFICIENTE / Clave incorrecta / formato), sin filtrar nada extra.
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', coalesce(v_val->>'error','Clave incorrecta'),
      'requiere', v_val->>'requiere');
  end if;

  -- (5) AUTORIZADO → activar (idempotente: re-aprobar un ACTIVO no rompe). Eco del device_id.
  perform mos._auth_registrar_intento(v_id, 'APROBAR_DISPOSITIVO', true);
  update mos.dispositivos
     set estado           = 'ACTIVO',
         nombre_equipo    = coalesce(nullif(v_nombre,''), nombre_equipo),
         app              = coalesce(nullif(v_app,''), app),
         suspendido_desde = null,
         ultima_conexion  = now()
   where id_dispositivo = v_id;

  begin
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
      'titulo', '✅ Dispositivo aprobado',
      'cuerpo', coalesce(v_app,'app') || ' · ' || coalesce(nullif(v_nombre,''),'equipo') || ' · ya puede operar',
      'data', jsonb_build_object('tipo','device_aprobado','deviceId',v_id)));
  exception when others then null;
  end;
  return jsonb_build_object('ok', true, 'autorizado', true, 'estado', 'ACTIVO',
    'device_id', v_id, 'aprobado_por', v_val->>'nombre', 'id_accion', v_val->>'id_accion');
exception when others then
  return jsonb_build_object('ok', false, 'error', 'ERROR_APROBACION');
end;
$function$
;
