# Plan de cierre — Migración ecosistema MOS a 100% Supabase

> Lista maestra paso a paso. 🔵 = lo hace Claude (con 40x). 🔴 = lo hacés vos (validación física / correr funciones / decisiones).
> Orden de menor a mayor riesgo. Cada paso: 40x + tu validación antes de avanzar al siguiente. Generado 2026-06-16.

---

## FASE 1 — Activar LECTURAS directas de MOS (bajo riesgo, ya construido) — ✅ CASI COMPLETA
Las RPCs de lectura + el wiring + el dual-write ya están. Solo falta encender por módulo.
- ✅ **P1.1** `semaforoLecturasMOS()` corrido 2026-06-16 → 9/10 ✓ (solo historial ⚠).
- ⏳ **P1.2** Resolver las 8 huérfanas de `historial_precios` (tus pruebas LEV217 del cutover viejo): limpiarlas o resembrarlas → deja historial en ✓. **PENDIENTE: decisión del usuario** (borrar de sombra vs resembrar a hoja).
- ✅ **P1.3** ACTIVADAS las 7 lecturas (2026-06-16): proveedores (ya estaba) + pedidos + pagos + provprod + jornadas + eval + horario. Read-paths verificados ok+_fresh+paridad antes de encender. Kill-switch: `update mos.config set valor='0' where clave='MOS_<MOD>_LECTURA'`.
- 🔴 **P1.4** Validar visualmente en MOS que cada módulo se ve igual (recargá MOS o esperá ~2min al refresh de flags). Es lectura, reversible al instante.

## FASE 2 — Activar Fase D: LIQUIDACIONES [DINERO] — ✅ COMPLETA Y VERIFICADA (2026-06-16)
- ✅ **P2.1** `compararLiquidacionMOS_semana()` → ✓ PARIDAD EXACTA toda la semana (09-15, 0 diff, al centavo).
- ✅ **P2.2** `MOS_LIQDIA_DIRECTO`='1'. Verificado end-to-end: materializar semana en curso dio **cre=0 act=N diasStale=0** → la RPC actualiza las filas del sync GAS preservando manuales, SIN duplicar (coexistencia probada en vivo). El sync GAS QUEDA de respaldo (apagarlo = P3.3).
- 🔴 **P2.3** Validación física (al final): una liquidación/pago de prueba cuadra.

## FASE 3 — Activar Fase E: pg_cron (snapshot/cierre nocturno) — ✅ COMPLETA (2026-06-16)
- ✅ **P3.1** Ambos jobs `active=true`: `mos-snapshot-liq-semana` (23:30 Lima) + `mos-health-frescura` (04:00). Health corrido manual → ok=true, alerta=OK.
- 🔴 **P3.2** Observar 1-2 noches: `! node -e "..."` o `select * from mos.cron_log order by ts desc` → debe aparecer `snapshot_liq_semana ok=true` tras las 23:30.
- 🔵 **P3.3** Recién tras observar, apagar los triggers GAS equivalentes (`_liqDiaCronDiario`/`_liqSyncJob`).

## FASE 4 — Cutover AUTH 100% puro (ecosistema) — 🔵 BASE 4.1 CONSTRUIDA (2026-06-16)
Hoy WH+ME verifican directo CON doble-check a GAS (rescate). "100% puro" = sombra única, sin GAS. **50 call-sites mapeados.** Enfoque = DUAL-WRITE/reconciliación (NO invertir sync). Diseño: `DISENO_FASE4_auth_puro.md`.
- ✅ **A** columnas sombra (SQL 101 aplicado): fcm_token, alerta_seguridad(+revisada), forzar_horario_hasta, razon_bloqueo, bloqueado_desde.
- ✅ **D** RPCs lectura (SQL 102 aplicado): consultar_estado_dispositivo, fcm_token_dispositivo, verificar_horario_dispositivo, listar_dispositivos, dispositivos_pendientes. (dispositivos_bloqueados pendiente: cruza hoja BLOQUEOS).
- ✅ **B/C** `gas/Fase4Dispositivos.gs`: `_dualWriteDispositivo`/`resembrarDispositivosDesdeHoja` (dedup)/`compararDispositivosMOS`. **Reconciliación foldeada en `syncMOSReciente` cada 15 min** (MOS en tope de 20 triggers → folding, NO trigger nuevo). Paridad confirmada (139=139). Sombra fresca automática.
- ⏳ **E (migrar lectores)** + **F (quitar doble-check)** = el CUTOVER que cambia el auth real → requiere infra sana (deploy+prueba incremental) + validación física (que TODOS entran). NO hacer a ciegas (40x).
- 🔵 **4.2 (escritura pura)**: escrituras a RPCs directas → apagar GAS→hoja → pg_cron seguridad.
- 📌 Dato sucio detectado: 2 deviceIds duplicados en la hoja (df61a710..., 5d31a553...) — limpiar fila repetida.

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

## ⏭️ PUNTO DE RETOMA (próximo paso, cuando vuelva la infra Anthropic)
**FASE 4 · Etapa E + F (cutover auth real).** Decisión del usuario 2026-06-16: hacerlo CON infra sana (prueba incremental + validación física). Pasos al retomar:
1. **E — migrar lectores** (con flag `MOS_DISP_LECTURA` + fallback a hoja, por categoría): empezar por consumidores transversales (push/audio/espía/horario → `fcm_token_dispositivo`/`verificar_horario_dispositivo`), luego paneles (`listar_dispositivos`/`dispositivos_pendientes`), luego heartbeat (`consultar_estado_dispositivo`). Editar GAS → `clasp push` → probar cada categoría → validar visual.
2. **F — quitar doble-check** en `assets/auth/device-auth.js` (las 3 apps) SOLO tras paridad sostenida + validar que vos+cajero+aliados entran. Bump SW + deploy 3 apps.
3. Construir `dispositivos_bloqueados` (requiere portar hoja BLOQUEOS a sombra).
4. Limpiar 2 deviceIds duplicados en hoja (df61a710.../5d31a553...).
5. **Pendiente git:** commitear SQL 101/102 + Fase4Dispositivos.gs + edit MigracionMOS.gs + docs (clasificador bloqueó `git push`).
Después: **FASE 4.2** (escritura pura + apagar GAS→hoja + pg_cron seguridad). Luego FASE 5 (WH escritura), 6 (ME CPE), 7 (corte Sheets), 8 (rotar credenciales).

## Estado HOY (de dónde partimos)
✅ Catálogo lectura directa (vivo) · dual-write todos los módulos MOS · Fase D+E construidas/validadas (inertes) · auth WH+ME directo a Supabase EN VIVO (doble-check+fallback) · semáforo lecturas 9/10 ✓.
Docs: ESTADO_MIGRACION_100.md · DISENO_auth_dispositivos_cutover_supabase.md · este plan.
