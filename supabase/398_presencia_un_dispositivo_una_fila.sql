-- 398 · Presencia: UN DISPOSITIVO = UNA FILA (mata la "sesión duplicada" del propio equipo).
-- Problema: me.presencia se dedupea por id_personal (NOID:<nombre>). Si en el MISMO equipo cerrás y
-- relogueás con otro nombre (cabanossi1 → caba), queda una fila huérfana del nombre viejo pulsando/vigente
-- hasta el TTL → aparece un fantasma "duplicado" de tu propia sesión. Fix: al registrar presencia, borrar
-- cualquier otra fila del MISMO device_id con distinto id_personal → el equipo solo tiene su identidad actual.
-- Cero-GAS. Reproduce la función viva (288) + agrega el DELETE de dedup por dispositivo.

create or replace function me.registrar_presencia(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare
  v_id        text := btrim(coalesce(p->>'id_personal',''));
  v_nombre    text := coalesce(p->>'nombre','');
  v_zona      text := coalesce(p->>'zona','');
  v_estacion  text := coalesce(p->>'estacion','');
  v_rol       text := lower(btrim(coalesce(nullif(p->>'rol',''),'vendedor')));
  v_device    text := nullif(btrim(coalesce(p->>'device_id','')),'');
  v_token     text := nullif(btrim(coalesce(p->>'push_token','')),'');
begin
  if me.jwt_app() <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id = '' then
    return jsonb_build_object('ok', false, 'error', 'id_personal requerido');
  end if;

  insert into me.presencia (id_personal, nombre, zona, estacion, rol,
                            device_id, push_token, ingreso, last_seen)
  values (v_id, v_nombre, v_zona, v_estacion, v_rol,
          v_device, v_token, now(), now())
  on conflict (id_personal) do update
    set nombre     = excluded.nombre,
        zona       = excluded.zona,
        estacion   = excluded.estacion,
        rol        = excluded.rol,
        device_id  = coalesce(excluded.device_id,  me.presencia.device_id),
        push_token = coalesce(excluded.push_token, me.presencia.push_token),
        ingreso    = coalesce(me.presencia.ingreso, excluded.ingreso),
        last_seen  = now();

  -- [398] UN DISPOSITIVO = UNA FILA: al reloguear con otro nombre en el mismo equipo, la identidad vieja
  -- desaparece AL INSTANTE (no espera el TTL) → sin "sesión duplicada" fantasma del propio dispositivo.
  if v_device is not null and v_device <> '' then
    delete from me.presencia where device_id = v_device and id_personal <> v_id;
  end if;

  -- [accesos unificados] registro + heartbeat en liquidaciones_dia (ME = TEMPORAL). Gateado + idempotente.
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') = '1' then
    begin
      perform mos.registrar_ingreso_personal(jsonb_build_object(
        'idPersonal',  case
                         when v_id like 'NOID:%' or v_id like 'MEX:%'
                           then mos._identidad_persona(null, coalesce(nullif(btrim(v_nombre),''), substring(v_id from 6)), v_zona, true)
                         else v_id end,
        'nombre',      v_nombre,
        'rol',         v_rol,
        'appOrigen',   'mosExpress',
        'zona',        v_zona,
        'estacion',    v_estacion,
        'deviceId',    btrim(coalesce(p->>'deviceId', p->>'device_id', '')),
        'esTemporal',  true));
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('ok', true, 'id_personal', v_id, 'last_seen', now());
end;
$function$;

grant execute on function me.registrar_presencia(jsonb) to authenticated, service_role, anon;

-- Limpieza inmediata de huérfanos ya existentes (mismo device_id, dejar solo la fila más reciente).
delete from me.presencia a
using me.presencia b
where a.device_id is not null and a.device_id <> ''
  and a.device_id = b.device_id
  and a.id_personal <> b.id_personal
  and a.last_seen < b.last_seen;
