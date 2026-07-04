# RUNBOOK — Corte total de GAS + Sheet (ecosistema MOS/ME/WH)

> DIRECTRIZ: en 2 días se borran TODOS los archivos GAS y TODOS los Sheet. Todo debe operar 100% Supabase:
> cero-GAS, cero-fallback, cero-Sheet. Nada puede depender de GAS/Sheet ni siquiera como fallback.
> Fuente: auditoría exhaustiva 2026-07-04 (4 agentes: MOS, ME, WH, assets compartidos).

## 🔴 BLOQUEANTES DUROS — rompen login/arranque al borrar GAS (máxima prioridad)

> ESTADO 2026-07-04: **B1–B5 HECHOS + DESPLEGADOS** (RPCs aplicadas en prod, frontends cableados cero-GAS/cero-fallback, versiones bumpeadas). Falta solo **B6** (portales cliente — greenfield grande).

| # | App | Qué | Estado |
|---|---|---|---|
| B1 | **Assets** | `device-auth.js` exigía `mosGasUrl` → no arrancaba | ✅ HECHO: `mosGasUrl` opcional (gate = app+storageKeys+sbAnon+sbUrl\|mintUrl). Aprobación in-situ 100% Supabase (removido `_aprobarViaGAS`+dual-write+fallback). device-auth v1.0.26, `?v=` bumpeado en 3 apps. |
| B2 | **MOS** | `verificarPinPersonal` (login) sin RPC | ✅ HECHO: RPC `mos.verificar_pin_personal` (SQL 359, espejo exacto GAS) + intercept `post` cero-GAS. MOS 2.43.446. |
| B3 | **ME** | Anulación `ANULACION` sin RPC (dinero) | ✅ HECHO: `me.anular_venta_directo` (SQL 360, wrapper que reusa `me.anular_venta` con elevación de claim para el reposo). `_postMutacionDinero` cero-GAS. ME 2.8.156. |
| B4 | **ME** | Registrar guía `REGISTRAR_GUIA` (inventario) | ✅ HECHO: `me.registrar_guia_directo` (SQL 361, ciclo ABIERTA meta-only / legacy inmediato). `_postGuiaBackground` cero-GAS. ME 2.8.156. |
| B5 | **ME** | Aprobar dispositivo in-situ | ✅ HECHO: `confirmarActivarInSitu` → `mos.aprobar_dispositivo` anon. ME 2.8.156. |
| B6 | **WH** | **Portales cliente 100% GAS** (pedido/clientes/reporte/clienteInbox) | ⛔ PENDIENTE (bloque grande). Requiere: 4 tablas mos (clientes, pedidos_cliente, _items, _adj) + 8 RPCs (cliente_obtener/registrar/listar, pedido recibir/confirmar/estado, inbox_polling, reporte_obtener) + 2 Edge (recibir-pedido con IA/Vision, analizar-imagen) + **migración de datos desde el Sheet de clientes vivo** (necesita export del Sheet). `wh.crear_lista_sombra` ya existe (reusar en confirmar). reporte.html es read-only sobre wh.guias/preingreso (migrable sin datos nuevos). |

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
