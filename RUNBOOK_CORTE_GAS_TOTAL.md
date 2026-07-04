# RUNBOOK — Corte total de GAS + Sheet (ecosistema MOS/ME/WH)

> DIRECTRIZ: en 2 días se borran TODOS los archivos GAS y TODOS los Sheet. Todo debe operar 100% Supabase:
> cero-GAS, cero-fallback, cero-Sheet. Nada puede depender de GAS/Sheet ni siquiera como fallback.
> Fuente: auditoría exhaustiva 2026-07-04 (4 agentes: MOS, ME, WH, assets compartidos).

## 🔴 BLOQUEANTES DUROS — rompen login/arranque al borrar GAS (máxima prioridad)

| # | App | Qué | Dónde | Falta |
|---|---|---|---|---|
| B1 | **Assets** | `device-auth.js` `init()` + `_verificarReal` EXIGEN `mosGasUrl`; sin ese valor el auth **no arranca en las 3 apps** | device-auth.js:1470,1906 | hacer `mosGasUrl` OPCIONAL (basta app+storageKeys+sbAnon/mintUrl). Workaround inmediato: seguir pasando cualquier string en mosGasUrl |
| B2 | **MOS** | `verificarPinPersonal` (login) sin RPC → nadie entra a MOS | app.js:693,709 | RPC `mos.verificar_pin_personal` + intercept en `post` |
| B3 | **ME** | Anulación de venta `ANULACION` sin RPC (dinero) | index.html:19160 / _postMutacionDinero 17114 | RPC `me.anular_venta_directo` + mapeo |
| B4 | **ME** | Registrar guía `REGISTRAR_GUIA` sin RPC (inventario) | index.html:20013,20064 | RPC directo |
| B5 | **ME** | Aprobar dispositivo in-situ `aprobarDispositivoEnSitu` → no se dan de alta tablets | index.html:7215 | usar `mos.aprobar_dispositivo` (ya existe; seguridad-modal ya lo hace) |
| B6 | **WH** | **Portales cliente 100% GAS** (pedido/clientes/reporte/clienteInbox) — mueren enteros | pedido.html:127, clientes.html:63, reporte.html:110, clienteInbox.js:19 | backend Supabase propio (RPCs cliente + Edge para el reporte/QR) — el bloque más grande |

## 🟠 MONEY / INVENTARIO sin ruta directa (rompen operación)

- **ME:** BAJA CPE (`BAJA_CPE`), Convertir NV→CPE (fac inerte → cae a GAS), Confirmar retoma caja (`CONFIRMAR_RETOMA_CAJA`), Cambio impresora caja, Editar cliente venta, Registrar auditoría stock (`REGISTRAR_AUDITORIA`), Devolución a WH, Desbloqueo temporal usuario, Desbloqueo horario overlay pre-Vue.
- **MOS:** `getOperacionesConDetalle`/`getOperacionDetalle` (poller vivo de operaciones), catálogo/precios master (`actualizarProductoMaster`, `actualizarCostoPorSku`, promociones, categorías, zonas — 0% migrado), personal/jornales (`actualizarPersonalMaster`, `backfillLiquidacionesDia`, `importarJornadasDesdeCajas`, `resolverHorarioPersonal`), seguridad admin-key (`getClaveAdminGlobal`, `rotarClaveAdminGlobal`), `setConfig`.
- **WH:** Mermas V2 (`agregarAMermas`/`solucionarMerma`/`procesarEliminacionMermas`), op-log (`aplicarOp`), fotos genéricas (`subirFotoEntidad`/`eliminarFotoEntidad`), `desbloquearUsuarioTemporal`, `autoCloseDayGuias`, reads solo-GAS (`verificarHorario`, `getWelcomeData`, `getRolUsuario`, `getDesempenoDia`, `getResumenPersonal`, `getProducto` single).
- **Assets:** membrete `getEstadoLoteAdhesivo` (polling → GAS; **RPC `mos.adhesivo_lote_estado` YA EXISTE, solo falta cablear en `_RPC_DIRECT`**); seguridad-modal `verificarHorario` (polling widget), `solicitarExtensionHorario`, `extenderHorarioHoy`.

## 🟡 FALLBACKS VIVOS a limpiar (el código llama GAS aunque el flag esté ON)

- **MOS `_conFallbackMOS`** (api.js:274): con `mos_lectura_navegador` OFF, las ~65 lecturas interceptadas vuelven a GAS → **quitar el arm `gas()`** (no depender del flag).
- **WH `call`/`post`** (api.js:2151,2236): fallback GAS presente en TODAS las escrituras aunque `WH_*_DIRECTO=1` → quitar el arm GAS por acción.
- **ME Cat.1** (14 rutas): venta/CPE/cierre/apertura(espejo)/cobros/extra-caja/impresión/cola-offline caen a GAS si su flag está OFF o el directo falla → verificar flags ON + quitar el fallback.
- **Dual-writes a Sheet:** `registrarPushToken` GAS (MOS app.js:37504, ME index.html:14964, WH app.js:3514) — dejar solo `registrarPushTokenSB`. ME apertura espejo (13254), `msg_push_destinatarios` (ME 15248 → Edge push), etiquetas escrituras (ME 7711+), espía chunks (MOS/ME/WH → Storage).
- **Fallbacks Supabase-first con GAS vivo:** MOS `enviarPushNotif`, `tribIGVEmitidoMes`, `meHistorialCliente`, `getProductosNuevosWH`.

## 🔵 MÓDULOS COMPARTIDOS cableados a GAS (re-cablear apiPost → RPC/Edge)

- **ME/WH `SeguridadSystem.iniciar`**: `apiPost` → GAS. Horarios/alertas/lockout por GAS. Solo `pushAudiencia` es cero-GAS.
- **ME `MembreteSystem.iniciar`**: datos `wh_*` (alertas precio, lotes) por GAS; impresión ya Edge.
- **device-auth `_aprobarViaGAS`**: dual-write + aprobación in-situ si `deviceAuthDirecto` OFF → prender el flag en las 3 + remover.

## 🟢 LIMPIEZA (dead code que apunta a GAS)

- MOS index.html: bloque `if(false)` (18908) + 3 fetch wizard-permisos muertos por `_getDeviceIdMos` undefined (20295/20344/20369); Editor Adhesivos GAS (19595 — migrar a Edge o gate).
- WH: `_mintViaGAS` (api.js:92, función inexistente/rota), ramas legacy `offline.js` (407-444), fallbacks de métodos ya cero-GAS por el caller (`estadoBloqueoUsuarioDirecto`, `registrarUbicacionDirecto`).
- membrete `asegurarTriggerLotes` + banner/botón trigger (sin sentido sin GAS).
- ME `_syncImpresorasFromProyectoMOS` (9690), etiqueta batch (7789), `_mirrorVentaAsync` (16680) — ya muertos.

## ✅ YA cero-GAS confirmado (no tocar)
CPE emisión (Postgres http, STUB probado), WH escritura directa (33 flags ON, harness = CERO GAS), auth boot/verify + heartbeat (fail-closed), extensor-horario (100%), mint tokens (Edge), lecturas directas MOS con frescura (finanzas incluida), 2a tokens (mos.push_tokens), catálogo, ticket/impresión centralizada Edge.

## Cola offline (ambos) — nota crítica
ME `sincronizarDatos` (10078) y WH `offline.js:628` drenan a GAS los ítems SIN sello `direct`/`_viaDirecta`. Con GAS borrado, esos ítems fallan. **Garantizar que TODA op encolada lleve el sello directo** antes del corte.
