# PLAN ORDENADO — Corte total de GAS (auditoría 500x · 2026-07-04)

## ▶ AVANCE DE EJECUCIÓN (2026-07-04) — N0–N3 ✅ · N2 ✅ · N4 parcial
- **NIVEL 0 ✅** cola offline directa.
- **NIVEL 1 ✅ COMPLETO** (desbloqueo, retoma, auditoría, 9 admin MOS, login-WH, getOperacionDetalle, promociones, lanzarProductoNuevo). 100x + fixes 367/371.
- **NIVEL 2 ✅** BAJA_CPE (Edge emitir-cpe op=baja) + EDITAR_CLIENTE (me.editar_cliente). ME 2.8.159.
- **NIVEL 3 ✅** getOperacionesConDetalle, getClaveAdminGlobal (372), resolverHorarioPersonal (330), setHorarioApp (82). MOS 2.43.450.
- **NIVEL 4 parcial** (ME 2.8.160): ✅ etiquetas marcar (373), CONFIG_MOS (config_me 374), devolución→WH (crear_devolucion_zona 374). ⏳ pendiente: reimprimirEtiqueta (print Edge), CAMBIO_IMPRESORA_CAJA (config estación), MOS backfillLiquidacionesDia/importarJornadasDesdeCajas (recompute admin), espía chunks (Storage), promos-al-POS (catalogo_pos_rls serve), verificarHorario WH (→ resolver_horario_personal). **Lecturas WH pasivas (getWelcomeData/getDesempenoDia/getResumenPersonal/getRolUsuario/getProducto/getResultadosDiagnostico/listarOpsPendientes) se auto-neutralizan vía `call()` (caché/error) → NO bloquean el corte.**
- **NIVEL 5 ⛔ BLOQUEADO por dependencia externa:** portales cliente WH necesitan migrar los datos del **Sheet de clientes vivo** (no accesible desde aquí). Backend (4 tablas+8 RPCs+2 Edge IA) construible; la migración de datos requiere el export del Sheet.
- **NIVEL 6** limpieza inerte (if(false), dead-code) — opcional, bajo valor, se deja.

