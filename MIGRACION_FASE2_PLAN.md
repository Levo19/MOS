# Plan de Fase 2 — DEFINITIVO (diseño + auditoría adversarial)

> Generado por workflow multi-agente (41 agentes · 64 hallazgos · 30x por parte + 50x final).
> Solo diseño/auditoría de lectura. NO toca producción. Verificado byte-a-byte contra código real.
> Mi pasada senior confirmó los hallazgos "HOY" (C5/C6) contra el código. Fecha: 2026-06-10.

## TL;DR
- **NO hacer Fase 2 completa.** Tres bloqueantes estructurales invalidan el grueso del valor (PWA directo + Realtime) hasta resolverlos.
- **Primer incremento seguro = completar Fase 1.D en MOS** (GAS-directo, flip de `getFinanzasRango`). Cero navegador, cero RLS, ~90% del beneficio de performance, rollback con paridad Fase 1.D.
- **URGENTE e independiente de Fase 2:** hay vulnerabilidades VIVAS hoy (C5 `getConfig` filtra ADMIN_GLOBAL_PIN sin auth; C6 `clienteListar` filtra PII de todos los clientes + IDOR de `clienteConfirmarPedido`). Arreglar primero.

## Los 3 bloqueantes estructurales de Fase 2
- **#0 — Sync sombra es BATCH 15 min, no inline.** Realtime sobre la sombra es MENOS fresco que el polling actual a Sheets. Realtime no aporta "<1s" hasta que la escritura a Supabase sea event-driven (toca caminos de dinero).
- **#1 — No hay binding autoritativo dispositivo→zona.** `mos.dispositivos.ultima_zona` se escribe desde el parámetro del cliente (Bloqueos.gs:70). Toda RLS por zona es teatro hasta tener `mos.dispositivo_zonas` admin-only.
- **#2 — Lectura directa pierde el rollback server-side de Fase 1.D.** Un flag client-side (bundle GitHub Pages + SW + iOS) no se apaga remotamente. Sin paridad de rollback, no apto para dinero.

## Modelo Auth + RLS recomendado (resumen)
- La PWA NUNCA lee tablas base: solo RPCs `security definer` que derivan la zona del JWT.
- Identidad: Edge Function `mint-token` (no GoTrue de usuarios). Firma ASIMÉTRICA RS256/ES256 (NO el secreto HS256 que valida service_role). `exp` ≤ 5 min, re-mint en heartbeat. `role:'authenticated'` literal.
- Claim de zona SOLO de `mos.dispositivo_zonas` (admin-only). Fail-closed: sin claim → 0 filas. Prohibido `OR zona_id IS NULL`.
- Prerequisitos: hashear `mos.personal.pin` (hoy texto plano); mover PINs/secretos a schema `secret` no expuesto en Data API.
- Endurecimiento inmediato (no rompe nada): `revoke usage on schema me from anon, authenticated`; `revoke all on function 06-12 from public`; RLS de `me` por loop dinámico (no lista hardcoded); test de aislamiento (grants anon/authenticated en me/wh/mos = VACÍO).

## Orden de implementación
- **2.A — Completar Fase 1.D (GAS-directo, el ROI real):** portar flip a MOS (`MigracionMOS.gs` ← patrón de `MigracionWH.gs:581-612`), flipear `getFinanzasRango` (NO `getFinanzasDia`, que materializa/escribe). `getDashboardFlip`/`getHistorialStockFlip` en WH.
- **2.B — Plumbing Auth+RLS** (sin exponer dinero): `mos.dispositivo_zonas` + `mint-token` + `13_fase2_rls_helpers.sql` + hash de PIN.
- **2.C — UN piloto de lectura directa** (no-dinero, analítico): `wh.rotacion_semanal_rls`, flag server-controlled, fallback a GAS, comparador corrido como `authenticated` (no service_role).
- **2.D — Realtime mínimo** SOLO tras resolver #0 (escritura inline). Broadcast `{tabla,zona,ts}` + refetch debounced. NUNCA `postgres_changes` sobre tablas de dinero.

## Registro de riesgos CRÍTICOS
- **C1** binding dispositivo→zona falsificable → `mos.dispositivo_zonas` admin-only.
- **C2** `ventas_hoy_zona` confía en `prefijos` del cliente (vacío→todo) → RPC que ignora prefijos y deriva zona del claim.
- **C3** `estado_cajas()` sin params devuelve TODAS las cajas/saldos → variante por `jwt_zonas()`.
- **C4** JWT HS256 = secreto de service_role → firma asimétrica.
- **C5 (HOY)** `getConfig` ungated devuelve ADMIN_GLOBAL_PIN (Code.gs:235→523). → allowlist de claves no-sensibles + gate admin.
- **C6 (HOY)** `clienteListar` filtra PII de todos los clientes sin auth (ClientePortal.gs:105) + IDOR `clienteConfirmarPedido` (240) + idPedido enumerable. → gate admin + validar token↔pedido + idPedido UUID.
- **C7** stock optimista pisado por refetch (offline.js:572 sin guard) → prohibir lectura directa/Realtime de datos con parche optimista.
- **C8** `ref_local = Date.now()` (index.html:14578) sin entropía → `crypto.randomUUID()`.
- **C9** dedup de venta solo escanea últimas 200 filas (Ventas.gs:182) → dedup por `ref_local` indexado o por día Lima.
- **C10** correlativos mirror puede retroceder si se mintea desde Postgres con sync batch activo → UN solo minter; Postgres read-replica hasta cutover atómico.
- **C11** premisa Realtime falsa (sync batch) → bloqueante #0.
- **C12** rollback sin paridad → flag server-controlled por endpoint + fallback GAS.
- **C13** se pierde el cache coalescente de GAS (polling 3s × N estaciones → ~4M RPC/mes) → no eliminar coalescing; directo tiene MAYOR costo de cuota.
- **C14** seq scans en path caliente (`ventas_hoy_zona` no sargable; `estado_cajas` sin cota de fecha) → índices/filtros sargables + EXPLAIN con volumen real.

## Primer incremento concreto (cuando se decida arrancar 2.A)
Portar el flip Fase 1.D a MOS y flipear `getFinanzasRango` (read histórico/cerrado, el más pesado):
- GAS: `MigracionMOS.gs` (+`_fuenteDatos`/`activar`/`desactivarUno`) + `Finanzas.gs` (`getFinanzasRangoFlip`).
- SQL: `13_mos_finanzas_rango.sql` (`mos.finanzas_rango(desde,hasta)` replicando FormaPago/TZ/POR_COBRAR; `revoke from public`, grant solo a service_role).
- Flag: Script Property `FUENTE_DATOS`/`FUENTE_DATOS_OFF` (solo GAS lo lee; frontend NO cambia).
- Prueba: `compararFinanzasRangoMOS()` diff por skuBase ±0.01 + validar lag real (max ts vs última fila) + 7 días cuadre 0 + speedup ≥1.3x.
- Rollback: `desactivarSupabaseMOS()` → ≤15s a Sheets, sin redeploy.
