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

## Pendiente (opcional, NO bloqueante)
- Cierre del **cajero ME** (me.cerrar_caja, flag ME_CIERRE_DIRECTO) — cutover del lado MosExpress.
- Sello PAGADO cero-GAS en ME (Edge).
- Smoke test en vivo del cobro-directo asignar (308) ahora que está fleet-wide.