## (histórico previo) AVANCE DE EJECUCIÓN
- **NIVEL 0 ✅ HECHO+desplegado** (ME 2.8.158): cola offline drena directo (CPE/NV, sin GAS) + guard CPE-off + panel fantasmas. Revisión 100x aplicada (fixes #A/#B).
- **NIVEL 1 · parcial (desplegado):**
  - ✅ Desbloqueo temporal usuario (WH+ME) — RPC `mos.desbloquear_usuario_temporal` (SQL 363). WH 2.13.400+, ME 2.8.158.
  - ✅ Retoma caja con PIN (ME) — `me.confirmar_retoma_caja` (364). ME 2.8.158.
  - ✅ Auditoría stock (ME) — `me.registrar_auditoria` (365, elevación claim). ME 2.8.158.
  - ✅ MOS admin (9 RPCs, SQL 366+367): setConfig, actualizarCostoPorSku, actualizarProductoMaster, crear/actualizarPersonalMaster, crear/actualizarZona, crearCategoria, rotarClaveAdminGlobal. Intercept `_MOS_ADMIN_RPC` en api.js. MOS 2.43.448. **Revisión 100x → fixes críticos aplicados (367):** rotar exige pinAdmin real, set_config bloquea claves del PIN global, personal setea pin_hash bcrypt, costo error si ambiguo, categoría no pisa.
  - ⏳ PENDIENTE NIVEL 1: WH login-confirmación background · getOperacionDetalle (read) · crear/actualizarPromocion (falta tabla mos.promociones) · lanzarProductoNuevo/crearPNManual (cross-app WH).
- **NIVEL 2–6: pendientes.**
- Fix de producción intercalado: adhesivos envasado no imprimían (sub_job_size=500 → cap 50 + Edge reembolsa en excepción). Resuelto.

---


> Fuente: auditoría 500x de las 3 apps (MOS/ME/WH) + revisión 500x de lo implementado hoy.
> Regla confirmada: los **fallbacks pasivos** (dispatchers, `_conFallbackMOS`, Cat.1 con flag ON) y **mirrors
> fire-and-forget** se auto-neutralizan al borrar GAS (fetch falla → caché/error). NO bloquean el corte.
> Lo que bloquea = GAS **ACTIVO sin ruta directa**. Los flags server directos DEBEN quedar en '1'.

## ✅ Revisión de lo implementado hoy (11am→): SÓLIDO
- RPC 359 verificar_pin / 360 anular_venta_directo / 361 registrar_guia_directo = **SEGURAS** (sin agujeros de
  dinero nuevos; elevación de claim revierte en commit y rollback, sin fuga bajo pooling; sin doble-conteo).
- Cableado frontend (ME _postMutacionDinero/_postGuiaBackground/in-situ, MOS intercept, device-auth) = **LIMPIO**
  (cero pantallas blancas, cero refs huérfanas, cero fugas GAS en write-paths de dinero/stock/auth).
- Batch limpieza (push tokens 3 apps, WH mint muerto, MOS wizard-permisos) = **LIMPIO**.
- Menores (no bloquean): 359 enumeración/timing + PIN plano (heredado del GAS); device-auth `_devAuthDirecto`
  dead; WH `_pushInitWH` guard `if(!mosUrl)return` (inofensivo hoy, atado a migración del espía).

---

## 🚨 NIVEL 0 — TRAMPA (verificar ANTES de cualquier corte, no es código)
- **ME cola offline** (`sincronizarDatos` ~10130): ítems CPE/legacy SIN sello `direct` se drenan a GAS; con GAS
  borrado el `fetch` lanza → NUNCA salen de `pendingSales` → reintento eterno + ticket posiblemente ya cobrado.
  **Acción: garantizar que TODA op encolada lleve sello `direct`/`_viaDirecta` + verificar `pendingSales` sin
  ítems no-direct antes de cortar.**

## 🔴 NIVEL 1 — BLOQUEADORES DUROS (rompe-operación, ACTIVO, sin RPC)
| App | Ítem | Acción |
|-----|------|--------|
| WH+ME | **desbloqueo temporal de usuario** (WH app.js:3682, ME index:13903) | 1 RPC `mos.desbloquear_usuario_temporal` sirve a ambos + wire |
| ME | **CONFIRMAR_RETOMA_CAJA** (13072, retomar caja con PIN) | RPC `me.retomar_caja_directo` + wire |
| ME | **REGISTRAR_AUDITORIA** (20720, guardar conteo auditoría stock) | RPC `me.registrar_auditoria_directo` + wire |
| MOS | **setConfig** (escribe flags/config; ~6 call-sites) | RPC `mos.set_config` + intercept |
| MOS | **rotarClaveAdminGlobal** (seguridad admin) | RPC + intercept |
| MOS | **getOperacionDetalle** (drill-down voucher del poller) | RPC + intercept |
| MOS | **actualizarCostoPorSku** (costo maestro/margen) | RPC + intercept |
| MOS | **crear/actualizarPersonalMaster** | RPC + intercept |
| MOS | **crear/actualizarZona, crearCategoria, crear/actualizarPromocion** | RPCs + intercept |
| MOS | **lanzarProductoNuevo / crearPNManual** (PN cross-app) | RPC + Edge/bridge WH |
| WH | **confirmación de login en background** (app.js:1403, `loginPersonal` GAS) | rutear a `loginPersonalSB` |

## 🟠 NIVEL 2 — FISCAL (dinero/SUNAT, sin RPC)
- ME **BAJA_CPE** (15819, baja SUNAT de comprobante). RPC vía capa `fac`.
- ME **EDITAR_CLIENTE_VENTA** (15880). RPC.
- (MOS/ME **NV→CPE**: hoy cae a GAS porque `fac` está inerte → parte del CPE go-live, doc aparte.)

## 🟢 NIVEL 3 — QUICK WINS (RPC YA EXISTE, solo cablear en api.js)
- MOS **resolverHorarioPersonal** → `mos.resolver_horario_personal` (SQL 330) — solo intercept.
- MOS **actualizarProductoMaster** (min/max) → reusar `mos.actualizar_producto` (SQL 78).
- MOS **getClaveAdminGlobal** → apoyar en `mos.admin_pins_cache` (SQL 280).
- MOS **getOperacionesConDetalle** → wire directo (hoy degrada silenciosa a `operaciones_unificadas`).
- MOS **setHorarioApp** → quitar el mirror GAS, dejar directo.

## 🟡 NIVEL 4 — DEGRADA-FEATURE (sin RPC, no rompe operación core)
- ME **etiquetas** escrituras: marcarPegada (7726), marcarPegadasBatch (7745), reimprimir (7766),
  CAMBIO_IMPRESORA_CAJA (7511) → RPCs `me.etiqueta_*`.
- ME **wh_crearDevolucionZona** (20059, notif cross-app a WH DEVOLUCIONES_ZONA) → RPC `wh.*`.
- ME **getConfig** refresh (9635) → RPC lectura config.
- WH **lecturas secundarias sin RPC** (ACTIVAS→GAS hoy): getWelcomeData, verificarHorario, getDesempenoDia,
  getResumenPersonal, listarCargadoresMaster, getRolUsuario, getProducto(single), getResultadosDiagnostico → RPCs.
- MOS **backfillLiquidacionesDia, importarJornadasDesdeCajas** (recompute jornales, admin puntual) → RPCs.
- WH+ME **espía audio/video chunks** (a Drive por GAS) → Edge + Storage. (degrada vigilancia, no operación.)

## 🔵 NIVEL 5 — B6 PORTALES CLIENTE (bloque grande, frente aparte)
- WH **pedido.html / clientes.html / reporte.html** = 100% GAS. Necesita 4 tablas mos + 8 RPCs + 2 Edge (IA/Vision)
  + **migración de datos del Sheet de clientes** (dependencia externa: export del Sheet).
- WH **clienteInbox.js** ya está DEAD (lee `window.cfg.gasUrl` inexistente) → no genera tráfico GAS; la feature
  "alerta de pedido cliente" está muerta (bug latente a corregir con el portal).

## ⚪ NIVEL 6 — LIMPIEZA (cosmético, no rompe)
- MOS: borrar bloque `if(false)` (index:18908) + fetch muerto Editor Adhesivos (19595).
- device-auth: borrar `_devAuthDirecto` (dead).
- WH: `_pushInitWH` guard `if(!mosUrl)return` (quitar junto con la migración del espía).
- ME: `_syncImpresorasFromProyectoMOS` (9684) y `etiqAutoPrintAlAperturaCaja` (7789) ya son dead (`return` arriba).

---

## Orden de trabajo sugerido
1. **NIVEL 0** (garantizar sello direct en cola offline) — es la trampa de dinero.
2. **NIVEL 1** (bloqueadores duros) — sin esto no se puede borrar GAS. Empezar por el RPC compartido de desbloqueo
   y los 2 bloqueadores ME (retoma caja, auditoría), luego el paquete MOS admin (setConfig primero).
3. **NIVEL 3** (quick wins — RPC ya existe) — barato, cierra huecos MOS rápido.
4. **NIVEL 2** (fiscal) — junto al CPE go-live.
5. **NIVEL 4** (degrada) — barrido de RPCs faltantes.
6. **NIVEL 5** (portales) — proyecto aparte, necesita export del Sheet.
7. **NIVEL 6** (limpieza) — al final.
