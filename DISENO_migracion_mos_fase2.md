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

**🟡 FASE 2 (escrituras inertes) — ~65%, todo lo hecho VALIDADO 40x e INERTE:**
- ✅ **Catálogo** SQL (78/79) + **frontend cableado** (v2.43.207). `crear_producto`/`actualizar_producto`/`publicar_precio`/equivalencias. ID atómico (secuencia, arregla lost-update), validado 51/51 + auto-40x del frontend cazó 2 bugs. Flag `mos_catalogo_directo`.
- ✅ **Proveedores/pedidos/pagos** SQL (80 cimiento local_id + 81 las 6 RPCs) + **frontend cableado** (v2.43.208). registrar_pago con idempotencia ESTRICTA. **Validado 65/65; el 40x cazó un BUG CRÍTICO de DINERO** (on-conflict contra índice parcial habría reventado el pago → corregido). Flags `mos_proveedores/pedidos/pagos/provprod_directo`.
- ✅ **Evaluaciones/etiquetas/horarios** SQL (82). Validado 77/77. Flags `mos_eval/etiq/horario_directo`. **Frontend: ⏳ FALTA cablear.**
- ✅ **Gastos** SQL (83): crear_gasto/eliminar_gasto. Validado 40/40. Flag `mos_gastos_directo`. **Frontend: ⏳ FALTA cablear.**
- ⏳ **Jornales/liquidaciones** (~45 acciones, DINERO, cierre semanal/snapshots/pagos personal): **NO empezado. Es el lote más grande y delicado — requiere varias sub-tandas acotadas.**
- ⏳ **Cableo frontend** de: evaluaciones/etiquetas/horarios + gastos (las RPCs ya existen+validadas; falta extender `_postDirectoMOS` como se hizo con catálogo/proveedores).
- ⏳ **Revisión 40x INTEGRAL de Fase 2** (al terminar todos los lotes).

**⚠️ ESTRATÉGIA APRENDIDA (2026-06-15): el sistema se satura con agentes CREADORES grandes** (5 timeouts de 35-52 min en agentes que crean muchas RPCs), pero los agentes **VALIDADORES acotados terminan bien** (100-200s). Por eso varios SQL se crearon-luego-validaron en 2 pasos (el creador a veces timeoutea tras dejar el archivo bueno; un validador acotado lo confirma + caza bugs — así se cazó el bug de dinero del 81). **Para jornales: dividir en micro-tandas de 3-5 RPCs.** Tras cada timeout, el SQL suele quedar creado en disco (revisar por Glob/Grep + commit + validar acotado).

---

## PLAN JORNALES/LIQUIDACIONES (mapeado 2026-06-15 — el lote más grande y delicado, NO implementado)
**17 acciones de escritura, 6 tablas, DINERO crítico con retroactividad.** Tablas: `mos.jornadas` (legacy/vetos), `mos.evaluaciones` (✅ ya en 82), `mos.liquidaciones_dia` (materializado diario, PK `LDIA-fecha-idPersonal` único persona×fecha, estado PENDIENTE/PAGADA/VETADA), `mos.liquidaciones_pagos` (audit trail, snapshot inmutable al pagar), `mos.liquidacion_semanal_snapshot` (congelado semanal, idempotente por semana×persona, nunca pisar PAGADO), `mos.gastos` (✅ ya en 83).

**Invariantes de DINERO (críticas):** `totalDia = montoBase + pagoEnvasado + bonoMeta + bonificacion − sancion` (capped ≥0). El upsert de liquidaciones_dia PRESERVA bonificacion/sancion (manual) y solo recalcula auto (base/envasado/meta) — `_liqDiaSetBonSan` es el único que reemplaza manual. Pagos: snapshot inmutable (si se edita la evaluación tras pagar, el pago queda congelado — correcto). Snapshot semanal NUNCA pisa PAGADO.

