-- ============================================================================================================
-- 280_mos_admin_pins_cache.sql — [CERO-GAS G4] cache de PINs admin para verificación OFFLINE → Supabase
-- ------------------------------------------------------------------------------------------------------------
-- Reemplaza el GAS getAdminPinsCache (Seguridad.gs:404) que WH baja al login (sincronizarAdminCache) para poder
-- verificar la clave admin SIN conexión. Devuelve el MISMO shape: { globalPin, adminPins:[{idPersonal,nombre,pin}],
-- generadoEn }. Paridad de filtro: rol admin+ (rol_nivel>=2) AND estado=true AND pin no vacío.
--
-- ⚠ SEGURIDAD — material sensible: este RPC expone PINs admin en PLAINTEXT (4 dígitos) al navegador, igual que el
-- endpoint GAS actual (que además es ABIERTO/sin auth). Acá lo endurecemos: gate `mos._claim_ok() OR wh._claim_ok()`
-- → requiere un JWT de app del ecosistema (NO anon). Es MÁS seguro que el GAS abierto, pero NO resuelve la debilidad
-- de fondo (PINs sin hashear en mos.personal.pin — 'Fase 1', pendiente hashear en Fase 2; ver 51_mos_verificar_
-- clave_admin). La verificación ONLINE ya usa bcrypt server-side (mos.verificar_clave_admin); esto es SOLO el
-- fallback offline. NO se expone a anon. NO entra en config_publico (que excluye /pin/).
--
-- INERTE: kill-switch server-side ADMIN_PINS_DIRECTO (mos.config) default OFF → devuelve *_OFF → WH cae a GAS.
-- ============================================================================================================

create schema if not exists mos;

create or replace function mos.admin_pins_cache(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_global text; v_admins jsonb;
begin
  -- gate de app (no anon): mismo criterio que verificar_clave_admin.
  if not (mos._claim_ok() or wh._claim_ok()) then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- kill-switch server-side (INERTE por default).
  if coalesce((select valor from mos.config where clave = 'ADMIN_PINS_DIRECTO' limit 1), '0') <> '1' then
    return jsonb_build_object('ok', false, 'error', 'ADMIN_PINS_DIRECTO_OFF');
  end if;

  select lpad(coalesce(valor, ''), 4, '0') into v_global
  from mos.config where clave = 'ADMIN_GLOBAL_PIN' limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
    'idPersonal', pe.id_personal,
    'nombre',     btrim(coalesce(pe.nombre,'') || ' ' || coalesce(pe.apellido,'')),
    'pin',        lpad(coalesce(pe.pin,''), 4, '0')
  ) order by pe.id_personal), '[]'::jsonb) into v_admins
  from mos.personal pe
  where mos.rol_nivel(pe.rol) >= 2        -- ADMIN/ADMINISTRADOR (2) o MASTER (3); espeja _esRolAdmin
    and pe.estado = true                   -- estado='1' en la hoja ⇔ true en la sombra
    and btrim(coalesce(pe.pin, '')) <> ''; -- solo con pin (paridad: p.pin truthy)

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'globalPin',  coalesce(v_global, ''),
    'adminPins',  v_admins,
    'generadoEn', to_char((now() at time zone 'utc'), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ));
end; $fn$;

revoke all on function mos.admin_pins_cache(jsonb) from public;
-- authenticated/service_role SOLAMENTE (NUNCA anon — es material de PIN).
grant execute on function mos.admin_pins_cache(jsonb) to authenticated, service_role;
