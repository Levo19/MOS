-- 723 · Extensión de dispositivo por QR — IDEMPOTENCIA del lado servidor.
--
-- Problema (ME 2.8.270): el 2º equipo escanea el QR, `extension_canjear_qr` ATA el equipo
-- server-side, pero el cliente se cuelga antes de persistir nada local. Tras F5 el equipo
-- arranca "como nuevo" (wizard inicial) y al reintentar solo recibe un toast de error
-- ("ya está vinculado") sin forma de ENTRAR. Faltaba una lectura: "¿este deviceId ya es
-- extensión de una sesión viva hoy? dame sus datos para entrar directo".
--
-- 1) NUEVA mos.extension_mi_estado(p{deviceId,fecha}) → estado REAL del equipo, sin depender
--    de localStorage. Devuelve el MISMO shape de `data` que extension_canjear_qr para que el
--    cliente reuse su misma función de aplicar sesión.
-- 2) PATCH mos.pedir_extension: en la rama `alreadyLinked` devolver también `data` (idDia,
--    nombre, rol, zona, principalDeviceId) → el toast de error se vuelve camino feliz.
--
-- Cero-GAS. Idempotente (create or replace).

-- ── 1) ¿este equipo ya es EXTENSIÓN de una sesión viva? ────────────────────────────────
create or replace function mos.extension_mi_estado(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare
  v_dev  text := btrim(coalesce(p->>'deviceId',''));
  v_dia  date;
  v_pref text;
  r record;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_dev = '' then return jsonb_build_object('ok',true,'vinculado',false); end if;
  begin v_dia := coalesce(nullif(btrim(coalesce(p->>'fecha','')),'')::date, (now() at time zone 'America/Lima')::date);
  exception when others then v_dia := (now() at time zone 'America/Lima')::date; end;
  -- las claves de liquidaciones_dia son 'LDIA-YYYYMMDD-...' → filtramos por prefijo del día
  v_pref := 'LDIA-' || to_char(v_dia,'YYYYMMDD') || '-%';

  select a.id_dia, l.nombre, upper(coalesce(l.rol,'')) rol, upper(coalesce(l.zona,'')) zona,
         upper(coalesce(a.rol,'')) rol_acceso
    into r
    from mos.accesos_dispositivos a
    join mos.liquidaciones_dia l on l.id_dia = a.id_dia
   where a.device_id = v_dev
     and a.id_dia like v_pref
     and coalesce(a.es_principal,false) = false
     and upper(coalesce(a.estado,'')) = 'ACTIVA'
     and upper(coalesce(l.estado_sesion,'')) = 'ACTIVA'
   order by a.ultima_conexion desc nulls last, a.hora_ingreso desc
   limit 1;

  if not found then return jsonb_build_object('ok',true,'vinculado',false); end if;

  return jsonb_build_object('ok',true,'vinculado',true,'data', jsonb_build_object(
    'idDia', r.id_dia,
    'nombre', coalesce(r.nombre,''),
    -- el rol que manda es el que se le concedió al equipo-extensión; si viniera vacío, hereda el de la sesión
    'rol', coalesce(nullif(r.rol_acceso,''), r.rol, ''),
    'zona', coalesce(r.zona,''),
    'principalDeviceId', (select a2.device_id from mos.accesos_dispositivos a2
                           where a2.id_dia = r.id_dia and a2.es_principal
                           order by a2.hora_ingreso limit 1)));
end; $fn$;

-- ── 2) pedir_extension: rama alreadyLinked ahora devuelve los datos de la sesión ────────
create or replace function mos.pedir_extension(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_nombre text := upper(btrim(coalesce(p->>'nombre','')));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_dev    text := btrim(coalesce(p->>'deviceId',''));
  v_rol    text := btrim(coalesce(p->>'rol',''));
  v_fecha  text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_idpers text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_dia    date; v_idp text; v_iddia text; v_ppal text; v_cod text; v_idreq text;
  v_prev   mos.extension_requests%rowtype;
  v_ses    record;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','EXTENSION_OFF');
  end if;
  if v_nombre = '' or v_dev = '' then return jsonb_build_object('ok',false,'error','nombre y deviceId requeridos'); end if;
  begin v_dia := coalesce(v_fecha::date, (now() at time zone 'America/Lima')::date);
  exception when others then v_dia := (now() at time zone 'America/Lima')::date; end;
  v_idp   := mos._identidad_persona(v_idpers, v_nombre, v_zona, v_idpers is null);
  v_iddia := mos._liqdia_key(v_idp, to_char(v_dia,'YYYY-MM-DD'));

  perform 1 from mos.liquidaciones_dia where id_dia = v_iddia and upper(coalesce(estado_sesion,''))='ACTIVA';
  if not found then return jsonb_build_object('ok', true, 'needsApproval', false); end if;

  perform 1 from mos.accesos_dispositivos where id_dia=v_iddia and device_id=v_dev and upper(coalesce(estado,''))='ACTIVA';
  if found then
    -- [723] IDEMPOTENCIA: ya está atado → devolver los datos de la sesión para que el cliente
    -- ENTRE directo (antes solo salía un toast "ya está vinculado" y el equipo quedaba varado).
    select nombre, upper(coalesce(rol,'')) rol, upper(coalesce(zona,'')) zona
      into v_ses from mos.liquidaciones_dia where id_dia = v_iddia limit 1;
    return jsonb_build_object('ok', true, 'needsApproval', false, 'alreadyLinked', true,
      'data', jsonb_build_object(
        'idDia', v_iddia, 'nombre', coalesce(v_ses.nombre,''), 'rol', coalesce(v_ses.rol,''),
        'zona', coalesce(v_ses.zona,''),
        'principalDeviceId', (select device_id from mos.accesos_dispositivos a
                               where a.id_dia=v_iddia and a.es_principal order by a.hora_ingreso limit 1)));
  end if;

  v_ppal := coalesce(
    (select device_id from mos.accesos_dispositivos where id_dia=v_iddia and es_principal order by hora_ingreso limit 1),
    (select device_id from mos.liquidaciones_dia where id_dia=v_iddia));

  -- [100x H2] si ya hay un PENDIENTE vivo de ESTE device para ESTA sesión → reusarlo (no spam)
  select * into v_prev from mos.extension_requests
   where id_dia=v_iddia and device_sol=v_dev and upper(coalesce(estado,'')) in ('PENDIENTE','QR') and now() <= expira
   order by creado desc limit 1;
  if found then
    return jsonb_build_object('ok',true,'needsApproval',true,'idReq',v_prev.id_req,'codigo',v_prev.codigo,'idDia',v_iddia,'principalDeviceId',v_ppal);
  end if;

  v_cod  := lpad((floor(random()*1000))::int::text, 3, '0');
  v_idreq := 'EXT-' || to_char(now(),'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text || v_dev), 1, 6);
  insert into mos.extension_requests (id_req, id_dia, device_sol, rol_sol, codigo, push_token)
  values (v_idreq, v_iddia, v_dev, v_rol, v_cod, btrim(coalesce(p->>'pushToken','')));
  -- [583] SIN push al admin: la extensión de 2º equipo se verifica por QR entre los equipos.
  return jsonb_build_object('ok',true,'needsApproval',true,'idReq',v_idreq,'codigo',v_cod,'idDia',v_iddia,'principalDeviceId',v_ppal);
end;
$fn$;

revoke all on function mos.extension_mi_estado(jsonb) from public, anon;
grant execute on function mos.extension_mi_estado(jsonb) to authenticated, service_role;
