-- ============================================================================
-- 512_identificar_solicitante_dispositivo.sql
-- ----------------------------------------------------------------------------
-- El buzón de solicitudes de acceso mostraba "Sin nombre" para los dispositivos
-- PENDIENTE_APROBACION porque un pendiente NUNCA inició sesión (no puede hasta ser
-- aprobado) → mos.dispositivos.ultima_sesion = NULL. El admin no sabía QUIÉN pide.
--
-- Fix: cuando el operador solicita acceso desde el equipo pendiente, se identifica con su
-- PIN de 4 díg; esta RPC lo resuelve a nombre y lo estampa en ultima_sesion del dispositivo
-- (solo si está PENDIENTE_APROBACION) → el buzón ya lo muestra con 👤. anon-callable (el
-- device es pre-auth, igual que registrar_dispositivo); solo escribe un campo de DISPLAY en
-- un pendiente, el admin igual verifica antes de aprobar.
-- ============================================================================
create or replace function mos.identificar_solicitante(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_dev text := nullif(btrim(coalesce(p->>'deviceId', p->>'device_id','')),'');
  v_pin text := nullif(btrim(coalesce(p->>'pin','')),'');
  v_nombre text;
begin
  if v_dev is null then return jsonb_build_object('ok',false,'error','deviceId requerido'); end if;
  if v_pin is null or v_pin !~ '^\d{3,8}$' then return jsonb_build_object('ok',false,'error','PIN inválido'); end if;
  -- resolver PIN → nombre (hash o plano; cualquier persona activa, no solo admins)
  select btrim(coalesce(nombre,'') || ' ' || coalesce(apellido,'')) into v_nombre
    from mos.personal
   where coalesce(estado,false) = true
     and ((pin_hash is not null and pin_hash = extensions.crypt(v_pin, pin_hash)) or coalesce(pin,'') = v_pin)
   limit 1;
  if v_nombre is null or v_nombre = '' then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('reconocido',false));
  end if;
  -- estampar SOLO si el device está pendiente (no pisa el ultima_sesion real de uno activo)
  update mos.dispositivos
     set ultima_sesion = v_nombre
   where id_dispositivo = v_dev and estado = 'PENDIENTE_APROBACION';
  return jsonb_build_object('ok',true,'data',jsonb_build_object('reconocido',true,'nombre',v_nombre));
end; $fn$;
revoke all on function mos.identificar_solicitante(jsonb) from public;
grant execute on function mos.identificar_solicitante(jsonb) to anon, authenticated, service_role;
