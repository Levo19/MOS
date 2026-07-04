-- 344c: push best-effort extension aprobada (#27 -> solicitante). Cero-GAS.
CREATE OR REPLACE FUNCTION mos.aprobar_extension(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idreq text := btrim(coalesce(p->>'idReq',''));
  v_cod   text := btrim(coalesce(p->>'codigo',''));
  v_dev   text := btrim(coalesce(p->>'deviceId',''));   -- device que APRUEBA (debe ser el principal)
  v_admin boolean := coalesce((p->>'admin')::boolean, false) and mos._claim_ok();
  r       mos.extension_requests%rowtype;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','EXTENSION_OFF');
  end if;
  select * into r from mos.extension_requests where id_req = v_idreq for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  if upper(coalesce(r.estado,'')) <> 'PENDIENTE' then return jsonb_build_object('ok',false,'error','YA_'||upper(r.estado)); end if;
  if now() > r.expira then update mos.extension_requests set estado='EXPIRADA' where id_req=v_idreq;
    return jsonb_build_object('ok',false,'error','EXPIRADA'); end if;
  -- [100x H1] el código es OBLIGATORIO y debe coincidir (antes vacío = bypass).
  if v_cod = '' or v_cod <> r.codigo then return jsonb_build_object('ok',false,'error','CODIGO_INVALIDO'); end if;
  -- [100x H1] quien aprueba debe ser el device PRINCIPAL ACTIVO de esa sesión (o un admin).
  if not v_admin and not exists(
       select 1 from mos.accesos_dispositivos
        where id_dia = r.id_dia and device_id = v_dev and es_principal and upper(coalesce(estado,''))='ACTIVA') then
    return jsonb_build_object('ok',false,'error','SOLO_EL_PRINCIPAL_APRUEBA');
  end if;

  insert into mos.accesos_dispositivos (id_dia, device_id, rol, es_principal, estado, push_token)
  values (r.id_dia, r.device_sol, r.rol_sol, false, 'ACTIVA', r.push_token)
  on conflict (id_dia, device_id) do update set estado='ACTIVA', ultima_conexion=now(), rol=excluded.rol;
  update mos.extension_requests set estado='APROBADA' where id_req = v_idreq;
  begin
    if coalesce(r.device_sol,'') <> '' then
      perform mos.emitir_push(jsonb_build_object('audiencia',jsonb_build_object('deviceIds',jsonb_build_array(r.device_sol)),'titulo','✅ Extensión aprobada','cuerpo','Tu solicitud de más tiempo fue aprobada · ya puedes seguir operando','data',jsonb_build_object('tipo','extension_aprobada')));
    end if;
  exception when others then null; end;
  return jsonb_build_object('ok',true,'idDia',r.id_dia,'deviceId',r.device_sol);
end;
$function$
;
