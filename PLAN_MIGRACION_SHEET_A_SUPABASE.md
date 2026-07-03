# 🗺️ Plan — Eliminar la Hoja de Google (VENTAS_CABECERA) → ME/MOS 100% Supabase

> Meta: que `me.ventas` (Supabase) sea la ÚNICA fuente de verdad de ventas. Hoy la Hoja es el "master"
> y Supabase la sombra; hay ~40 lecturas de la Hoja (incl. el cierre de caja) que deben migrarse ANTES
> de apagar la Hoja. Programa por ETAPAS, cada una probada (paridad Supabase↔Hoja) antes de avanzar.
> Origen: investigación 2026-07-02 (feasibility turno.html→Supabase).

## Principio de seguridad (money-safe)
- **Nunca** apagar una escritura/sync a la Hoja hasta que TODAS sus lecturas estén en Supabase.
- Cada etapa: (1) verificar que el dato existe en Supabase con paridad; (2) migrar el lector; (3)
  validar en vivo; (4) recién entonces avanzar. La Hoja queda como respaldo inerte hasta la última etapa.
- Orden: primero lo que ya está listo + duele (turno), luego lo money-crítico, luego el resto.

## Precondición — Etapa 0: durabilidad de la escritura a Supabase
Hoy cada venta/cobro/cierre hace `_dualWriteVentaME` (best-effort, maxRetry:1, error tragado, fuera de la
tx de la Hoja). Si Supabase está degradado en ese instante, la venta queda solo en la Hoja hasta el heal
de 15min. **Antes de que algún lector dependa 100% de Supabase:**
- [ ] Endurecer el dual-write (retry con backoff, o cola persistente) O confiar en el heal insert-missing
      (MigracionME `activarMEVentasDirecto` ya hace ON CONFLICT DO NOTHING cada 15min sin revertir ediciones).
- [ ] Verificar diario: `count(me.ventas del día) == count(Hoja del día)` (script de paridad).

## Inventario de lectores de la Hoja VENTAS_CABECERA (~40) — a migrar
**Money-crítico (primero):**
- ME `Caja.gs:_cerrarCajaAtomicoCore` (cuadre de efectivo lee FormaPago de la Hoja). ⚠️ **Mitigado en parte:**
  el cierre YA corre por `me.cerrar_caja` directo (lee Supabase); solo el FALLBACK GAS lee la Hoja.
- MOS `Cajas.gs:datosTurno` (turno.html) · `getCierresCaja` · `anularTicketME` · `cambiarMetodoME` · `imprimirTicketZCierre`
- MOS `Finanzas.gs:472,1286` (ingresos del día) · ME `ReporteCierre.gs`, `AlertaEfectivo.gs`, `Code.gs:estadoCajas`
**Cross-app / analítica:**
- MOS `Conexiones.gs`, `Almacen.gs` (velocidad/ranking stock), `Evaluaciones.gs` (KPIs vendedor), `Proveedores.gs`
- ME `Radio.gs:topProductosHoy`
**Fiscal / correlativo / reportes:**
- ME `NubeFact.gs:reconciliarCPEsPendientes` · `Ventas.gs` (correlativo + reportes IGV/CPE mensuales) · `Guias.gs`
- ME `Creditos.gs` (6 funciones leen FormaPago) · `EditarVenta.gs` (5, read-then-write)
**Bridge/infra (se retiran al final):** `Fase2Auth.gs`, `MigracionME.gs`, el sync mismo.

## Etapas
### ✅ Etapa 1 — turno.html / datosTurno → `me.datos_turno` (HECHO + LIVE 2026-07-02)
DESPLEGADO (clasp deploy @437) + VERIFICADO: el endpoint GAS `datosTurno` devuelve `me.datos_turno`
(Supabase EN VIVO). La Hoja ELIMINADA del camino del turno. GAS queda solo como proxy autenticado
(service_role). **Para cero-GAS TOTAL** (turno.html directo a Supabase sin GAS) falta darle auth segura a
turno.html — el atajo anon fue (bien) bloqueado por seguridad (expondría datos del turno al público).
⚠️ **Pendiente para que las ediciones no se reviertan:** correr `activarMEVentasDirecto()` en el editor
de Apps Script de ME (mete `ventas` a ME_SYNC_OFF_TABLAS) — si no, el sync Hoja→Supabase revierte la
edición directa de forma de pago en ≤15min.

