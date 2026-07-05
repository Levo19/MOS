# PUNTO DE RETOMA — Corte total GAS (ecosistema MOS) — 2026-07-05

> Objetivo: MOS + ME + WH 100% Supabase, **cero-GAS, cero-fallback, cero-Sheet**. GAS+Sheets se borran.
> Estado boot verificado por web-check (Playwright real): **MOS ✅ · ME ✅ · WH ✅ cero fetches a script.google.com**.
> Harness de verificación: `browsercheck/` → `node check.js gaskill_{mos,me,wh}.json`.

---

## ⚠️ GOTCHAS CRÍTICOS (leer antes de tocar nada)

1. **Un intercept en `_postDirectoMOS` (js/api.js) es CÓDIGO MUERTO si la acción NO está también en el gate map `_MOS_POST_DIRECTO`** (o `_MOS_POST_DUALWRITE`). `_postMOS` solo entra al directo si la acción está en el mapa; si no → cae a `_fetch('POST')` = GAS. Para cero-GAS puro: `X: () => true`. (Los GET tienen su propio dispatcher con `if(action===)` reachable; el problema es solo el path de ESCRITURA.)
2. **`_conFallbackMOS` (MOS api.js) ya NO cae a GAS**: reintenta el directo 3× y devuelve `null`. Los callers DEBEN tolerar `null` (si asumen valor → clobbean estado; ver bugs BUG-1/BUG-2 ya reparados). Cualquier lectura nueva: guardar contra null.
3. **ME: los flags `ME_ESCRITURA_DIRECTA/IMPRESION_DIRECTA/CIERRE_DIRECTO/APERTURA_DIRECTO/COBRO_DIRECTO/CPE_DIRECTO` están TODOS =1 en prod** → ME ya opera cero-GAS en el happy path; los brazos GAS son fallback pasivo (dormidos). NO apagar esos flags.
4. **WH: `WH_CONFIG.escrituraNavegador/lecturaNavegador/impresionNavegador = true` server-wide** → `_postDirecto` de WH corre. `call()` (GET) ya no tiene brazo GAS. `post()` (WRITE) sí lo tiene vivo para acciones no cableadas.
5. **Aplicar SQL**: `cd ProyectoMOS/supabase && node _apply_sql.js NNN_x.sql`. **DB query**: script inline pg leyendo `C:/Users/ISO/.sb_db.url`, `ssl:{rejectUnauthorized:false}`. **Edge deploy**: `supabase functions deploy <name> --project-ref rzbzdeipbtqkzjqdchqk`.
6. **Bump de versión al desplegar frontend**: MOS = `var V`(index.html) + api.js?v= + app.js?v= + sw VERSION + version.json. ME = var V + sw VERSION + version.json. WH = sw VERSION + version.json. Módulos compartidos (assets/seguridad|membrete) → bumpear su `?v=` en los index.html de MOS+ME+WH.

---

## ✅ HECHO ESTA SESIÓN (referencia, no re-hacer)
SQL 376-394 en prod. Deploys: **MOS 2.43.462, ME 2.8.164, WH 2.13.407** + Edge print-adhesivo/emitir-cpe.
- Jornales money (backfill/importar cajas), recalc stock min/max + aplicar precios, WH-inventario reconciliar/alertas/cuadre (elevación claim), tributación (resumen/IGV-favor/limpiar-huérfanas/IGV-emitido), OCR-jefa backend (contexto/aplicar-respuesta/precio-detalle), notif config, dispositivos/bloqueos/forzar, equivalencias, prov-prod, adhesivo estado/calibrar/cancelar (Edge), rotación WH, lecturas MOS (authCatalogo/promociones/cronStatus/liq-semana/meHistorial), mermas WH (aplicarOp→wh.aplicar_op), procesarEliminacionMermas, ME (MIRROR no-op/msg_push Edge/verificarImpresora Edge/retry-caja/verificarClaveAdmin/cambiar-impresora/reimprimir-etiqueta), bridges compartidos (verificarHorario/getEstadoLoteAdhesivo), jalarProdProv, probarNotif, setupAdhesivos.
- 2 revisiones 500x de esos cambios (SQL 393/394) + 1 revisión 500x de código de las 3 apps (bugs reparados: catálogo null-clobber, finRender null, doble-tap gasto/jornada, liqLock deadlock, fuga intervalos, sync try/finally ME, pending_sales anti-dup, guards apertura/cierre, MIXTO validation, WH localId/deshacer-etiquetas/diasVencer-TZ/aprobar-trycatch).

