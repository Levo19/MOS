-- 793_fix_recon_tipo_etiqueta.sql — [AUDITORÍA 7 DÍAS · FIX] la reconciliación de stock
-- llevaba 28 DÍAS muerta en silencio.
--
-- HALLAZGO (auditoría 2026-08-15): el cron `riz-reconciliar-stock` (7:30 a diario) falla
-- desde el 2026-07-19 con `function mos._recon_tipo_etiqueta(integer) does not exist`
-- (28 fallos consecutivos; última corrida OK: 2026-07-18). Evidencia: mos.cron_log
-- job='reconciliar_stock' ok=false.
--
-- CAUSA: la función existe pero declarada `(p_tipo smallint)`, y `mos.reconciliar_stock`
-- la llama con enteros (`v_tipo` y los literales `3` / `5`, líneas 56/216/257/284 de su
-- fuente). PostgreSQL NO resuelve integer→smallint en la selección de sobrecarga (el cast
-- existe pero es de asignación, no implícito), así que la llamada no encuentra función y
-- la excepción aborta TODA la reconciliación.
--
-- FIX DE MÍNIMO RIESGO: se agrega una SOBRECARGA `(integer)` que delega en la de smallint.
-- Deliberadamente NO se reescribe `mos.reconciliar_stock` (17.681 caracteres, camino de
-- stock): un wrapper de 4 líneas resuelve el bug sin tocar una sola línea de esa lógica.
--
-- IMPACTO DE REACTIVARLA (verificado antes de aplicar): la reconciliación SOLO escribe en
-- `mos.stock_diferencias` (diagnóstico, el "Log de errores" de MOS). NO toca wh.stock ni
-- me.stock_zonas → reactivarla no mueve inventario. Al volver a correr aparecerán las
-- diferencias acumuladas que llevaban un mes sin detectarse: eso es la señal, no un daño.

create or replace function mos._recon_tipo_etiqueta(p_tipo integer)
returns text language sql immutable set search_path to '' as $$
  select mos._recon_tipo_etiqueta(p_tipo::smallint);
$$;

grant execute on function mos._recon_tipo_etiqueta(integer) to anon, authenticated, service_role;
