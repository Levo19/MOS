# Plan — ZONA (ME) 100% Supabase: espejo del sistema WH

> Objetivo del dueño: replicar EXACTO el sistema de WH en la zona (ME/MosExpress): tabla stock + tabla AJUSTES (con tiempo+usuario) + kardex + cierre idempotente + autolock 30min + reapertura con auth-admin, sin duplicación. 100% Supabase. Test físico real.
> Ventana limpia: nadie usa las apps → cutover seguro (como WH).

## Flujo objetivo (simple)
1. Almacén emite **guía SALIDA a zona** → imprime ticket con idGuiaWH.
2. **Operario ME** (vendedor/cajero), en ME → Tools → "Guías de almacén": escanea el **código de la guía** → jala el JSON de productos de esa guía → escanea **producto por producto** (no ve cantidad esperada).
3. Lo ESCANEADO entra a zona (no lo enviado). 
4. **El ADMIN ve las DISCREPANCIAS en MOS** (no hace el registro). Si hace falta, hace el AJUSTE del producto (como ya existe).

## UI a corregir (módulo Zona en MOS)
- **Quitar de la vista principal** la lista larga "Traslados por verificar (101)" — estorba.
- **Botón "Guías"** al lado de "Lista compras" → abre layout con TODA la info guía-por-guía, **agrupado por día**, con filtro. Cada card de guía: al click → detalle con **discrepancias en el primer grupo**. Botón "verificado" por guía (marca que el admin lo resolvió). Símbolo de **alerta** en el botón si hay guías con pendientes.
- **Quitar el botón "Ingreso por almacén" de MOS** → ese flujo (escaneo) va en **ME (MosExpress)**, sección Tools → Guías de almacén. MOS solo MUESTRA discrepancias + permite ajuste.
- **Empezar con lista VACÍA**: marcar las ~101 guías actuales como "correctas/verificadas" (línea base), y de ahora en adelante las nuevas entran a verificar.

## Backend a construir (espejo de WH, 100% Supabase)
- **`me.stock_zonas`** ya existe (snapshot). Falta: que ME escriba directo (no sync Hoja).
- **`me.stock_movimientos`** (kardex) — YA creada (SQL 140) pero vacía. Activar el registro real.
- **Tabla de AJUSTES de zona** (NUEVA, como `wh.ajustes`): con tiempo + usuario + motivo. (Hoy NO existe; las correcciones son por auditoría set-absoluto.)
- **Cierre idempotente** de guías de zona (delta = nueva − aplicada; recerrar = 0) — como `wh.cerrar_guia_idempotente`.
- **Autolock 30min** + reapertura con auth-admin, sin duplicar al reabrir (igual que WH `wh-autocierre-inactividad` + `cantidad_aplicada`).
- **Reconciliación** zona ya existe (`mos.reconciliar_stock` ámbito ZONA) + log master.
- El traslado escaneado escribe el kardex + (con gate) el saldo `me.stock_zonas`.

## Migración ME a 100% Supabase (revisar + hacer — ventana limpia)
- Auditar (como WH 50x): ¿ME lee/escribe stock_zonas y guías de la Hoja o de Supabase? ¿hay sync ME que cruce? ¿RPCs de escritura directa ME?
- Escritura directa ME (stock/guías/ajustes/ventas que tocan stock) → RPCs Supabase.
- Apagar el sync ME→Supabase de las tablas de stock/guías (solo tras escritura directa + validar + flota 100%).
- Verificar CERO duplicación (mismo patrón idempotente + clave única ref).

