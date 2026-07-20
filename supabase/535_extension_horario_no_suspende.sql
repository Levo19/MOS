-- 535: FIX GRAVE — la extensión de horario reusaba desbloqueo_temporal_hasta, y el cron
-- mos-revertir-desbloqueos (min 7 de cada hora) SUSPENDE a ciegas todo ACTIVO con ese campo
-- vencido. Resultado: tablet zona1 (ea76596d) suspendida EN PLENO USO el 2026-07-19 a las
-- 19:07 Perú, 1h después de probar el permiso remoto. El mensaje "2 días sin uso" era solo
-- el texto genérico de la UI.
--
-- Semántica corregida:
--   desbloqueo_temporal_hasta → SOLO desbloquear_temporal_dispositivo (revivir un SUSPENDIDO
--                               por N horas; al vencer SÍ corresponde re-suspender).
--   forzar_horario_hasta      → extensiones de horario (device sano fuera de ventana; al
--                               vencer NO pasa nada con el estado — solo expira el permiso).
--
-- Cambios:
--   1) aprobar_extension_horario   → escribe forzar_horario_hasta
--   2) extender_horario_dispositivo → escribe forzar_horario_hasta
--   3) migración: dispositivos ACTIVO (nunca suspendidos en esta ventana) con
--      desbloqueo_temporal_hasta puesto por extensiones pasan el valor a forzar_horario_hasta
--      para que el cron no los toque.
--   4) grants verificar_horario_dispositivo (el bloqueo lo pollea para enterarse de la
--      aprobación remota SIN cerrar la pantalla).

begin;

-- 1) aprobar_extension_horario → forzar_horario_hasta
create or replace function mos.aprobar_extension_horario(p jsonb)
returns jsonb
language plpgsql security definer set search_path to ''
as $function$
declare
  v_alerta text := nullif(btrim(coalesce(p->>'idAlerta','')),'');
  v_por    text := left(btrim(coalesce(p->>'aprobadoPor','admin')), 80);
  r        mos.seguridad_alertas%rowtype;
  v_dev    text; v_actual timestamptz; v_hasta timestamptz;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_alerta is null then return jsonb_build_object('ok',false,'error','idAlerta requerido'); end if;
  select * into r from mos.seguridad_alertas where id_alerta = v_alerta for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  if upper(coalesce(r.tipo,'')) <> 'EXTENSION_HORARIO_PENDIENTE' then
    return jsonb_build_object('ok',false,'error','TIPO_INVALIDO'); end if;
  if upper(coalesce(r.estado,'')) <> 'PENDIENTE' then
    return jsonb_build_object('ok',false,'error','YA_'||upper(coalesce(r.estado,'RESUELTA'))); end if;

  v_dev := nullif(btrim(coalesce(r.id_dispositivo, r.datos_extra_json->>'deviceId','')),'');
  if v_dev is null then
    update mos.seguridad_alertas set estado='APROBADA', revisada_por=v_por, revisada_en=now() where id_alerta=v_alerta;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('sinDispositivo',true));
  end if;

  -- 1h al UUID (preserva la mayor vigente) — HORARIO, no desbloqueo de suspensión:
  -- forzar_horario_hasta jamás lo toca el cron mos-revertir-desbloqueos.
  select forzar_horario_hasta into v_actual from mos.dispositivos where id_dispositivo = v_dev;
  v_hasta := greatest(now() + interval '1 hour', coalesce(v_actual, now()));
  update mos.dispositivos set forzar_horario_hasta = v_hasta where id_dispositivo = v_dev;
  update mos.seguridad_alertas set estado='APROBADA', revisada_por=v_por, revisada_en=now() where id_alerta=v_alerta;

  begin
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('deviceIds', jsonb_build_array(v_dev)),
      'titulo', '✅ Extensión aprobada · +1h',
      'cuerpo', 'Un admin te concedió 1 hora más · ya puedes seguir operando',
      'data', jsonb_build_object('tipo','extension_horario_aprobada')));
  exception when others then null; end;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'deviceId', v_dev, 'aprobadoPor', v_por,
    'hastaTs', to_char(v_hasta at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"'), 'minutos', 60));
end; $function$;

-- 2) extender_horario_dispositivo (in-situ con clave admin) → forzar_horario_hasta
--    Solo cambian las 2 líneas del campo; el resto (validación de clave, alerta, respuesta)
--    se re-crea idéntico desde la definición vigente en prod.
do $mig$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='mos' and p.proname='extender_horario_dispositivo';
  if v_src is null then raise exception 'extender_horario_dispositivo no existe'; end if;
  v_src := replace(v_src,
    'select desbloqueo_temporal_hasta into v_actual from mos.dispositivos where id_dispositivo = v_dev',
    'select forzar_horario_hasta into v_actual from mos.dispositivos where id_dispositivo = v_dev');
  v_src := replace(v_src,
    'update mos.dispositivos set desbloqueo_temporal_hasta = v_hasta where id_dispositivo = v_dev',
    'update mos.dispositivos set forzar_horario_hasta = v_hasta where id_dispositivo = v_dev');
  if v_src !~ 'forzar_horario_hasta' then raise exception 'replace no aplicó (fuente cambió de forma)'; end if;
  execute v_src;
end $mig$;

-- 3) Migración: ACTIVO con desbloqueo vigente o vencido puesto por extensiones →
--    mover a forzar_horario_hasta (si vigente) y limpiar el campo minado.
update mos.dispositivos
   set forzar_horario_hasta = greatest(coalesce(forzar_horario_hasta,'-infinity'), desbloqueo_temporal_hasta),
       desbloqueo_temporal_hasta = null
 where estado = 'ACTIVO' and desbloqueo_temporal_hasta is not null;

-- 4) grants: el bloqueo pollea verificar_horario_dispositivo con token minted (authenticated)
grant execute on function mos.verificar_horario_dispositivo(jsonb) to authenticated;
grant execute on function mos.aprobar_extension_horario(jsonb) to authenticated;

commit;
