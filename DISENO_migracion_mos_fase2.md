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
- ✅ **Finanzas + historial COMPLETO** (commit 4fe698e): SQL 76/77 APLICADOS (gate mos._claim_ok + grant authenticated + fix seguridad: historial tenía acceso PUBLIC, eliminado); heartbeat `_estamparLatidoMOS` en gas/MigracionMOS.gs (syncMOSReciente/Completo, **GAS pusheado**); frontend `getFinanzasRango`/`getHistorialPrecios` cableados con `_conFallbackMOS` + flags `mos_finanzas_directo`/`mos_historial_directo` (OFF). curl 200, paridad centavo. INERTE.
- ⏳ Resto de lecturas (proveedores, pedidos, jornales-lectura, etc.) — no empezadas (opcionales; las 3 principales ya están).

**🟡 FASE 2 (escrituras inertes) — EN CURSO:**
- ✅ **Catálogo SQL** (commit 4fe698e): `mos.crear_producto`/`actualizar_producto`/`publicar_precio` (78) + `crear/actualizar_equivalencia` (79). ID atómico (secuencia `mos.seq_producto`, arregla lost-update de Productos.gs), idempotencia on-conflict, UPDATE atómico, gate `mos._claim_ok` + kill-switch `MOS_CATALOGO_DIRECTO`. Validado **51/51** tx-rollback. INERTE.
- ✅ **Cimiento idempotencia proveedores** (commit 43f3f19): `80` columnas `local_id` + índices únicos en las 4 tablas de proveedores.
- ⏳ **FALTA**: (a) cablear escritura del catálogo en frontend (portar `_postDirectoMOS` a js/api.js — el agente se cortó por timeout, api.js quedó SIN tocar/intacto); (b) RPCs de escritura proveedores/pedidos/**pagos** (sobre el cimiento 80); (c) RRHH/etiquetas/horarios; (d) **finanzas/gastos/jornales/liquidaciones AL FINAL** (dinero, máximo cuidado).

**⏳ FASE 3 (cutover) / FASE 4 (apagar sync) — del usuario / posteriores.**

### ⚠️ NOTA DE SESIÓN (2026-06-15): el sistema se SATURÓ
3 agentes consecutivos fallaron por "Stream idle timeout" (B finanzas-1ª-vez, C frontend-escritura, D proveedores-RPCs) tras una sesión muy larga. Se consolidó todo lo bueno en commits limpios; NADA quedó roto (api.js MOS validado, el 80 es inerte). **Retomar en sesión fresca** para que los agentes no fallen.

### SIGUIENTE PASO CONCRETO (retoma)
1. Portar `_postDirectoMOS` a js/api.js MOS (dispatcher escritura, patrón de WH `_postDirecto`) + cablear escritura del catálogo (crear/actualizar producto/equivalencia/publicar_precio) con flag `mos_catalogo_directo`. Las RPCs ya existen (78/79).
2. RPCs de escritura proveedores/pedidos/pagos (sobre cimiento 80, gate + idempotencia local_id estricta en pagos).
3. Seguir lotes Fase 2 por riesgo creciente; finanzas/jornales al final.

### LO QUE DEBE HACER EL USUARIO (al final, para ACTIVAR — no antes)
Correr `syncCatalogoSupabase()` 1 vez (crea CATALOGO_SYNC_HEARTBEAT) → activar `localStorage mos_catalogo_directo='1'` en un piloto → validar catálogo directo. Ídem finanzas cuando esté cableado. Todo con rollback = borrar el flag.
