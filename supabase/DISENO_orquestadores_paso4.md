# PASO 4 — RPCs atómicas vs orquestadores (decisión de diseño, 2026-06-13)

## ✅ RPCs ATÓMICAS de datos — HECHAS (7, todas inertes + validadas)
Operaciones que escriben 1-3 tablas de forma directa. Ideales como RPC. Validadas tx-rollback:
1. `wh.crear_ajuste` 12/12 · 2. `wh.registrar_merma` 8/8 · 3. `wh.crear_preingreso` 7/7 ·
4. `wh.actualizar_preingreso` 8/8 · 5. `wh.crear_guia` 8/8 · 6. **`wh.cerrar_guia` 18/18 (stock+FIFO+lotes)** ·
7. `wh.reabrir_guia` 11/11.

## ⏳ ORQUESTADORES — requieren diseño de descomposición (NO RPC monolítica)
Estas funciones GAS componen varias operaciones. Replicarlas como una RPC gigante es frágil. El camino correcto
es descomponerlas en RPCs atómicas componibles que el frontend/GAS orqueste, O dejarlas en GAS con dual-write
de sus efectos (que YA existe del PASO 2) hasta el PASO 5.

- **`registrar_envasado`** (Envasados.gs): resuelve catálogo (base/derivado/`factorConversionBase`) → crea/reusa
  guía SALIDA_ENVASADO del día + detalle + `_actualizarStock(base, -cantBase)` → crea/reusa guía INGRESO_ENVASADO
  + detalle + `_actualizarStock(derivado, +unidades)` → fila ENVASADOS → etiquetas PrintNode. Idempotente por cache key.
  **Pieza faltante para componerlo:** `wh.agregar_detalle_guia` (INSERT línea en guia_detalle con `linea = max+1`)
  y `wh.get_o_crear_guia_dia(tipo,usuario)`. Con esas + crear_ajuste/cerrar, envasado se compone. Etiquetas quedan en GAS.
- **`aprobar_preingreso`**: crea guía (reusa crear_guia) + marca preingreso PROCESADO. Componible: `crear_guia` +
  un `wh.marcar_preingreso_procesado(id, id_guia)` chico.
- **`auditar_producto`**: registra auditoría + (si difiere) crea ajuste + actualiza stock. Componible:
  `wh.crear_auditoria` + `crear_ajuste` (ya existe).
- **`aprobar_producto_nuevo`**: catálogo (crea producto en MOS) + ajusta stock + lote. Toca mos.productos (catálogo)
  → más delicado, cruza esquemas. Diseño aparte.

## Próximo (fase de orquestación, contexto fresco)
1. RPCs atómicas faltantes chicas: `agregar_detalle_guia`, `get_o_crear_guia_dia`, `marcar_preingreso_procesado`,
   `crear_auditoria`. Cada una con su 40x.
2. Componer los orquestadores (envasado, aprobar_preingreso, auditar) desde esas + las 7 ya hechas.
3. `aprobar_producto_nuevo` (cruza a mos.productos) — su propia sesión.
4. **Fase de ACTIVACIÓN coordinada**: wiring GAS (llamar RPC como primario, NO duplicar escritura local+dual-write)
   + flip de flags uno a uno con validación de cierre real. Recién ahí el PASO 5 (retirar GAS) es posible.

## Estado: 7 RPCs atómicas core LISTAS (inertes). La escritura de stock crítica (cerrar/reabrir guía con FIFO) está cubierta.
