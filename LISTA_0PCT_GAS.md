# LISTA COMPLETA para 0% GAS REAL (no solo lo principal) — 2026-07-05

## PROGRESO CORTE FINAL 2026-07-08 (Fable 5)
- ✅ **F1 HECHO+DESPLEGADO+VERIFICADO cero-GAS** (MOS 2.43.470 / ME 2.8.188 / WH 2.13.408):
  - **Notificaciones** (item 1-resto): `getNotifLog`→mos.notif_log_listar · `reenviarNotificacion`→mos.notif_log_get + Edge push. La Edge `push` ahora ESCRIBE el log (mos.notificaciones_log, SQL 405) en cada envío visible. Reemplaza la hoja NOTIF_LOG.
  - **Extensión de horario** (item 29-resto): `solicitarExtensionHorario`→mos.solicitar_extension_horario · `extenderHorarioHoy`→mos.extender_horario_hoy (SQL 406). `resolver_horario_personal` honra un marcador `extension_hoy` que **auto-expira por fecha** (sin cron; elimina el trigger 00:01 revertirExtensionesDiarias). Módulo compartido seguridad-modal.js cableado + ?v= bump en las 3 apps.
  - **turno.html** (item 33): ya era cero-GAS (mint-mos + datos_turno + Edge imprimir) — verificado, nada que migrar.
- 🟡 **F2 PARCIAL** (MOS 2.43.471):
  - ✅ **Ticket Z de cierre** cero-GAS: reusa turno.html (que ya lee me.datos_turno + Edge `imprimir`) vía iframe oculto same-origin. Sin duplicar 600 líneas de render.
  - ✅ **Ticket de PAGO/liquidación** (reimpresión) cero-GAS: `mos.pago_detalle` + builder ESC/POS client-side (port fiel de Liquidaciones.gs) + `_imprimirTicketEdge`. Verificado estructuralmente (ESC/POS válido, columnas alineadas). **Falta confirmación física en papel.**
  - ⬜ Falta: `imprimirCostosGuia` (→F3, es del flujo Jefa/OCR) · WH `imprimirCargadoresDia`/`imprimirHistorialStock` (builders ESC/POS + Edge).
- ✅ **F8 PARCIAL — limpieza segura** (MOS 2.43.472): eliminado el bloque device-auth inline DEPRECATED (`if(false)`, 178 líneas con `GAS_URL` muerto) + `mosGasUrl` del `DeviceAuth.init` (v1.0.26 lo ignora). Runtime MOS ya SIN URL de script.google.com (queda solo el input de config admin, vestigial). **NOTA: el corte de `GAS_URL`/`_fetch`/`_postMOS` de api.js es el PASO FINAL — NO se puede hacer hasta migrar OCR/espía/portales/converter, o esas rutas se rompen.**

## DATOS CONFIRMADOS para construir el resto (2026-07-08, para retomar rápido)
- **WH prints cargadores/historial:** data YA en Supabase → `wh.resumen_cargadores_dia({fecha})` (cargadores) · historial: el frontend YA arma `params.texto` completo (app.js ~20693, solo hay que envolverlo en ESC/POS). WH tiene `_imprimirDirecto(printerId, base64, title)` + `_escposB64()`. Falta: resolver printerId por defecto (WH_TICKET_PRINTER_ID = 75247847, hoy server-side) client-side o pasar hint a la Edge `imprimir`, + portar el builder de cargadores (120 líneas GAS Reporte.gs:1944).
- **F3 OCR:** backend YA hecho (mos.contexto_ticket_jefa 383 · mos.aplicar_respuesta_jefa MONEY con clave server-side · wh.actualizar_precios_detalle). Falta CLIENTE: `ocrTicketJefa`/`ocrComprobanteGuia` = foto→base64→Edge `ia` (existe) + `imprimirCostosGuia` (Almacen.gs:1820, 182 líneas ESC/POS). **Gate: cámara física.**
- **F5 portales:** `wh.crear_lista_sombra` existe · reporte.html es read-only sobre wh.guias/preingreso (migrable sin datos nuevos). **Gate duro: export del Sheet de clientes vivo (dato del dueño).**
- **F6:** `editarPNCantidad` necesita port de `_sincronizarLoteDesdeDetalle` (máquina lote-vencimiento, bug histórico "lote congelado") — TOCA STOCK, requiere verificación. `getSugerenciaPrecioIndividual` = FIFO+política categorías.
- **F7 flips (TOCA DINERO LIVE):** `MOS_CONVERT_NV_DIRECTO`='0'→'1' (converter NV→CPE; falta smoke B2 huérfano) · apagar sync Hoja→Supabase (hoy 19 tablas en MOS_SYNC_OFF_TABLAS siguen espejando de respaldo).