### ✅ Etapa 1b — turno.html DIRECTO a Supabase (CERO-GAS TOTAL — HECHO 2026-07-02, MOS 2.43.426 / turno v1.3.56)
**turno.html ya no tiene NI RASTRO de GAS** (ni datos ni impresión):
- **Datos:** `loadData()` llama SOLO a `_cargarDirectoSupabase()` (mint-mos device-gated → `me.datos_turno` directo). Sin proxy GAS, sin 302, sin cold-start.
- **Impresión Z (última traza GAS, eliminada):** `doPrint()` ya no salta a `imprimirTicketZCierre` (GAS). Ahora envuelve el texto YA renderizado por `buildPrintTicket` (`pre#pkt-pre` = lo mismo que ve el dueño en pantalla → **papel==pantalla**, sin re-derivar totales = cero riesgo de mismatch) en ESC/POS y lo manda a la Edge `imprimir` con un token app=MOS minteado. Preámbulo/feed/corte = espejo de `ticket-comprobante` (misma flota PrintNode): init `1b40` · texto crudo `charCodeAt&0xff` (mismo encoding que el ticket de venta) · feed `1b4a96` · corte `1d5600`. **Verificado byte-a-byte** (round-trip base64, acentos é=0xe9/Ñ=0xd1 OK).
- **Seguridad:** el GAS `imprimirTicketZCierre` era **print-only (cero writes)** → quitarlo no dropea ningún efecto. Los efectos del cierre (stock/pickup) ya viven server-side en `me.cerrar_caja`. Cambio solo-impresión = **cero riesgo dinero/stock**.
- `_mintMOS()` extraído como helper (lo comparten datos + impresión); guard `!API_URL` y la constante `API_URL` eliminados.
- **Verificación de campo pendiente (dueño):** hacer 1 impresión Z real desde turno.html → debe salir el ticket idéntico al de pantalla y cortar. Si falla, revisar que la Edge `imprimir` esté desplegada + `PRINTNODE_API_KEY` seteado (es Edge ya usada por el reimprimir de MOS).

#### (histórico) Etapa 1b — diseño original
Con la Etapa 1 el dato ya es Supabase, pero el PROXY GAS sigue: `exec?action=datosTurno` hace un **302 +
~1.88s** (cold-start GAS + salto a googleusercontent). Para que cargue en ~200ms Y sea cero-GAS, turno.html
debe llamar a `me.datos_turno` DIRECTO (sin GAS). BLOCKER = auth segura (el anon fue bloqueado — expondría
datos del turno al público). Opciones a decidir:
  (a) el opener (MOS/ME, autenticado) mintéa un token corto y lo pasa en la URL a turno.html; en expiración
      (turno abierto horas) cae al proxy GAS o re-abre;
  (b) turno.html mintéa vía mint-me con un contexto de device/claim (agregarle setup);
  (c) RPC con token firmado por caja (HMAC) — más trabajo.
Recomendado: (a) con fallback GAS al expirar. Diseñar + implementar como etapa propia (frontend, deployable
por mí; sin exponer anon). Contemplado a pedido del dueño (trace 1.88s, 2026-07-02).

### (histórico) Etapa 1 — descripción original
`me.datos_turno(p_id_caja)` ya existe y devuelve la MISMA forma que consume turno.html, leyendo `me.ventas`
en vivo → refleja ediciones al instante + rápido. Migrar el lector (datosTurno) a la RPC, con fallback Hoja
detrás de un flag. turno.html no cambia (o pasa a directo si se le da token). **Arregla el desync + la lentitud.**

