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
### PASO 1 ✅ HECHO — Gate de paridad (read-only)
`verificarParidadWH(dias, tabla)` (GAS, GET `?action=verificarParidadWH&dias=7&tabla=guias|stock`).
Corrida inicial: **GUIAS 0 huecos** (sombra completa); STOCK inconcluso por truncamiento PostgREST
(arreglar el verificador con paginación cuando se aborde stock).

### PASO 2 — Dual-write en tiempo real (la base) — EN PROGRESO
Helpers: `_dualWriteWH(tabla,o)` (upsert best-effort, reusa `_WH_SPECS`+`_whRowMap`) y
`_dualWritePatchWH(tabla,pkFilters,patch)` (PATCH puntual). Ambos NUNCA lanzan; el sync batch (15min) +
reconciliación quedan de red.
- ✅ **STOCK COMPLETO** (GAS @421-425): `_actualizarStock` → upsert `wh.stock` (captura idStock real) +
  `_logStockMovimiento` → upsert `wh.stock_movimientos`. Como `_actualizarStock` es la mutación central,
  cubre stock fresco desde TODOS los caminos (cierres, envasados, ajustes). Validado end-to-end.
- 🟡 **GUÍAS PARCIAL** (GAS @426-430): `cerrarGuia` (PATCH estado+monto) y `reabrirGuia` (PATCH estado).
  ⚠️ **Gap conocido:** el PATCH es no-op si la guía aún NO está en la sombra (creada después del último
  batch). **Falta dual-write en la CREACIÓN de guía** (`crearGuia` / aprobar preingreso) para cobertura
  total → próximo incremento.
- ⏳ **PENDIENTE:** dual-write de `guia_detalle` (ítems), `preingresos`, creación de guía. Luego
  reconciliación periódica Supabase←Sheets (red de seguridad, como `reconciliarDirectasSheets` de ME).

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