## ESTADO (actualizado 2026-07-05, MOS 2.43.454 desplegado)
- ✅ **HECHO+DESPLEGADO+VERIFICADO** (MOS): items **1** (notif config actualizar/restaurar — falta probar/reenviar=push), **2** ⚠️, **3** ⚠️ (jornales money: backfill + importarCajas, SQL 378, idempotentes), **4** (resolver alerta auditoría), **5** (equivalencia update), **6** (prov-prod crear/actualizar), **7** (dispositivo), **8** (bloqueos dispositivos/vendedor, SQL 377), **9** (recalc stock min/max SQL 379 + aplicar precios = loop publicarPrecio). SQL 376/379.
- ✅ **HECHO** item **14-adhesivo**: `wh_estado/calibrar/cancelarLoteAdhesivo` → Edge print-adhesivo modos estado/calibrar/cancelar (estado+cancelar smoke-test prod OK). `wh_getRotacionSemanal` → mos.wh_rotacion_semanal (SQL 380). crear/imprimirSub ya eran Edge-primario (fallback muerto con flag ON).
- ✅ **HECHO money-safe** item **14-inventario** (SQL 381, MOS 2.43.455): `wh_auditarStockGlobal` → mos.wh_auditar_cuadre (wh.auditar_cuadre_stock **corte+delta**) · `wh_getAlertasStock` → mos.wh_get_alertas_stock · `wh_reconciliarStockProducto/Masivo` → wrappers que reusan `wh.aceptar_teorico_alerta` (atómica) con **elevación de claim a warehouseMos**. ⚠️CLAVE: auto-corrigen SOLO alertas `ALAC_` frescas del corte+delta; IGNORAN las 386 huérfanas `AL_` stale (su diff almacenado es obsoleto → aplicarlas corrompería stock). Verificado: dryRun=23 (no 409), maxDiff=5→10/13, elevación OK, YA_CUADRA sin mutar.
- ⏸️ **DIFERIDO**: `wh_editarPNCantidad` (necesita port de `_sincronizarLoteDesdeDetalle` = máquina de estados lote-vencimiento, usada también por guías; bug histórico "lote congelado").
- ✅ **HECHO** item **10 Tributación** (SQL 382, MOS 2.43.456): `tribResumenMes`→mos.trib_resumen_mes (ventas ME + IGV-favor WH + renta MYPE 1.5%) · `tribIGVFavorMes`→wh.igv_favor_mes · `tribIGVEmitidoMes`→cpe_trazabilidad · `tribLimpiarVentasHuerfanas`→mos.limpiar_ventas_huerfanas. (`tribReintentarCPE` ya tenía path directo Edge; `tribReprocesarOCR` pendiente = pipeline OCR).
- ✅ **HECHO backend** item **11 OCR/Jefa** (SQL 383/385): `getContextoTicketJefa`→mos.contexto_ticket_jefa · `aplicarRespuestaJefa`→mos.aplicar_respuesta_jefa (⚠️MONEY: valida clave server-side + reusa publicar_precio) · `llenarCostosGuia`→wh.actualizar_precios_detalle. **Falta CLIENTE** (verificación física): `ocrComprobanteGuia`/`ocrTicketJefa` (foto→Edge `ia`) + `imprimirCostosGuia`/ticket-confirmación (ESC/POS→Edge `imprimir`) + sugerencias FIFO.
- ✅ **HECHO** item **20-22 ME** (SQL 384, ME 2.8.161): `CAMBIO_IMPRESORA_CAJA`→me.cambiar_impresora_caja · `reimprimirEtiqueta`→ESC/POS client-side + Edge imprimir · batch auto-print ya neutralizado.
- ✅ **YA ERA cero-GAS** (LISTA desactualizada): item **29 ExtensorHorario** (v1.0.2→mos.extender_horario_dispositivo SQL 334) · tribIGVEmitido/ReintentarCPE (frontend ya llamaba Edge/RPC directo).
- ⬜ **PENDIENTE — necesita VERIFICACIÓN FÍSICA (impresora/cámara)**: item **13** ticket Z-cierre (462 líneas ESC/POS, ALTA freq) + pago (175) → Edge imprimir · OCR imagen pipeline (item 11 cliente) · ticket costos/confirmación jefa.
- ⬜ **PENDIENTE greenfield/bloqueado**: **12/23/27** espía chunks (Storage+Edge) · **1-resto** notif probar/reenviar (push) · **33** turno.html · `editarPNCantidad` (modelo lote) · **32** portales cliente (BLOQUEADO: export Sheet del dueño).
- 🧹 **Limpieza (no pega GAS en runtime con flags ON)**: items **16-18** (if(false)/GAS_URL/mirror), **19** (dual-writes), **25/26/28** (mirrors + fallbacks pasivos).

