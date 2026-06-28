# 🔧 Lista de Reparaciones — 2026-06-26

> **Directrices de esta sesión:**
> 1. **100% Supabase / cero GAS** — sin excusas, sin rastro que caiga a GAS.
> 2. **Revisión 40x senior por paso · 100x al cerrar cada punto.**
> 3. **Registrar cada requerimiento acá** (reclamo → análisis → solución → estado), a medida que se trabaja.

Estados: 🆕 nuevo · 🔍 analizando · 🛠️ en progreso · ✅ desplegado (pend. verificación del usuario) · ✔️ **VERIFICADO FUNCIONA** (usuario confirmó) · ⏸️ pausado/bloqueado

> **Verificación:** los ✅ están en vivo pero esperan que el usuario confirme en su dispositivo. Cuando el usuario dice "funciona", se pasa a ✔️ VERIFICADO. Pendientes de verificar hoy: #1 (ME apertura), #5/#6 (WH lock), #7 (MOS purga).

---

<!-- Cada requerimiento se agrega como un bloque acá abajo a medida que el usuario lo pasa. -->
> **#1 update:** RPC `me.abrir_caja` (SQL 246) construido + **verificado 5/5** (abre/dedup-retry/guard-otro-cajero/anon-bloqueado/fila-ok), flag `ME_APERTURA_DIRECTO='0'` inerte. **Falta:** cablear ME (`_abrirCajaDirecto` gateado, push/sheet fire-and-forget) + deploy + flip.


