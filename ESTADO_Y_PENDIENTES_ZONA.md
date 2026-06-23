# Estado y pendientes — Módulo Zona (RIZ) + cutover 100% Supabase del ecosistema
> Inventario consolidado desde la idea original del módulo zona (2026-06). Actualizado 2026-06-18.

## ✅ HECHO Y VERIFICADO
**Módulo Zona / RIZ (MOS, administrativo):** cards producto×zona, BCG, kardex, lista compras, pedir-almacén, ajustes, log de errores master, lista de guías. 100% Supabase, lee tablas vivas, **auto-refresh cada 25s + al volver foco** (v2.43.261). Chip de frescura honesto. Reconciliación nocturna + log master.
**ME stock 100% Supabase:** ventas, ajustes/auditoría, guías (todos los tipos), recepción WH→ME por escaneo. Sync Hoja→Supabase apagado. Bugs de dinero corregidos: convención `{p}` (escrituras nunca llegaban), doble-conteo de guía en reintento, kardex de recepción perdido, recepción escaneo rota, reverso de anulación, conversión NV→CPE no duplica. Deploy hasta @220 / 2.8.27.
**WH stock 100% Supabase:** ajustes, auditorías, guías (idempotentes), envasado (salida+ingreso+envasados+lote, recién cableado v2.13.258), stock, kardex. Doble-conteo cerrar→reabrir corregido (v2.13.257).
**MOS lee WH:** módulo zona ya en vivo; dashboard almacén (`Almacen.gs`) migrado a Supabase (7 RPC `mos.wh_*_crudo`, @419) — **INERTE hasta activar flag** (revisión 40x: seguro).

## 🟢 SOLO REQUIERE UN CLIC TUYO (activaciones en el editor GAS)
1. **`MOS_WH_LECTURA_DIRECTO=1`** (MOS GAS) → activa las lecturas WH del dashboard desde Supabase. Ya validado seguro.
2. **Re-correr `backfillGuiasASupabase`** (ME GAS) cuando resetee la cuota de UrlFetch (medianoche hora Pacífico) → cierra el gap de guías + drena las colas de reintento. Ahora es 1 sola llamada (instantáneo).
3. (Ya hechos: `activarMESupabase`, `setupStockRetryTrigger`, `setupDescuentoRetryTrigger`.)

## 🔵 VALIDACIÓN EN VIVO PENDIENTE (lo más importante para tu tranquilidad)
Todo se validó en rollback/aislado. Falta confirmar EN VIVO, con una operación real de cada tipo, que aterriza limpio en Supabase:
- Una **venta** real → descuenta `me.stock_zonas` + kardex al cierre.
- Un **ajuste/auditoría** real → `me.zona_ajuste_log` + saldo.
- Una **recepción WH→ME por escaneo** real → suma saldo + verificación visible en MOS.
- Un **envasado** WH real → `wh.envasados` + guías + stock.
- Una **anulación** y una **conversión NV→CPE** → stock correcto (sin doblar).

## 🟠 PENDIENTES DE LA IDEA ORIGINAL RIZ (features que quedaron sin terminar)
- **Capa 5:** verificar/terminar el cableado del ticket diario 80mm + lista de compras del lunes (Edge `riz-print`) y el panel de sugerencias IA real (Edge `ia`). Botón "+Lista compras" → `mos.zona_lista_compras`.
- **Lotes FIFO WH→zona:** cablear `cerrar_guia` (WH) → `zona_recibir_lote` cuando el destino es una zona (heredar lote+vencimiento). RPC de dinero, sesión dedicada.
- **BCG "perro" — botones Promocionar/Mover/Rematar:** hoy son stubs (toast "Capa 5"). Definir acción real.
- **BCG volumen:** `me.zona_panel` no devuelve `volumen` → burbujas/orden BCG planos. Agregar volumen.
- **Conteo físico ZONA-02:** 392/1090 saldos negativos (basura histórica) → tu reconteo con ajuste set-absoluto. Limpiar también `ZONA_MOCK_FALLBACK` (6 filas mock).

