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

## 🔑 HALLAZGO DEFINITIVO (2026-06-13): límite natural de las RPCs de escritura directa
Al analizar `agregar_detalle_guia` se confirmó: **casi todas las operaciones WH restantes son orquestadores que
dependen del CATÁLOGO** (PRODUCTOS_MASTER/EQUIVALENCIAS para validar/resolver base) **+ lógica condicional**
(AUTO-SUMA, sync de lote, ajuste de stock si la guía está cerrada, "guía del día"). Ejemplos: `agregar_detalle_guia`
(valida catálogo + auto-suma + lote + stock condicional), `registrar_envasado`, `aprobar_producto_nuevo`.

**Conclusión de ingeniería:** las 7 RPCs atómicas hechas son el conjunto SENSATO de escritura directa en SQL
(ajustes, mermas, preingresos, crear/cerrar/reabrir guía — incluido el stock con FIFO). Replicar los orquestadores
como RPCs SQL monolíticas sería frágil y de bajo valor (operaciones poco frecuentes, dependientes del catálogo que
vive en mos.* y se sincroniza por trigger). **Decisión recomendada:**
- Los orquestadores **se quedan en GAS** (orquestando) con su **dual-write ya existente** (PASO 2) manteniendo la
  sombra fresca. NO se convierten a RPC.
- El **PASO 5 (retirar GAS por completo)** NO es alcanzable sin un REDISEÑO mayor (mover catálogo + orquestación al
  frontend/Edge con múltiples RPCs). Eso es un proyecto aparte, no una continuación lineal de este PASO 4.

## ✅ VEREDICTO PASO 4: COMPLETO en su alcance sensato
7 RPCs atómicas (incl. la crítica cerrar/reabrir con FIFO) escritas, aplicadas (inertes), validadas (72 casos, 0 fallos).
Próximo razonable: **fase de ACTIVACIÓN** de estas 7 (wiring GAS anti-doble-escritura + flip de flags uno a uno con
validación de operación real + tu OK), que YA da valor (escritura directa de las operaciones core). El resto (orquestadores
+ retiro total de GAS) requiere decisión de rediseño, no más RPCs.

## ⚠️ PRE-REQUISITO DE ACTIVACIÓN (auditoría 40x): integridad de wh.stock
Antes de prender cualquier flag de escritura de stock:
1. **Consolidar duplicado**: wh.stock tiene 1 producto con 2 filas (7750243071406). Las RPCs ya lo manejan
   (UPDATE de la 1ra fila por id_stock, como GAS), pero lo correcto es consolidar (sumar en 1, borrar la otra)
   en la HOJA STOCK (fuente) y en la sombra.
2. **Índice único** wh.stock(cod_producto) + INSERT-else con `on conflict (cod_producto) do update` → cierra el
   residual B-2 (producto nuevo en 2 guías concurrentes → 2 filas). Requiere DDL + limpieza en prod (usuario con `!`).

## Estado (2026-06-13): 10 RPCs LISTAS (inertes, validadas) · DOS auditorías 40x · integridad de stock blindada
**7 atómicas** (crear_ajuste, registrar_merma, crear_preingreso, actualizar_preingreso, crear_guia, cerrar_guia, reabrir_guia)
**+ 3 chicas** (marcar_preingreso_procesado, crear_auditoria, get_o_crear_guia_dia) — 90 casos de validación, 0 fallos.

### Lo que FALTA para cerrar el PASO 4 100%
- **`agregar_detalle_guia`** 🔴🔴 BLOQUEADA POR SCHEMA: `wh.guia_detalle` solo tiene (id_guia, linea, cod_producto,
  cant_esperada, cant_recibida, precio_unitario, id_lote, observacion, id_producto_nuevo) — **FALTAN `id_detalle` y
  `fecha_vencimiento`**, que la lógica usa (el frontend referencia líneas por idDetalle; los lotes dependen de la fecha).
  PRE-REQUISITO antes de escribir la RPC: **decisión de schema** → `alter table wh.guia_detalle add column id_detalle text,
  add column fecha_vencimiento date` + ajustar `_WH_SPECS.guia_detalle` + re-backfill + verificar que el batch las suba.
  Recién ahí la RPC (catálogo + AUTO-SUMA + INSERT linea=max+1 + sync lote + ajuste stock condicional) es viable.
  La validación de catálogo (mos.productos/equivalencias) la puede hacer el cliente (tiene el catálogo en cache).
- **`aprobar_producto_nuevo`** 🔴: crea producto en `mos.productos` (catálogo) + ajusta stock + lote. Cross-schema.
- **Se COMPONEN en el cliente (NO necesitan RPC monolítica)** de las RPCs ya hechas:
  - `aprobar_preingreso` = `crear_guia` + `marcar_preingreso_procesado` ✅ (piezas listas)
  - `auditar_producto` = `crear_auditoria` + `crear_ajuste` (si difiere) ✅ (piezas listas)
  - `registrar_envasado` = `get_o_crear_guia_dia` ×2 + `agregar_detalle_guia` ×2 + `crear_ajuste` ×2 (falta agregar_detalle_guia)
- **Auth B1 (PASO 5)** ya hecho: `mintSupabaseTokenWH` validado → el frontend podrá llamar estas RPCs directo.