| # | Estado | App/Pantalla | Reclamo / Requerimiento | Análisis (causa) | Solución | Deploy |
|---|--------|--------------|--------------------------|------------------|----------|--------|
| 1 | ✔️ | ME · abrir caja | "Creando caja" demora mucho al escoger cajero. Sospecha: no es 100% Supabase. | **CONFIRMADO GAS.** La apertura iba 100% a GAS (cold-start + 2 saltos GAS→Supabase + Sheet + push SÍNCRONOS antes de responder `idCaja`). El CIERRE ya estaba migrado; la apertura nunca se construyó. | RPC `me.abrir_caja` (SQL 246, **verificada 5/5**: abre/dedup/guard/anon/fila) + flag en whitelist (SQL 247, server-side para todos los dispositivos) + front `_abrirCajaDirecto` gateado (caja lista al instante, espejo Hoja+push a background) + GAS `procesarAperturaCaja` modo espejo (data.idCaja, sin duplicar). **ACTIVADO** `ME_APERTURA_DIRECTO=1`. | ME 2.8.74 + GAS @234 ✔️ **VERIFICADO** (apertura ultra rápida) |
| 7 | ✔️ | MOS · eliminar producto catálogo | Al eliminar (purga) sale "procesando" eterno + **"⚠ Lock timeout"**, nunca borra. ¿Por qué? ¿Es 100% Supabase? | **Era 100% GAS.** El borrado (purga) iba a `PurgaCatalogo.gs` bajo `LockService.waitLock(15000)`; el doc-lock de GAS (sync horario + concurrencia) excedía 15s → timeout → no borraba. **Riesgo de arquitectura detectado:** el sync Hoja→Supabase es solo-upsert → borrar solo en Supabase RESUCITARÍA el producto al siguiente sync. | RPC `mos.eliminar_items_catalogo` (SQL 248) = port fiel a transacción Postgres (sin LockService, instantáneo): items + clave + **rol MASTER** + **INTEGRIDAD** (no dejar canónico sin presentaciones/equivalentes) + snapshot + delete atómico + bump. **Verificada** (guards 5/5, integridad detecta huérfanos, delete+tombstone con rollback). **Anti-resurrección:** la RPC deja LÁPIDA en `mos.purgas_historicas`; el sync (`migrarCatalogoCompartido`) se parcheó para NO re-subir ids con lápida (`mos.purga_tombstones`). Front gateado `MOS_PURGA_DIRECTO`, RPC-first (shape crudo == GAS), null→GAS. SQL 249 expone el flag. **ACTIVADO.** | MOS 2.43.349 + GAS push ✔️ **VERIFICADO** (purga rápida y optimista) |
| 2 | ✅ | WH · guía salida + adhesivo granel | ¿editar re-imprime adhesivo? ¿stock inteligente? ¿adhesivo solo si cambió peso? | **NO HAY BUG — todo correcto.** Q1: editar NO re-imprime (form solo toca cabecera vía `actualizarGuia`, nunca llama `_dispararAdhesivosGranel`; sale solo en emisión, 2 call-sites). Q2: stock por DELTA (nuevo−viejo) solo la línea tocada, idempotente por `local_id`, cabecera=cero stock — es "inteligente" ✅. Q3: el adhesivo NUNCA re-imprime al editar (más estricto que lo pedido, jamás reenvía todos) ✅. | Sin reparación necesaria. OPCIONAL (si querés): reimprimir adhesivo al corregir PESO de granel, con guard por `idDetalle+peso`. | — |
| 6 | ✔️ | WH · lock screen lento/laggy | En pantalla de bloqueo el PIN va lentísimo, efectos congelados, el giro tarda, crashea. | **Mismo root que #5 (parte 2):** el loop de re-descarga del catálogo satura el main thread → la UI del lock se congela. **Causa:** cada UPDATE de `mos.catalogo_meta` (MOS bumpeando versión) o WS flapeando (CLOSED↔SUBSCRIBED) disparaba una re-descarga del maestro POR evento. | **Debounce** en `_rtNotificar` (api.js): coalesce el burst → 1 sola descarga de la versión más alta (trailing 1.5s). + **throttle 15s** del resync por SUBSCRIBED. | WH 2.13.350 ✔️ **VERIFICADO** (entra sin lag) |
| 5 | ✔️ | WH · lock/desbloqueo (BLOQUEABA ENTRADA) | Pide PIN y no deja entrar. Console: `TypeError: Cannot read properties of null (reading 'idPersonal') at _intentarDesbloqueo (app.js:1799)`. | **NO era regresión de mis revokes** (WH no llama ninguna RPC revocada). `_intentarDesbloqueo` derefenciaba `sesionActual.idPersonal` sin guard; cuando el lock quedaba arriba sin sesión (reload vacía `_unlockPin`, o logout cross-tab) → CRASH en cada intento → intrabable aun con el PIN correcto. | **Guard null** en los 3 derefs (cache predicate + server compare); si no hay sesión, un PIN válido en servidor **desbloquea Y RECUPERA la sesión** (`sesionActual = r.data` + `_guardarSesion`) en vez de aterrizar en null. + try/catch implícito (loginPersonalSB ya con `.catch`). | WH 2.13.350 ✔️ **VERIFICADO** (entra sin lag) |
| 4 | 🛠️ | MOS · modal acciones de ticket (Cajas) [E1+E2 ✅] | 6 botones: forma-pago/editar-cliente/convertir-CPE/anular/historial/historial-cliente. (a) verificar que funcionen + 100% Supabase, (b) botón Imprimir, (c) sección detalle, (d) efectos. | **(a) VERIFICADO: los 6 funcionan** — todos vía GAS→bridge ME (anular escribe Sheet directo); ninguno Supabase-nativo aún. Detalle: las líneas NO estaban en memoria (getCierresCaja no las trae). Historiales: RPCs existen inertes (me_historial_venta portable; cliente con GAP). Print: no había builder; Edge `imprimir` no aceptaba app=MOS. | **Etapa 1 ✅ desplegado (MOS 2.43.351):** (b) botón Imprimir → picker + ESC/POS client-side + Edge `imprimir` (ampliada a app=MOS, cero GAS); (c) sección Detalle scrollable (RPC `mos.me_detalle_venta` SQL 251, Supabase-first); (d) efectos+CSS. **Falta:** Etapa 2 (2 historiales→Supabase), Etapa 3 (3 escrituras fp/cliente/anular→RPC), Etapa 4 (orquestador CPE). | MOS 2.43.351 + Edge ✅ Etapa 1 |
| 3 | ✔️ | MOS · modal Guías·Zona | Guía externa (ajo, `G-...`) sale como pendiente; debe ser solo almacén→zona. | **CONFIRMADO filtro mal.** `me.zona_traslados_pendientes` (SQL 141) filtra `g.tipo like 'ENTRADA%'` SIN filtro de origen → surfacea la guía interna `G-1782479398702` (tipo=ENTRADA_LIBRE, ABIERTA) como pendiente. El flujo REAL de almacén→zona NO pasa por `guias_cabecera`: WH emite `SALIDA_ZONA` → al escanear, `me.recibir_guia_wh_cerrar` escribe en `me.zona_traslado_verificacion` con id `WH:<id>`. Las verificadas vienen de ahí; las pendientes de `ENTRADA%` (universo equivocado). **Rediseño (decisión usuario):** NO eliminar guías; mostrar TODAS, pero estados+diff SOLO para las de almacén. **Taxonomía confirmada:** 2 universos. (a) `me.guias_cabecera` (ids `G-`) = guías INTERNAS de la zona (ingreso manual, ventas, traslados, devolución) — NUNCA las crea un despacho de WH. (b) Despacho real de almacén → `wh.guias` tipo `SALIDA_ZONA` (ids `G_L`=despacho rápido, `GPCK_`=pickup); al escanear, `me.recibir_guia_wh_cerrar` crea fila `WH:<id>` en `zona_traslado_verificacion` con el diff real (enviado/escaneado/dif). **`WH:` = único marcador de "viene de almacén".** Diff sobró/faltó SOLO para `WH:`/SALIDA_ZONA (las internas tienen diff auto-referencial=sin sentido). **GAP crítico:** el "pendiente de recibir de almacén" (wh.guias SALIDA_ZONA sin fila WH:) HOY es invisible — las pendientes salen de `guias_cabecera ENTRADA%` (universo equivocado). | **Backend:** nueva fuente de pendientes = `wh.guias` SALIDA_ZONA+id_zona sin verificación `WH:`. RPC devuelve cada card con `origen` (WAREHOUSE/INTERNAL) + `tipo` + label amigable + (si WAREHOUSE) estado+diff. **Front (modal app.js:41632+):** render con label amigable (no el ID), estados+sobró/faltó SOLO si origen=WAREHOUSE; internas = informativas con label, click→detalle. Labels: SALIDA_ZONA→"Despacho de almacén (pickup/rápido)", ENTRADA_ALMACEN→"Ingreso de almacén (manual)", SALIDA_VENTAS→"Salida por ventas", ENTRADA_LIBRE→"Ingreso manual", SALIDA_MOVIMIENTO→"Traslado enviado", ENTRADA_TRASLADO→"Traslado recibido", SALIDA_JEFA→"Salida autorizada", SALIDA_DEVOLUCION_WH→"Devolución a almacén". | |