**Micro-tandas sugeridas (3-5 RPCs c/u, lineal):**
1. **Jornadas**: `crear_jornada`/`eliminar_jornada`(veto tombstone)/`rehabilitar_jornada`/`importar_jornadas_cajas`. Bajo riesgo.
2. **liquidaciones_dia**: `upsert_liquidacion_dia`(preserva manual)/`set_bonificacion_sancion`/`vetar_liquidacion_dia`/`desvetar`/`recomputar_liquidacion_dia`. ⚠️ el RECOMPUTE lee cross-app (envasados/ventas) — evaluar si la RPC puede recomputar o si el cálculo se queda en GAS y la RPC solo persiste.
3. **Pagos (DINERO crítico)**: `marcar_pagos`(batch N días→1 idPago, inserta liquidaciones_pagos + 1 gasto JORNALES + marca PAGADA)/`anular_pago`(revierte las 3). Idempotencia estricta. PrintNode del ticket queda en GAS/Edge.
4. **Snapshot semanal**: `snapshot_liquidacion_semanal`(idempotente semana×persona, dedup conserva PAGADO). Hoy es trigger domingos 8pm en GAS → puede quedar en GAS o pg_cron.
5. **Cierre nocturno** (cierra sesiones WH + cajas ME, 23:00): cross-app, dejar en GAS/pg_cron.

**⚠️ lo que probablemente QUEDA en GAS (no portar a RPC):** `_liqSyncJob` (trigger 1h), `cerrarSemanaAutomatico` (trigger dom 8pm), `cierreNocturnoTodos` (trigger 23:00) — son time-based async, no on-demand; migrarlos sería a pg_cron (Fase 4). Los recomputes que leen cross-app (getResumenDia) pueden quedar calculados en GAS con la RPC solo persistiendo.

**Riesgos:** retroactividad (snapshot congela vs recompute cambia), invariante bonificacion/sancion en upsert, dedup snapshot nunca pisa PAGADO, idempotencia de pago batch. Por esto + ser DINERO, jornales debe hacerse con sistema FRESCO (los creadores timeoutean; un timeout a medias en pagos es peligroso) y validador acotado por micro-tanda.

---

## ✅ CIERRE 2026-06-15: FASE 2 COMPLETA + 100x INTEGRAL PASADO

**FASE 2 (escrituras) COMPLETA**, todos los lotes con SQL + frontend + 40x por lote, todo INERTE (flags `MOS_*_DIRECTO`/`mos_*_directo` en '0' → MOS opera 100% por GAS):
- Catálogo (78/79, 51/51) · Proveedores/pedidos/pagos (80/81, 65/65, bug dinero cazado) · Evaluaciones/etiquetas/horarios (82, 77/77) · Gastos (83, 40/40) · **Jornadas (84, 46/46)** · **Liquidaciones_día (85, 62/62)** · **Pagos jornales (86, 65+8)**. Frontend cableado en `js/api.js` (`_postDirectoMOS`) para todos salvo marcar/anular-pago jornales + recompute (omitidos a propósito: el front no arma el snapshot/clave → cablearlos pagaría S/0 o saltaría el gate de clave; las RPCs quedan listas).

**100x INTEGRAL (3 revisores adversariales) PASADO:**
- **Seguridad/auth**: SÓLIDO. Cerró 3 helpers con EXECUTE public (hoy_lima/_liqdia_key/_liqdia_total). Gate en todas, search_path en las 33 definer, sin inyección, datos sensibles excluidos (cuenta/cci/pin), Edge mint-mos fail-closed, RLS 31 tablas deny-all.
- **Dinero/idempotencia/atomicidad**: SÓLIDO. Cazó+corrigió 1 ALTO: `marcar_pagos` validaba solo `liquidaciones_dia` (más débil que GAS) → fecha sin fila-día podía doble-pagarse; ahora escanea el ledger `liquidaciones_pagos`. Atomicidad 3 tablas, invariante total_dia capped, preservación manual/PAGADA, montos exactos.
- **Frontend/coherencia**: APROBADO sin defectos. Inertness hermético (nada setea los flags), shapes exactos (bool10 load-bearing), anti-duplicado cross-backend, local_id estable, coherencia Edge↔claim↔RPC↔api.js.

**LO QUE QUEDA (del usuario / refinamientos / Fase 3-4):**
1. **Refinamiento**: cablear marcar/anular-pago jornales requiere que `app.js` arme el snapshot `dias[]` + maneje la clave admin (hoy por GAS, seguro). Opcional para cerrar ese 5%.
2. **FASE 3 (cutover) = del USUARIO**: activar flags módulo por módulo en prod + validar en vivo (app de dinero). Empezar por catálogo lectura (desbloquea WH/ME). ⚠️ Caveats documentados: evaluación con bono/sanción y horario con push/cache aún dependen de hooks GAS → no activar esos dos a ciegas. Requiere: `syncCatalogoSupabase()`+heartbeat, luego activar `mos_*_directo` por dispositivo.
3. **FASE 4**: snapshot semanal + cierre nocturno → pg_cron; apagar triggers de sync por módulo migrado.

