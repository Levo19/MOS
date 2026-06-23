# Lista de reparaciones — Módulo Zona / ecosistema (2026-06-18)
> Reportadas por el dueño. Cada una con revisión 40x senior.

## 1. 🔴 Kardex de zona INCOMPLETO (incongruente con el stock)
- El kardex de un producto (ej. MAGGI ZONA-02) muestra SOLO los ajustes (INC +12 Luis, +34 Javier → saldo 46/34) pero el **stock real es −1**. No aparecen las **SALIDA_VENTA** (descuentos por venta).
- **Debe mostrar TODOS los movimientos**: ajustes + ventas + guías. Incluso los **tickets de venta aún no reconciliados** con la guía de venta del día (porque el día no se ha cerrado).
- **Color naranja** para lo no-reconciliado/pendiente (como acordamos: naranja = abierto/pendiente).
- Causa probable: `zona_kardex_historial` reconstruye de auditorías+guías pero NO incluye las ventas vivas del día (o el saldo mostrado no cuadra con me.stock_zonas).

## 2. 🔴 Ticket del día y Lista de compras NO IMPRIMEN
- "Imprimir ticket del día" → PrintNode job `8577845317` "RIZ Ticket ZONA-02" en **HP / POS-80C (copy 1)** → estado **error**. Igual la lista de compras.
- Comparar: los tickets de venta/guía sí imprimen (XP-80C / POS-80C). Sospecha: impresora destino mal resuelta ("POS-80C (copy 1)") o el contenido ESC/POS del Edge `riz-print` falla.

## 3. 🟠 Guías SALIDA_JEFATURA (WH) no imprimen
- Creé guías tipo Jefatura en WH; aparecen en la app pero al imprimir → toast **"ese id no existe"**. Revisar el path de impresión de guías y agregar el tipo JEFATURA a la lista soportada.

## 4. 🟠 Recibir guía de almacén — escaneo QR + UX confusa
- La guía SALIDA_ZONA de WH imprime un ticket con un **QR que ya tiene embebido el idGuia**. Que ME, en "Recibir guía", permita **escanear ESE QR con la cámara y extraer solo el idGuia** (no crear otro QR).
- UX confusa: hay 2 opciones ("Recibir guía de almacén" y "Registro manual"). El flujo correcto: al ingresar de almacén **primero se escanea el idGuia**, y de ahí se escanean los productos manualmente. Aclarar/unificar.

## 5. 🟡 "Pedir a almacén" → rediseño a CARRITO + persistencia
- Bug: pedí 15 chicha jora 3lt → marcó "pedido" + apareció pickup en WH → al rato **se "desmarcó"** → pedí otra vez → "pedido" de nuevo pero a WH **ya no apareció** → ¿se duplicó en su tabla? Revisar dedup de pickups.
- El mark "pedido" **debe persistir ~1 semana** con texto "pedido hoy / pedido ayer / pedido el martes" para saber que ya se pidió.
- **Rediseño**: en vez de enviar uno por uno, "Pedir" agrega a un **CARRITO flotante** por zona; el admin agrega solo los que quiere, ajusta cantidad con +/−, y con **un click envía TODO en un solo paquete** (más limpio).
- Aun marcado "pedido hoy/ayer", un click **re-agrega al carrito** (por si se re-despacha por insistencia). El botón muestra "pedido hoy y ayer".

## 6. (verificar) Posible duplicado de pickup en WH
- Derivado del #5: confirmar en `wh.pickups` si la chicha jora quedó duplicada.

---
## ✅ TODAS REPARADAS Y VALIDADAS (2026-06-18)
1. ✅ Kardex completo + naranja (MOS v2.43.266, SQL 172) — muestra ajustes+ventas+guías, naranja=no-reconciliado, saldo cuadra con stock (1229/1229). Causa: rama que ocultaba ventas + ajuste como delta vs set-absoluto.
2. ✅ Ticket/lista RIZ imprime (v2.43.265) — apuntaba a impresora duplicada rota (75452612 "POS-80C copy 1"); desactivada, usa la buena (75287158) + fix caché de impresora.
3. ✅ Guías JEFATURA imprimen (@495) — se crean directo en Supabase (G_L…), no en la Hoja; imprimirTicketGuia ahora cae a leer wh.guias de Supabase.
4. ✅ Recibir guía QR + UX (ME v2.8.28) — el QR es URL `...&id=G…`; parser _rwExtraerIdGuia extrae el idGuia; UX reagrupada (con guía / sin guía), CTA "Escanear QR".
5. ✅ Pedir a almacén = CARRITO flotante (MOS v2.43.267, SQL 173) — +/−, enviar paquete (1 pickup N líneas), idempotente por localId. Estado "Pedido hoy/ayer/martes" persistido (me.zona_pedido_log, 7 días). Re-pedir permitido.
6. ✅ Pickup NO se duplicó (1 solo en wh.pickups). Causa de la confusión: mark optimista no persistido + dedup determinista que tragaba el re-pedido → ambos corregidos en #5.

