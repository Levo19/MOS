-- ============================================================================
-- 303_mos_500x_r1_fixes.sql — correcciones de la Ronda 1 del 500x (seguridad)
-- ----------------------------------------------------------------------------
-- PII: accesos_duplicados_dia devolvía datos de NÓMINA (quién ganó cuánto) a CUALQUIER
--   token de app (gate era solo jwt_app<>''). FIX: solo contexto admin MOS (_claim_ok).
-- M3: los RPC del companion (pedir/aprobar/rechazar/estado/pendientes) aceptaban tokens
--   de warehouseMos (over-broad). FIX: solo mosExpress (el companion) o MOS (fallback admin).
-- (C1 recompute-guard va en 289; vetar-clave-server + marcar_pagos-server-truth quedan
--  documentados para la iteración 2 — requieren cambio de frontend.)
-- ============================================================================

-- helper: ¿el token es del ecosistema companion (ME) o admin (MOS)?
create or replace function mos._ext_app_ok()
returns boolean language sql stable set search_path = '' as $fn$
  select coalesce(me.jwt_app(),'') in ('mosExpress','MOS');
$fn$;
revoke all on function mos._ext_app_ok() from public;
grant execute on function mos._ext_app_ok() to authenticated, service_role;

-- PII: accesos_duplicados_dia → solo admin MOS
create or replace function mos.accesos_duplicados_dia(p jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  with dia as (
    select mos._norm_nom(nombre) nrm, id_personal, coalesce(zona,'') zona,
           coalesce(venta_cobrada,0) venta, coalesce(total_dia,0) total
    from mos.liquidaciones_dia
    where (fecha at time zone 'America/Lima')::date
        = coalesce(nullif(btrim(p->>'fecha',''),'')::date, (now() at time zone 'America/Lima')::date)
      and btrim(coalesce(nombre,'')) <> ''
      and mos._claim_ok()                                   -- [500x PII] solo admin MOS ve nómina
  ), dup as ( select nrm from dia group by nrm having count(*) > 1 )
  select coalesce(jsonb_object_agg(nrm, filas), '{}'::jsonb)
  from (
    select d.nrm, jsonb_agg(jsonb_build_object(
             'idPersonal', d.id_personal, 'zona', d.zona, 'venta', d.venta, 'total', d.total)
             order by d.venta desc) filas
    from dia d join dup u on u.nrm = d.nrm group by d.nrm
  ) s;
$fn$;
revoke all on function mos.accesos_duplicados_dia(jsonb) from public;
grant execute on function mos.accesos_duplicados_dia(jsonb) to authenticated, service_role;

-- M3: gate del companion a mosExpress/MOS (re-create solo la línea del gate via wrapper).
-- pedir/aprobar/rechazar/estado/pendientes ya validan me.jwt_app()<>''; los endurecemos.
-- (Se re-crean con el gate _ext_app_ok; cuerpo idéntico al de 299/301.)
create or replace function mos.rechazar_extension(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._ext_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  update mos.extension_requests set estado='RECHAZADA'
   where id_req = btrim(coalesce(p->>'idReq','')) and upper(coalesce(estado,''))='PENDIENTE';
  return jsonb_build_object('ok', found);
end;
$fn$;
revoke all on function mos.rechazar_extension(jsonb) from public;
grant execute on function mos.rechazar_extension(jsonb) to authenticated, service_role;
