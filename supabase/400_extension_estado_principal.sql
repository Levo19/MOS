-- 400 · extension_estado: permitir que el PRINCIPAL (device 1) consulte el estado, no solo el solicitante.
-- Bug: extension_estado filtraba `device_sol = deviceId` (solo el 2º equipo). El QR que muestra el PRINCIPAL
-- (_extMostrarQR) pollea extension_estado con SU device → device_sol no coincide → siempre 'NO_ENCONTRADA' →
-- el QR nunca detecta que el 2º equipo escaneó (estado='APROBADA') y el modal del QR NO se cerraba.
-- Fix: aceptar al solicitante (device_sol) O al principal de la sesión de esa solicitud (es_principal en
-- mos.accesos_dispositivos del id_dia). Sigue siendo cerrado a terceros. Cero-GAS.

create or replace function mos.extension_estado(p jsonb)
returns jsonb language sql stable security definer set search_path='' as $function$
  select case
    when coalesce(me.jwt_app(),'') = '' then jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA')
    when coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1'
      then jsonb_build_object('ok',false,'error','EXTENSION_OFF')
    else coalesce(
      (select jsonb_build_object('ok',true,'estado',upper(coalesce(r.estado,'')),'idDia',r.id_dia)
         from mos.extension_requests r
        where r.id_req = btrim(coalesce(p->>'idReq',''))
          and (
            r.device_sol = btrim(coalesce(p->>'deviceId',''))                          -- el solicitante (2º equipo)
            or exists (                                                                -- o el PRINCIPAL de esa sesión
              select 1 from mos.accesos_dispositivos a
              where a.id_dia = r.id_dia and a.es_principal
                and a.device_id = btrim(coalesce(p->>'deviceId',''))
            )
          )
        limit 1),
      jsonb_build_object('ok',true,'estado','NO_ENCONTRADA')) end;
$function$;

grant execute on function mos.extension_estado(jsonb) to authenticated, service_role;
