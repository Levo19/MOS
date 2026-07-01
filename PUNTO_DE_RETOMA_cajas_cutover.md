# Punto de retoma — Cajas UX + cutover cero-GAS (2026-07-01)

## Desplegado y en vivo
- **v2.43.409** — Cajas UX: ✈ orbita la baraja (cjAvionOrbit 9s) · botones reasignar/cancelar alto contraste · sirena ⚠ rojo↔amarillo en grupo sin-caja (cjSiren).
- **v2.43.410** — Fixes de la revisión 100x:
  - `getAlertasWarehouse` **cero-GAS Supabase-only** (mata el CORS del arranque). RPC `mos.alertas_warehouse` verificada: `_fresh:true`, 413 lotes frescos. NO se borró (alimenta KPI Vencimientos + Almacén→Vencimientos; NO se usa en Zonas).
  - [1.1] override móvil `.cj-mano-avion` (deck→`relative` en <720px, avión no se despega ni orbita sobre la grilla).
  - [1.2] badges `.cj-deck-badge`/`.cj-scc-badge` → keyframe propio `cjBadgePulse` sin `translateX(-50%)` parásito.

## Revisión 100x — resultado
- **Cierre de caja: paridad de dinero PROBADA vs GAS.** Fórmula idéntica (`inicial + efectivo_ventas + INGRESO − EGRESO`), **excluyendo `INGRESO_VIRTUAL`** igual que GAS (probado en caja con S/639.30 de virtual: `diff_excl=0.00` vs `diff_incl=−639.30`). Los descuadres restantes son conteos físicos declarados reales. Script: `supabase/_paridad_cierre.js`.
- **[HIGH latente] `mos.cierres_caja` doble-conteo:** usaba exact-match `('ANULADO','CREDITO')`; un `ANULADO_CONVERSION` (NV→CPE) caería en COMPLETADO y se **sumaría al total**. Verificado: **0 filas `ANULADO_*` en prod hoy → latente, no vivo**. Parche prefix-match aplicado al **archivo** `supabase/111_mos_cierres_caja.sql` (alinea con 311/312), byte-idéntico con data actual.
  - ⏳ **PENDIENTE APLICAR A PROD** (bloqueado por ser RPC de dinero): `node supabase/_apply_sql.js 111_mos_cierres_caja.sql` — requiere OK del dueño.

## NO se flipeó (money-safe) — huecos cero-GAS reales que faltan
1. **Cierre forzado MOS (`meCerrarCajaForzado`) sigue en GAS.** NO se puede cablear a `me.cerrar_caja`: opera distinto (GAS **devuelve POR_COBRAR a la mesa de créditos** + libera cobros + regenera guía SALIDA_VENTAS + auth admin; la RPC **ANULA** los POR_COBRAR). Necesita **RPC dedicada `me.cerrar_caja_forzado`** que replique la semántica GAS + efectos (stock/guía/pickup vía `me.cerrar_caja_efectos`) + auth admin. Luego cablear + parity + flip.
2. **Cobro: confirmar/cancelar/reasignar siguen en GAS.**
   - `meCobrarCredito` (confirmar cobro directo) → RPC `me.confirmar_cobro` (SQL 310) **existe pero sin cablear**. Falta: parity vs GAS + **sello PAGADO** en Edge `ticket-comprobante` (agregar flag `conSelloPagado` tras la línea forma_pago) + cablear.
   - `meCancelarCobroAsignado` / `meReasignarCobroAsignado` → **NO existen RPCs**; hay que construirlas.
   - Ya directo/live: `meAsignarCobroCajero` (asignar, SQL 308).

## Orden sugerido al retomar
1. (Dueño) aplicar SQL 111 a prod (1 línea, byte-idéntico).
2. Sello PAGADO Edge + cablear `me.confirmar_cobro` (parity primero).
3. RPCs cancelar/reasignar cobro.
4. RPC dedicada cierre forzado + cutover.
