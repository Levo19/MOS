# Diseño `wh.cerrar_guia` — la RPC más crítica del PASO 4 (estándar 40x)

> Lógica extraída de `_cerrarGuiaImpl` + `_sincronizarLoteDesdeDetalle` + `_consumirLotesFIFO` + `_actualizarLote`
> (Guias.gs). Esta RPC aplica STOCK + LOTES + FIFO al cerrar una guía. Un error = descuadre de inventario real.

## ⚠️ DECISIÓN DE DISEÑO CLAVE (define el contrato)
La sombra `wh.guia_detalle` **NO tiene `fecha_vencimiento` ni `id_detalle`** (spec: id_guia, cod_producto,
cant_esperada, cant_recibida, precio_unitario, id_lote, observacion, id_producto_nuevo). Pero el cierre los
necesita para los lotes. → **La RPC recibe los detalles COMO PARÁMETRO** (no los lee de la sombra). GAS, que ya
tiene los detalles en memoria desde Sheets, los pasa. Patrón correcto del PASO 4: GAS orquesta, RPC ejecuta atómico.

**Contrato `p`:** `{ id_guia, usuario, tipo (opcional, si no lo lee de wh.guias),
  detalles: [{ codigo_producto, cantidad_recibida, precio_unitario, id_lote, fecha_vencimiento,
               id_detalle, id_mov, id_lote_nuevo }] }`
Los `id_mov` (movimiento de stock por línea) e `id_lote_nuevo` (por si crea lote) los GENERA GAS y los pasa →
idempotencia y mismos ids que Sheets.

## Lógica a replicar (plpgsql, 1 transacción, corre bajo lock en GAS — acá atómica por la tx)
1. **Idempotencia:** leer estado de wh.guias. Si `CERRADA`/`AUTOCERRADA` → return `{ok,yaCerrada:true,montoTotal}` SIN tocar stock.
2. **montoTotal** = Σ(cantidad_recibida × precio_unitario) de los detalles del parámetro.
3. **esIngreso** = tipo empieza con 'INGRESO'. **esEnvasado** = tipo IN (INGRESO_ENVASADO, SALIDA_ENVASADO).
4. **Si NO esEnvasado**, por cada detalle con cantidad_recibida ≠ 0:
   a. **stock**: delta = esIngreso ? +cant : −cant. UPDATE wh.stock (cod_producto) += delta (o INSERT si no existe);
      INSERT wh.stock_movimientos (id_mov, delta, stock_antes, stock_despues, tipo='CIERRE_GUIA', origen=id_guia).
   b. **INGRESO + fecha_vencimiento** → sincronizar lote (ver casos abajo).
   c. **INGRESO sin fecha + id_lote** → legacy: UPDATE wh.lotes_vencimiento (cant_inicial=cant_actual=cant, fecha) o INSERT.
   d. **SALIDA** → consumir FIFO (ver abajo).
5. **UPDATE wh.guias** set estado='CERRADA', monto_total=montoTotal where id_guia.
6. (efectos secundarios GAS: cerrar mermas si SALIDA_MERMA, sync MOS proveedor — NO van en la RPC, los hace GAS.)

### Sincronizar lote desde detalle (INGRESO + fecha) — 6 casos
- C) id_lote_actual ∃ + fecha ∅ → UPDATE estado='ANULADO'.
- B) id_lote ∅ + fecha ∅ → NOOP.
- D) id_lote ∃ + misma fecha + misma cant + ACTIVO → NOOP.
- E) id_lote ∃ + (fecha≠ o cant≠) → UPDATE cant_inicial=cant_actual=cant, fecha, estado='ACTIVO'.
- A1) id_lote ∅ + fecha ∃ + existe lote (cod,id_guia,fecha) → REUSE: UPDATE ese (estado ACTIVO, cant).
- A2) id_lote ∅ + fecha ∃ + no existe → INSERT nuevo (id_lote_nuevo, cod, fecha, cant, cant, id_guia, 'ACTIVO', now).
  Clave de reuso: (cod_producto, id_guia, fecha_vencimiento yyyy-MM-dd).

### Consumir FIFO (SALIDA)
- Candidatos: wh.lotes_vencimiento where cod_producto=X and estado='ACTIVO' and cantidad_actual>0.
- Orden: fecha_vencimiento ASC (null/sin-fecha al final). Consumir secuencial: consumir=min(disp, restante);
  UPDATE cantidad_actual -= consumir; si llega a 0 → estado='AGOTADO'. restante puede quedar huérfano (solo log, no rompe).
- NOTA: FIFO NO toca stock (el stock ya bajó en 4a con el delta negativo). Solo baja cantidad_actual de lotes.

## Validación 40x (tx-rollback, casos a cubrir)
- INGRESO suma stock por línea; monto = Σ(cant×precio). · SALIDA resta stock.
- Idempotencia: cerrar 2 veces → 2da yaCerrada, stock NO cambia.
- INGRESO con fecha nueva → INSERT lote; con fecha existente (cod,guia,fecha) → REUSE; sin fecha → no lote.
- SALIDA FIFO: consume lote que vence primero; agota y pasa al siguiente; marca AGOTADO; huérfano si insuficiente.
- esEnvasado → NO toca stock ni lotes.
- cantidad 0 en una línea → se salta.
- guía inexistente → error.
- movimiento: stock_antes/despues correctos acumulando entre líneas del mismo producto.

## Estado: PENDIENTE de escribir (próxima sesión, contexto fresco). Toda la lógica está acá — listo para traducir a plpgsql.