---

## ⬜ LO QUE FALTA (por prioridad y app)

### A. MOS — escrituras/lecturas aún a GAS
- ⬜ **reenviarNotificacion + getNotifLog** — falta tabla `mos.notificaciones_log` + escribir el log en cada envío (write-path repartido) + RPC `mos.reenviar_notificacion(idLog)` + reader `mos.notif_log`. (Sin la tabla no se puede reenviar: título/cuerpo salen del log.)
- ⬜ **getHistorialPersonal** — falta `ALTER TABLE mos.personal ADD COLUMN historial_cambios jsonb` + backfill (dato vive en el Sheet PERSONAL_MASTER) + reader `mos.historial_personal`.
- ⬜ **getPromociones** — reader `mos.promociones_lista` YA existe pero `mos.promociones` está VACÍA → falta **backfill** de las promos del Sheet ME (o recrearlas en el panel MOS).
- ⬜ **getSugerenciaPrecioIndividual** — RPC `mos.sugerencia_precio_individual` (FIFO + política de categorías con herencia canónica; algoritmo en gas/Almacen.gs:1279 `_construirSugerenciaPrecio` + Categorias.gs:234/302). Complejo. Hoy cae a fallback 40% client-side.
- ⬜ **editarPNCantidad** — necesita port de `_sincronizarLoteDesdeDetalle` (máquina de estados lote-vencimiento, gas/Guias.gs:1000; usada también por guías). Money-adjacente.
- ⬜ **Impresión tickets** (item 13): `imprimirTicketZCierre` (462 líneas ESC/POS, gas/Cajas.gs:712, ALTA frecuencia) + `imprimirTicketPago` (175, gas/Liquidaciones.gs:598) + `imprimirCostosGuia`/ticket-jefa → Edge `imprimir` (armar ESC/POS client-side). **Requiere verificación física en impresora.**
- ⬜ **OCR imagen** (item 11 cliente): `ocrComprobanteGuia`/`ocrTicketJefa` → Edge `ia` (Claude Haiku, prompts en gas WH IA.gs:609/757; foto migra de Drive a Storage). `tribReprocesarOCR` depende de esto. **Requiere foto real de prueba.**
- ⬜ **Chunks espía/audio** → Supabase Storage + Edge (greenfield). MOS app.js ~14737-14877 (sendBeacon/subirChunkAudio/detener/espiaPushBatch).
- 🧹 **Dead-code / fallback** (Block 9, hacer AL FINAL, solo tras migrar todo lo de arriba): quitar brazos GAS de `_postMOS`/`get` fall-through, dual-writes (pedidos/pagos/provprod/gastos/eval/jornadas — hoy GAS-primero por diseño), `getProductosNuevosWH` fallback, `_adhGasRaw` editor, bloque `if(false)` device-auth (index.html ~18908), `const GAS_URL`, ~50 brazos muertos `_conFallbackMOS`.

