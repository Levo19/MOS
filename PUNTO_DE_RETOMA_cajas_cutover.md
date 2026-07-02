# Punto de retoma — Cajas UX + cutover cero-GAS (2026-07-01)

## ✅ COMPLETADO Y EN VIVO

### Frontend (GitHub Pages)
- **v2.43.409** — Cajas UX: ✈ orbita la baraja · botones alto contraste · sirena ⚠ sin-caja.
- **v2.43.410** — 100x fixes: getAlertasWarehouse cero-GAS · override móvil ✈ · badges sin translateX.
- **v2.43.411** — Cobro cancelar/reasignar cero-GAS (SQL 313) + push del front.
- **v2.43.412** — Cobro directo (314) + cierre FORZADO directo (315) + get_flags 316. **ACTIVADO.**

### Backend (Supabase, aplicado a prod)
- **SQL 111** — fix doble-conteo ANULADO_CONVERSION (defensivo).
- **SQL 313** — me.cancelar_cobro_asignado + me.reasignar_cobro_asignado.
- **SQL 314** — me.cobrar_credito_directo (cobro directo admin = cobrarCreditoConExtra + cierra cobro asignado).
- **SQL 315** — me.cerrar_caja_forzado (auth PIN + anular POR_COBRAR + montoFinal auto + efectos stock idempotentes).
- **SQL 316** — get_flags expone meCobroDirecto + meCierreForzadoDirecto (control fleet-wide).

### Flags (mos.config) — ACTIVOS
- `ME_COBRO_DIRECTO = 1` (cobro directo/asignar/cancelar/reasignar/confirmar por Supabase).
- `ME_CIERRE_FORZADO_DIRECTO = 1` (cierre forzado MOS por Supabase).
- **KILL-SWITCH:** `update mos.config set valor='0' where clave in ('ME_COBRO_DIRECTO','ME_CIERRE_FORZADO_DIRECTO');`

## P4 · Corte de GAS del CIERRE + 2 rondas 500x (2026-07-02) — HECHO + LIVE
Objetivo: cierre del cajero 100% Supabase (retirar el mirror GAS `CIERRE_CAJA`). Al testear se
destaparon 3 bugs reales (no cortar a ciegas = money-safe):
- **BUG silencioso de stock (crítico):** `me.cerrar_caja_efectos`→`zona_descontar_venta` exige
  `mos._claim_ok()` = app ''/'MOS'; el cajero corre como 'mosExpress' → el descuento fallaba
  SILENCIOSO (descuentoOk=false, tragado) y el stock lo descontaba SOLO el mirror GAS. Cero pickups
  `PK-VENTAS-` en toda la prod lo confirmó. FIX: elevar claim a MOS solo alrededor del descuento
  (idéntico al path GAS probado), guardar/restaurar. Ahora el cierre directo descuenta stock.
- **Doble-pickup (HIGH):** RPC crea `PK-VENTAS-<caja>`, mirror crea `PCK-CC-<caja>` — claves distintas,
  no dedupean. FIX (318+319): cross-guard recíproco + `pg_advisory_xact_lock('cerrarcaja:'||caja)` en
  AMBAS fns (cierra el race cross-txn; el mirror bloquea hasta que la RPC commitee).
- **Items divergentes (MEDIUM):** PK-VENTAS usaba `factor` crudo + ANULADO exacto; PCK-CC/descuento
  usan `_venta_canonico` (granel) + ANULADO prefijo. FIX (319): ambas leen ventas_detalle con
  `_venta_canonico` + `not like 'ANULADO%'` → paridad EXACTA (probada). Bonus: el path viejo resolvía
  mal presentaciones granel INACTIVAS (SKU+cant equivocados en todo pickup previo) — ahora correcto.
- **Observabilidad:** `me.cerrar_caja` devuelve `efectos` en el return (no lo traga); frontend avisa si
  `descuentoOk===false` O `efectos.ok===false` (fallo total ya no es invisible).
