-- 334_mos_extender_horario_dispositivo.sql
-- [CERO-GAS auth] Reemplaza gas/Config.gs::extenderHorarioDispositivo. Extensión in-situ de horario por
-- dispositivo (admin/master, clave 8 díg). Setea mos.dispositivos.desbloqueo_temporal_hasta = max(actual,
-- now+minutos), preserva la extensión mayor vigente, audita vía _validar_clave_admin_core.
-- Patrón IDÉNTICO a aprobar/revocar_dispositivo (SQL 100): anon-callable, gate real = bcrypt de la clave.
-- Shape de retorno EXACTO al GAS (extensor-horario.js lee j.data.autorizado / d.hastaTs / d.aprobadoPor /
-- d.preservoExistente / d.error). desbloqueo_temporal_hasta = timestamptz.
create or replace function mos.extender_horario_dispositivo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_dev  text := nullif(btrim(coalesce(p->>'deviceId','')), '');
  v_cla  text := coalesce(p->>'claveAdmin','');
  v_app  text := coalesce(p->>'app','');
  v_min  int  := coalesce(nullif(btrim(coalesce(p->>'minutos','')),'')::int, 0);
  v_actual  timestamptz;
  v_nuevo   timestamptz;
  v_hasta   timestamptz;
  v_preservo boolean;
  v_auth   jsonb;
  v_nombre text;
begin
  if v_dev is null      then return jsonb_build_object('ok', false, 'error', 'Requiere deviceId'); end if;
  if btrim(v_cla) = ''  then return jsonb_build_object('ok', false, 'error', 'Requiere claveAdmin'); end if;
  if v_min <= 0 or v_min > 240 then
    return jsonb_build_object('ok', false, 'error', 'Minutos inválidos (1-240 max)');
  end if;

  -- Serializa 2 admins extendiendo el mismo UUID (equiv. LockService del GAS).
  perform pg_advisory_xact_lock(hashtext('exthor:' || v_dev));

  -- Device DEBE existir (se valida ANTES de auditar la clave, igual que el GAS).
  select desbloqueo_temporal_hasta into v_actual from mos.dispositivos where id_dispositivo = v_dev;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Dispositivo no encontrado — solicita primero alta del UUID');
  end if;

  -- Valida clave + audita (tier 2). Core = sin gate de claim (device pre-auth).
  v_auth := mos._validar_clave_admin_core(
    v_cla, 'EXTENDER_HORARIO_DISPOSITIVO', v_dev, v_app, v_dev,
    'Extensión in-situ de ' || v_min || ' min para el dispositivo', 2);
  if coalesce((v_auth->>'ok')::boolean, false) is not true then
    return v_auth;  -- error de config (ok:false)
  end if;
  if coalesce((v_auth->>'autorizado')::boolean, false) is not true then
    return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'autorizado', false, 'error', coalesce(v_auth->>'error', 'Clave incorrecta')));
  end if;
  v_nombre := coalesce(nullif(v_auth->>'nombre',''), 'admin');

  -- Preserva la extensión vigente mayor (Math.max del GAS).
  v_nuevo := now() + (v_min * interval '1 minute');
  v_hasta := greatest(v_nuevo, coalesce(v_actual, v_nuevo));
  v_preservo := (v_actual is not null and v_actual > v_nuevo);

  update mos.dispositivos set desbloqueo_temporal_hasta = v_hasta where id_dispositivo = v_dev;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'autorizado', true,
    'aprobadoPor', v_nombre,
    'hastaTs', to_char(v_hasta at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"'),
    'minutos', v_min,
    'preservoExistente', v_preservo));
end;
$fn$;
revoke all on function mos.extender_horario_dispositivo(jsonb) from public;
grant execute on function mos.extender_horario_dispositivo(jsonb) to anon, authenticated, service_role;
