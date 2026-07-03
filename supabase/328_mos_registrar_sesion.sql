-- 328_mos_registrar_sesion.sql  (CORREGIDO)
-- [CERO-GAS · teardown] Heartbeat de sesión del dispositivo directo a Supabase.
-- Reemplaza el GAS registrarSesionDispositivo que ME pingaba en CADA venta (fire-and-forget).
-- El poll de extensión (mos.extension_pendientes) SOLO LEE → no mantenía vivo el acceso; el heartbeat real
-- lo hacía este ping. Ahora, cero-GAS:
--   (1) keep-alive de la fila de acceso ACTIVA del dispositivo → mos.accesos_dispositivos.ultima_conexion
--       (lo que mira el panel de "conectados"/personal del día).
--   (2) última zona/estación/vendedor a nivel dispositivo → mos.dispositivos.ultima_* (paridad con el GAS,
--       que actualizaba la hoja DISPOSITIVOS).
-- SOLO UPDATE (no inserta, no crea acceso, no cambia estado/rol/autorización). anon-callable (mismo patrón que
-- mos.verificar_dispositivo, que ya es anon y escribe ultima_conexion). Dato cosmético (conectados), no money.
create or replace function mos.registrar_sesion(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = mos, public
as $$
declare
  v_dev  text := btrim(coalesce(p->>'deviceId', p->>'ID_Dispositivo', ''));
  v_vend text := btrim(coalesce(p->>'vendedor', ''));
  v_zona text := btrim(coalesce(p->>'idZona', p->>'zona', ''));
  v_est  text := btrim(coalesce(p->>'idEstacion', p->>'estacion', ''));
  v_acc  int;
  v_disp int;
begin
  if v_dev = '' then return jsonb_build_object('ok', false, 'error', 'deviceId requerido'); end if;

  -- (1) keep-alive del acceso ACTIVO (NO crea filas; si no hay acceso activo, no hace nada)
  update mos.accesos_dispositivos
     set ultima_conexion = now()
   where device_id = v_dev and estado = 'ACTIVA';
  get diagnostics v_acc = row_count;

  -- (2) última zona/estación/vendedor a nivel dispositivo (paridad con el GAS)
  update mos.dispositivos
     set ultima_conexion = now(),
         ultima_sesion   = case when v_vend <> '' then v_vend else ultima_sesion end,
         ultima_zona     = case when v_zona <> '' then v_zona else ultima_zona end,
         ultima_estacion = case when v_est  <> '' then v_est  else ultima_estacion end
   where id_dispositivo = v_dev;
  get diagnostics v_disp = row_count;

  return jsonb_build_object('ok', true, 'acceso_upd', v_acc, 'dispositivo_upd', v_disp);
end;
$$;

revoke all on function mos.registrar_sesion(jsonb) from public;
grant execute on function mos.registrar_sesion(jsonb) to anon, authenticated, service_role;
