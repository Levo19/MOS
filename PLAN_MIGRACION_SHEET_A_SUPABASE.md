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

### Etapa 2 — money-crítico
- Confirmar que el cierre corre 100% directo (ya verificado: PK-VENTAS) → el fallback GAS que lee la Hoja
  se puede retirar tras P4/P5. `estadoCajas`, `ReporteCierre`, `AlertaEfectivo`, MOS `getCierresCaja/Finanzas`
  → migrar a RPCs Supabase (`me.estado_cajas`, `mos.cierres_caja`, etc. — varias ya existen).

### Etapa 3 — cross-app / analítica (MOS)
Conexiones/Almacen/Evaluaciones/Proveedores → leer `me.ventas` sombra (o RPCs) en vez de la Hoja ME.

### Etapa 4 — fiscal / correlativo / reportes (ME)
Correlativo ya está migrado a `me.correlativos`/`fac.series`. Migrar reportes IGV/CPE + reconciliar +
Creditos + EditarVenta a Supabase. (Se cruza con el go-live CPE.)

### Etapa 5 — apagar la Hoja
Cuando 0 lectores dependan de la Hoja: apagar el sync Hoja↔Supabase para `ventas`, dejar de escribir la Hoja,
Hoja = archivo histórico. ME/MOS 100% Supabase para ventas.

## Estado
- Etapa 1: EN CURSO. Resto: pendiente, en orden.
- Verificación de escritura (Etapa 0): el heal insert-missing ya cubre (no revierte ediciones).