---
## #8 — Pickup almacén→zona: ¿agrupado por presentación en vez de canónico? (INVENTARIO, importante)
**Reclamo:** la lista de pickup que almacén despacha a ZONA-02 (281.594 uds, 148 productos) muestra filas por **presentación** (100GR/250gr/500GR/25UN con LEV distintos) en vez de **consolidado por canónico** (skuBase). Lógica esperada (implementada 24/06): cierre caja zona2 → guía de salida agrupada por skuBase del canónico; ej. 100gr clavo + 1kg clavo → 1.1 kg de clavo en UNA fila; con o sin equivalente debe enviarse; se acumula con el acumulador semanal; debe verse igual en MOS y almacén. Se ve tanto en MOS como en WH.
**Diagnóstico:** ✅ La **consolidación por canónico y las CANTIDADES estaban CORRECTAS** (ACU ZONA-02 = 113 filas = 113 skuBase distintos, 0 duplicados; `mos._venta_canonico` aplicado bien). **Era SOLO bug de etiqueta:** `wh.crear_pickup_cierre_caja` (215b) elegía el `nombre` por sku_base SIN filtrar el canónico (`factor_conversion=1`) → tomaba descripción de presentación ("100GR"/"25UN"). Sin impacto en inventario/dinero.
**Solución (SQL 253, puro Supabase):** (1) la función elige descripción del canónico (factor=1, activo; prefiere `codigo_producto_base` null + nombre más largo → robusto ante catálogos con varias filas factor=1). (2) backfill name-only de pickups activos (ZONA-01:18, ZONA-02:1082 filas; 0 nombres basura post-fix), sin tocar cantidades/códigos. **Refrescar WH** (caché del front mostraba lo viejo).
**Confirmaciones al usuario:** (a) ✅ agrupa por canónico, NO por presentación (113=113). (b) ✅ escanear el código EQUIVALENTE cuenta para el despacho — "REGLA DE ORO WH" (`app.js:14160`/`_matchPickupItem` 14133): acepta skuBase · cb canónico · cb equivalente activo; cada fila del pickup lleva en `codigosOriginales` el canónico Y el equivalente (verificado con data).
**Nota (catálogo):** LEV724/LEV342 tienen varias filas `factor=1` (presentaciones "1"/"500 GR"/"1K X 5 PQT" mal marcadas como canónico) → el orden robusto eligió el real; arreglo de fondo = limpiar esas filas del catálogo (posible punto futuro).
**Estado:** ✅ desplegado (commit `c5a76b0`); data live verificada (0 nombres malos); realtime pickups bumpeado 61→62 para forzar re-fetch en WH. Pend. verificación del usuario.

