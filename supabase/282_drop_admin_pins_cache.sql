-- ============================================================================================================
-- 282_drop_admin_pins_cache.sql — [G4 → online-only] elimina el caché de PINs admin (revierte 280)
-- ------------------------------------------------------------------------------------------------------------
-- Decisión: la verificación de clave admin es SIEMPRE online (mos.verificar_clave_admin, bcrypt + lockout +
-- auditoría). El caché offline exponía PINs de 4 dígitos al navegador (texto plano o hash = igual de débil por
-- el espacio chico). Se elimina el RPC mos.admin_pins_cache (280) y su flag. WH ya no baja ni guarda PINs.
-- (El endpoint GAS getAdminPinsCache se neutraliza por separado en Seguridad.gs.)
-- ============================================================================================================
drop function if exists mos.admin_pins_cache(jsonb);
delete from mos.config where clave = 'ADMIN_PINS_DIRECTO';