### 🔎 Hallazgo (2026-07-02): la migración es MUCHO más chica de lo estimado
El FRONTEND ya lee Supabase en la mayoría de los casos money/display:
- `getCierresCaja`→`mos.cierres_caja` ✅ · `estadoCajas`→`me.estado_cajas` ✅ · `getFinanzasRango`→`mos.finanzas_rango` ✅
Los cuerpos GAS aún leen la Hoja, pero solo importa cuando se llama a GAS (no el navegador). **No queda un
batch "read-only + RPC lista + aún en Hoja" para flipear** — los que tienen RPC ya están cableados. Lo que
resta: (a) displays de BAJO valor sin RPC (`getCierreHtml`, `topProductosHoy` Radio) → necesitan RPC nueva;
(b) funciones que ESCRIBEN (alertas efectivo, `getFinanzasDia`→liquidaciones/jornadas, impresión Z) → NO
apurar, tienen side-effects; (c) el cierre de caja money-crítico → **ya corre directo** (el GAS es fallback).
**Recomendación:** el pain (turno/desync) YA está resuelto (Etapa 1 + sync-off). El resto es bajo valor /
requiere RPCs nuevas o migrar money-writes con cuidado — hacerlo deliberado, no de golpe. Priorizar Tema 1
(modal convertir) y el go-live CPE por encima de migrar displays de bajo valor.

### ✅ Etapa 2/3 (displays) — lectores de VENTAS Hoja sin RPC (HECHO 2026-07-02)
Los dos displays que el hallazgo marcó "necesitan RPC nueva":
- **`topProductosHoy` (Radio TV) — MIGRADO + LIVE.** Era el ÚNICO lector VIVO de VENTAS_CABECERA/DETALLE en el camino del radio. Nueva RPC `me.radio_ventas()` (SQL 325) replica la lógica sobre la sombra (me.ventas + me.ventas_detalle): top 20 del día/7d + skus_de_la_tienda 30d/alguna_vez, TZ Lima, excluye ANULADO/HUERFANA_LIMPIADA. GAS `topProductosHoy` reescrito para leerla vía `_sbRpc`, **sin fallback a la Hoja** (cero-GAS). Verificado LIVE: `top_productos_hoy` y `radio_productos` devuelven data de Supabase (paridad exacta: AJO 5.945 = test directo RPC). Radio.gs ya solo toca la hoja `RadioConfig` (config, no ventas). Deploy ME @237 (deployment AKfycbzG84…, el que usa radio.html).
- **`getCierreHtml` (`ver_cierre`) — CÓDIGO MUERTO.** El botón "🖨 Reporte" que lo abría se **eliminó en v2.43.7**; `grep` confirma 0 consumidores del campo `urlReporte`/`ver_cierre` en todo el frontend. NO es un lector vivo → no bloquea. No se toca `mos.cierres_caja` (RPC grande de dinero) por un campo cosmético muerto; se borra en Etapa 5 junto con la Hoja. (Si algún día vuelve un consumidor, apuntarlo a `turno.html?idCaja=…`, que ya renderiza el cierre cero-GAS.)

### Etapa 2 — money-crítico
- Confirmar que el cierre corre 100% directo (ya verificado: PK-VENTAS) → el fallback GAS que lee la Hoja
  se puede retirar tras P4/P5. `estadoCajas`, `ReporteCierre`, `AlertaEfectivo`, MOS `getCierresCaja/Finanzas`
  → migrar a RPCs Supabase (`me.estado_cajas`, `mos.cierres_caja`, etc. — varias ya existen).

### Etapa 3 — cross-app / analítica (MOS)
Conexiones/Almacen/Evaluaciones/Proveedores → leer `me.ventas` sombra (o RPCs) en vez de la Hoja ME.

### ✅ Etapa 3 (analítica MOS) — HECHO 2026-07-02 (mapeo 3 agentes + fix)
Hallazgo: **~90% ya construido.** 10/12 lectores vivos (ranking_zonas, insights_stock, eco_status,
analitica_producto, productos_sin_venta, catalogo_stock_resumen, productos_proveedor_stock,
resumen_todos_dia, rotacion, catalogo) YA tienen RPC `mos.*` y están cableados Supabase-first en api.js.
- **FIX aplicado (2.43.427):** el dashboard llamaba `getRotacion` pero api.js solo interceptaba
  `getRotacionProductos` → caía a GAS. Alias agregado (verificado: `mos.rotacion_productos` 1397 items, `_fresh`).