---
## #9 — Centralizar + formatear el modelo de TICKET (un formato para todo)
**Requerimiento:** la reimpresión del ticket de venta no es igual al original (le falta QR con id-ticket; si es CPE le falta QR/hash SUNAT). Centralizar UN modelo de ticket usado en TODOS los lugares donde se emite (nota de venta, boleta, factura, nota crédito/débito) — todo lo de dinero venta empresa→cliente con NubeFact debe tener el MISMO formato. Analizar qué pide NubeFact + cómo se hace en otros lados, proponer y DIBUJAR opciones.
**Estado:** 🔍 análisis + propuesta (sin implementar aún). Banners de versión = punto aparte, después.

---
## 📊 ESTADO CONSOLIDADO al 2026-06-27 (cierre de jornada 2)

### ✅ HECHO + desplegado (jornada 2 — ventas/fiscal/CPE)
- **Cutover ventas-ME Etapa 3** (forma pago / editar cliente / anular → RPCs `me.*` directas): construido + 100x + **verificado en POS** (NVa2-002019/2016, NV01-001622). ✔️
- **Emisión NV cero-GAS** (ME 2.8.79): infra→cola directa, negocio→bloquea; sin caer a GAS. ✅
- **CPE por Edge** (3-hop me.crear_cpe_directo→Edge emitir-cpe→set_cpe_nf, token en secret) + serie 100% Supabase (SQL 270). DEMO activo (BBB1/FFF1). ✅
- **Revisión 500x #1** (27 hallazgos) + **#2** (23 hallazgos, 12 accionables) → todos corregidos+desplegados (ME 2.8.81, SQL 264-271, MOS GAS). ✅
- **Trazabilidad fiscal CPE 100% Supabase** (SQL 272 + Edge `consultar` + panel Tributario MOS lee Supabase, distingue aceptado-NubeFact vs aceptado-SUNAT). ✅
- **Reconciliador BATCH** (Edge `reconciliar-cpe` + pg_cron + Vault, SQL 273) — INERTE (flag `CPE_RECON_ON=0` hasta el cutover). ✅
- **LOW18 + backfill huérfano** (SQL 273 / convertir_nv_cpe). ✅
- **Tarjeta de presentación** (grant anon a get_tarjeta_config — daba toast falso). ✅
- **Auto-VARIOS en boleta <S/700** (SUNAT) + Edge manda numero '0' para sin-documento. ✅ (ME 2.8.83)
- **Listado del vendedor desde Supabase** (SQL 274 + cargarVentasVendedor, cero-GAS, merge). ✅ (ME 2.8.84)
- **Cache de cliente en lookup** (consultar-documento upserta clientes_frecuentes apenas APISPeru responde). ✅