- **Frontend:** retirado el mirror GAS del cierre directo (ME v2.8.118 LIVE); **fallback GAS síncrono
  se MANTIENE** como red de seguridad si el directo falla. Push a MOS lo cubre el polling de
  me.estado_cajas; sin dependencia de Sheet (liquidación = pg_cron Supabase).
- SQL 27/315/318/319 aplicados a prod. Revisiones: R1 (3 lentes: claim/concurrencia/frontend) →
  HIGH+MED+LOW → corregidos; R2 → 319 CORRECTO y sin regresión (verificado empírico 2 conexiones).

### ⏳ ÚNICA verificación de campo pendiente (P4)
Hacer UN cierre de caja real con ventas y verificar en la DB que aparezcan:
`select id_pickup from wh.pickups where id_pickup like 'PK-VENTAS-%<caja>';` (pickup RPC) y
`select 1 from me.guias_cabecera where id_guia='G-VENTAS-<caja>';` (guía RPC).
- Si aparecen `PK-VENTAS`/`G-VENTAS` → el cierre directo corre cero-GAS ✅.
- Si aparece `PCK-CC-<caja>` → cayó al fallback GAS (revisar token/timeout del directo). No hay doble
  descuento ni doble pickup en ningún caso (guards + idempotencia).

### Tail cero-GAS restante (flujos de cobro SOLO-GAS, baja frecuencia) — NO hecho
Aún con fallback/primario GAS (tienen red de seguridad; construir RPC directa es esfuerzo aparte):
- `adminConfirmarCobrar` (COBRAR_CREDITO_CON_EXTRA) — RPC `me.cobrar_credito_directo` (314) YA existe;
  falta cablear + verificar paridad de auth (¿PIN admin?). NO cableado por seguridad.
- `confirmarRechazarAsignado` (RECHAZAR_COBRO_ASIGNADO) — sin RPC directa.
- `procesarCobroPendiente`/`confirmarMoneda`/`revertirCobro`/`confirmarCredito` (COBRAR_VENTA/
  CREDITAR_VENTA vía `_enviarMutacionDinero` con cola offline) — sin RPC directa.
- startup yesterday-close (index.html ~8988) CIERRE_CAJA montoFinal:0 — cleanup, aparte.
El cobro PRINCIPAL (`confirmarCobrarAsignado`) YA es cero-GAS (directo primario + GAS fallback).

## 100x senior — batch doble-conteo + efectos cero-GAS (2026-07-01, última)
- **Contexto:** exclusión de ventas cobradas-vía-cobro del efectivo del cierre (evita 2x: venta EFECTIVO + INGRESO 'Abono deuda') en 27/315/26/111 + `me.cerrar_caja` corre `me.cerrar_caja_efectos` best-effort (cierre del cajero cero-GAS).
- **Veredicto:** matemática de dinero CORRECTA en las 4 fuentes y en EFECTIVO/VIRTUAL/MIXTO + caso cross-caja (cobro cae en caja B, se excluye de caja A correctamente); efectos idempotentes (guard caja-level en `zona_descontar_venta` + kardex único → sin doble descuento con el mirror GAS); swallow best-effort no corrompe (subtransacción: solo revierte efectos, el dinero commitea). **0 HIGH.**
- **F1 (MED perf) CORREGIDO:** el `not exists(position('ticket '||id||' ' in obs))` era un scan correlacionado por venta (riesgo statement_timeout en caja grande al cerrar). Reemplazado por el patrón de 111: set `cobradas` materializado 1 vez (`substring(obs from 'ticket ([^ ]+)')`) + anti-join `id_venta not in (...)` **exacto** → sargable Y colision-safe estructuralmente (V-100 ya no colisiona con V-1000). Aplicado 27/315/26.
- **F2 (LOW) CORREGIDO:** `_paridad_cierre.js` actualizado con la misma exclusión.
- **Test ROLLBACK:** `me.cerrar_caja` efe=10/final=25 (V-1000 excluido, V-100 NO), `simular` efe=10 ✅. Paridad 40 cajas: 21 exactas, 19 descuadres pre-existentes (declarados + cobros GAS-era cuyo obs precede el formato 'ticket <id>').
- Commit: "perf(cierre): exclusion doble-conteo via anti-join materializado…" (pushed). DB-only, sin bump de frontend.