### B. ME (MosExpress) — index.html
- ⬜ **Bridge Membrete** (`MembreteSystem.apiPost` → MOS_GAS_URL): acciones lote-adhesivo/membrete en ME. `crearLoteAdhesivo`/`crearLoteMembrete`/`imprimirSubLoteMembrete` YA tienen Edge print-adhesivo (modes crear/crear-membrete/lote); falta que ME las rutee por Edge en vez del bridge GAS (WH lo hace en su api.js; ME no). `asegurarTriggerLotes` = vestigio GAS (remap a `procesarAhoraTodos` mode:pending o quitar).
- ⬜ **turno.html** (Ticket-Z / `&api=MOS_GAS_URL`, index.html ~13653): la ventana de cierre lee vía GAS. Migrar la página o su lectura a Supabase.
- ⬜ **solicitarExtensionHorario** + **extenderHorarioHoy** (bridge Seguridad): faltan RPCs `mos.*` (solicitar = persistir solicitud + push; extenderHoy = override de cierre por-app-por-día sobre `mos.config_horarios_apps` + que `resolver_horario_personal` lo consulte). `verificarHorario`/`consultarEstadoDispositivo` YA migrados.
- ⬜ **Chunks espía/audio** → Storage+Edge (index.html ~14737-14877).
- 🧹 **Fallback arms** (Block 9, al final): venta/cobro/cierre/apertura/extra/reserva-correlativo/drain-cola caen a GAS solo si el directo falla (dormidos con flags ON) → removerlos. Dead: etiqAutoPrintAlAperturaCaja, getEstacionesParaApp, mirrors (ya vaciados).

### C. WH (warehouseMos) — js/*
- ⬜ **clienteInbox.js** (~línea 22): portal cliente pollea `gasUrl()+'?action=clienteInboxPolling'` cada 20s. **Es la superficie GAS activa más visible que queda.** Parte del bloque "Portales cliente".
- ⬜ **imprimirCargadoresDia** (app.js:19217) + **imprimirHistorialStock** (app.js:20680) → Edge `imprimir`. Falta builder client-side `ImpresionDirecta.armarCargadores/armarHistorial` (patrón: PRINT_ACTIONS en api.js:2067). Cargadores lee `wh.preingresos` (RPC lectura); Historial: el browser ya arma el texto. **Verificación física.**
- ⬜ **subirFotoEntidad / eliminarFotoEntidad** (photos.js:197) → Drive→Supabase Storage (Edge `fotos` existe). Preingresos/producto-nuevo suben fotos por acá.
- ⬜ **Diagnósticos**: iniciarTestDiagnostico/finalizarTestDiagnostico/runInternalTests (app.js ~22911) → GAS (admin, baja frecuencia; portar o retirar).
- ⬜ **Chunks espía/audio** → Storage+Edge (app.js ~2401/2461/3424).
- 🧹 **Fallback/dead** (Block 9): brazo GAS de `post()`/`_doFetchWithRetry` + cola offline legacy (offline.js:628) + aviso-cajeros fallback (api.js:2735, flag `WH_AVISO_DIRECTO=1` ya prendido → validar paridad ticket ANTES/AHORA y quitar el `return post(...)`). Dead: `loginPersonal`, `autoCloseDayGuias`, ramas merma directas sin OpLog, `_mosUrl` BloqueoRemoto.

### D. PORTALES CLIENTE WH — BLOQUEADO (necesita input del dueño)
- `pedido.html` / `clientes.html` / `reporte.html` + `clienteInbox.js` — 100% GAS. Necesita: 4 tablas mos (clientes/pedidos_cliente/_items/_adj) + ~8 RPCs + 2 Edge (recibir-pedido IA/Vision, analizar-imagen) + **MIGRACIÓN DE DATOS del Sheet de clientes vivo (export del dueño = dependencia externa)**. `reporte.html` es read-only sobre wh.guias/preingreso → migrable sin datos nuevos (sub-win fácil). `wh.crear_lista_sombra` ya existe.

---

