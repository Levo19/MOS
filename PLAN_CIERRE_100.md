# Plan de cierre — Migración ecosistema MOS a 100% Supabase

> Lista maestra paso a paso. 🔵 = lo hace Claude (con 40x). 🔴 = lo hacés vos (validación física / correr funciones / decisiones).
> Orden de menor a mayor riesgo. Cada paso: 40x + tu validación antes de avanzar al siguiente. Generado 2026-06-16.

---

## FASE 1 — Activar LECTURAS directas de MOS (bajo riesgo, ya construido)
Las RPCs de lectura + el wiring + el dual-write ya están. Solo falta encender por módulo.
- 🔴 **P1.1** Correr `semaforoLecturasMOS()` en el editor GAS de MOS → confirmar qué módulos están en ✓ (la última vez: 9/10).
- 🔵 **P1.2** Resolver las 8 huérfanas de `historial_precios` (tus pruebas LEV217 del cutover viejo): limpiarlas o resembrarlas → deja historial en ✓.
- 🔵 **P1.3** Activar la lectura directa módulo por módulo (flag server), empezando por los no-dinero (proveedores → pedidos → prov-producto → jornadas → evaluaciones → horarios).
- 🔴 **P1.4** Tras cada módulo, validar visualmente en MOS que se ve igual (es lectura, reversible al instante con kill-switch).

## FASE 2 — Activar Fase D: LIQUIDACIONES [DINERO]
Construida y validada (paridad exacta). Falta encender.
- 🔴 **P2.1** Correr `compararLiquidacionMOS_semana()` → confirmar ✓ PARIDAD sobre datos reales.
- 🔵 **P2.2** Activar `MOS_LIQDIA_DIRECTO`='1' + apagar el sync Hoja→sombra de `liquidaciones_dia`/`liquidaciones_pagos` (sino lo pisa) + cablear.
- 🔴 **P2.3** Validación física: hacer una liquidación/pago de prueba y verificar que cuadra (es dinero).

## FASE 3 — Activar Fase E: pg_cron (snapshot/cierre nocturno)
Jobs construidos, inertes (doble candado).
- 🔵 **P3.1** Tras validar Fase D: `alter_job(... active:=true)` en los 2 jobs (snapshot-liq + health-frescura).
- 🔴 **P3.2** Observar 1-2 noches en `mos.cron_log` que persiste el snapshot.
- 🔵 **P3.3** Recién entonces apagar los triggers GAS equivalentes (`_liqDiaCronDiario`/`_liqSyncJob`).

## FASE 4 — Cutover AUTH 100% puro (ecosistema — la tabla es compartida)
Hoy WH+ME verifican directo CON doble-check a GAS (rescate). "100% puro" = sombra única, sin GAS.
- 🔵 **P4.1** Sync INVERSO: `mos.dispositivos → HOJA` + apagar el viejo Hoja→sombra (no coexisten).
- 🔵 **P4.2** Migrar los ~40 lectores de la hoja DISPOSITIVOS (mint cross-app, paneles, bloqueo, espía) a leer la sombra.
- 🔵 **P4.3** Quitar el doble-check (sombra = fuente única) en las 3 apps.
- 🔴 **P4.4** Validar que TODOS los devices reales entran (vos + cajero + aliados). Watchdog/Reintentar como red.
- 🔵 **P4.5** Limpiar devices: dejar ACTIVOS solo los en uso, bloquear el resto (ya efectivo, sin sync que pise).

## FASE 5 — WH escritura directa
Las 7 RPCs PASO 4 están inertes.
- 🔵 **P5.1** Cablear WH a escritura directa (dual-write / RPCs atómicas) con su 40x.
- 🔴 **P5.2** Validación física en almacén (guías, envasado, stock — dinero/inventario).

## FASE 6 — ME CPE (boleta/factura directa)
Edge `emitir-cpe` cableada, inerte.
- 🔴 **P6.1** Cargar el token de NubeFact (secrets `NUBEFACT_TOKEN`/`NUBEFACT_RUC`).
- 🔵 **P6.2** Verificar serie + activar `ME_CPE_DIRECTO`.
- 🔴 **P6.3** Emitir UNA boleta de prueba vigilada (es fiscal, SUNAT).

## FASE 7 — Corte final de Sheets (la gran decisión, por app)
- 🔵 **P7.1** Verificar que TODA lectura/escritura de cada app va por Supabase (cero dependencia de hoja).
- 🔴 **P7.2** Decisión final: retirar Sheets como fuente. Con vos, app por app, validando.

## FASE 8 — Cierre
- 🔵 **P8.1** pg_cron nocturno completo (reconciliación/snapshot) + limpieza de wiring muerto.
- 🔴 **P8.2** Rotar credenciales (PAT Supabase `sbp_*` + Anthropic `sk-ant-*`). **NO** rotar `WH_JWT_SECRET`.

---

## Regla transversal (todas las fases)
- **40x adversarial** en cada paso antes de declararlo listo (apps de dinero en prod).
- **Nada se activa sin tu validación física** en los módulos de dinero (lección del rollback).
- Cada activación tiene **kill-switch** (revertir en 1 comando / flag).
- Device colgado → **Reintentar / re-aprobar, NUNCA borrar cache**.

## Estado HOY (de dónde partimos)
✅ Catálogo lectura directa (vivo) · dual-write todos los módulos MOS · Fase D+E construidas/validadas (inertes) · auth WH+ME directo a Supabase EN VIVO (doble-check+fallback) · semáforo lecturas 9/10 ✓.
Docs: ESTADO_MIGRACION_100.md · DISENO_auth_dispositivos_cutover_supabase.md · este plan.
