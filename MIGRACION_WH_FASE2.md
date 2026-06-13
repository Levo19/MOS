# 🏭 Migración warehouseMos (WH) a Supabase — Plan Fase 2

> WH va MUY por detrás de ME. Este doc traza el camino. Estado: **arrancando Fase 2** (2026-06-12).
> Repo WH: `C:\Users\ISO\warehouseMos`. Misma DB Supabase (`rzbzdeipbtqkzjqdchqk`, esquema `wh.*`).

## Dónde está WH hoy (Fase 1)
- ✅ **Schema completo en Supabase**: 24 tablas `wh.*` (guias, guia_detalle, stock, stock_movimientos,
  lotes_vencimiento, mermas, auditorias, ajustes, envasados, preingresos, producto_nuevo, sesiones,
  desempeno, pickups, ops_log, cargadores_log, listas_sombra, lotes_adhesivo, alertas_stock, config,
  clientes, pedidos_cliente*...).
- ✅ **Sombra por sync BATCH** (`MigracionWH.gs` `_WH_SPECS` + `syncWHReciente` cada 15min,
  `syncWHCompleto` diario 3:30am). Upsert por PK de cada tabla.
- ✅ **2 RPCs de lectura**: `wh.stock_enriquecido`, `wh.rotacion_semanal` (el panel MOS las usa).
- ❌ **El frontend WH NO toca Supabase** — escribe y lee 100% vía GAS/Sheets.
- ⚠️ La sombra es **batch (hasta 15min de atraso)** — NO sirve para lectura directa operativa tal cual.

## Diferencias clave vs ME (por qué WH es más difícil)
- **Stock con FIFO** agrupado por canónico, **lotes/vencimientos**, **envasados** (transforman stock),
  **preingresos** con merge de campos in-flight → la lógica de escritura es bastante más compleja que una venta NV.
- **Volumen**: `wh.stock` tiene ~1348 productos → **supera el `db-max-rows=1000` de PostgREST**. Toda
  lectura directa de stock DEBE paginar (range headers) o se trunca silenciosamente.
- Escrituras críticas bajo `_conLock` (lock global reentrante) — el equivalente al LockService de ME.

## Plan Fase 2 (orden por riesgo, más seguro primero)
### PASO 1 ✅ HECHO — Gate de paridad (read-only) · RE-CORRIDO R5
`verificarParidadWH(dias, tabla)` (GAS, GET `?action=verificarParidadWH&tabla=<t>&dias=7`).
**R5 (GAS @443):** verificador UNIVERSAL por presencia de PK (cubre toda tabla de `_WH_SPECS` con PK de
1 col = col0 de la hoja) + **stock paginado** (`_sbSelectAll`, evita el cap `db-max-rows=1000`) +
heurística de columna-fecha (prioriza creación/registro, nunca vencimiento/aprobación).
**Re-corrida 2026-06-12 — GATE VERDE TOTAL** (`solo_en_sheets_count:0` en todas):
`stock` 1349=1349 (0 diffs de cantidad) · `guias` 0 huecos · `auditorias` (fechaAsignacion) ·
`producto_nuevo` (fechaRegistro) · `mermas` (fechaIngreso) · `lotes_vencimiento` · `envasados` ·
`ajustes` · `preingresos`. Nota: PK compuesta (guia_detalle, pedidos_cliente_*) NO soportada por el
verificador universal (se valida al cerrar la guía vía `_dualWriteDetallesGuiaWH`).

### PASO 2 — Dual-write en tiempo real (la base) — EN PROGRESO
Helpers: `_dualWriteWH(tabla,o)` (upsert best-effort, reusa `_WH_SPECS`+`_whRowMap`) y
`_dualWritePatchWH(tabla,pkFilters,patch)` (PATCH puntual). Ambos NUNCA lanzan; el sync batch (15min) +
reconciliación quedan de red.
- ✅ **STOCK COMPLETO** (GAS @421-425): `_actualizarStock` → upsert `wh.stock` (captura idStock real) +
  `_logStockMovimiento` → upsert `wh.stock_movimientos`. Como `_actualizarStock` es la mutación central,
  cubre stock fresco desde TODOS los caminos (cierres, envasados, ajustes). Validado end-to-end.
- ✅ **GUÍAS — estado + creación** (GAS @436, 5 IDs): `_crearGuiaImpl` upsertea la guía nueva a `wh.guias`
  al crearse (gap cerrado: guía post-batch ya está en la sombra); `cerrarGuia` PATCH estado+monto;
  `reabrirGuia` PATCH estado. `aprobarPreingreso` reusa `crearGuia` → cubierto. 20x: sin bugs.