## ORDEN RECOMENDADO PRÓXIMA SESIÓN
1. **Backfills de datos** (readers ya listos): promociones, historial_personal (col+backfill), notif_log (tabla+write-path).
2. **WH prints** (cargadores/historial) + **MOS prints** (Z-cierre/pago/costos) → Edge imprimir, **con el dueño imprimiendo 1 prueba de cada uno**.
3. **OCR imagen** (MOS ocrComprobante/ticketJefa) → Edge ia, **con una foto de boleta de prueba**.
4. **ME bridge Membrete + turno.html + solicitar/extenderHorario**.
5. **photos.js → Storage** (WH) + **clienteInbox/portales** (necesita export Sheet).
6. **Espía chunks → Storage+Edge** (3 apps, greenfield).
7. **BLOCK 9 — quitar TODOS los brazos GAS/fallback + dead-code** (al final, apps sin uso, tras confirmar que todo lo anterior opera).
8. Web-check final de las 3 apps + borrar GAS_URL/API_URL/MOS_GAS_URL.

Docs relacionados: `LISTA_0PCT_GAS.md`, `RUNBOOK_CORTE_GAS_TOTAL.md`. Memoria: `project_corte_gas_bloqueantes`, `architecture_mos_postdirecto_gate_obligatorio`.

---

# 🎯 META EXPLÍCITA: ELIMINAR **TODO** RASTRO DE GAS
No basta con que "no se dispare". El objetivo es **borrar cada referencia a Google Apps Script** — activa, pasiva (fallback), dead-code, mirrors, y las **constantes/URLs** (`GAS_URL`, `API_URL`, `MOS_GAS_URL`, `mosGasUrl`, `_gasUrl()`, `getUrl()`). Al terminar, `grep -rn "script.google.com\|GAS_URL\|API_URL\|MOS_GAS_URL\|mosGasUrl\|UrlFetchApp" ` en los 3 frontends debe dar **0 resultados** (fuera de comentarios de historia). Abajo el INVENTARIO COMPLETO línea por línea (de la auditoría 500x). Nada de esto puede quedar.

## INVENTARIO COMPLETO DE TOQUES GAS — todo debe morir

### MOS — `js/api.js`
- [ ] `const GAS_URL` (5) + `getUrl()` (7) — CONSTANTE, borrar al final.
- [ ] `_postMOS` fall-through `_fetch('POST', {action,...p})` (2542) — fallback de toda escritura no cableada. Migrar cada acción restante + borrar el `_fetch`.
- [ ] dispatcher `get` fall-through `_fetch('GET', ...)` (3077) — fallback de toda lectura no interceptada.
- [ ] dual-write GAS-primero `await _fetch('POST', ...)` (2507) — apagar los `mos_*_dualwrite` + prender `*_directo` puro + apagar sync Hoja→sombra (pedidos/pagos/provprod/gastos/eval/jornadas).
- [ ] `getProductosNuevosWH` fallback `_fetch('GET')` (3246) — cuando WH escriba PN directo, quitar.
- [ ] `_adhGasRaw` (1008-1016) + `_adhesivoEditorBackend` (1051) — CRUD editor adhesivos raw a GAS; migrar a RPC `mos.adhesivo_*` o Edge y borrar.
- [ ] setHorarioApp ping `_fetch('POST').catch()` (2531) — dead, borrar.
- [ ] ~50 brazos muertos `() => _fetch('GET', ...)` dentro de `_conFallbackMOS` (2891-3067) — dead-code, borrar todos.

### MOS — `index.html`
- [ ] Bloque `if(false)(function(){...})()` device-auth inline (~18908): 3 fetch GAS (18975 registrarSesionDispositivo, 19016 aprobarDispositivoEnSitu, 19059 consultarEstadoDispositivo). Borrar entero.
- [ ] `mosGasUrl: GAS_URL` en `DeviceAuth.init` (~18876) — plumbing muerto, quitar.

### MOS — espía/audio `js/app.js` (→ Storage+Edge, luego borrar GAS)
- [ ] sendBeacon `MOS_GAS_URL` beforeunload (~14737) · espiaPushBatch/cerrar (~14762/14791) · subirChunkAudio/detener (~14822/14846/14877).