---


> Estado verificado por web-check (Playwright real): **las 3 apps bootean 0 GAS**. Todo lo de abajo son
> acciones/paths GAS que NO se disparan en el arranque ni en los flujos principales, pero existen. Para el
> 0% REAL hay que matar cada uno (RPC/Edge nuevo, o eliminar el brazo, o migrar la app aparte).
> Leyenda: [W]=escritura sin RPC · [F]=fallback pasivo (solo si el directo falla) · [M]=mirror fire-and-forget ·
> [D]=dead-code · [EXT]=app/módulo aparte · ⚠=dinero/fiscal.

---

## MOS (index.html + js/api.js + js/app.js)

### A. Escrituras sin RPC → caen al fall-through GAS de _postMOS  [W]
1. `actualizarNotifConfig` / `restaurarNotifDefault` / `probarNotificacion` / `reenviarNotificacion` — config de notificaciones push.
2. ⚠ `backfillLiquidacionesDia` — recompute masivo de liquidaciones (dinero jornal).
3. ⚠ `importarJornadasDesdeCajas` — importa jornadas desde cajas (dinero jornal).
4. `resolverAlertaAuditoria` — resolver alerta de auditoría de stock.
5. `actualizarEquivalencia` — editar equivalencia (existe `crear_equivalencia`; falta el update).
6. `actualizarProductoProveedor` — editar proveedor-producto (ya hice `eliminar`; falta `actualizar`/`crear`).
7. `actualizarDispositivo` — editar metadatos de dispositivo.
8. `bloquearVendedorME` · `bloquearDispositivosDeUsuario` · `liberarDispositivoBloqueado` · `rechazarDispositivoPendiente` — seguridad/dispositivos.
9. `recalcularStockMinMaxAuto` · `aplicarPreciosVentaSugeridos` — catálogo/stock recompute.

### B. Familia Tributación (módulo completo por GAS)  [W]
10. `tribResumenMes` · `tribIGVEmitidoMes` · `tribIGVFavorMes` · `tribReintentarCPE` · `tribReprocesarOCR` · `tribLimpiarVentasHuerfanas`.

### C. Familia OCR / Ticket Jefa (IA)  [W]
11. `getContextoTicketJefa` · `ocrTicketJefa` · `ocrComprobanteGuia` · `aplicarRespuestaJefa` · `llenarCostosGuia` · `imprimirCostosGuia` — probablemente → Edge `ia` / `imprimir`.

### D. Espía / audio (WebRTC)  [W]
12. `iniciarEscuchaAudio` · `detenerEscuchaAudio` · `subirChunkAudio` + familia espía — señalización tiene RPC parcial; **los chunks de audio/video a Drive NO** → necesitan Storage + Edge.

### E. Impresión no cableada a Edge  [W]
13. `imprimirTicketZCierre` · `imprimirTicketPago` · `imprimirCargadoresDia` — deberían ir al Edge `imprimir`.

### F. MOS → WH forwards (postToWarehouse) por GAS  [W/F]
14. `wh_reconciliarStockProducto` · `wh_reconciliarStockMasivo` · `wh_getRotacionSemanal` · `wh_getAlertasStock` · `wh_editarPNCantidad` · `wh_crearLoteAdhesivo` · `wh_imprimirSubLoteAdhesivo` · `wh_cancelarLoteAdhesivo` · `wh_calibrarImpresoraAdhesivo` · `wh_estadoImpresoraAdhesivo` — el panel MOS opera adhesivos/stock de WH vía bridge GAS. Necesitan RPCs `wh.*` (algunas existen: lote_adhesivo_*).

### G. Editor Adhesivos  [W]
15. `setupAdhesivosBase` (index.html ~19597) — sube hex de iconos al abrir el editor. Hacer condicional al flag `mos_adhesivos_edge` o migrar a RPC.

