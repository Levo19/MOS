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
- ✅ **F (auth puro) COMPLETA Y EN VIVO (2026-06-16)**: flag `MOS_AUTH_SIN_DOBLECHECK='1'` + device-auth v1.0.23 (lee `sin_doblecheck` de verificar_dispositivo, SQL 103). Las 3 apps verifican leyendo SOLO la sombra, sin GAS. Validado: MOS+WH+ME cargan v1.0.23 y entran. Gradual (v1.0.22 ignora el flag = seguro). Kill-switch: `node supabase/_flag_doblecheck.js off`. Espejo instantáneo cableado en revocar/bloquear/liberar (Config.gs/Bloqueos.gs).
- ⏳ **E (migrar lectores GAS de paneles a RPCs)**: opcional/secundario (los paneles admin pueden seguir por GAS; el auth de ENTRAR ya es puro). Pendiente.
- 🛑 **4.2 (escritura pura) — RECLASIFICADA (hallazgo 40x 2026-06-16):** NO hacer como paso intermedio. La escritura directa de auth (aprobar/revocar en la sombra) NO coexiste con el resembrado hoja→sombra de 15min (lo pisa = bug del rollback) NI con los 50 lectores GAS que aún leen la hoja. **El estado actual (escritura GAS→hoja + espejo sombra + lectura sombra) es el ÓPTIMO ESTABLE.** Apagar la hoja = parte del CORTE DE SHEETS de dispositivos (FASE 7), seguro solo tras migrar los 50 lectores (Etapa E). El auth ya es "puro" en lo que importa (ENTRAR sin GAS ✅).
- 📌 Dato sucio detectado: 2 deviceIds duplicados en la hoja (df61a710..., 5d31a553...) — limpiar fila repetida.

## FASE 5 — WH escritura directa — 🔵 PRE-REQUISITOS LISTOS (2026-06-16)
- ✅ 10 RPCs PASO 4 construidas+validadas inertes (90 casos, 0 fallos): crear_ajuste/registrar_merma/crear_preingreso/actualizar_preingreso/crear_guia/cerrar_guia(FIFO)/reabrir_guia + marcar_preingreso_procesado/crear_auditoria/get_o_crear_guia_dia/agregar_detalle_guia.
- ✅ **Integridad de stock blindada**: 0 duplicados por cod_producto (el 7750243071406 ya consolidado) + índice único `ux_wh_stock_cod_producto` (SQL 104 aplicado) → habilita el `on conflict` de las RPCs.
- 🎯 **DECISIÓN DEL USUARIO 2026-06-16: WH GAS-CERO.** ⚠️ **HALLAZGO 40x 2026-06-16: WH YA ESTÁ CASI EN GAS-CERO** (los docs DISENO_paso5/orquestadores estaban DESACTUALIZADOS). Estado REAL verificado (`_diag_flags_wh.js`):
  - ✅ **B1 auth · B2 RLS · B3 lecturas directas** (`lecturaNavegador:true` server-wide, validado e2e hoy: mint-wh+stock_enriquecido_rls+leer_tabla_rls 200).
  - ✅ **ESCRITURA DIRECTA DE DATOS EN PRODUCCIÓN** desde 2026-06-14 (`escrituraNavegador:true` + **27/28 flags WH_*_DIRECTO ON**): guías/stock/mermas/envasado/ajustes/preingresos/auditorías/cargadores/OCR/alertas. Solo 1 OFF: `WH_MARCAR_PRODUCTO_NUEVO_APROBADO` (cross-domain WH↔MOS, crea producto en MOS — queda en GAS por diseño).
  - ⏳ **Falta para GAS-CERO TOTAL (WH ~95% hecho)**: (1) **impresión** — los 6 builders YA portados en `js/impresion-directa.js` (bienvenida/etiquetas/aviso/membretes, byte-a-byte del GAS); falta cargar el módulo + cablear (inerte) + **VALIDAR IMPRIMIENDO físicamente** + el **aviso-cajeros fan-out cruza a ME.CAJAS** (necesita Edge cross-dominio, el navegador WH no ve cajas de ME) + drift térmico (hoy offset base=0). (2) **OCR boleta** (IA+imagen SUNAT). (3) **`aprobar_producto_nuevo`** (cross-domain MOS, único flag OFF). (4) **B6**: apagar el GAS residual. Todo necesita validación física en impresora / Edge fan-out / cross-domain — NO "a ciegas".

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