## 🔁 ROUND 2 — hallazgos al probar (2026-06-18 tarde)
- **R2-1 · Ticket del día RIZ VACÍO:** imprime pero dice "sin productos para hoy, verificar stock real…". Debía dar ~45 productos (≈315 rotación / 7 días) para el CONTEO FÍSICO. Backend `zona_ticket_dia`/cola-7-días/`me.zona_esperado` no materializado o query mal.
- **R2-2 · Kardex saldo NO cuadra:** muestra movimientos pero el saldo corrido está mal (ajuste +34→saldo 0; +12→saldo 12; CUADRE saldo 3 ≠ Stock zona −1). Arreglar el cálculo cronológico (set-absolutos anclan, deltas acumulan, final == stock_zonas) + **mostrar el STOCK actual en el layout del kardex** para verificar la suma. Validar con el cod EXACTO de MAGGI que ve el usuario.
- **R2-3 · Recibir guía (ME) UX + escáner se cierra tras 1 producto:** (a) el escáner se CIERRA después de escanear UN producto y no deja seguir — pasa en TODAS las guías (bug general del escáner) → escaneo CONTINUO. (b) Debe abrirse la guía y escanear productos de forma clara. (c) "…o ingrésala a mano" ¿para qué sirve si es lo mismo? = redundante → aclarar/quitar. Moderno, intuitivo.
- **R2-4 · Carrito + botón "pedido":** (a) el modal del carrito parece TRANSPARENTE (revisar opacidad/diseño). (b) el botón sigue diciendo "Pedir 63 un a almacén" aunque haya chip "📦 Pedido hoy" — debe reflejar el estado pedido (qué día, y permitir re-pedir) de forma intuitiva, no verse igual que no-pedido.
- **R2-5 · Lista compras imprime ✅ (el dueño la revisa luego).**
- ⚠️ **R2-1, R2-2, R2-3, R2-4 QUEDARON PENDIENTES** (los agentes se cortaron por límite de sesión, devolvieron 0). RE-LANZAR.

## 🔁 ROUND 3 — remodelación + overhaul (2026-06-18, "vamos")
**R3-WH1 · Envasados — total por día + LIQUIDACIÓN semanal (remodelación, no error):** el historial de envasados ya está agrupado por día → mostrar el **TOTAL por día**. Y en una parte que no estorbe, la **suma de la semana actual = liquidación del envasado**: desde el **LUNES de la semana en curso hasta HOY** (ej. jueves = lun→jue), se actualiza solo y **se reinicia cada lunes**. El operador quiere saber cuánto va a cobrar.
**R3-ME1 · Guías de ME — replicar UX/UI de WH:** moderno, con **sonido** al agregar a la lista, lista en vivo que crece, la **misma plantilla** de guías/registro de productos que WH. Intuitivo. (Hoy ME no tiene eso; WH sí — replicarlo.)
**R3-ME2 · Candado/estado de guías ME (replicar reglas WH):** mostrar abierto/cerrado (candado, efectos). Hoy deben verse TODAS cerradas. Reglas WH: autolock a los **30 min** de inactividad, reabrir con **auth-admin** solo **+30 min**. Backend YA existe (SQL 147: `me.cerrar_guia_zona_idempotente`/`me.reabrir_guia_zona`/cron `me-autocierre-inactividad`) → falta el FRONTEND (candado + reabrir authadmin).
**R3-ME3 · Scan se CRUZA con carrito de venta:** al agregar un producto a una guía, a veces se agrega al **carrito de VENTA** en vez de a la guía. La regla deseada: el scan va a la GUÍA mientras se está en ese flujo; SOLO tras **5 min de inactividad** debe cerrar todo + ir al módulo de **ventas** (ahí el scan agrega a venta). Hoy se cruza. Arreglar el ruteo del scan según el contexto activo.
**R3-ME4 · Escáner se cierra tras 1 producto** (= R2-3): escaneo CONTINUO en guías/recepción.

