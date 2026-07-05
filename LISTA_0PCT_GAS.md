# LISTA COMPLETA para 0% GAS REAL (no solo lo principal) — 2026-07-05

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
