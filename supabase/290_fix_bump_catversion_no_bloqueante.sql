-- ============================================================================
-- 290_fix_bump_catversion_no_bloqueante.sql — FIX 500 al guardar precio/producto
-- ----------------------------------------------------------------------------
-- BUG (reproducido): mos._bump_catalogo_version hace UPDATE de UN solo renglón
-- (catalogo_meta id=1) en CADA cambio de producto. Si otra transacción retiene ese
-- renglón (un batch lento: auto-min-max, propagación de un canónico con muchas
-- presentaciones, sync), el siguiente actualizar_producto/publicar_precio se BLOQUEA
-- esperando ese lock → a los 8s salta statement_timeout (57014) → PostgREST 500 →
-- el precio nunca commitea → la UI "parpadea" al valor nuevo y vuelve al viejo.
--
-- FIX: el bump del contador pasa a ser NO-BLOQUEANTE con pg_try_advisory_xact_lock.
--   · Si nadie más está bumpeando → toma el lock y hace el +1 (camino normal).
--   · Si otro writer ya lo tiene → NO espera: salta el bump y el guardado del
--     producto sigue sin trabarse. El cambio NO se pierde: cada UPDATE de producto
--     ya movió su updated_at, y el delta del catálogo (mos.catalogo_wh_delta) lee por
--     server_ts; en cuanto cualquier writer bumpee la versión, los pollers re-leen el
--     delta y capturan también este cambio.
-- Resultado: el guardado de precio NUNCA da 500 por contención del contador.
-- Aditivo: solo reemplaza la función del trigger (no toca el trigger ni el read-path).
-- ============================================================================

create or replace function mos._bump_catalogo_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  -- NO-BLOQUEANTE: intentar el lock del contador sin esperar. Clave fija y distintiva.
  if pg_try_advisory_xact_lock(778899001122) then
    update mos.catalogo_meta set version = version + 1, updated_at = now() where id = 1;
  end if;
  -- Si no se obtuvo el lock, se salta el bump (otro writer lo hará). El cambio del
  -- producto ya quedó guardado con su updated_at → el delta por timestamp lo cubre.
  return null;
end;
$fn$;