### ME — `index.html` (constantes `API_URL` 6638, `MOS_GAS_URL`/`MOS_URL` 1424/6645/8546)
Activos por-default-si-flag-OFF (flags hoy ON, pero **el brazo debe borrarse**):
- [ ] G1 `registrarExtra` EXTRA_CAJA (16510) · G2 `_prereservaIniciar` RESERVAR_CORRELATIVO (18211) · G3 `_prereservaCancelar` (18246) · G4 `mandarImpresionPrintNode` imprimir (12976) · G5 apertura mirror (13327) · G6 apertura fallback (13332).
- [ ] G7 **bridge Membrete** `apiPost`→MOS_URL (8558) — migrar acciones a Edge/RPC.
- [ ] G8 **turno.html** `&api=MOS_GAS_URL` (13653) — Ticket-Z lee por GAS.
Fallback money-write (borrar el brazo GAS tras confirmar directo estable):
- [ ] G9 adminConfirmarCobrar (15719) · G10 adminConfirmarConvertir (15841) · G11 confirmarCobrarAsignado (16380) · G12 confirmarRechazarAsignado (16450) · G13 boot cierre-ayer (9144) · G14 cierre loop ×2 (13731) · G15 venta legacy dren (10180) · G16 `_enviarVentaConReintentos` (18812) · G17 timeout venta→cola (19013).
- [ ] Espía/audio ME: 14737/14762/14791/14822/14846/14877 → Storage+Edge.
- [ ] Dead: etiqAutoPrint (7781), getEstacionesParaApp (9677), mirrors 15710/16840 (ya no-op, borrar).

### WH — `js/*`
- [ ] `_doFetchWithRetry`/`fetch(GAS_URL)` brazo de `post()` (api.js:2240 + fallthrough 2342) + `_gasUrl()` (api.js:5) — borrar tras cablear todas las escrituras.
- [ ] `offline.js:628` drain legacy a GAS — quitar rama.
- [ ] `imprimirCargadoresDia` (app.js:19217) + `imprimirHistorialStock` (app.js:20680) → Edge imprimir (falta builder `ImpresionDirecta.armarX`).
- [ ] `clienteInbox.js:22` poll `clienteInboxPolling` cada 20s → parte de Portales (bloqueado por export Sheet).
- [ ] `subirFotoEntidad`/`eliminarFotoEntidad` (photos.js:197 / api.js:2928) → Storage (Edge `fotos`).
- [ ] Diagnósticos iniciar/finalizarTestDiagnostico/runInternalTests (app.js ~22911/22945/23026).
- [ ] aviso-cajeros fallback `return post(...)` (api.js:2735) — validar paridad Edge y borrar.
- [ ] Espía/audio: 2401/2461/2583/3424 + `_mosUrl` 3557 → Storage+Edge.
- [ ] Dead: `loginPersonal` (2788), `autoCloseDayGuias` (2785), ramas merma directas sin OpLog (mermas.js), offline.js 407/413/417/724.

### Módulos compartidos (assets/, sirven a las 3 apps)
- [ ] `seguridad-modal.js`: `verificarHorario`✅ migrado; falta `solicitarExtensionHorario` (1006), `extenderHorarioHoy` (1261) → RPCs `mos.*` nuevas; `consultarEstadoDispositivo`✅.
- [ ] `membrete-modal.js`: `getEstadoLoteAdhesivo`✅; falta rutear `crearLoteAdhesivo`/`asegurarTriggerLotes`/lote-membrete por Edge en ME (WH ya lo hace).

### CIERRE FINAL (cuando todo lo de arriba esté en 0)
- [ ] Borrar constantes `GAS_URL`/`API_URL`/`MOS_GAS_URL`/`mosGasUrl` de los 3 frontends.
- [ ] Borrar los guards sentinela `=== 'ENLACE_DE_TU_SCRIPT_GAS_AQUI'` (ME, ~30 sitios, ya inocuos).
- [ ] `grep` final = 0 · web-check final las 3 apps · recién ahí el dueño borra GAS+Sheets.
