-- 103_mos_auth_sin_doblecheck.sql — [FASE 4.1 · Etapa F] Flag server-side para QUITAR el doble-check del auth.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- HOY (doble-check): device-auth.js entra directo si la sombra dice ACTIVO; si dice BLOQUEO, CONFIRMA con GAS
-- (la hoja, fuente real) antes de bloquear — para no dejar afuera un device legítimo con la sombra desfasada.
-- Eso ata el auth a GAS. Con la sombra ahora SIEMPRE fresca (reconciliación 15min + espejo instantáneo en
-- revocar/bloquear/liberar/aprobar/reactivar), el doble-check ya no es necesario → se puede confiar 100% en la
-- sombra (auth puro, sin GAS).
--
-- ESTE SQL: re-crea mos.verificar_dispositivo IDÉNTICA, agregando UN campo `sin_doblecheck` en todos los
-- returns (leído de mos.config MOS_AUTH_SIN_DOBLECHECK). device-auth.js (v1.0.23) lo lee: si true, ante un
-- estado de bloqueo NO consulta GAS, usa el veredicto directo. ADITIVO: agregar el campo no cambia nada para
-- los clientes viejos (lo ignoran).
--
-- ⚠️ NACE INERTE: MOS_AUTH_SIN_DOBLECHECK='0' → sin_doblecheck=false → device-auth.js mantiene el doble-check
--    EXACTO de hoy. ACTIVAR (cuando se valide que la sombra está fresca y TODOS entran):
--      update mos.config set valor='1' where clave='MOS_AUTH_SIN_DOBLECHECK';
--    KILL-SWITCH (reversible al instante, ~el front lo ve al próximo verify):
--      update mos.config set valor='0' where clave='MOS_AUTH_SIN_DOBLECHECK';

insert into mos.config (clave, valor, descripcion) values
  ('MOS_AUTH_SIN_DOBLECHECK','0','FASE 4.1: 1 = device-auth.js confía 100% en la sombra (auth puro, sin doble-check a GAS). 0 = doble-check ON (confirma bloqueos con la hoja).')
on conflict (clave) do nothing;

create or replace function mos.verificar_dispositivo(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id   text := btrim(coalesce(p->>'id_dispositivo',''));
  v_ver  text;
  v_sdc  boolean;
  d      mos.dispositivos%rowtype;
begin
  select valor into v_ver from mos.config where clave = 'DEVICE_VERIFY_VERSION' limit 1;
  v_ver := coalesce(v_ver, '1');
  -- [FASE 4.1 · F] flag: ¿el front debe SALTARSE el doble-check a GAS y confiar en la sombra? (default false)
  v_sdc := (coalesce((select valor from mos.config where clave='MOS_AUTH_SIN_DOBLECHECK' limit 1),'0') = '1');

  if v_id !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false,
      'verify_version', v_ver, 'sin_doblecheck', v_sdc,
      'fecha_hoy_lima', to_char((now() at time zone 'America/Lima')::date,'YYYY-MM-DD'));
  end if;

  -- heartbeat + limpieza de suspendido_desde si reaparece ACTIVO; devuelve la fila actualizada.
  update mos.dispositivos
     set ultima_conexion  = now(),
         suspendido_desde = case when estado='ACTIVO' then null else suspendido_desde end
   where id_dispositivo = v_id
   returning * into d;

  if not found then
    return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false,
      'verify_version', v_ver, 'sin_doblecheck', v_sdc,
      'fecha_hoy_lima', to_char((now() at time zone 'America/Lima')::date,'YYYY-MM-DD'));
  end if;

  return jsonb_build_object(
    'ok', true,
    'estado',                    d.estado,
    'autorizado',                (d.estado = 'ACTIVO'),
    'nombre_equipo',             d.nombre_equipo,
    'app',                       d.app,
    'forzar_wizard',             coalesce(d.forzar_wizard,false),
    'forzar_logout',             coalesce(d.forzar_logout,false),
    'forzar_push',               coalesce(d.forzar_push,false),
    'forzar_reverify',           coalesce(d.forzar_reverify,false),
    'logout_auto_ts',            d.logout_auto_ts,
    'suspendido_desde',          d.suspendido_desde,
    'desbloqueo_temporal_hasta', d.desbloqueo_temporal_hasta,
    'fecha_caducidad',           d.fecha_caducidad,
    'permisos_json',             d.permisos_json,
    'verify_version',            v_ver,
    'sin_doblecheck',            v_sdc,
    'fecha_hoy_lima',            to_char((now() at time zone 'America/Lima')::date,'YYYY-MM-DD')
  );
exception when others then
  -- fail-soft: si la RPC falla, el front cae a su cache; la denylist de get_flags es el backstop server.
  return jsonb_build_object('ok', false, 'error', 'ERROR_VERIFICACION');
end;
$fn$;
revoke all on function mos.verificar_dispositivo(jsonb) from public;
grant execute on function mos.verificar_dispositivo(jsonb) to anon, authenticated, service_role;