- **Único hueco read-write (DEFERIDO):** `recalcularStockMinMaxAuto` (lee me.ventas_detalle, ESCRIBE
  mos.productos.stock_min/max). No hay RPC; la escritura a `mos.productos` tiene caveats de sync
  ([[architecture_mos_cutover_escritura_requiere_apagar_sync]]). Background 12h, no user-facing → deferido.
- **Fallbacks:** NO se quitan aún — leen la Hoja de ME, mueren atómicamente con la Hoja en Etapa 5.

### 🔧 Etapa 4 (fiscal/reportes ME) — CONSTRUIDO, activación money/SUNAT gateada
Mapeo: la mayoría YA existe (inerte tras flags o ya activo):
- **Reconciliador CPE cero-GAS VIVO** (verificado): crons `cpe-reconciliar`(:23)/`fac-reconciliar`(:07)/
  `fac-huerfanos`(diario) `active:true` + `me.cpe_reconciliar_cron`/`fac.reconciliar`. → el reconciliador
  GAS de la Hoja (NubeFact.gs) es REDUNDANTE → retirar en el corte de E5.
- **Ya cubiertos por flag `FUENTE_DATOS`** (inertes, listos para flip): ventas_hoy_zona, creditos_pendientes,
  estado_cajas, detalle_venta. **Ediciones money** (cobrar_credito, editar_forma_pago/cliente, convert, asignar,
  expiry) YA construidas cero-GAS (SQL 260/264/268/308-321), algunas activas. Correlativo ya en me.correlativos/fac.series.
- **✅ 3 RPCs read-only HECHAS (SQL 326, ME @238):** `me.alerta_calcular_efectivo`, `me.tributario_ventas_mes`,
  `me.tributario_cpe_mes` — GAS reescrito para leerlas vía `_sbRpc` SIN fallback a la Hoja. Verificado live
  (ventas_mes 28k, cpe_mes 59, fecha ISO exacta, alerta S/). `getCierreHtml`=muerto (no migrar).
  ⚠️ **EXACTITUD FISCAL gateada en paridad:** el total de junio fluctuó 28004.8↔28174.7 en minutos (heal 15min +
  ediciones/anulaciones vivas) → los reportes reflejan la sombra AL INSTANTE; son fiables para SUNAT solo cuando
  la sombra del mes está estable/convergida. Mismo gate que E5.
- **Read-write CPE a wire:** `tributarioReintentarCPE`→single-row de reconciliar; `bajaCPEVenta`→`fac.anular`.
- **Gate:** flip de flags + wire CPE = cutover money/SUNAT → acoplado a la verificación de paridad de E5.

### ⛔ Etapa 5 (apagar la Hoja) — IRREVERSIBLE, gateada en paridad multi-día
Descubrimiento: la durabilidad ya está resuelta por el modo `CORRELATIVO_SOURCE=supabase` +
`me.crear_venta_directa` (RPC atómica, correlativo por UPDATE..RETURNING con lock, idempotente por localId,
sin fallback silencioso). NO hay que inventar cola nueva; hay que hacer cutover a ese modo. Orden money-safe:
1. `activarCorrelativoSupabase()` (valida `me.correlativos ≥ target` por serie; aborta si atrás → evita
   duplicado SUNAT). Aditivo/reversible.
2. `instalarTriggerReconciliacionDirectas()` (espejo Supabase→Hoja, backstop 10min). Aditivo.
3. **PARIDAD (reloj físico):** `verificarParidadLectura(3)` = 0 sostenido varios días + `reconciliarME()` sin
   drift en ventas/ventas_detalle. Se ejercita solo con operación real (cierres/cobros/CPE). **NO acortable por código.**
