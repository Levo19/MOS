# Migración 100% Supabase — Acumulador Pickup v2 (P1) + Precio en vivo ME (P2)

> Fuente de verdad viva. Pedido del dueño (2026-06-24): **migración total a Supabase, sin
> inerte / sin fallback / sin GAS en el camino vivo.** Cada paso con revisión 40x; cada
> problema cerrado con 100x. Dinero en producción → cada SQL se valida con smoke-rollback
> antes del cutover.

## Diagnóstico confirmado (con datos reales)

### P1 — "se suben productos no escaneados" (zona 2)
- NO era bug de escaneo. Eran los **106 ítems del acumulado semanal** `PCK-ACU-ZONA-02-2026-W26`
  (toda la reposición pendiente de la semana). Los 3 fantasma (maní/fideo/nakamoto) estaban
  ahí con `despachado:0` (pendientes, icono caja+reloj).
- **Money-safe:** la guía sale solo de lo escaneado (RPC 210, `despachado>0`). Pendientes no
  descuentan stock. ABSORBIDO/REZAGADO no pasan el guard de 210.

### P2 — precio nuevo no llega a ME (huevo granel S/7.00)
- Confirmado en Supabase: `HUEVO A GRANEL precio_venta=7.00 updated HOY`; `catalogo_meta` v1204.
- **MOS escribe bien** (`MOS_CATALOGO_DIRECTO=1`, `productos` en `MOS_SYNC_OFF_TABLAS` → ya NO
  escribe la Hoja). **ME lee de la Hoja vía GAS** (`Catalogo.gs:16,113`) → ve precio viejo.
  Split-brain: detecta versión por Supabase pero baja el dato por GAS (estrangulado por cuota).

## Modelo del acumulador (canónico, aprobado por el dueño)
- UNA lista despachable **por zona**, por **semana-DOMINGO** (emite hoy/despacha mañana → el
  pickup del domingo nace limpio; lun-sáb acumulan; domingo muere).
- `pendiente = max(0, solicitado − despachado)`. **Sobre-despacho NO acredita** (dar 25 de 20 →
  falta 0, el próximo pedido de 20 sigue siendo 20). Validado: R1→0, R2→20, R3→35.
- No despachado rueda aunque la guía nunca se tocó.
- **Disparador = llegada de cada pickup** (varios cierres/día → una sola lista). Cron nocturno = red.
- Domingo: el bucket viejo con pendiente → **REZAGADO** (oculto). Lunes 1ª hora: **impresión
  automática "lista de compra" 80mm** (canónicos), sin permiso → la jefa aprueba compra.

## Plan de migración (cada paso 100% Supabase)
1. **[HECHO ✅ validado 40x · APLICADO EN VIVO]** Motor v2 — `214_wh_acumulador_v2.sql`:
   `wh._bucket_dom`, `wh.consolidar_pickup_zona`, `wh.consolidar_pickups_todas`, trigger
   `tg_pickup_consolidar`. Smoke `_smoke_214.js` TODO VERDE. 40x: trigger con EXCEPTION
   (no bloquea cierre de caja), guard zona vacía.
2. **[HECHO ✅ validado 40x · aplicado, INACTIVO hasta wiring ME]** Nacimiento del pickup —
   `215_wh_crear_pickup_cierre_caja.sql`. Smoke `_smoke_215.js` VERDE contra caja real
   (21 prod, 59.15 uds, match exacto). Race-safe (ON CONFLICT). **FALTA:** que ME lo llame
   al cerrar caja + quitar el alta GAS (`warehouseMos/gas/Guias.gs:2021` `_dualWritePickupWH`).
   ⚠️ CRÍTICO: NO activar el RPC en ME sin quitar el alta GAS a la vez (doble-conteo). Deploy ME+WH.
3. **[HECHO ✅ · APLICADO]** Rezagado + impresión compra lunes — `wh.cron_rezagado_compra()`
   (pg_cron `wh-rezagado-compra` lunes 11 UTC → Edge `print-adhesivo` mode pickup-ticket).
4. **[PENDIENTE · sesión de frontend]** P2 catálogo — el `?accion=descargar` de ME trae 6
   estructuras; replicar TODAS desde Supabase (RPC tipo `mos.catalogo_pos_rls`, base
   `mos.productos_master_rls` ya existe), mapear en `sincronizarCatalogoBase`, eliminar GAS +
   botón sync. Deploy ME (GitHub Pages, git push) + prueba en navegador.
5. **[HECHO ✅ · CUTOVER APLICADO EN VIVO 2026-06-24]** `216_wh_cutover_acumulador_v2.sql`:
   migró `PCK-ACU-*-W26` (zona 1 y 2) → bucket-domingo asentado (zona2: 89 pend/210.59 uds,
   verificado); viejos → MIGRADO; cron `[20]` → `consolidar_pickups_todas`. Dry-run + apply
   verificados. **Revert disponible** (MIGRADO recuperable; drop trigger; cron→v1).

## Estado actual de prod (al 2026-06-24)
- Flags: `WH_PICKUP_ACUMULADO=1`, `MOS_CATALOGO_DIRECTO=1`, `ME_CIERRE_DIRECTO=0`.
- Cron `[20] wh-pickup-acumular | 10 7 * * *` → todavía llama la v1 (212). **Repuntar en cutover.**
- ACU vivo zona 2: 106 ítems (26 con algo despachado, 80 intactos). Mañana (jueves) la lista
  única debería mostrar **89 pendientes / 210.59 uds**.
- Deps verdes: `me.ventas` en Supabase · `http`+`pg_cron`+`pg_net` · `mos.productos_master_rls`.

## Puntos que requieren al dueño
- **Deploy de ME (MosExpress)** vía clasp (auth Google).
- **Ventana de cutover** (paso 5): es el momento irreversible que toca stock/listas reales.