**Estado: toda la capa MOS (Fase 0+1+2) está construida, validada 40x por lote, revisada 100x integral, INERTE y sin riesgo activo. Lista para que el usuario haga el cutover (Fase 3) cuando quiera.**

**⏳ FASE 3 (cutover) / FASE 4 (apagar sync) — del usuario / posteriores.**

### ⚠️ NOTA DE SESIÓN (2026-06-15): el sistema se SATURÓ
3 agentes consecutivos fallaron por "Stream idle timeout" (B finanzas-1ª-vez, C frontend-escritura, D proveedores-RPCs) tras una sesión muy larga. Se consolidó todo lo bueno en commits limpios; NADA quedó roto (api.js MOS validado, el 80 es inerte). **Retomar en sesión fresca** para que los agentes no fallen.

### SIGUIENTE PASO CONCRETO (retoma)
1. Portar `_postDirectoMOS` a js/api.js MOS (dispatcher escritura, patrón de WH `_postDirecto`) + cablear escritura del catálogo (crear/actualizar producto/equivalencia/publicar_precio) con flag `mos_catalogo_directo`. Las RPCs ya existen (78/79).
2. RPCs de escritura proveedores/pedidos/pagos (sobre cimiento 80, gate + idempotencia local_id estricta en pagos).
3. Seguir lotes Fase 2 por riesgo creciente; finanzas/jornales al final.

### LO QUE DEBE HACER EL USUARIO (al final, para ACTIVAR — no antes)
Correr `syncCatalogoSupabase()` 1 vez (crea CATALOGO_SYNC_HEARTBEAT) → activar `localStorage mos_catalogo_directo='1'` en un piloto → validar catálogo directo. Ídem finanzas cuando esté cableado. Todo con rollback = borrar el flag.

---

## ✅ FASE E (2026-06-15): AUTOMATIZACIÓN SNAPSHOT/CIERRE NOCTURNO vía pg_cron — INERTE × 2

SQL aplicado: **`supabase/97_mos_cron_nocturno.sql`** (pg, verificado). Apply: `apply_mos_97.js`; verificación 40x: `verify_mos_97_40x.js`.

**Estado del entorno (verificado, no asumido):** pg_cron **1.6.4 INSTALADO** (schema `pg_catalog`). pg_net disponible pero **NO instalado** — y **no se necesita** (los jobs llaman RPCs SQL internas directo, sin HTTP/Edge). Ya había 2 jobs WH activos (`wh-autocierre` 02UTC, `wh-auditar-cuadre` 03UTC) — **intactos**.

**Lo que se construyó (todo bajo schema `mos`, SECURITY DEFINER, `search_path=''`, grant solo `service_role`):**
- `mos.cron_log` — bitácora de corridas (RLS on, 0 policies, sin grant anon/authenticated → no es dato de negocio, no expuesta por PostgREST). Auto-purga > 90 días.
- `mos.cron_snapshot_liquidacion_semana()` — wrapper sin args: calcula lunes..hoy de la semana **Lima** en curso (`date_trunc('week')` = lunes ISO, igual que `_lunesDeSemana` de GAS) y llama `mos.materializar_liquidacion_semana(forzar:false)` (Fase D, SQL 96). Envuelto en `exception` → nunca propaga error a pg_cron. **PERSISTE el snapshot que hoy falta** (resuelve el problema histórico: el cierre semanal GAS solo manda push).
- `mos.cron_health_frescura()` — **solo lectura + log**: mide frescura de `wh.sesiones` y `me.ventas` del día de negocio Lima de ayer + corre `mos._liq_gate_frescura`; registra veredicto OK/STALE en `cron_log` para alertar antes de activar. No toca ningún dato de negocio.
- Jobs pg_cron, **creados DESHABILITADOS** (`active=false`):
  - `mos-snapshot-liq-semana` → `'30 4 * * *'` UTC = **23:30 Lima** (= GAS `_liqDiaCronDiario`, reemplazo 1:1).
  - `mos-health-frescura`     → `'0 9 * * *'` UTC = **04:00 Lima**.
  - (Perú = UTC-5 fijo, sin DST.)