## HALLAZGOS DEL AUDIT ME (2026-06-17) — el sistema YA está construido, falta cablear
**Estado:** ME stock_zonas + guías = **Hoja(GAS) fuente de verdad + sombra por sync batch**. Ventas/cajas SÍ escriben directo a Supabase (`ME_ESCRITURA_DIRECTA=1`), pero **stock y guías NO** (solo GAS→Sheets→sync).
**YA EXISTE en Supabase (orphan, reusar — NO reconstruir):** `me.stock_movimientos` (kardex, 0 filas/inactivo) · `me.zona_ajustar_stock` (ajuste idempotente por localId + log `me.zona_ajuste_log` = tabla de ajustes zona ✓) · `me.zona_kardex_registrar/historial` · `me.zona_recibir_lote` + `me.zona_lotes` (FIFO) · **`me.zona_traslado_cerrar` + `me.zona_traslado_verificacion`** (cierre por escaneo producto-a-producto, idempotente por id_guia, compara enviado vs escaneado = el flujo del QR que pide el dueño) · `me.zona_panel/esperado/lista_compras` · `mos.reconciliar_stock` ya soporta ambito ZONA.
**FALTA (cableo + cutover, ventana limpia):**
1. **Apagar el sync de stock_zonas + guias_cabecera + guias_detalle** (no hay `ME_SYNC_OFF_TABLAS` — crearlo en MigracionME.gs). ANTES de cualquier escritura directa (si no, el batch re-upsertea la Hoja en ≤15min y revierte = el cruce).
2. **Desbloquear el gate** `v_aplicar_stock=false` (hardcodeado OFF) en `me.zona_traslado_cerrar` → UPDATE atómico cantidad±delta (NO read-modify-write).
3. **Cablear las RPCs** en ME: lectura (`zona_panel`/`zona_kardex_historial`), escritura (`zona_ajustar_stock`/`recibir_lote`/`traslado_cerrar`). Hoy ME no llama ninguna `zona_*`.
4. **Reescribir `generarGuiaSalidaVentas`** (Guias.gs, hoy read-modify-write con doble conteo — hay 3 herramientas de limpieza de duplicados = el bug ya pasó) como descuento directo atómico + kardex + idempotencia por id_caja.
5. **Recepción WH→ME por escaneo de guía** (NO EXISTE hoy; `ENTRADA_ALMACEN` es manual sin vínculo a la guía WH): construir `recibirGuiaDeWH(idGuiaWH)` que precargue el detalle del despacho WH + use `zona_traslado_cerrar` con escaneo. La RPC ya existe; falta el endpoint WH→ME + la pantalla de escaneo en ME (Tools→Guías de almacén).
6. **Sanear los 414 negativos** (33%, min −10512 = basura de saldo acumulado + doble conteo). El cutover debe arrancar de **conteo físico** (auditoría) o `zona_ajustar_stock` masivo set-absoluto, NO del saldo actual. (= el "test físico" que el dueño quiere.)
7. **Activar el kardex** (`me.stock_movimientos`) en cada escritura.
**Autolock guías zona:** ME hoy NO tiene cierre/reapertura/autolock (toda guía nace CONFIRMADO). Hay que añadir el modelo estado + autolock 30min + reapertura auth-admin idempotente (espejo de `wh-autocierre-inactividad` + `cantidad_aplicada`).