## 🔧 HILOS TÉCNICOS MENORES DETECTADOS (no bloquean, conviene cerrarlos)
- **PROVEEDORES** en `Almacen.gs:884` no migrado a Supabase (nombres de proveedor podrían quedar viejos con el flag ON; cae al ID). RPC `wh_proveedores_crudo` opcional.
- **3 bugs PRE-EXISTENTES de MOS** (ajenos al cutover, KPIs en cero): `Almacen.gs` lee `m.cantidad`/`m.fecha` (header es `cantidadPendiente`/`fechaIngreso`), `e.eficiencia` (es `eficienciaPct`), `s.cantidad` (es `cantidadDisponible`). Corregir → arregla KPIs de mermas/eficiencia/FIFO.
- **CONVERTIR_NV_A_CPE:** resuelto (cierre excluye `ANULADO%`).
- **WH GAS-relay:** la PWA de WH llama endpoints GAS que relayean a Supabase (el dato YA es Supabase, pero pasa por GAS como proxy). Cutover de cliente puro = reescribir api.js de WH a PostgREST directo. Workstream grande, opcional.
- **WH PICKUPS / DEVOLUCIONES_ZONA / SESIONES / LOTES_HISTORIAL:** se leen/escriben de la Hoja sin sombra Supabase. Diseñar RPCs si se quieren mover.
- **WH flota SW viejo:** 06-18 unos ajustes regresaron a GAS (dispositivos con caché viejo); se resuelve al recargar v2.13.258.
- **Realtime entre apps:** hoy MOS tiene polling 25s. ME/WH no se auto-refrescan entre sí. Evaluar si se quiere.

## 🔬 VEREDICTO REVISIÓN 100x DE CADA APP (2026-06-18)
**ME:** dinero (ventas/cajas/movimientos/créditos/guías-metadata) 100% Supabase y verificado que aterriza. Convención {p} limpia (0 PGRST202). Idempotencia OK. STOCK (`me.stock_movimientos`) aún en 0 = no hubo cierre desde el fix @216 (las escrituras previas fallaban por el bug {p}, ya corregido; las colas drenan lo pendiente). Falta: confirmar con un cierre real + asegurar `ME_ESCRITURA_STOCK_DIRECTA=1`. Creada `desactivarTriggersPisanSupabaseME()`. Deploy @222.
**WH:** ✅ 100% Supabase. Escrituras directas aterrizan (evidencia: ajustes/guías/envasados recientes con id directo). Idempotencia limpia (0 sobre-aplicadas). Lecturas Supabase. Cuadre 98.9% (15 alertas = revisión física por diseño). Flags 40+ en '1'. Solo se corrigió un comentario obsoleto (v2.13.259). Cron idempotente único autocierre.
**MOS:** módulo Zona/RIZ + dashboard Almacén ✅ 100% Supabase en vivo (16 RPC zona + 8 lecturas WH, convención {p} ok, cross-app live, auto-refresh, chip honesto, BCG volumen, perro real). **NO migrado: ESCRITURA de DATOS MAESTROS** (catálogo/proveedores/pedidos/pagos/gastos/evaluaciones/etiquetas/horarios/jornadas) — siguen Hoja+sync (flags `MOS_*_DIRECTO=0`); el código directo existe pero INERTE. Es el cutover documentado en [[architecture_mos_cutover_escritura_requiere_apagar_sync]] (NO es un flip: prender sin apagar sync DUPLICA finanzas → requiere sesión dedicada: migrar read-backs + apagar sync + recompute). Por eso los 3 sync de sombra MOS se quedan ON. Heartbeats sync ~1.4h atrasados (triggers caídos, patrón conocido) → reanimar.

## ⚙️ LISTA CONSOLIDADA DE FUNCIONES GAS QUE CORRE EL DUEÑO (al final, en orden por app)
**ME (editor Apps Script ME):** 1) `activarMESupabase()` (asegura stock flag ON + sync off) · 2) hacer un cierre/venta real y avisarme (validación en vivo) · 3) `backfillGuiasASupabase()` cuando resetee la cuota UrlFetch · 4) al final `desactivarTriggersPisanSupabaseME()`.
**WH (editor Apps Script WH):** 1) `estadoFuenteDatosWH()`→si no es supabase `activarSupabaseWH()` · 2) `backfillWH()` (sombras nuevas devoluciones/lotes_historial) + `verificarCuadreWH()` · 3) al final `desactivarTriggersPisanSupabaseWH()` · flota: `wh_escritura_navegador` ON.
**MOS (editor Apps Script MOS):** 1) `MOS_WH_LECTURA_DIRECTO='1'` (ya puesto) · 2) reanimar sync: `syncMOSCompleto()`+`syncCatalogoSupabase()`+reinstalar triggers (heartbeats atrasados) · 3) `desactivarTriggersPisanSupabaseMOS({dryRun:true})` luego sin dryRun (NO `incluirSombra` aún).

