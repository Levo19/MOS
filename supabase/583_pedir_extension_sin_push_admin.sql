-- 583 · [Extensión de DISPOSITIVO · fix] mos.pedir_extension mandaba al admin un push
-- titulado "⏰ Solicitud de extensión de HORARIO · pide más tiempo · aprueba o rechaza".
-- MAL: (1) es una extensión de DISPOSITIVO (2º equipo), no de horario; (2) el flujo v2 es
-- QR peer-to-peer (el 2º equipo escanea el QR del 1º — tener ambos equipos a la mano ES la
-- verificación), así que el ADMIN no aprueba nada → el push sobra por completo.
-- Fix: quitar el push. Todo lo demás igual a la def viva (344b). Si algún día se quiere un
-- aviso INFORMATIVO ("Mia vinculó un 2º equipo"), va en el camino de VINCULACIÓN exitosa, no acá.
create or replace function mos.pedir_extension(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_nombre text := upper(btrim(coalesce(p->>'nombre','')));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_dev    text := btrim(coalesce(p->>'deviceId',''));
  v_rol    text := btrim(coalesce(p->>'rol',''));
  v_fecha  text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_idpers text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_dia    date; v_idp text; v_iddia text; v_ppal text; v_cod text; v_idreq text;
  v_prev   mos.extension_requests%rowtype;
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
  if found then return jsonb_build_object('ok', true, 'needsApproval', false, 'alreadyLinked', true); end if;

  v_ppal := coalesce(
    (select device_id from mos.accesos_dispositivos where id_dia=v_iddia and es_principal order by hora_ingreso limit 1),
    (select device_id from mos.liquidaciones_dia where id_dia=v_iddia));

  -- [100x H2] si ya hay un PENDIENTE vivo de ESTE device para ESTA sesión → reusarlo (no spam)
  select * into v_prev from mos.extension_requests
   where id_dia=v_iddia and device_sol=v_dev and upper(coalesce(estado,''))='PENDIENTE' and now() <= expira
   order by creado desc limit 1;
  if found then
    return jsonb_build_object('ok',true,'needsApproval',true,'idReq',v_prev.id_req,'codigo',v_prev.codigo,'idDia',v_iddia,'principalDeviceId',v_ppal);
  end if;

  v_cod  := lpad((floor(random()*1000))::int::text, 3, '0');
  v_idreq := 'EXT-' || to_char(now(),'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text || v_dev), 1, 6);
  insert into mos.extension_requests (id_req, id_dia, device_sol, rol_sol, codigo, push_token)
  values (v_idreq, v_iddia, v_dev, v_rol, v_cod, btrim(coalesce(p->>'pushToken','')));
  -- [583] SIN push al admin: la extensión de 2º equipo se verifica por QR entre los equipos,
  -- no requiere aprobación del admin. (Antes se mandaba un push de "extensión de horario" errado.)
  return jsonb_build_object('ok',true,'needsApproval',true,'idReq',v_idreq,'codigo',v_cod,'idDia',v_iddia,'principalDeviceId',v_ppal);
end;
$function$;

notify pgrst, 'reload schema';
