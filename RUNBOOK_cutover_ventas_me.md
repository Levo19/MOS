# RUNBOOK — Cutover ventas-ME (Etapa 3: edición de ticket 100% Supabase)

**Estado:** construido + verificado + revisión adversarial 100x aplicada. **INERTE** (flag `me_edit_directo` OFF → opera por GAS bridge, idéntico a hoy). Falta solo el **flip controlado** (pasos abajo).

## Qué migra
Las 3 ediciones de ticket del panel MOS dejan de ir `MOS→GAS→bridge-ME` y pasan a RPCs atómicas en Postgres:
- `meEditarFormaPago` → `me.editar_forma_pago` (corrige forma de pago + historial)
- `meEditarCliente` → `me.editar_cliente` (cambia cliente; bloquea si CPE EMITIDO; + historial)
- `anularTicketME` → `me.anular_venta` (ANULADO + historial + reposición stock idempotente + descuento pickup WH vía `wh.pickup_descontar_venta`, **todo atómico**)

**NO migra** (siguen en GAS, a propósito): `cambiarMetodoME` (semántica POR_COBRAR→activación), `meAprobarComoCredito`, y **NV→CPE** (`convertirNVaCPE`, Etapa 4 — fiscal, depende de `ME_CPE_DIRECTO`).

## Artefactos
- **SQL 260** (`supabase/260_me_ventas_edicion_directa.sql`) — APLICADO. 4 RPCs + helper `me._venta_hist_append` + redefinición de `me.venta_reposicion_datos` (gate ampliado a `MOS`).
- **MOS frontend** (`js/api.js`, v2.43.358) — helper `_sbRpcMEWrite` (profile `me`), normalizador `_desempacarME`, flag `_mosEditDirecto`, 3 branches en `_postDirectoMOS`, registro en `_MOS_POST_DIRECTO`. Gateado `me_edit_directo` (OFF).
- **ME GAS** (`MigracionME.gs`) — `activarMEVentasDirecto()`/`revertirMEVentasDirecto()` (sync-off de `ventas`) + heal insert-missing de `ventas` en `_syncMEImpl`. **`NubeFact.gs`** — `reconciliarCPEsPendientes` ahora patchea la sombra (nf_estado) además de la Hoja.

## El blocker y por qué
El sync ME `Hoja→sombra` (cada 15 min, cola 500) re-upsertea `me.ventas` desde la Hoja → **revertiría** una edición directa. Por eso hay que meter `ventas` a `ME_SYNC_OFF_TABLAS`. Con sync-off, el heal insert-missing cubre el agujero de durabilidad (una creación cuyo `_dualWriteVentaME` falló se re-inserta; **nunca** actualiza filas existentes → no revierte ediciones).

## Preconditions (verificadas por la revisión 100x)
1. ✅ **Toda escritura de `me.ventas` llega a la sombra directo** (no depende del batch): creación (`crear_venta_directa`/`_dualWriteVentaME`), cierre/anulación masiva, cobro crédito, baja CPE, edits — todas patchean directo. Auditado writer-por-writer.
2. ✅ **`reconciliarCPEsPendientes`** ahora patchea la sombra (antes Sheet-only → estado fiscal stale bajo sync-off). CORREGIDO.
3. ✅ **Lecturas del panel ya son Supabase-directo** (`mos.cierres_caja`, `lecturaNavegador=1`) → una edición directa se refleja.
4. ✅ **`me.anular_venta` atómico** → reposición/pickup todo-o-nada (sin stock fantasma, sin doble-descuento de pickup no-idempotente).
5. ⚠️ **Verificar el valor vivo** de `ME_SYNC_OFF_TABLAS` antes de flipear (debe terminar incluyendo `ventas` sin perder `stock_zonas,guias_cabecera,guias_detalle`).

## Pasos del FLIP (en orden)
1. **Deploy** (si no está): MOS frontend v2.43.358 (git push → GitHub Pages) + ME GAS (`clasp push`).
2. **ME editor** → correr `estadoMESupabase()` → anotar `ME_SYNC_OFF_TABLAS` actual.
3. **ME editor** → correr `activarMEVentasDirecto()` → confirma `ventas` agregado preservando lo existente. (Esto detiene el revert; el heal insert-missing arranca solo en el próximo sync.)
4. **Prender el flag** `me_edit_directo` (server MOS config `meEditDirecto=1` o localStorage `me_edit_directo=1`).
5. **Validar en vivo (con un ticket de prueba):**
   - Cambiar forma de pago → refrescar panel → persiste (no revierte a los 15 min).
   - Editar cliente de una NV → persiste; intentar sobre un CPE EMITIDO → debe rechazar.
   - Anular una venta (caja abierta) → ANULADO, sin tocar stock (el cierre la filtra).
   - Anular una venta **post-cierre** → ANULADO + reposición de stock (kardex `ANUL:<id>`) + pickup origen descontado.
   - Verificar el historial del ticket muestra las entradas nuevas.

## Rollback
- Apagar `me_edit_directo` (vuelve al GAS bridge al instante).
- Correr `revertirMEVentasDirecto()` (reactiva el sync de `ventas`). **Apagar el flag ANTES** para no descuadrar.

## Pendientes menores (no bloquean el flip; documentados)
- **`clientes_frecuentes`**: `me.editar_cliente` NO back-fillea el directorio de clientes frecuentes (el GAS sí, vía `verificarYAgregaCliente`). La venta se corrige igual; el directorio solo no auto-aprende en una *corrección*. No es dinero. (Si molesta: agregar upsert a `me.clientes_frecuentes` en la RPC.)
- **Anular idempotente**: una venta ya ANULADO ahora togglea éxito (noop) en vez de error (GAS daba "ya anulada"). Comportamiento más seguro.
- **Pickup ABSORBIDO**: descontar un pickup ya absorbido por el acumulador es no-op para el despacho real (paridad exacta con el GAS, que salta solo COMPLETADO/CANCELADO/PARCIAL). Tema ortogonal del acumulador, no lo introduce este cutover.