## 🎯 ESCRITURA DE MAESTROS MOS — RESUELTA POR DUAL-WRITE (2026-06-18)
El "directo puro" (MOS_*_DIRECTO=1 + apagar sync) **se descartó**: ya se probó 15-jun y causó pérdida de datos (un device con frontend viejo escribe a la Hoja, con sync off no llega a la sombra). Modelo seguro = **DUAL-WRITE**, YA VIVO: GAS escribe la Hoja Y espeja a `mos.<tabla>` al instante. Cubre proveedores/proveedores_productos/pedidos/pagos/gastos/jornadas/evaluaciones/etiquetas/horarios + (NUEVO @421) **productos y equivalencias** (helper `_dualWriteCAT` + DELETE propagado en PurgaCatalogo.gs). Lecturas directas en frontend con gate `_fresh` + fallback. → **El dato maestro YA está 100% en Supabase al instante.** El sync queda de respaldo (NO apagar). NO activar MOS_*_DIRECTO ni MOS_SYNC_OFF hasta que la flota esté 100% en frontend nuevo. ⚠ `gastos/pagos_proveedor/pedidos_proveedor` = 0 filas en sombra → verificar `compararSombraHojaMOS` antes de activar su LECTURA directa.

## 🧹 CUTOVER "DELETE-SAFE DEL SHEET" (2026-06-18, revisado 40x)
**ME (@225):** flujo de dinero delete-safe. `me.cierre_datos_caja` (SQL 160) = el cierre lee ventas de Supabase (verificado = lógica Sheet, 0 dif/8 cajas). `me.venta_reposicion_datos` (SQL 164) → reposición de anulada delete-safe. FIX: `notificarAnulacionPickupAWH` leía mal columnas (Nombre como cantidad→0) = aviso pickup a WH era no-op (WH sobre-contaba); corregido → **anulación ahora SÍ descuenta pickup WH** (cambio de comportamiento). Gate `ME_LECTURA_CIERRE_DIRECTA` (default ON)+fallback. **Residuales que aún leen Sheet (no-cierre):** `cobrarVentaExistente`, `creditarVenta`, `retomarCajaPorDeviceId`, `confirmarRetomaCaja` → migrar para delete-safe total.
**MOS (@423):** **LECTURAS delete-safe** (24 read-backs GAS → mos.* con _fresh+fallback; finanzas money-correctas, cuadre exacto: pend S/2665.20, pag S/3337.10). **ESCRITURAS aún dual-write al Sheet** → delete-safe total requiere cutover de escritura directo-puro, que necesita re-cablear el frontend de ~10 módulos (solo catálogo+proveedores tienen front-direct hoy) + coordinar sync-off. Runbook en PLAN_CIERRE_100.md Fase 6.6. MOS_*_DIRECTO sin flipear (flipear sin front-direct no haría nada).
**ACTUALIZADO 2026-06-18 (cutover delete-safe final):**
- **ME (@226):** flujo de dinero **100% delete-safe**. 4 residuales migradas (cobrar/creditar/retoma/confirmarRetoma → RPC 166). Fix: creditar obs ahora en me.ventas.obs. Solo herramientas manuales/diagnóstico tocan el Sheet.
- **MOS (@424):** escritura directo-puro en 6 tablas (proveedores, proveedores_productos, gastos, pagos_proveedor, pedidos_proveedor, horarios; `MOS_SYNC_OFF_TABLAS` seteado para esas + flags=1). SQL 165 (relaja upsert_proveedor_producto). Helper `_sbEscribirDirectoMOS` (directo-puro si flag ON, sino dual-write fallback).
- **4 tablas MOS QUEDAN en dual-write — razón de DINERO (no se pueden forzar sin corromper):** `evaluaciones`+`jornadas` (su recálculo de bonos/sanciones y dedupe LEEN el Sheet → directo-puro daría bonos mal / jornadas duplicadas); `etiquetas_zona` (generación+cron escanean el Sheet, sin RPC); `catalogo` (foto/segmentos/side-effects de publicarPrecio en GAS+Sheet).
- **Para borrar el Sheet 100% falta:** (a) migrar a Supabase la lógica de recálculo de evaluaciones/jornadas (getResumenDia/_liqDiaRecomputar lee Sheet) + dedupe de jornadas + cron de etiquetas + foto/segmentos catálogo; (b) **latido nativo Supabase** (pg_cron que estampe MOS_SYNC_HEARTBEAT) — hoy el gate `_fresh` depende del sync que lee el Sheet, así que sin Sheet el latido muere y las lecturas caerían al Sheet inexistente a los 30 min. Es la capa más sensible (bonos) → sesión enfocada.