### H. Dead-code que mantiene `GAS_URL` vivo (limpieza)  [D]
16. Bloque `if(false)(…)` device-auth inline (index ~18908, 3 fetch GAS) — eliminar entero.
17. `const GAS_URL` + `mosGasUrl: GAS_URL` en `DeviceAuth.init` (device-auth v1.0.26 lo ignora) — quitar.
18. Mirror `setHorarioApp` fire-and-forget en `_postMOS` (~2320) — dead, eliminar.
19. Dual-write `mos_*_dualwrite` (si algún flag está ON: proveedores/pedidos/provprod/gastos/jornadas/eval) — apagar el dualwrite + prender el `*_directo` puro + apagar sync Hoja.

---

## ME (index.html, single-file)

### A. Escrituras sin RPC  [W]
20. `reimprimirEtiqueta` — reimprime etiqueta de precio vía PrintNode → Edge `imprimir`.
21. `CAMBIO_IMPRESORA_CAJA` — cambia la impresora de la estación (config).
22. `imprimirBatchEtiquetasZona` — impresión batch de etiquetas → Edge.

### B. Espía / audio  [W]
23. `subirChunkAudio` · `detenerEscuchaAudio` · `espiaPushBatch` · `espiaSubirChunk` (video) — chunks a Drive → Storage+Edge.
24. `espiaCerrarSesion` (`sendBeacon`) [M] — cierre best-effort; el cierre real ya va por RPC.

### C. Mirrors fire-and-forget (se auto-neutralizan)  [M]
25. `MIRROR_MOV` · `msg_push_destinatarios` · apertura-espejo — best-effort a Hoja/push (el server reconcilia). `msg_push_destinatarios` → Edge push.

### D. Fallbacks pasivos de venta (solo si el directo por infra falla)  [F]
26. Venta NV/CPE: retry infra → GAS (con escritura directa ON + dedup por ref_local; casi nunca dispara). `RESERVAR_CORRELATIVO`/`CANCELAR_RESERVA_CORRELATIVO` — solo en modo NO-directo (con directo el RPC es el minter). `CIERRE_CAJA`/`APERTURA_CAJA`/`COBRAR_VENTA`/`EXTRA_CAJA`/`CONFIRMAR_COBRO_ASIGNADO`/`RECHAZAR_COBRO_ASIGNADO` — fallback si el directo lanza. Con flags ON no se ejecutan; para 0% REAL: quitar los brazos.

---

## WH (js/*.js) — casi todo ya muerto tras call()/login fix

### A. Espía / audio  [W]
27. `subirChunkAudio` / `detenerEscuchaAudio` (app.js ~2417) + `espiaSubirChunk` (video, ~3326) a `mosGasUrl`→Drive — Storage+Edge.
28. `sendBeacon` espía cierre (~3430) [M] — eliminable.

### B. Módulo externo  [EXT]
29. `ExtensorHorario` (extensor-horario.js) — escribe la extensión de horario por GAS; necesita RPC `mos.*` + actualizar el módulo compartido.

### C. Dead / offline  [D/F]
30. offline.js rama legacy (getPersonalConPin/getProductos/getProveedores, ~441) — casi-DEAD, eliminable.
31. Escrituras uncovered (agregarAMermas/solucionarMerma/procesarEliminacionMermas/subirFotoEntidad/eliminarFotoEntidad/aplicarOp/autoCloseDayGuias) — **0 callers (muertas)**; el brazo GAS de `post()` ya es inalcanzable, pero el código existe → limpieza.

---

## APPS/PÁGINAS APARTE (100% GAS — proyecto propio)  [EXT]
32. **Portales cliente WH**: `pedido.html` · `clientes.html` · `reporte.html` + `clienteInbox.js` — 4 tablas + 8 RPCs + 2 Edge (IA/Vision) + **migración de datos del Sheet de clientes** (dependencia externa: export del Sheet).
33. **`turno.html`** (ME) — página de turno de caja, opera 100% GAS. Migrar o retirar.

---

## Resumen de esfuerzo
- **RPCs a construir:** ~25 (notif, jornales⚠, dispositivos/seguridad, tributación×6, OCR/jefa×6, WH-forwards×10, equivalencia/prov-prod update).
- **Edge/Storage a construir:** chunks de audio/video espía (MOS+ME+WH), impresión etiquetas/tickets Z-pago.
- **Flips de flag / limpieza:** dual-writes, if(false), GAS_URL, mirrors, offline legacy.
- **Módulo externo:** ExtensorHorario.
- **Apps aparte:** portales cliente (needs Sheet export) + turno.html.

Nada de esto está en el boot ni en vender/cobrar/cerrar/despachar/guías/auditoría/login (ya 0-GAS verificado).
