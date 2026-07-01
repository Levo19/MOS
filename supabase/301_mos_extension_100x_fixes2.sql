-- ============================================================================
-- 301_mos_extension_100x_fixes2.sql — 2ª ronda 100x (índice principal + polling)
-- ----------------------------------------------------------------------------
-- #6: el índice único de principal contaba también un principal CERRADO → si el
--     principal del día se cerró y entra otro device, el insert es_principal=true
--     violaba el índice (login sobrevivía por el wrapper, pero el device no se ataba).
--     FIX: el índice solo cuenta principal ACTIVO.
-- #7: extension_estado filtraba nada → fuga del id_dia/estado de otra sesión por
--     adivinar id_req. FIX: scope por device_sol + gate de flag.
-- (El #1 GAS _liqDiaKey se corrige en gas/Liquidaciones.gs, aparte.)
-- ============================================================================

-- #6: índice único solo entre principales ACTIVOS ────────────────────────────
drop index if exists mos.ux_accdisp_principal;
create unique index ux_accdisp_principal on mos.accesos_dispositivos (id_dia)
  where es_principal and estado = 'ACTIVA';

-- #7: extension_estado con ownership (device_sol) + gate de flag ─────────────
create or replace function mos.extension_estado(p jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select case
    when coalesce(me.jwt_app(),'') = '' then jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA')
    when coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1'
      then jsonb_build_object('ok',false,'error','EXTENSION_OFF')
    else coalesce(
      (select jsonb_build_object('ok',true,'estado',upper(coalesce(estado,'')),'idDia',id_dia)
         from mos.extension_requests
        where id_req = btrim(coalesce(p->>'idReq',''))
          and device_sol = btrim(coalesce(p->>'deviceId',''))     -- [100x #7] solo el solicitante
        limit 1),
      jsonb_build_object('ok',true,'estado','NO_ENCONTRADA')) end;
$fn$;

-- extension_pendientes: agregar gate de flag (paridad; ya estaba scopeada por principal)
create or replace function mos.extension_pendientes(p jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select case
    when coalesce(me.jwt_app(),'') = '' then jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA')
    when coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1'
      then jsonb_build_object('ok',true,'pendientes','[]'::jsonb)
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