### ⏳ PENDIENTE REAL (lo que falta)
1. **#9 Centralizar el modelo de TICKET** — un solo formato para NV/boleta/factura/NC/ND con QR id-ticket + QR/hash SUNAT en la reimpresión. 🔍 Analizado, **NO implementado**. (El más grande que queda.)
2. **CPE a PRODUCCIÓN** (miércoles): token NubeFact real + series reales por zona + alinear correlativos + flags (`ME_CPE_DIRECTO` real, `FAC_CPE_DIRECTO`, `CPE_RECON_ON=1`).
3. **#4 Etapa 2** del modal de ticket: los 2 historiales (venta + cliente) → Supabase nativo (hoy por GAS bridge). Etapa 3 y 4 ya hechas.
4. **#3 modal Guías·Zona** — la solución está descrita (status ✔️) pero la celda Deploy quedó vacía → **verificar si se desplegó** el render origen WAREHOUSE/INTERNAL.
5. **Test de calibración del adhesivo de granel** — requiere impresora física (layout TSPL2 estimado).
6. **Auto-update banner para ME** (portar el patrón de MOS 2.43.339, con cuidado: no forzar reload mid-venta).
7. **Banners de versión** — punto aparte (mencionado en #9).
8. **DNI fallback 2º proveedor** — el dueño está buscando proveedor/token.
9. **#2 opcional** — reimprimir adhesivo al corregir el PESO de un granel (guard idDetalle+peso).

---
## 🔍 500x ADVERSARIAL jornada 2 (2026-06-27) — 23 hallazgos (0 CRIT / 7 HIGH / 10 MED / 6 LOW)
Corrida con 8 dimensiones + 3 escépticos por hallazgo + crítico de completitud (63 agentes). **TODOS los 7 HIGH + 10 MED + 4/6 LOW corregidos+desplegados** (ME 2.8.86 / MOS 2.43.366 / SQL 275 / 3 Edges / GAS @236). Lo más valioso:
- **TRIGGER fiscal `me.ventas`** (`tg_nf_estado_guard`): normaliza vocabulario (BAJA*/STUB/RECHAZADO*), hace EMITIDO y BAJA **terminales**, y no borra hash/enlace/qr con vacío. **Cubre de un solo lugar 4 HIGH/MED**: el PATCH crudo de GAS que eludía `set_cpe_nf`, la reversión de una BAJA, el vocab divergente y el STUB. Verificado: raw `BAJA_ACEPTADA`→`BAJA`, `BAJA`→`EMITIDO` bloqueado, hash conservado.
- **set_cpe_nf**: `nullif` en nf_hash/nf_enlace (ya no se borra el comprobante bueno con `''`).
- **crear_venta_directa/crear_cpe_directo**: exigen items (no quemar correlativo en comprobante vacío — verificado SIN_ITEMS) + serie SOLO de la zona de la caja (la estación user-supplied ya no cruza zonas).
- **HIGH que introduje hoy**: el merge del listado vendedor no emparejaba (faltaba `ref_local` en la entrada local) → perdía items/QR y recaía a GAS. Corregido + dedup.
- **Edge emitir-cpe (consultar)**: devuelve RECHAZADO en vez de enmascarar como PENDIENTE + captura sunat_code.
- **HIGH bloqueante del cutover**: `reconciliar-cpe` necesitaba `verify_jwt=false` en config.toml (el cron lo invoca sin Bearer → habría dado 401). Declarado. + `consultar-documento` verify_jwt=true (tocaba token APISPeru + service-role).
- **cero-GAS**: botón "Reconciliar TODOS los CPE" ahora itera el Edge (no GAS); ventana del reconciliador 7→45d (no abandona pendientes 8-35d); reconciliarCPEsPendientes GAS no revierte BAJA.
- **2 LOW diferidos** (no funcionales): XSS-onclick en panel Tributario (valores generados por el sistema, patrón preexistente) + comentario stale de dedup POR_COBRAR.

---
## #10 — Validaciones/límites de emisión en ME + editar cliente en MOS (2026-06-28)
**Reclamo:** (a) al poner un RUC no dejaba emitir boleta — ¿se puede boleta con RUC? (b) al editar cliente de una boleta sale toast rojo del backend; si un CPE no cambia titular, deshabilitar la opción. (c) el modal de editar cliente en MOS no tiene el buscador inteligente de ME (toggle Extranjero, sugerencias) — replicarlo/centralizar.
**Análisis:**
- (a) **SUNAT SÍ permite boleta con RUC (tipo 6).** Bug: `errorDocumento` (ME index ~8031) exigía exactamente 8 díg (DNI) para boleta → un RUC (11) daba "DNI debe tener 8 dígitos". El mapeo SUNAT (11→6) y el guard de procesarVenta ya lo soportaban; solo esa validación estaba de más. **Otros: boleta<700 con RUC también bloqueada (mismo fix).** Validaciones por capa documentadas (diagrama entregado al usuario).
- (b) Regla viva `me.editar_cliente` (SQL 271 H7): **editar cliente solo en NOTA_DE_VENTA**; cualquier CPE → bloqueado (titular fiscal no cambia tras mintear correlativo). El botón en MOS salía con `!cpeEmitido` → aparecía en boletas PENDIENTES y el backend lo rechazaba.
- (c) MOS leía clientes solo por documento (lookup); ME busca por nombre en su cache local. No había RPC de búsqueda por nombre.
**Solución (desplegado):**
- (a) ME 2.8.98: `errorDocumento` acepta DNI(8) **o** RUC(11) en boleta (CE por bypass; VARIOS<700). 
- (b) MOS 2.43.369: botón "Editar cliente" solo en NV; en CPE muestra 🔒 que **explica** (anula y reemite) en vez del toast rojo. Regla front↔backend alineada.
- (c) MOS 2.43.370: modal de editar cliente **replica el buscador de ME** — toggle Perú/Extranjero + búsqueda por NOMBRE con sugerencias de frecuentes (RPC `me.buscar_clientes_frecuentes`, SQL 284, Supabase directo) + lupa DNI/RUC + X. Misma fuente `me.clientes_frecuentes`.
**Revisión:** 500x adversarial sobre el modal+RPC (13/13 ids, contrato OK, XSS escapado, inyección-segura, cero-GAS). Sin hallazgos críticos.
**Estado:** ✅ desplegado (ME 2.8.98 · MOS 2.43.369/370 · SQL 284). Pend. verificación del usuario.
