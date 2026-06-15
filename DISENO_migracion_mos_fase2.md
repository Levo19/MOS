# Migración MOS (master) → Supabase directo — Plan Fase 2

> Estado: Fase 1 (sombra `mos.*` backfilleada + sync triggers) HECHA. Falta Fase 2 = PWA directo, replicando WH.
> MOS = `C:\Users\ISO\ProyectoMOS`, frontend `index.html`+`js/api.js`, GAS deploy `AKfycbxalFhPdiVi`, router `gas/Code.gs _route()` con **314 acciones**.
> ⚠️ MOS la master NO empezó migración de lectura/escritura directa (el trabajo previo fue ME+WH). `js/api.js` de MOS es un wrapper finito: NO tiene _postDirecto/token/Supabase/OfflineManager → se porta desde WH.

## Roadmap (replica WH: PASO3 lectura → PASO4 escritura inerte → PASO5 cutover → apagar sync)

**FASE 0 — Cimientos (inerte, bajo riesgo):** Edge `mint-mos` (clon de mint-wh, `APP='mos'` hardcodeado, device app∈{'','mos'}) · `mos._claim_ok()` aceptando `('','mos')` + wrappear `mos.catalogo_wh_rls`/`mos.verificar_clave_admin` para aceptar claim mos · portar a js/api.js MOS: `_mintTokenMOS`/`_sbRpcMOS`/`_postDirecto`/OfflineManager (copiar shape de WH) · garantizar que el sync catálogo vive (gate cuadre).

**FASE 1 — Lecturas directas:** flag `MOS_LECTURA_DIRECTA` por módulo + fallback GAS+cache. Empezar por las que YA tienen RPC: `mos.finanzas_rango` (13), `mos.historial_precios_lista` (12) — solo falta grant authenticated+claim wrapper. Luego catálogo lectura (`mos.productos`/`mos.catalogo_wh_rls`) con **gate de frescura** (sombra congelada silencia alertas — bug ya visto).

**FASE 2 — Escrituras directas INERTES+validadas:** capa `mos.*` write (security definer set search_path='' + `mos._claim_ok()` + idempotencia local_id + UPDATE atómico), flag `MOS_*_DIRECTO=0`, tx-rollback. Orden por riesgo: (1) **catálogo** crear/actualizar/publicar_precio/equivalencias (cross-domain, NO dinero; arregla el lost-update — Productos.gs hoy SIN _conLock), (2) proveedores/pedidos, (3) evaluaciones/etiquetas/horarios, (4) **finanzas/jornales/liquidaciones/pagos AL FINAL** (dinero, 45 acciones jornales = lo más delicado).

**FASE 3 — Cutover por módulo:** flip `MOS_*_DIRECTO=1` uno por uno + fallback + reconciliación. Catálogo primero (desbloquea crear-producto-directo en WH/ME).

**FASE 4 — Apagar sync + Edge/pg_cron:** apagar trigger sync del módulo migrado; side-effects (push/print/notif) a Edge; triggers GAS (cierre semanal) a pg_cron.

## PILOTO recomendado (próxima sesión): CATÁLOGO en LECTURA DIRECTA
Máximo valor cross-domain (hoy WH/ME delegan crear-producto a GAS MOS), sombra ya backfilleada, RPC `mos.catalogo_wh_rls` ya probada por WH, lectura=bajo riesgo. Valida TODO el cimiento (mint-mos+_claim_ok+_sbRpcMOS+_postDirecto+flag) sin tocar dinero. Pasos: mint-mos → mos._claim_ok+grant → portar token/rpc a api.js → flag MOS_CAT_LECTURA_DIRECTA → gate frescura → flip+paridad.

## Reuso de WH
COPIAR tal cual: `_postDirecto`, `_sbRpcWH`→`_sbRpcMOS`, `_mintTokenWH` shape, `OfflineManager`, template RPC, Edges `imprimir`/`ia`/`fotos`.
NUEVO: Edge `mint-mos` (mint-wh hardcodea warehouseMos), `mos._claim_ok()`, toda la capa write `mos.*`, grants authenticated+claim sobre finanzas_rango/historial_precios.