## ✅ ROUND 2+3 CERRADOS + REVISIÓN SENIOR (2026-06-18 noche)
- R2-1 ticket día ✅ (MOS SQL 174; review cazó bug de partición: 27 huecos+9 dups+68 saltos → anclado a lunes + orden determinista, cron 138 alineado; partición completa/disjunta/estable).
- R2-2 kardex saldo ✅ (cuadra 17 códigos incl. negativos; chip "stock actual"). R2-4 carrito ✅ (modal opaco + botón 3 estados + re-pedir). R2-3/R3-ME4 escáner continuo ✅.
- R3-WH1 envasados: total/día + liquidación semanal (lun→hoy TZ Lima, reinicia lunes; unidades, no hay tarifa $) ✅ WH v2.13.260, review senior PASS (1517 un).
- R3-ME1 UX WH replicada en guías ME (sonido/slide-in/count-up) ✅. R3-ME2 candado ABIERTA/CERRADA + reabrir auth-admin ✅ (review cazó: reabrir fallaba por gate mos._claim_ok→me._claim_zona_ok). R3-ME3 cruce scan↔venta ✅ (review cazó: _intervalFocus robaba foco→scan a venta; ruteo por contexto + 5min→ventas). ME v2.8.31.
- WH ícono ⚡ Envasador en menú inferior móvil ✅ WH v2.13.261.
- R2-6 comparar guía: sobrantes YA aparecen ✅; refinamiento lote/vencimiento = pendiente menor opcional.

## 🔬 REVISIÓN 100x 3 APPS (2026-06-18 noche) — bugs reparados
- 🟠 MOS v2.43.270: "+Lista compras" no armaba la lista (faltaba param `semana` ISO → RPC rechazaba). Fix: `_zonaSemanaISO()`. Validado 13/13 bordes.
- 🟡 SQL 175: `recibir_guia_wh_cerrar` temp table no reentrante (crash si 2 llamadas/tx, como 148). Fix reentrante en BD + origen 146.
- R2-6 refinado v2.43.269: comparar guía con codbarra + lote/venc + 3 secciones (Faltan/Sobran/OK).
- HILOS SUELTOS (acción dueño): WH alertas_stock 1159 huérfanas (NO flipear getAlertasStock→supabase sin sync-off de esa tabla) · WH Reporte.gs JEFATURA sin commit git (verificar print en vivo, clasp si falla) · ME Creditos.gs (cobrar/creditar/retoma) aún lee Sheet (cutover aparte, no rompe hoy).
- SÓLIDO: MOS kardex 25/25, ticket partición OK, eval/jornadas 23/23, {p} limpio · ME anti-cruce hermético, money-safe · WH cierre idempotente delta-0, envasados 1517, FIFO.

## 🔬 AUDITORÍA 100x DEPENDENCIA DEL SHEET (2026-06-18 noche) — delete-safe
**Veredicto: las 3 apps operan sobre Supabase como FUENTE; el Sheet = espejo/respaldo.** Bugs de dependencia corregidos:
- ME @227: 6 vías que leían/escribían el Sheet como fuente → Supabase-primario+fallback (anulacionMasiva, getExtrasCaja, detalleVenta, getCobrosAsignadosCajero, cajeroActivo, registrarGuia guard). (Creditos cobrar/creditar/retoma ya estaba migrado.)
- WH @501-505: 3 vías (marcar/aceptar alertas escribían a Hoja muerta; mermas registrar/resolver; stock mostrado) → Supabase. `_WH_SYNC_OFF_DEFAULT`=10 tablas (+mermas+alertas_stock). Memoria: architecture_wh_auditoria_dependencia_sheet.
- MOS @433: categorías/zonas ahora espejan al instante (eran Sheet-only write).
**AÚN dependen del Sheet (con razón):** 🔴 MOS pagos de jornal (marcarPagos/anularPago, DINERO, pagosJornalDirecto=0 → sesión dedicada: RPC registrar_pago_jornal + sync-off liquidaciones) · 🟢 MOS categorías/zonas write (no-dinero, mitigado) · ME AlertaEfectivo + getCierreHtml (no bloquean) · WH preingresos/producto_nuevo (no mueven stock).
**ACCIÓN DUEÑO:** `whSyncOffEstado()` → si falta, `whSyncOffTablas()` (10 tablas) para que el sync nocturno no pise Supabase.

## R2-6 original:
- **R2-6 · Comparar guía (recepción):** CORRECCIÓN — el SOBRANTE SÍ aparece ("QUAKER AVENA … env 0 · esc 13 sobra 13"). Funciona. Refinamiento pendiente (menor): agrupar faltan/sobran de forma más intuitiva + agregar **codigobarra + lote/vencimiento** a cada línea. NO bug.