## REVISIÓN 100X (2026-06-18) — estado verificado
**HECHO+VERIFICADO:** WH 100% Supabase · 11 RPCs núcleo presentes · 5 crons activos · LOPESA=216 · 0 duplicados kardex WH · 15 diferencias (todas negativas=auditoría) · baseline 225 (pendientes=0) · MOS zona UI (Guías agrupada/colores/log-solo-abiertas) 100% Supabase · ME núcleo cableado+deployado @209 (gate ME_ESCRITURA_STOCK_DIRECTA).
**🔴 HALLAZGO (regresión):** `me.zona_traslado_cerrar.v_aplicar_stock` quedó en **FALSE** (la SQL 144 lo puso TRUE, la edición posterior de 141 para fechaGuia lo revirtió). El traslado registra kardex pero NO aplica saldo. Sirve como red de seguridad → **desbloquear (TRUE) DESPUÉS de validar el cierre de venta**.
**BUILDS COMPLETADOS (2026-06-18, SQL 146+147):**
- **(4) ✅ Recepción WH→ME por escaneo** — `me.recibir_guia_wh` (lee `wh.guias`+`wh.guia_detalle`, el vínculo WH→ME que faltaba) + `me.recibir_guia_wh_cerrar` (compara enviado vs escaneado, kardex `TRASLADO_IN`, idempotente por `WH:<idGuiaWH>`) + wrappers `mos.*` + gate `me._claim_zona_ok()` (acepta claim mosExpress; las 141/144 que gatean con `mos._claim_ok` rechazaban mosExpress). UI ME: Tools→Guías→Entrada→"Recibir guía de almacén" (escanea idGuiaWH→cuenta producto×producto sin ver esperado→cierra). SW ME 2.8.26. **`v_aplicar_stock=false` INERTE** (registra kardex+verificación, no mueve saldo). Validado guía real `G1781712569625` (27 líneas/612 uds): cierre INCOMPLETO, recerrar=dedup 0 kardex. **NO pusheado (git push ME pendiente).**
- **(5) ✅ Autolock guías zona** — modelo de cierre idempotente espejo WH: `me.cerrar_guia_zona_idempotente` (delta=cantidad−cantidad_aplicada, recerrar=0, `v_aplicar_stock=false` INERTE) + `me.reabrir_guia_zona` (gate `mos._claim_ok`=admin, no la PWA) + `me.autocerrar_guias_zona_inactivas` + cron `me-autocierre-inactividad` 15min + `ME_AUTOCIERRE_MIN=30` + trigger `ultima_actividad`. Backfill 5176 líneas históricas (cantidad_aplicada=cantidad, no destructivo). Validado en transacción rollback: recerrar=delta 0, 0 kardex dup (regla de oro ✓). **No-op seguro** hasta el cutover (hoy las guías nacen CONFIRMADO, no ABIERTA). 39/39 checks OK, re-corrida idempotente.

**✅ VENTA REAL VALIDADA (2026-06-17):** corrida con datos reales (venta `V-1781640560657-70fc2d43`, CAJA-1781612875117, ZONA-02, 3 líneas) en transacción ROLLBACK: `me.zona_descontar_venta` resta correcto (kardex SALIDA_VENTA delta −1 c/u + UPDATE atómico de `me.stock_zonas`) e idempotente (2da corrida = 100% dedup por refId `VENTA-CAJA:caja:cod`, saldo idéntico). **Hallazgo blindado (SQL 148):** la temp table `_venta_agg` de nombre fijo `on commit drop` rompía si se llamaba 2× en la misma tx → `if not exists`+`truncate`. NOTA: la venta de caja YA aterriza directo en `me.ventas`/`me.ventas_detalle` (ME_ESCRITURA_DIRECTA ON); el descuento a `me.stock_zonas` solo ocurrirá cuando ME llame `zona_descontar_venta` en el flujo de cierre (gate ME_ESCRITURA_STOCK_DIRECTA + sync-off).

**FALTA (solo activación del dueño + auditoría física):** (1) ✅ validar venta real — HECHO; (2) `ME_SYNC_OFF_TABLAS=stock_zonas,guias_cabecera,guias_detalle` (tras validar); (3) desbloquear `v_aplicar_stock=true` en `me.zona_traslado_cerrar` + `me.recibir_guia_wh_cerrar` + `me.cerrar_guia_zona_idempotente` (re-aplicar 146/147, tras validar + sync-off); (4) que el cutover marque guías nuevas `estado='ABIERTA'` para que el autolock opere; (5) `git push` MosExpress (SW 2.8.26); (6) conteo físico de los negativos.

