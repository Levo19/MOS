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

## FASE 6.5 — MOS read-backs GAS delete-safe (✅ HECHO 2026-06-18, GAS @422)
**Objetivo: "si borro el Sheet de MOS, la LECTURA de MOS sigue funcionando" — COMPLETO para todos los read-backs operativos de GAS.**
Antes: los endpoints GAS (getProveedoresMaster/getJornadas/getGastos/getEvaluacionesDia/getLiquidaciones*/...) leían la HOJA → eran el fallback del front y los usaban los orquestadores GAS (P&L). Ahora leen la SOMBRA `mos.*` con gate `_fresh` + fallback HOJA (espejan el patrón del front).
- ✅ **Helper nuevo** en `gas/Supabase.gs`: `_sbLeerListaMOS(fn,args,flag)` (array), `_sbLeerObjetoMOS` (objeto), `_sbLeerRpcFreshMOS` (respuesta-completa). Gate = MAESTRO `MOS_LECTURA_NAVEGADOR` OR flag de módulo (memo por-ejecución). `_fresh!==true`/error/flag-off ⇒ `null` ⇒ fallback HOJA. NUNCA lanza.
- ✅ **24 read-backs migrados** (todos con paridad de shape verificada contra la RPC + smoke-test `_fresh:true`):
  - Proveedores.gs: getProveedoresMaster·getPagosProveedor·getPedidosProveedor·getProveedorProductos·getProveedoresQueVenden + el read de PAGOS dentro de getHistoricoProveedor.
  - Finanzas.gs [DINERO]: getJornadas·getGastos·`_calcularGastos`·`_calcularPersonal` (PERSONAL_MASTER + JORNADAS-tombstones + LIQUIDACIONES_DIA presente).
  - Liquidaciones.gs [DINERO]: getLiquidacionesPendientesDia·getPersonalDiaFast·getLiquidacionesPagadas·getPagoDetalle·getLiqDiaBonSan·getLiquidacionesVetadas.
  - Catálogo/otros: getEquivalencias·getProductosEditadosRecientes·getCategorias·getEvaluacionesDia·getEtiquetasPendientes·getHorariosApps.
- ✅ **2 RPCs nuevas** (aplicadas): `mos.gastos_lista` (163), `mos.liquidaciones_dia_lista` (161). + flags `MOS_GASTOS_LECTURA`/`MOS_ETIQ_LECTURA`='1' (162).
- ✅ **Money-safety TZ:** los filtros por día usan `at time zone 'America/Lima'` server-side; cuando el dato viene de la RPC NO se re-aplica el filtro `substring(0,10)` (UTC) → no se descartan filas tarde-Lima. Validado: `liquidaciones_dia_lista`==`personal_dia_lista`==raw (n=3, sum=165, exacto).
- 🟡 **SKIP deliberado (riesgo de shape / hot-path):** getProductosMaster·getProductoMaster·getProductoPorCodigo (el front re-mapea el crudo; GAS quedaría frágil), getResumenDia (RPC devuelve array, GAS objeto), getEtiquetasPorZona (sin RPC del shape agregado), `_liqMapaPagados` (idempotencia DENTRO de marcarPagos = write path; el Sheet es autoridad ahí hasta el cutover de escritura). Estos NO bloquean el delete-safe de lectura porque PRODUCTOS_MASTER lo lee el front directo; el resto son agregados con su propio fallback.

## FASE 6.6 — MOS ESCRITURA directo-puro (🔴 OWNER-GATED · runbook listo, NADA flipeado)
**Hallazgo clave 2026-06-18:** la escritura directo-puro SOLO está cableada en el FRONTEND para **catálogo** (`MOS_CATALOGO_DIRECTO`, gate `_mosCatalogoDirecto`) y **proveedores** (`MOS_PROVEEDORES_DIRECTO`, gate `_mosProveedoresDirecto`). Los demás módulos (pedidos/pagos/provprod/gastos/jornadas/eval/horario/liqdia) SOLO tienen cableado DUAL-WRITE (GAS=verdad + espejo) — prender su `MOS_*_DIRECTO` NO cambia nada en el front (seguiría escribiendo la HOJA). ⇒ Esos módulos NO pueden ser delete-safe-de-escritura solo con flags: requieren RE-CABLEAR el front (tanda futura). **Por eso NO se flipeó ningún `MOS_*_DIRECTO` de escritura** (siguen en '0' salvo `MOS_LIQDIA_DIRECTO`='1' ya vigente, que es materialización por RPC, no escritura-de-usuario).

### Orden EXACTO para cutover de ESCRITURA de PROVEEDORES (el único limpio hoy; NO es dinero):
La sombra de proveedores la sincroniza `_syncMOSImpl` (clave `_MOS_SPECS`='proveedores'), apagable por CSV `MOS_SYNC_OFF_TABLAS` en `mos.config`.
1. 🔴 **(dueño)** Apagar el sync de la tabla ANTES de prender la escritura: en el editor GAS correr `apagarSyncTablaMOS('proveedores')` (escribe `MOS_SYNC_OFF_TABLAS='proveedores'`). Verificar `_mosSyncOffTablas()` → `{proveedores:true}`.
2. 🔵 **(SQL, tras el paso 1)** `update mos.config set valor='1' where clave='MOS_PROVEEDORES_DIRECTO';` (prende RPC `crear/actualizar_proveedor` + gate del front).
3. 🔴 **(dueño)** Validar en rollback: crear/editar un proveedor → aparece en `mos.proveedores` → recargar MOS lo muestra (lectura ya directa) → NO duplica. Heartbeat lo mantiene `_tocar_latido_sync`.
4. 🔴 **Kill-switch:** `update mos.config set valor='0' where clave='MOS_PROVEEDORES_DIRECTO';` + `prenderSyncTablaMOS('proveedores')` (vuelve el sync) → rollback total.
**Regla de oro money-safety:** el paso 1 (sync-off) SIEMPRE va ANTES del paso 2 (flag-on). Flag-on con sync vivo = el sync re-upsertea la HOJA stale sobre la sombra = pérdida (lección 15-jun).

