-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- 507 · mos.dispositivos.ultima_conexion MONÓTONA — neutraliza el reseed GAS que revierte la actividad
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- CAUSA RAÍZ (confirmada): el GAS `_resembrarDispositivosJob` (Fase4Dispositivos.gs) corre CADA 5 MIN y hace
-- un "forward de actividad" Hoja→Sombra: copia ultima_conexion (y zona/estacion/sesion) de la HOJA a Supabase.
-- Para equipos cuya actividad NO se refleja en la hoja (MASTER/ADMIN de MOS y ~95% de la flota), la hoja tiene
-- un ultima_conexion viejo → el reseed lo copia a Supabase cada 5 min → el cron mos.cron_dispositivos_inactivos
-- lo ve >2 días → SUSPENDE. Cualquier refresco en Supabase (reactivación, touch) lo revierte el reseed a los 5'.
-- Churn verificado: equipos suspendidos hasta 13 veces en 3 días.
--
-- FIX 100% Supabase (sin tocar GAS): ultima_conexion NUNCA retrocede. Si un write trae un valor MÁS VIEJO
-- (el reseed con el valor de la hoja) o null, se conserva el valor existente (más fresco). Así el touch de la
-- app (mos.touch_dispositivo, SQL 506) mantiene fresco en Supabase y el reseed ya no lo puede revertir.
-- El reseed sigue corriendo pero su write de ultima_conexion viejo queda NEUTRALIZADO. Un equipo REALMENTE
-- 2 días sin abrir ninguna app no recibe touch → su ultima_conexion queda vieja → el cron sí lo suspende. OK.
--
-- Solo afecta ultima_conexion (la columna que gobierna la suspensión). Idempotente. Reversible: drop trigger.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

create or replace function mos._dispositivos_uc_monotona()
 returns trigger
 language plpgsql
 set search_path to ''
as $function$
begin
  -- ultima_conexion es MONÓTONA: nunca retrocede. new null o < old → conservar old.
  if new.ultima_conexion is null
     or (old.ultima_conexion is not null and new.ultima_conexion < old.ultima_conexion) then
    new.ultima_conexion := old.ultima_conexion;
  end if;
  return new;
end;
$function$;

drop trigger if exists tg_dispositivos_uc_monotona on mos.dispositivos;
create trigger tg_dispositivos_uc_monotona
  before update on mos.dispositivos
  for each row
  when (new.ultima_conexion is distinct from old.ultima_conexion)
  execute function mos._dispositivos_uc_monotona();
