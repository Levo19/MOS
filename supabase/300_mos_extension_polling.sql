-- ============================================================================
-- 300_mos_extension_polling.sql — lecturas para el flujo companion (polling)
-- ----------------------------------------------------------------------------
-- · extension_estado: el equipo SOLICITANTE consulta si su pedido ya fue aprobado.
-- · extension_pendientes: el equipo PRINCIPAL consulta si hay pedidos por aprobar
--   para sus sesiones activas (para mostrar el modal de aprobación).
-- Solo lectura, gateadas por MOS_EXTENSION_DIRECTO + jwt_app.
-- ============================================================================

create or replace function mos.extension_estado(p jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select case when coalesce(me.jwt_app(),'') = '' then jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA')
    else coalesce(
      (select jsonb_build_object('ok',true,'estado',upper(coalesce(estado,'')),'idDia',id_dia)
         from mos.extension_requests where id_req = btrim(coalesce(p->>'idReq','')) limit 1),
      jsonb_build_object('ok',true,'estado','NO_ENCONTRADA')) end;
$fn$;

create or replace function mos.extension_pendientes(p jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select case when coalesce(me.jwt_app(),'') = '' then jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA')
    else jsonb_build_object('ok',true,'pendientes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'idReq', er.id_req, 'idDia', er.id_dia, 'deviceSol', er.device_sol,
               'rol', er.rol_sol, 'codigo', er.codigo, 'expira', er.expira,
               'nombre', (select nombre from mos.liquidaciones_dia l where l.id_dia = er.id_dia limit 1))
             order by er.creado)
        from mos.extension_requests er
       where upper(coalesce(er.estado,'')) = 'PENDIENTE' and now() <= er.expira
         and exists(select 1 from mos.accesos_dispositivos a
                     where a.id_dia = er.id_dia and a.device_id = btrim(coalesce(p->>'deviceId',''))
                       and a.es_principal and upper(coalesce(a.estado,''))='ACTIVA')
    ), '[]'::jsonb)) end;
$fn$;

revoke all on function mos.extension_estado(jsonb)     from public;
revoke all on function mos.extension_pendientes(jsonb) from public;
grant execute on function mos.extension_estado(jsonb)     to authenticated, service_role;
grant execute on function mos.extension_pendientes(jsonb) to authenticated, service_role;