4. `activarMEVentasDirecto()` → sync-off `ventas` (+detalle/cajas/movimientos_extra). El heal insert-missing cubre faltantes.
5. Migrar los últimos lectores de la Hoja a `me.*` (quitar fallbacks) = "sin fallback" real.
6. Dejar de escribir la Hoja (gate/eliminar appendRow/setValues; `mirrorVentaASheets` último espejo).
Precondición innegociable: paso 3 en verde. Falla → venta perdida o boleta SUNAT duplicada (legal).

## ⭐ CORTE EJECUTADO — 2026-07-03 (write-path Supabase-primario, PROBADO)
En ventana de mantenimiento (nadie usando), con gates verificados:
- **Gate paridad:** `verificarParidadLectura(3)` = `solo_en_sheets_count:0` ✅ (ninguna venta solo-en-Hoja).
- **reconciliarME:** destapó ventas cabecera drift (Supabase 2643 vs Hoja 2447) → INVESTIGADO: la Hoja fue **recortada** (207 detalle sin cabecera) + **196 colisiones históricas de correlativo NV** (Mar–May, ventas reales distintas, NO fantasma; series SUNAT limpias). Sombra = registro MÁS completo → cortar es data-safe (Supabase ⊇ Hoja).
- **Activaciones (corridas por el dueño en editor, wrappers cut5a/b/c):** `activarCorrelativoSupabase` (✅ 6 series sembradas+validadas, CORRELATIVO_SOURCE=supabase) + `instalarTriggerReconciliacionDirectas` (backstop 10min) + `activarMEVentasDirecto` (sync-off ventas).
- **Venta de prueba REAL:** NV01-001625, id directo `V-...-uuid`, `me.correlativos` NV01 avanzó atómicamente 1625→1626, detalle OK → **write-path 100% Supabase, cero-GAS, idempotente, PROBADO.**
- **Write ya cero-GAS de antes:** frontend llama `crear_venta_directa` directo; impresión=PrintNode directo; CPE=Edges. Sin retención local (sync-primero, borra tras confirmar, 4 flusheadores).
- **300x post-corte:** 6 series sin riesgo colisión, venta prueba única (no dup), ventas directas entrando. ✅

### Falta para cero-GAS/cero-fallback TOTAL (desmonte del GAS de respaldo — DELIBERADO, no blind-strip)
El GAS restante es RED DE RESPALDO (no causa errores en operación normal): espejo a la Hoja (`mirrorVentaASheets`)+backstop, fallbacks de lectura (~65 en api.js + 4 Flips ME), y el cierre GAS-fallback que lee la Hoja. Orden money-safe (con checkpoints):
1. Cierre → Supabase-only (quitar brazo GAS/Hoja del arqueo; primary ya es me.cerrar_caja). REQUISITO para matar el espejo.
2. Retirar espejo+backstop (correr `desinstalar...` en editor). Cero-GAS write total.
3. Fallbacks de lectura: convertir `null→GAS` en vacío/error (evitar pantalla blanca) — uno por uno, no en bloque.
4. Heartbeat de sesión (registrarSesionDispositivo) → migrar a RPC (alimenta personal-del-día; no borrar sin migrar).
⚠️ Blind-strip rompe arqueo + white-screen (auditado). Requiere: 2-3 GAS-runs del dueño + 1 venta/cierre de prueba.

## Estado (2026-07-02)
- **Etapa 1/1b: HECHO+LIVE** (turno.html cero-GAS total, incl. Z-print).
- **Etapa 2/3 displays: HECHO+LIVE** (radio `me.radio_ventas`; getCierreHtml muerto).
- **Etapa 3 analítica: HECHO** (fix getRotacion 2.43.427; resto ya cableado; recalcular_min_max deferido).
- **Etapa 4: construido; activación money/SUNAT gateada** (reconciliador cero-GAS ya vivo; faltan 3 RPCs read-only + wire CPE + flips).
- **Etapa 5: infraestructura lista; corte gateado en paridad multi-día** (pasos 1-2 aditivos ejecutables cuando el dueño diga; 3 = reloj de días).
- Escritura directa durable = modo `CORRELATIVO_SOURCE=supabase` (existe). El dual-write best-effort actual NO basta para apagar la Hoja.