## Revisiones 100x (todas hechas)
- Paridad de dinero del cierre PROBADA vs GAS (excl. INGRESO_VIRTUAL).
- Stock del cierre forzado: SEGURO — mismo ledger vivo `me.stock_zonas`, idempotente por caja (no drift).
- **100x senior final → 1 HIGH + 1 MED, AMBOS CORREGIDOS:**
  - HIGH-1: cobro directo (314) vs confirmar (310) lockeaban keys distintas → posible doble
    registro de dinero. FIX: ambos lockean `cobro:'||idVenta` (mismo namespace que asignar 308).
  - MED-1: cierre forzado sin advisory lock → agregado `cerrarcaja:'||idCaja`.
  - Confirmado CLEAN: stock no dobla, cierre concurrente no dobla, sin bypass de auth.

## Notas de diseño
- El cierre forzado ANULA los POR_COBRAR (paridad GAS; `devueltosACredito` es alias legacy de anulados).
- yaCerrada NO re-corre efectos (evita doble descuento en cajas viejas de GAS legacy sin guard).
- El sello PAGADO al confirmar es del lado **ME/cajero** (confirmarCobroAsignado, otra app) — el
  flujo MOS (meCobrarCredito) NO reimprime; si se quiere el sello cero-GAS en ME es tarea aparte
  (Edge ticket-comprobante + wiring en MosExpress).

## Revisión 500x iterante (2 vueltas) — 2026-07-01
- **v2.43.413 (R1):** HIGH — cobro cancelar/reasignar (313) lockeaban `cobrocancel:idCobro` → race de
  doble-cobro con confirmar/directo. FIX: unificado a `cobro:idVenta`. + 111:444 kpisTickets prefix
  ANULADO%; 315 array_length→0; seguridad ?v=; _cjTkAplicarRango try/catch.
- **v2.43.414 (R2):** HIGH — cierre (`cerrarcaja:idCaja`) y cobros (`cobro:idVenta`) NO compartían lock →
  dinero podía entrar a una caja cerrándose / monto_final sub-contar. FIX: 310/314 toman TAMBIÉN
  `cerrarcaja:caja` antes de validar ABIERTA; 27 (cierre cajero) también. + MED editar_forma_pago (264)
  anula cobro ASIGNADO vivo (evita doble-cobro); MIXTO monto≥0; 313 re-guard not-found; membrete ?v=.
- Todos con test ROLLBACK + aplicados a prod. Lock unificado: `cobro:idVenta` (asignar/confirmar/
  directo/cancelar/reasignar/editar) + `cerrarcaja:idCaja` (cierre forzado/cajero + cobros que entran).

## PENDIENTES — estado 2026-07-01 (continuación)

### P0 · Hardening concurrencia — ✅ HECHO + aplicado a prod
- 309: los UPDATE re-chequean `estado='ASIGNADO'` (no pisan COBRADO/CANCELADO concurrente).
- 260 anular_venta: lock `cobro:idVenta` + anula (CANCELADO_ANULACION) el cobro ASIGNADO vivo.
- 264 zona_descontar_venta: restaurado el guard caja-nivel de 143 (corte total si ya hay kardex).
- Testeados ROLLBACK (177 líneas/dedupCaja) + aplicados.

### P2 · Cierre cajero ME — ✅ ACTIVADO
- `ME_CIERRE_DIRECTO=1`. Frontend MosExpress ya cableado a `me.cerrar_caja` (con lock nuevo, paridad
  probada). Efectos vía mirror GAS idempotente. Kill-switch: `node supabase/activar_cierre_cajero.js off`.

### P1 · Sello PAGADO cero-GAS — ✅ HECHO + desplegado
- Edge `ticket-comprobante` +param `pagoDiferido` (byte-paridad GAS Impresion.gs; aditivo). Desplegado +
  smoke OK (base64 contiene PAGADO/COBRO RECIBIDO/Fecha cobro).