- ✅ **PREINGRESOS** (GAS @437, 5 IDs): `_dualWritePreingresoWH(id)` (re-lee fila + upsert) en
  crearPreingreso / actualizarPreingreso / aprobarPreingreso. 20x: sin bugs.
- ✅ **GUIA_DETALLE** (GAS @438): `_dualWriteDetallesGuiaWH(idGuia)` re-sincroniza TODAS las líneas al
  CERRAR la guía (reproduce la numeración del batch). Con esto **una guía cerrada queda 100% legible desde
  Supabase (cabecera + ítems)**. 20x: sin bugs (orphan-de-borrado-físico = misma limitación que el batch).
- ✅ **SECUNDARIAS COMPLETAS** (GAS @438→@443, Rondas 1-4): dual-write en tiempo real de
  `lotes_vencimiento` (R1), `envasados` (R2), `mermas` + `ajustes` (R3), `auditorias` + `producto_nuevo` (R4).
  Helpers re-lee-fila `_dualWriteLoteWH`/`_dualWriteMermaWH`/`_dualWriteAuditoriaWH`/`_dualWriteProductoNuevoWH`
  + dual-write inline en `crearAjuste`/`_writeAjuste`/`auditarProducto` (cubre el stock-create directo que NO
  pasa por `_actualizarStock`). `aprobarProductoNuevo` re-sincroniza `guia_detalle`. Todo best-effort. 20x c/u.
- 🛡️ **RED DE SEGURIDAD YA EXISTE:** el sync batch `syncWHReciente` (cada 15min) ES la reconciliación
  Sheets→Supabase — si un dual-write se pierde, se cura en ≤15min. El dual-write solo lo hace MÁS fresco
  (tiempo real vs 15min). Por eso NO urge una reconciliación extra como en ME.

### ✅ Estado tras esta sesión: las tablas OPERATIVAS CORE de WH dual-writean en tiempo real
stock + movimientos + guías(cabecera+ítems) + preingresos → frescos al instante. El resto (lotes/envasados/
mermas) lo cubre el batch a 15min. **Próximo (con datos reales de mañana):** re-correr el gate de paridad
para medir la mejora de frescura, y recién ahí habilitar **lectura directa de WH** (con paginación para stock).

### 🚀 Patrón de deploy eficiente (para no re-topar las 200 versiones)
`clasp push` → `clasp deploy -i <id1> -d "..."` (crea 1 versión N) → los otros 4 con `clasp deploy -i <idN> -V N`
(apuntan a la MISMA versión, NO crean nuevas). 1 versión por cambio en vez de 5.

### 🔒 20x review (2026-06-12): hallazgo crítico corregido
`_sbOnce_` (WH **y** ME) bloqueaba DELETE sin filtros pero **NO PATCH** → un PATCH sin filtros haría
UPDATE de TODA la tabla. Agregado el guard a PATCH en ambos + `_dualWritePatchWH` valida valores de filtro.

### ⚠️ NOTA OPS — WH GAS al tope de 200 versiones
`clasp deploy -i <id>` crea una versión nueva cada vez; WH llegó a 200. Workaround usado: deployar a una
versión EXISTENTE con `clasp deploy -i <id> -V <N>` (no crea versión). **Pendiente:** purgar versiones
viejas del project history de WH (Apps Script → project history) para liberar espacio.

### PASO 3 — Lectura directa (con gate + paginación)
Tras validar paridad fresca (paso 1 re-corrido con dual-write activo), flipear lecturas de WH a RPCs
Supabase: stock (PAGINADO), guías del día, preingresos, alertas. Flag `WH_LECTURA_DIRECTA` en `mos.config`
(o `wh.config`) + fallback a GAS. Mismo patrón `serverFlag || localStorage` que ME.

### PASO 4 — Escritura directa, pieza por pieza
RPCs `wh.cerrar_guia`, `wh.ajustar_stock` (con FIFO/lotes), `wh.aprobar_preingreso`, etc. — cada una
con su validación + flag + reconciliación, como las de ME. La del **stock con FIFO/lotes es la más
delicada** (el equivalente al cierre de caja de ME) → su propia sesión + validación.

### PASO 5 — Retirar GAS de WH.

## Gotchas a recordar (de la revisión del sistema)
- Toda escritura a hojas críticas va bajo `_conLock` (reentrante). Cualquier RPC directa debe preservar
  la atomicidad equivalente (lock de fila / constraint).
- codigoBarra siempre como texto; guías registran codigoBarra real, nunca skuBase.
- Día/agrupación en TZ Perú (`_diaPeru`/`_hoyPeru`).
- WH tiene **5 deployment IDs versionados** — al agregar un case que el frontend consuma, redeployar TODOS.
  (El gate `verificarParidadWH` es diagnóstico que llamo yo → está solo en 1 deployment, suficiente.)