## ✅ GO-LIVE COMPLETADO (2026-06-17) — ME stock 100% Supabase
El dueño corrió `activarMESupabase()` → `ME_SYNC_OFF_TABLAS=stock_zonas,guias_cabecera,guias_detalle` + `ME_ESCRITURA_STOCK_DIRECTA=1`. Sync Hoja→Supabase APAGADO. Estado verificado end-to-end:
- **Escrituras 100% Supabase (gated ME_ESCRITURA_STOCK_DIRECTA, money-safe con cola+reintento idempotente):** ventas (`zona_descontar_venta`, cola `ME_DESCUENTO_PENDIENTE`) · ajustes/auditoría (`zona_ajustar_stock`) · guías manuales (`zona_registrar_guia`) · recepción WH→ME por escaneo (`recibir_guia_wh_cerrar`) — las 2 últimas con cola `ME_STOCK_PENDIENTE` nueva. Sin choque de gate (GAS usa service_role; la única vía con token ME es recepción → `me._claim_zona_ok` acepta mosExpress). Deploy GAS @211.
- **`v_aplicar_stock=true`** en `recibir_guia_wh_cerrar` + `cerrar_guia_zona_idempotente` (SQL 146/147 re-aplicados; autorizado explícito por el dueño). Recepciones SUMAN saldo (UPDATE atómico).
- **Lectura de stock migrada a Supabase:** `getStockZonas()` → RPC nueva `me.zona_stock` (SQL 149) bajo flag `FUENTE_DATOS` + fallback a Hoja. Shape idéntico (sin cambio de frontend). Deploy GAS @212. Validado: ZONA-02 endpoint-vivo = BD directa (859 filas con cantidad≠0, suma −23015).
- **Crons:** `me-autocierre-inactividad` */15 activo + RIZ (recompute/lista/reconciliar) + WH. 7 RPCs ME presentes.

### ⚠️ ACCIONES PENDIENTES DEL DUEÑO (no bloquean, pero importan)
1. **`setupStockRetryTrigger()`** (y `setupDescuentoRetryTrigger()` si no se corrió) — 1 vez en el editor GAS, para reintento automático de las colas de fallo. Sin esto las colas persisten pero se reintentan a mano (`reintentarStockPendiente()`/`reintentarDescuentosPendientes()`).
2. **🔴 CONTEO FÍSICO ZONA-02 (PRIORIDAD):** 392 de 1090 filas negativas, suma −23015 = baseline basura histórica. El sistema es correcto de aquí en adelante, pero los saldos de arranque están mal y empeorarán con ventas hasta un conteo físico → `zona_ajustar_stock` set-absoluto. ZONA-01 está sana (+27521, 16 neg). Limpiar también `ZONA_MOCK_FALLBACK` (6 filas mock). El reconciliador nocturno (`riz-reconciliar-stock` 02:30) + "Log de errores" master los vigilan.
3. **Reverso de anulación de venta** (documentado pendiente): hoy la anulación no re-suma stock por RPC.

## ✅ GUÍAS 100% SUPABASE + REVISIÓN 40x (2026-06-17, SQL 150)
Las guías ya no dependían de la Hoja solo en lectura: cableado metadata + lecturas a Supabase.
- **Escritura metadata:** `me.zona_guia_registrar_meta` (NO toca stock → sin doble-conteo) llamada por `generarGuiaSalidaVentas` + `registrarGuia` (best-effort, cola `ME_STOCK_PENDIENTE` tipo `guia_meta`). Las 2 únicas vías que crean guías → ambas cableadas (verificado).
- **Lecturas migradas:** `listarGuias`/`detalleGuia`/`trasladosEntrantes` → RPCs `me.zona_guias_listar`/`zona_guia_detalle`/`zona_traslados_entrantes` bajo `_fuenteDatos('guias')` (ON por opt-out) + fallback Hoja. Shape idéntico. Deploy GAS @214.
- **REVISIÓN 40x adversarial — 3 fixes aplicados + re-verificados con rollback (todos PASAN):**
  - 🔴-1 doble-conteo latente: la meta grababa `cantidad_aplicada=0` → si la guía se reabría y autocerraba, `cerrar_guia_zona_idempotente` re-aplicaba stock completo. FIX: meta graba `cantidad_aplicada=cantidad` → cierre da delta 0 → SKIP.
  - 🔴-2 pérdida de datos: items vacío borraba el detalle y reportaba ok. FIX: solo borra+reinserta si hay ≥1 línea válida.
  - 🟠-4 case-sensitivity: lecturas comparaban zona sin `upper()`. FIX: normalizar a mayúsculas.
