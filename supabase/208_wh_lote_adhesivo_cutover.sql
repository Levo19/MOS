-- 208_wh_lote_adhesivo_cutover.sql
-- ════════════════════════════════════════════════════════════════════════════
-- FASE 5 — CUTOVER de la impresión de adhesivos a Supabase. ⚠️ NO APLICAR HASTA EL CORTE.
-- Correr SOLO cuando: (1) Edge `print-adhesivo` desplegada, (2) secret PRINTNODE_API_KEY seteado,
-- (3) probado end-to-end en una impresora real con el flag ON en 1 dispositivo.
--
-- ORDEN DEL CUTOVER (lo ejecuta/coordina el dueño):
--   A. Deploy Edge + secret:
--        supabase secrets set PRINTNODE_API_KEY=<key> --project-ref rzbzdeipbtqkzjqdchqk
--        supabase functions deploy print-adhesivo --project-ref rzbzdeipbtqkzjqdchqk
--   B. (opcional, red de seguridad cron) guardar la service key en vault:
--        select vault.create_secret('<SERVICE_ROLE_KEY>','wh_edge_service_key','cron->Edge print-adhesivo');
--   C. Prueba en 1 dispositivo: localStorage 'wh_lote_adhesivo_navegador'='1' → envasar y verificar
--      que imprime la cantidad EXACTA (sin 50/80). Revisar wh.lotes_adhesivo (completadas == total_etq).
--   D. APAGAR el lado GAS para que NO imprima en paralelo (doble motor):
--        - En el proyecto GAS warehouseMos: desinstalarTriggerLotesEtiqueta()  (mata procesarLotesPendientes)
--        - (el frontend deja de orquestar solo con el flag; GAS crearLote/imprimirSubLote quedan sin caller)
--   E. Correr este archivo (clamp + CHECK), luego:
--        update mos.config set valor='1' where clave='WH_LOTE_ADHESIVO_DIRECTO';   -- activa las RPCs
--      y activar el flag del frontend en los dispositivos (localStorage 'wh_lote_adhesivo_navegador'='1'
--      o WH_CONFIG.loteAdhesivoNavegador=true vía perfil).
--
-- ROLLBACK: update mos.config set valor='0' where clave='WH_LOTE_ADHESIVO_DIRECTO';  + reinstalar el
-- trigger GAS + apagar el flag del frontend → vuelve 100% a GAS. (El CHECK queda; es inocuo.)
-- ════════════════════════════════════════════════════════════════════════════

-- 1) CLAMP defensivo: filas heredadas de la sombra GAS con el bug podrían tener completadas > total
--    (el over-print histórico). Las normalizamos ANTES de poner el CHECK, sino el ALTER falla.
update wh.lotes_adhesivo set completadas = total_etq where completadas > total_etq;
update wh.lotes_adhesivo set completadas = 0 where completadas < 0;

-- 2) GARANTÍA DURA money-safe a nivel DB: imposible contar (ni imprimir) más que el total.
--    NOT VALID primero (no re-escanea histórico ya clampeado en el paso 1) → luego VALIDATE.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'lotes_adhesivo_completadas_rango') then
    alter table wh.lotes_adhesivo
      add constraint lotes_adhesivo_completadas_rango
      check (completadas >= 0 and completadas <= total_etq) not valid;
    alter table wh.lotes_adhesivo validate constraint lotes_adhesivo_completadas_rango;
  end if;
end $$;

-- 3) LIMPIAR la cola heredada: cancelar TODA fila pre-cutover aún incompleta (de la sombra
--    dual-write de GAS). Si no, el cron las vería 'pendientes' y RE-imprimiría lotes viejos.
--    El sistema nuevo arranca limpio: solo procesa lotes creados por la RPC de aquí en adelante.
update wh.lotes_adhesivo
   set status='CANCELADO', fecha_ultimo_update=now()
 where completadas < total_etq
   and status in ('ENCOLADO','CREADO','IMPRIMIENDO','CALIBRANDO','PAUSADO_ERROR','PAUSADO_OUT_PAPER','PAUSADO_USUARIO');

-- 4) ACTIVAR el lado servidor (RPCs + cron). El frontend además necesita su flag por dispositivo
--    (localStorage 'wh_lote_adhesivo_navegador'='1' o WH_CONFIG.loteAdhesivoNavegador=true).
update mos.config set valor='1' where clave='WH_LOTE_ADHESIVO_DIRECTO';
