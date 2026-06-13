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

### PASO 3 — Lectura directa · EN CURSO (2026-06-13)
**Infra genérica** (`MigracionWH.gs`): `_sbValToSheet`/`_sbRowsToObjsWH`/`_leerTablaWH` invierten
`_sheetToObjects` desde `wh.*` reusando `_WH_SPECS` (un helper para todas las tablas). Punto único
`_filasLecturaWH(tabla,hoja)` con **fallback a Sheets** reemplaza la lectura cruda en las funciones de API.
Gate genérico `compararLecturaWH(tabla)` (router) valida paridad EXACTA por id, tolerante a JSON
(`_jsonEqLoose`, pg jsonb reordena claves) y a número (`_numEqLoose`). Flip por tabla: key `lectura_<tabla>`.

**FLIPEADAS (paridad exacta, LIVE)**: stock, rotación, mermas, auditorias, ajustes, envasados,
producto_nuevo, preingresos, lotes_vencimiento, **stock_movimientos** (flip server-side por código). (GAS @456, 5 IDs.)

**PENDIENTES del PASO 3 (con hallazgos — son las "dudas" a resolver):**
- `getGuias`/`getGuia`: sombra `wh.guias` diverge en campos OCR — `OCR_Fecha_Comprobante` quedó con
  `Date.toString()` feo (bug del dual-write: `_whText` sobre una celda Date) y `OCR_Fecha_Proceso`
  normalizada. Fix: tipar esos OCR como `date` en `_WH_SPECS` (o normalizar en dual-write) + **re-backfill
  guias**, luego flipear. `getGuia` además trae detalle de PK compuesta sin `idDetalle` → diseño aparte.
- `alertas_stock`: ⚠️ **sombra 3989 filas vs 421 en hoja** — HUÉRFANOS: la hoja se purga pero el batch
  hace upsert sin DELETE → la sombra acumula borrados. Flipear mostraría alertas fantasma. + campo
  `revisado` mal tipado (`bool` vs texto "SI/NO"). Fix: purgar sombra (DELETE de lo que no está en hoja)
  + corregir spec, o no flipear. **Riesgo general del modelo de sombra para tablas purgables.**
- `stock_movimientos`: paridad exacta pero **~5s** (6197 filas, creciente) — flipear con `_filasLecturaWH`
  carga todo. Optimizar con filtro server-side (`_sbSelect` por `cod_producto` + limit) antes de flipear.
- `cargadores`/`historial`: agregaciones (no lectura de tabla directa) → fuera del patrón genérico.

### PASO 3 (notas originales) — Lectura directa (con gate + paginación)
Tras validar paridad fresca (paso 1 re-corrido con dual-write activo), flipear lecturas de WH a RPCs
Supabase: stock (PAGINADO), guías del día, preingresos, alertas. Flag `WH_LECTURA_DIRECTA` en `mos.config`
(o `wh.config`) + fallback a GAS. Mismo patrón `serverFlag || localStorage` que ME.

### PASO 4 — Escritura directa · PLAN (2026-06-13) — RPCs a escribir, aplicar a DB requiere OK del usuario
**Patrón por sesión** (igual que ME): cada RPC `wh.*` nace INERTE detrás de un flag en `mos.config`
(`WH_<OP>_DIRECTO='0'`), con kill-switch server-side dentro de la RPC; se valida contra GAS (simulación
tx-rollback + comparación) ANTES de prender; el GAS sigue como orquestador y cae a Sheets si la RPC falla.
**⚠️ El dual-write actual YA escribe a Supabase best-effort**; el PASO 4 invierte a Supabase PRIMARIO →
solo tiene sentido pleno junto al PASO 5. Las RPCs SQL se ESCRIBEN en `ProyectoMOS/supabase/30+_wh_*.sql`
pero **aplicarlas a la DB de producción lo bloquea el classifier → lo autoriza/corre el usuario**.

**Sesiones ordenadas por riesgo (menor→mayor):**
1. `wh.crear_ajuste` — INC/DEC stock + fila AJUSTES. Aislada, sin FIFO. (la más simple)
2. `wh.registrar_merma` / `wh.solucionar_merma` — fila MERMAS + estado.
3. `wh.crear_preingreso` / `wh.actualizar_preingreso` / `wh.aprobar_preingreso`.
4. `wh.crear_guia` / `wh.cerrar_guia` / `wh.reabrir_guia` — cabecera + detalle + monto.
5. `wh.registrar_envasado` — transforma stock (base→derivado), 2 guías + etiquetas.
6. 🔴 `wh.actualizar_stock` con **FIFO/lotes** — el núcleo, lo más delicado (= cierre de caja de ME). Sesión propia.
7. `wh.auditar_producto` / `wh.aprobar_producto_nuevo` — tocan stock + catálogo.

### PASO 4 (notas) — Escritura directa, pieza por pieza
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