- **🟠-3 hueco de datos** (guías creadas sync-off→@214 solo en Hoja, invisibles en lectura Supabase; el fallback no las rescata): backfill idempotente `backfillGuiasASupabase(desdeMs)` (default 4 días) en MigracionME.gs, deploy GAS @215. **El dueño lo corre 1 vez** (idempotente, no toca stock).

## ✅ AUDITORÍA 50x 3 APPS + FIXES (2026-06-17) — disparada por PGRST202 en backfill
**Causa raíz (CRÍTICA):** los helpers GAS de ME llamaban las RPC `me.zona_*` (param único `p jsonb`) con campos sueltos → PGRST202 → `me.stock_movimientos` VACÍO (ninguna escritura llegó nunca). FIX raíz: `_sbRpc` (Supabase.gs) envuelve `me.zona_*` en `{p}` (GAS @216). Doc: [[architecture_rpc_p_jsonb_convencion]].
**FASE 1 — bugs de DINERO (aplicados + validados rollback + confirmados vivos):**
- 🔴 ME-A `zona_registrar_guia` doblaba saldo en reintento (upsert sin mirar dedup) → SQL 151: saldo solo si kardex no-dedup. Validado: 2 llamadas = saldo −7 (no −14).
- 🟠 ME-C `zona_kardex_registrar` gateaba con `mos._claim_ok` (rechaza mosExpress) → kardex de recepción se perdía → SQL 151: gate `me._claim_zona_ok`.
- 🔴 ME-B recepción escaneo `_rwRpc` (index.html) sin `{p}` → PGRST202 → nunca funcionó. Fix 2.8.27.
- 🔴 WH doble-conteo cerrar→reabrir→autocerrar (3 rutas inconsistentes) → SQL 152 + api.js: PWA usa `cerrar_guia_idempotente`, `reabrir_guia` invariante (no toca stock ni resetea cantidad_aplicada), `cerrar_guia` deprecada delega. Validado: ciclo dejó 120 no 140. WH v2.13.257.
**FASE 3 — instantáneo + UX:**
- ✅ ME reverso de anulación post-cierre (@218): repone stock idempotente (refId `GUIA:ANUL:<venta>:<cod>`), validado.
- ✅ MOS sync instantáneo (v2.43.261): polling 25s + foco, pausa en edición, diff sin parpadeo, chip frescura honesto, refetch tras pedir.
**PENDIENTE:**
- ⚠️ **CONVERTIR_NV_A_CPE** (EditarVenta.gs) marca NV original `ANULADO_CONVERSION` (≠ ANULADO) → el cierre no la filtra y el CPE nuevo también descuenta → posible **doble descuento del mismo físico**. REQUIERE DECISIÓN del dueño.
- WH envasado sigue 100% GAS (nunca cortó a directo) — cobertura, no pérdida de dinero.
- WH ajustes 06-18 por GAS = flota con SW viejo; v2.13.257 fuerza recarga.
- Re-correr `backfillGuiasASupabase` (ahora funciona con el fix {p}) para cerrar el gap de guías + drenar colas.

## Reglas (money-safety)
- Igual que WH: escritura directa + validar ANTES de apagar sync; idempotencia en todo; autolock idempotente; backups; reconciliación nocturna de vigilancia.
- Todo con efectos modernos (optimista, háptico, transiciones) + revisión 40x en cada paso.