- MosExpress v2.8.109: helper `_reimprimirCobroSello` disparado en el branch directo del confirm
  (best-effort, no bloquea el cobro). LIVE.

### ⏳ P3 · Smoke asignar directo (308) — verificación tuya en la app
- Programáticamente OK: `get_flags.meCobroDirecto=1` (cliente usa directo) + RPC viva. Falta que
  asignes un cobro real y confirmes en Network que llama `asignar_cobro_cajero` (no GAS).

### ⏳ P4 · Corte definitivo de GAS (cobro/cierre) — BLOQUEADO hasta validación de campo
- Requiere P1/P2 validados con operaciones reales (cierres de cajero + cobros con sello). Es una acción
  grande + difícil de revertir → NO hacer hasta que el campo confirme. Money-safe.


### P1 · Sello PAGADO cero-GAS en ME (lado cajero)
- **Qué:** al confirmar un cobro asignado en MosExpress (confirmarCobroAsignado), reimprimir el
  ticket con sello "PAGADO · COBRO DIFERIDO" arriba. Hoy lo hace GAS (imprimirTicketInternamente
  con esPagoDiferido). El flujo MOS (meCobrarCredito) NO reimprime — esto es SOLO del lado ME.
- **Cómo:** (1) leer `imprimirTicketInternamente` en `C:\Users\ISO\Documents\MosExpress\gas\` para
  el ESC/POS exacto del sello; (2) agregar flag `conSelloPagado`/`pagoDiferido{cajaCobro,cajeroCobro,
  adminAsig,fechaCobro}` al Edge `supabase/functions/ticket-comprobante/index.ts` (inyectar tras la
  línea forma_pago ~241, o en el header); `supabase functions deploy ticket-comprobante`;
  (3) cablear el reimprimir en el frontend ME tras `me.confirmar_cobro` (helper `_imprimirComprobanteEdge`
  en MOS; en ME el equivalente). Datos que ya devuelve me.confirmar_cobro: cajaDest,idVenta,metodo,monto,adminAsig,cliente.
- **App:** MosExpress (no MOS). Requiere tocar el front de ME (index.html monolito — validar inline).

### P2 · Cierre del cajero ME cero-GAS (me.cerrar_caja, flag ME_CIERRE_DIRECTO)
- **Qué:** el cierre NORMAL de caja que hace el cajero en MosExpress (distinto del forzado de MOS,
  ya hecho). RPC `me.cerrar_caja` (SQL 27) + efectos (me.cerrar_caja_efectos) YA existen y testeados.
- **Cómo:** cablear el frontend ME → me.cerrar_caja + me.cerrar_caja_efectos; verificar paridad de
  dinero con me.simular_cierre_caja sobre cierres reales; flipear `ME_CIERRE_DIRECTO=1`. Ojo: ese flag
  también afecta lecturas; revisar que el cajero ME lea/escriba coherente. Ídem manejo POR_COBRAR→ANULADO.
- **App:** MosExpress. La lógica de dinero/stock ya está probada (misma que el forzado).

### P3 · Smoke test en vivo del cobro-directo asignar (308)
- **Qué:** `me.asignar_cobro_cajero` (308) ahora está fleet-wide (get_flags 316 + ME_COBRO_DIRECTO=1);
  antes el cliente caía a GAS (localStorage canary). Confirmar en vivo que asignar un cobro desde MOS
  usa el directo sin problema (revisar Network → asignar_cobro_cajero, no GAS).
- **Riesgo:** bajo (idempotente, revisado 100x, kill-switch). Solo verificación.

### P4 · Corte definitivo de GAS del cobro/cierre (cuando P1/P2 estén)
- Una vez ME 100% Supabase en cobro+cierre, retirar/decomisar los handlers GAS correspondientes
  (cobrarCreditoConExtra, cerrarCajaForzado bridge, confirmarCobroAsignado) — cero-GAS pleno.