### Cutover de ESCRITURA de CATÁLOGO (productos/equivalencias): MÁS involucrado.
El sync del catálogo es SEPARADO (`syncCatalogoSupabase`, trigger horario propio + foldeado en `syncMOSReciente._refrescarCatalogoThrottled`), NO usa `MOS_SYNC_OFF_TABLAS`. Apagarlo = (a) 🔴 `desinstalarTriggerCatalogo()` y (b) comentar/gate el `_refrescarCatalogoThrottled()` dentro de `_syncMOSImpl` (GAS edit + push). RECIÉN luego (c) 🔵 `update mos.config set valor='1' where clave='MOS_CATALOGO_DIRECTO';`. Por el paso (b) requiere edit+deploy de GAS → coordinar en sesión dedicada. Kill-switch inverso.

### MOS_SYNC_OFF_TABLAS — lista exacta + funciones GAS por tabla (cuando el dueño quiera cutover de escritura):
| Tabla (clave `_MOS_SPECS`) | ¿front cableado direct-pure? | apagar sync | flag |
|---|---|---|---|
| `proveedores` | ✅ SÍ | `apagarSyncTablaMOS('proveedores')` | `MOS_PROVEEDORES_DIRECTO` |
| productos/equivalencias (catálogo) | ✅ SÍ | `desinstalarTriggerCatalogo()` + gate `_refrescarCatalogoThrottled` (GAS edit) | `MOS_CATALOGO_DIRECTO` |
| `pedidos_proveedor`,`pagos_proveedor`,`gastos`,`jornadas`,`evaluaciones`,`etiquetas_zona`,`proveedores_productos`,`liquidaciones_dia`,`liquidaciones_pagos` | ❌ NO (solo dual-write) | `apagarSyncTablaMOS('<tabla>')` | requiere RE-CABLEAR front primero (tanda futura) — NO flipear aún |

## FASE 7 — Corte final de Sheets (la gran decisión, por app)
- 🔵 **P7.1** Verificar que TODA lectura/escritura de cada app va por Supabase (cero dependencia de hoja).
- 🔴 **P7.2** Decisión final: retirar Sheets como fuente. Con vos, app por app, validando.
- 📌 **MOS LECTURA = delete-safe (✅ Fase 6.5)**. MOS ESCRITURA = aún depende de la HOJA salvo catálogo/proveedores tras su cutover (Fase 6.6). Veredicto delete-safe: ver REPORTE de la sesión 2026-06-18.

## FASE 8 — Cierre
- 🔵 **P8.1** pg_cron nocturno completo (reconciliación/snapshot) + limpieza de wiring muerto.
- 🔴 **P8.2** Rotar credenciales (PAT Supabase `sbp_*` + Anthropic `sk-ant-*`). **NO** rotar `WH_JWT_SECRET`.

---

## Regla transversal (todas las fases)
- **40x adversarial** en cada paso antes de declararlo listo (apps de dinero en prod).
- **Nada se activa sin tu validación física** en los módulos de dinero (lección del rollback).
- Cada activación tiene **kill-switch** (revertir en 1 comando / flag).
- Device colgado → **Reintentar / re-aprobar, NUNCA borrar cache**.

## ⏭️ PUNTO DE RETOMA v2 (2026-06-16, sesión nueva con contexto fresco)
**Optimización lecturas MOS — quedan los read-paths COMPLEJOS (~69, cross-app/agregados).** Ya directos: ~19 (finanzas/catálogo/historial/proveedores/pedidos/pagos/provprod/jornadas/eval/horario/personal-dia/equivalencias/categorías/personal-master/zonas/estaciones/impresoras/series). Pendientes (cada uno = RPC con LÓGICA, NO copia de tabla → 40x individual obligatorio):
- `getFinanzasDia` (Finanzas.gs:11 — materializa + calcula; ojo side-effect _liqDiaSync)
- `getDashboard` (KPIs agregados del día)
- `getHistoricoProveedor` (Proveedores.gs:204 — CROSS-APP: lee GUIAS de WH)
- `getProductosProveedorConStock` (Proveedores.gs:563 — CROSS-APP: provprod + stock WH)
- `getHistorialPersonal` (Auditoria.gs:282 — auditoría de cambios)
- getCierresCaja (CROSS-APP: viven en ME) · vistas warehouse desde MOS
**Patrón:** RPC SQL con la lógica + cablear en api.js (dispatcher get, gate _mosLecturaDirecta + fallback) + bump SW + deploy. ⚠️ 40x: verificar SIEMPRE el shape/orden/filtros + datos sensibles del getter GAS (la revisión cazó `adminPin` expuesto). Aplicador: `node supabase/_apply_sql.js`. Maestro ya ON.
Otras fases del cierre 100%: WH impresión (sub-proyecto, impresora física) + ME CPE (token NubeFact) + corte Sheets + rotar credenciales.

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