## Riesgos
App de DINERO en prod (ventas/cajas/finanzas/jornales). NO tocar sin extremo cuidado: liquidaciones/jornales/finanzas/pagos. Catálogo sin lock → UPDATE atómico obligatorio. Sombra congelada=alertas silenciadas → gate frescura. setConfig/device-auth = superficie de ataque (Web App público). Espía WebRTC = aislado, dejar para el final.

---

## PROGRESO (2026-06-15) — PUNTO DE RETOMA

**✅ FASE 0 (cimientos) — COMPLETA, deployada, inerte.**
- Edge `mint-mos` (app='MOS', reusa WH_JWT_SECRET, verify_jwt=false) deployada+verificada (curl: válido→token, inválido→401, RPC→200, corrupto→401).
- `mos._claim_ok()` (SQL 74). `catalogo_wh_rls`/`verificar_clave_admin` re-gateadas (wh OR mos) sin romper WH.
- `js/api.js` MOS: `API._sb = {lecturaDirecta, flag, mintToken, deviceId, rpc, leerTabla, conFallback}`. Flags `mos_lectura_navegador`/`MOS_CONFIG` default OFF. (commits abfe5d2)

**🟡 FASE 1 (lecturas) — en curso:**
- ✅ **Catálogo (PILOTO) COMPLETO** (commit 3ab8f7d): RPC `mos.productos_master_rls` (75) gate+grant+_fresh; gate de frescura por HEARTBEAT (`_estamparLatidoCatalogo` en MigracionCatalogo.gs estampa `CATALOGO_SYNC_HEARTBEAT`, TTL 180min, NO usa updated_at); `API.get('getProductos')` envuelto con `_conFallbackMOS`, flag `mos_catalogo_directo` (OFF), mapeo snake→shape-hoja `_MOS_PROD_SPEC`. Validado 17/17+curl+paridad 2368. **GAS pusheado (clasp)**. INERTE.
- 🟡 **Finanzas + historial PARCIAL** (commit b55ada0): SQL `76_mos_finanzas_rango_rls` + `77_mos_historial_precios_rls` listos y SEGUROS (gate mos._claim_ok + gate frescura MOS_SYNC_HEARTBEAT/TTL). ⚠️ El agente se cortó por timeout: **FALTA (1) verificar que 76/77 estén aplicados a Supabase, (2) estampar MOS_SYNC_HEARTBEAT en `syncMOSReciente`/`syncMOSCompleto` (gas/MigracionMOS.gs) — NO hecho, (3) cablear `getFinanzasRango`/`getHistorialPrecios` en js/api.js con `_conFallbackMOS`+flag por-acción.** Hasta eso, finanzas/historial siguen 100% GAS.
- ⏳ Resto de lecturas (proveedores, pedidos, jornales-lectura, etc.) — no empezadas.

**⏳ FASE 2 (escrituras inertes) — NO empezada.** Es la mayor parte (capa write `mos.*` para ~314 acciones, orden: catálogo→proveedores→evaluaciones/etiquetas→finanzas/jornales/liquidaciones). Requiere portar OfflineManager + `_postDirecto` a js/api.js de MOS (hoy MOS no los tiene).

**⏳ FASE 3 (cutover) / FASE 4 (apagar sync) — del usuario / posteriores.**

### SIGUIENTE PASO CONCRETO (retoma)
Completar Fase 1 finanzas/historial: verificar 76/77 aplicados → agregar heartbeat MOS en MigracionMOS.gs → cablear los 2 GET en api.js (patrón idéntico al catálogo). Luego seguir con más lecturas o arrancar FASE 2 (escrituras), empezando por el catálogo (crear/actualizar producto — desbloquea WH/ME, y arregla el lost-update de Productos.gs sin _conLock).

### LO QUE DEBE HACER EL USUARIO (al final, para ACTIVAR — no antes)
Correr `syncCatalogoSupabase()` 1 vez (crea CATALOGO_SYNC_HEARTBEAT) → activar `localStorage mos_catalogo_directo='1'` en un piloto → validar catálogo directo. Ídem finanzas cuando esté cableado. Todo con rollback = borrar el flag.
