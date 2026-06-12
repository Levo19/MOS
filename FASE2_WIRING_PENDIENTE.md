# Fase 2 — Escritura directa PWA→Supabase: WIRING PENDIENTE (handoff)

> Estado al 2026-06-12 (madrugada). El BACKEND está construido, probado y endurecido.
> Falta SOLO el wiring de la cola offline en la PWA — money-critical, para sesión fresca.
> NO habilitar escritura directa en vivo hasta cumplir el CONTRATO (abajo).

## TL;DR
- ✅ **Lectura directa** (cajero) funciona en dispositivo real. Flag `localStorage me_lectura_directa='1'`. Segura.
- ✅ **Motor de escritura directa** (`me.crear_venta_directa`) probado: idempotente, correlativo atómico, fail-closed.
- ✅ **Mirror a Sheets** endurecido (LockService + cabecera/detalle atómicos). Índice `ref_local` versionado.
- ⛔ **Wiring NO hecho**: la PWA todavía NO crea ventas directo. El último paso es modificar `syncPendientes`.

## Qué está construido (todo desplegado)
| Pieza | Ubicación |
|---|---|
| mint-token (JWT HS256 scoped, auth por DISPOSITIVO no zona) | `gas/Fase2Auth.gs` `mintSupabaseToken` + router `MINT_TOKEN` (Code.gs) |
| RPC lectura directa (device-auth, fail-closed app) | `supabase/16` `me.ventas_hoy_zona_auth(prefijos,desde)` |
| RPC ESCRITURA directa NV (insert+correlativo+dedup) | `supabase/17` `me.crear_venta_directa(jsonb)` |
| Mirror venta directa → Sheets (idempotente, lock) | `gas/Fase2Auth.gs` `mirrorVentaASheets` + router `MIRROR_VENTA` |
| Índice único parcial ref_local (versionado) | `supabase/18` `ux_me_ventas_ref_local` |
| Lectura directa cableada en PWA (flag OFF) | `index.html` `cargarVentasZona` / `_ventasZonaDirecto` |
| Vistas solo-lectura para revisar en `public` | `public.ventas`, `public.cajas`, etc. |
| Secretos en GAS Script Properties | `SUPABASE_JWT_SECRET` (firma), URL/anon públicas en index.html |

## Modelo de auth (IMPORTANTE — corregido)
Autorización **por DISPOSITIVO registrado** (UUID activo en DISPOSITIVOS/`mos.dispositivos`), **NO por zona**:
los dispositivos/empleados **rotan** entre zonas. El token lleva `app:mosExpress` (no `zonas`). La zona la
pone el turno/caja (los prefijos que pasa la estación, como el path GAS). `mos.dispositivo_zonas` quedó SIN uso.

## El 20× (w5gl14r76) — veredicto: NO en vivo hasta cerrar esto
- 🔴 **C1 índice ref_local no versionado** → ✅ ARREGLADO (`supabase/18`, commit f5aa040).
- 🔴 **C2 doble fila en VENTAS_CABECERA**: si la MISMA venta entra por `crear_venta_directa`+mirror Y por
  `procesarVenta` (cola offline) → 2 filas (mismo ref_local, mismo correlativo, distinto id_venta) → el cierre
  (lee Sheets) cuenta DOBLE. El correlativo SUNAT NO se duplica (mismo minter idem_key=ref_local) — la fila Sheets SÍ.
- 🟠 mirror sin reintento → si falla, cierre SUB-cuenta (faltante falso).
- 🟠 sin LockService en scan+append → ✅ ARREGLADO en el mirror (no en `procesarVenta`, ver contrato).
- 🟠 revocación stale: el mint valida la sombra `mos.dispositivos` (≤15min), no el Sheet vivo → device baneado
  a mano sigue minteando un rato. Mitigar: validar contra el Sheet vivo (cacheado) o dirty-sync de suspensión.

## CONTRATO que el WIRING DEBE cumplir (antes de habilitar en vivo)
1. **Exclusividad de path por venta**: al crear directo OK, **sacar la venta de `pendingSales`** inmediatamente
   → la cola NUNCA la reenvía a `procesarVenta`. (Sin esto = C2 = doble fila = dinero doble.)
2. **Mirror reintentable + idempotente**: ✅ **reconciliación HECHA** (`gas/Fase2Auth.gs` `reconciliarDirectasSheets`,
   ME@196): busca ventas NV de hoy en `me.ventas` sin fila en VENTAS_CABECERA y las espeja (idempotente). Pendiente:
   engancharla a un trigger (5-10min) o al inicio del cierre + (opcional) cola `pendingMirrors` para reintento inmediato.
3. **CORRELATIVO_SOURCE=supabase invariante**: si quedara en 'sheets', `procesarVenta` mintearía número
   distinto = duplicado SUNAT real. Verificar al activar el path directo.
4. (Opcional) LockService también en el append de `procesarVenta` (hoy sin lock; mitigado por lock del botón
   de venta en el frontend). Si se comparte lock con el mirror, cierra el TOCTOU del lado Sheets por completo.

## Plan de wiring (sesión fresca)
1. **Flag** `me_escritura_directa` (OFF default). Solo NV + online + flag → path directo.
2. En el flujo de venta (donde hoy se encola/sincroniza vía `procesarVenta`, ver `index.html` `syncPendientes`
   ~línea 8783-8818 y la creación de la venta ~14680-14730):
   - Si flag+NV+online: `POST MINT_TOKEN` → token → `POST {SUPABASE_URL}/rest/v1/rpc/crear_venta_directa`
     (apikey anon + Bearer token + Content-Profile me) con el payload (ref_local, serie, vendedor, estacion,
     cliente, total, forma_pago, id_caja, dispositivo_id, obs, items).
   - On success: **remover de pendingSales** + disparar `MIRROR_VENTA` (con reintento) + imprimir local.
   - On error (red/RPC): **fallback** al path normal `procesarVenta` (queda en pendingSales).
3. **Mirror con reintento**: si `MIRROR_VENTA` falla, reintentar (cola). + reconciliación periódica/al cierre.
4. **Test en 1 dispositivo**: NV directa → ver en Network el POST a `…supabase.co/rest/v1/rpc/crear_venta_directa`
   (no GAS) → verificar: 1 sola fila en `me.ventas` Y en VENTAS_CABECERA (no duplicado), correlativo correcto,
   cierre de caja cuadra. Reintento/doble-tap → no duplica.
5. **20×** del wiring antes de declararlo listo. **Rollback**: apagar el flag.

## Verificación rápida (tooling)
- pg directo: `C:\Users\ISO\.sbtools` (cliente `pg`) + `C:\Users\ISO\.sb_db.url`. anon key en `.sb_anon.key`.
- `select * from public.ventas order by created_at desc limit 10;` (vista para revisar sin código).
- mint de prueba: `probarMintToken` en el editor GAS (loguea token + payload).