## 🏁 CIERRE FINAL (2026-06-18, v2.43.263/@425/SQL 167+168)
**DINERO 100% Supabase delete-safe + validado al centavo.** Evaluaciones+jornadas directo-puro ACTIVADO: recálculo bonos/sanciones/score server-side (paridad 432/0 contra Sheet), dedupe jornadas server-side (no duplica), fix bug fecha UTC. Latido nativo pg_cron `mos-heartbeat-nativo` (10min) → `_fresh` ya no depende del Sheet. Delete-safe total: evaluaciones, jornadas, finanzas, liquidaciones, proveedores, pagos, pedidos, provprod, horarios, gastos + (ME) todo el flujo operativo + (WH) stock/guías/ajustes/envasado.
**Falta SOLO para borrar el Sheet literalmente (NO es dinero, operativo/display):** (1) fotos de producto → migrar de Google Drive a Supabase Storage+Edge (RPC `subir_foto`); (2) `actualizar_segmentos` RPC (port validación solapamientos); (3) etiquetas: generación fan-out server-side en `mos.publicar_precio` + escalación/auto-OBSOLETA por pg_cron. Estas 3 quedan dual-write (catalogo `MOS_CATALOGO_DIRECTO=0`, etiquetas `MOS_ETIQ_DIRECTO=0`) — no forzadas porque romperían fotos/etiquetas sin el Sheet. NO son money.

## 🏁🏁 DELETE-SAFE TOTAL ALCANZADO (2026-06-18, v2.43.264/@429)
Catálogo (@427): segmentos RPC `mos.actualizar_segmentos_precio` + fotos→Supabase Storage (bucket `producto-fotos`, `set_foto_producto`, 0 fotos Drive a migrar) + fix: sync catálogo ahora honra MOS_SYNC_OFF_TABLAS. `MOS_CATALOGO_DIRECTO=1`+sync-off. Etiquetas (@429): `mos.generar_etiquetas_zona` (fan-out) + `mos.escalar_etiquetas_zona`+pg_cron `mos-escalar-etiquetas` (hora) + fix bug colisión id (ZONA-01/02 mismo prefijo→perdía etiqueta). `MOS_ETIQ_DIRECTO=1`+sync-off. 38/38 validado.
**EL ECOSISTEMA ES DELETE-SAFE DEL SHEET** en TODO lo money + operativo + catálogo + etiquetas (ME venta/cierre/descuento/anulación/crédito/CPE · WH stock/guías/ajustes/envasado · MOS proveedores/pagos/pedidos/gastos/jornadas/evaluaciones-bonos-sanciones[validado al centavo]/liquidaciones/horarios/catálogo-incl-fotos/etiquetas + latido nativo pg_cron).
**Estados de impresión de etiquetas (visto/pegada/impresa) CERRADOS @431 (SQL 171):** directo-puro vía `mos.actualizar_etiqueta_zona` (+ `agregarVisto` merge server-side anti lost-update). 23/23+3/3 validado. → etiquetas 100% delete-safe (generación+escalación+estados).
**ÚNICO que toca el Sheet = herramientas de migración/diagnóstico (backfill) — POR DISEÑO** (su trabajo ES leer el Sheet para migrarlo; una vez borrado, no se corren). NO son dependencia operativa.
**= DELETE-SAFE 100.0%: borrar el Google Sheet no rompe ninguna escritura/lectura del flujo operativo, money ni display de las 3 apps.**

## Reglas que rigen todo (no romper)
- RPC `*.zona_*`/`wh.*` reciben un solo `p jsonb` → llamar SIEMPRE con `{p:{...}}` (ver architecture_rpc_p_jsonb_convencion).
- Toda escritura idempotente (clave única ref / cantidad_aplicada) → nunca duplica. Reabrir/recerrar = delta 0.
- No apagar sync sin escritura+lectura directa validada. Validar en vivo antes de confiar.
- Cada paso con revisión 40x. codigoBarra siempre texto. Money-safety primero.