**INERTE × 2 (doble candado), probado en pg:**
1. **Flag** (fuente de verdad): la RPC de Fase D respeta `MOS_LIQDIA_DIRECTO` (hoy `'0'`) → con flag '0' devuelve `MOS_LIQDIA_DIRECTO_OFF` y **0 escrituras**. DRY RUN en tx-rollback: `liquidaciones_dia` 205→205→205.
2. **Job** (pg_cron): `active=false` → pg_cron 1.6 **no ejecuta** el job.
- **Idempotencia probada** (flag ON dentro de tx-rollback, 2 corridas seguidas): filas 205→205→205 y `sum(total_dia)` 11754.00 = 11754.00 → no duplica ni infla. Día stale se salta (no aborta la semana).

### PLAN DE CORTE DE SHEETS — Fase E final (DOC, decisión del usuario; no ejecutado)

**Triggers GAS que esta Fase E reemplaza** (sync/snapshot de liquidaciones):
- `_liqDiaCronDiario` (Liquidaciones.gs:1647, diario 23:30) — sweep del día → reemplazado por `mos-snapshot-liq-semana`.
- `_liqSyncJob` (Liquidaciones.gs:1709, horario) — sync hoy+ventana rotativa → cubierto por el snapshot nocturno semanal (lunes..hoy cada noche).
- (Sync sombra) `syncMOSReciente` / `syncMOSCompleto` (MigracionMOS.gs:485-486) — son el sync **Hoja→Supabase**; se apagan por tabla vía `MOS_SYNC_OFF_TABLAS` cuando la escritura directa de esa tabla esté activa (ver SQL 95), **no** por pg_cron.

**Triggers GAS que NO reemplaza (siguen en GAS):**
- `cierreNocturnoTodos` (Liquidaciones.gs:1752, 23:00) — cierra **sesiones WH + cajas ME + fuerza logout de dispositivos**, escribe a las **Hojas** (que siguen siendo verdad para WH/ME mientras esas apps no migren su escritura). NO es persistencia de liquidación MOS → fuera del alcance de Fase E.
- `cerrarSemanaAutomatico` (Evaluaciones.gs:1265, domingo 20:00) — solo manda push; puede quedarse como notificador, ahora respaldado por el snapshot persistido.

**ORDEN DE APAGADO (cuando el usuario active Fase E):**
1. Activar Fase D: `update mos.config set valor='1' where clave='MOS_LIQDIA_DIRECTO'` (+ cablear el invocador si MOS escribe liquidaciones por front; hoy lo escribe el snapshot).
2. Habilitar el job: `select cron.alter_job((select jobid from cron.job where jobname='mos-snapshot-liq-semana'), active := true);` (ídem `mos-health-frescura`).
3. Observar 1-2 noches en `mos.cron_log` (snapshot ok + health OK).
4. **Recién entonces** apagar el equivalente GAS para no duplicar: `configurarTriggerLiquidacionDia`/`setupLiqSyncTrigger` → borrar los triggers `_liqDiaCronDiario` y `_liqSyncJob` desde el editor de Apps Script.
   ⚠️ Mientras ambos corran con flag '1' habría **doble materialización** (misma tabla); con flag '0' el pg_cron no escribe → no hay riesgo durante la fase inerte. La regla: apagar el GAS DESPUÉS de validar el pg_cron, nunca a ciegas.

### QUÉ QUEDA PARA ACTIVAR FASE E (decisión del usuario)
- Activar flag `MOS_LIQDIA_DIRECTO='1'` (depende de validar Fase D en vivo primero).
- `cron.alter_job(..., active := true)` para los 2 jobs.
- Ejecutar el plan de corte de Sheets (apagar `_liqDiaCronDiario`/`_liqSyncJob` tras validar).
- **Limitación honesta:** la frescura de `wh.sesiones`/`me.ventas` depende de que el sync GAS→Supabase de WH/ME siga vivo (esos triggers no son MOS). El health job alerta si se atrasan, pero no los repara. El snapshot nocturno de un día stale se SALTA (no paga de menos) → ese día queda pendiente hasta que la sombra se ponga al día y el job re-corra (idempotente).
