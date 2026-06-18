# DISEÑO — KARDEX CENTRALIZADO de stock (plantilla única ZONA + ALMACÉN)

> Estado: **FUNDACIÓN**. Lo de **ZONA** (esquema `me` + RPCs + wrapper `mos`) se crea/aplica **INERTE**
> (nadie lo llama todavía salvo la lectura de historial, que es de solo-lectura y reconstruye).
> Lo de **ALMACÉN** (`wh`) es **SOLO PROPUESTA** — no se toca producción de WH en esta entrega.
>
> Autor: fundación kardex · Revisión 40x senior · Apps de DINERO en prod.

---

## 0. Por qué un kardex centralizado

Hoy conviven **dos formatos distintos** de "log de movimiento de stock":

| | Almacén (WH) | Zona (ME) |
|---|---|---|
| Tabla | `wh.stock_movimientos` (6777 filas, ACTIVA) | `me.stock_movimientos` (0 filas, **nunca activada**) |
| Columnas | `id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario` | `id, cod_barras, zona_id, tipo, delta, referencia, usuario, ts` |
| Ajustes | `wh.ajustes` (496) | (no existe tabla de ajustes de zona) |
| Conteo físico | `wh.auditorias` (set absoluto) | `me.auditorias` (1216, solo ZONA-02, set absoluto) |
| Saldo | **dato** (`stock_antes`/`stock_despues` por fila) | n/a (tabla vacía) |
| Lectura UI | `getHistorialStock` (Productos.gs:1038) | n/a |

Problemas de no centralizar:
1. **Dos shapes** → dos lecturas, dos clasificadores, dos fuentes de bug.
2. `me.stock_movimientos` no tiene `stock_antes/stock_despues` → el saldo habría que **recalcular** hacia atrás (el mismo "saldo fantasma" que el cutover de WH ya sufrió y arregló — ver el comentario BUG 2 en `getHistorialStock`).
3. Sin `zona_id` no se puede distinguir el mismo `cod_barra` en distintas zonas. WH lo ignora porque solo tiene un "almacén"; ZONA lo necesita.
4. Sin **idempotencia** (`local_id` / clave de referencia) → reabrir/recerrar una guía re-aplica el delta y **duplica stock** (bug raíz confirmado por el dueño).

La solución: **un único esquema de movimiento (la "plantilla")** que sirva igual a ZONA y a ALMACÉN, con `ambito` como discriminante y `zona_id` nullable.

---

## 1. La PLANTILLA — esquema único del movimiento

Campo lógico → cómo se materializa en cada ámbito:

| Campo plantilla | Tipo | ZONA (`me.stock_movimientos`) | ALMACÉN (`wh.stock_movimientos`, PROPUESTA) | Notas |
|---|---|---|---|---|
| `id` | bigserial / text | `id bigserial` | `id_mov text` (ya existe) | clave técnica, no de negocio |
| `ambito` | text `ZONA`/`ALMACEN` | constante `'ZONA'` | constante `'ALMACEN'` | discriminante |
| `zona_id` | text (null si almacén) | `zona_id` (NOT NULL en zona) | `null` (col nueva propuesta, siempre null) | dimensión de zona |
| `cod_barra` | text | `cod_barras` | `cod_producto` | **alias**: misma semántica, distinto nombre histórico |
| `id_lote` | text? | `id_lote` (nuevo, nullable) | (deriva de `LOTES_HISTORIAL`) | trazabilidad FIFO |
| `tipo` | text (catálogo) | `tipo` | `tipo_operacion` | catálogo unificado abajo |
| `delta` | numeric(20,3) | `delta` (con signo) | `delta` | + entra, − sale |
| `saldo_antes` | numeric(20,3) | `saldo_antes` (nuevo) | `stock_antes` | saldo **dato**, no recálculo |
| `saldo_despues` | numeric(20,3) | `saldo_despues` (nuevo) | `stock_despues` | saldo **dato** |
| `ref_tipo` | text | `ref_tipo` (nuevo) | (derivable de `tipo_operacion`/`origen`) | GUIA / VENTA / AJUSTE / AUDITORIA / ENVASADO / TRASLADO |
| `ref_id` | text | `ref_id` (nuevo) | `origen` | clave de negocio del evento (ver idempotencia) |
| `usuario` | text | `usuario` | `usuario` | quién lo causó |
| `fecha` | timestamptz | `fecha` (renombrar `ts`→`fecha` o mantener ambos) | `fecha` | fecha de **negocio** |
| `origen` | text | `origen` (app/dispositivo) | (n/a hoy) | 'ME-PWA' / 'GAS' / 'WH' |
| `local_id` | text | `local_id` (nuevo) | (propuesto) | idempotencia de reintentos offline |

### 1.1 Catálogo único de `tipo`

| `tipo` | Signo `delta` típico | ZONA | ALMACÉN | Equivalente WH actual (`tipo_operacion`) |
|---|---|---|---|---|
| `INGRESO_GUIA` | + | sí (entrada por guía/traslado) | sí (ingreso de guía proveedor) | `INGRESO`, `APROBACION_PN` |
| `SALIDA_VENTA` | − | sí (venta en zona) | (raro) | `SALIDA` |
| `SALIDA_JEFA` | − | sí (retiro de la jefa) | n/a | `SALIDA` |
| `TRASLADO_IN` | + | sí (llega de otra zona/almacén) | sí (devolución) | `INGRESO` |
| `TRASLADO_OUT` | − | sí (sale a otra zona/almacén) | sí (despacho) | `SALIDA` |
| `AJUSTE` | ± | sí | sí | `AJUSTE_MANUAL`, `AJUSTE` |
| `AUDITORIA` | ± | sí (conteo físico) | sí | `AUDITORIA` |
| `ENVASADO` | ± | (futuro) | sí | `ENVASADO` |
| `INICIAL` | + | sí (saldo de arranque) | sí | `INICIAL`, `INI` |

El **clasificador de UI** (qué label/ícono pinta el front) se deriva de `tipo` + signo de `delta`, exactamente como `_clasificar()` en `getHistorialStock`. La plantilla guarda `tipo` canónico; la UI mapea label legible. La RPC de historial de zona devuelve **el mismo shape de campos** que WH (ver §5) para que el card sea idéntico.

---

## 2. Regla de DELTA por cierre de guía (anti-duplicado) — ⭐ núcleo

### 2.1 El bug raíz
Modelo "aplicar al cerrar": al **cerrar** una guía se aplica el delta de cada línea al stock. Si la guía se **reabre y se vuelve a cerrar**, el código ingenuo re-aplica el delta completo → **duplica** (o, peor, si la cantidad cambió, descuadra).

### 2.2 La solución (confirmada con el dueño)
Cada **línea de guía** guarda cuánto stock ya **aplicó** al kardex: columna `cantidad_aplicada` (default 0).

Al cerrar (o recerrar) la guía, por cada línea:
```
delta_a_aplicar = cantidad_nueva − cantidad_aplicada
```
- Primer cierre: `cantidad_aplicada = 0` → `delta = cantidad_nueva` (aplica todo). Luego se setea `cantidad_aplicada = cantidad_nueva`.
- Recerrar **sin cambios**: `delta = cantidad_nueva − cantidad_nueva = 0` → **no mueve stock** (no duplica).
- Recerrar **con cambio** (p.ej. 18 → 20): `delta = 20 − 18 = 2` → solo aplica el incremental. Se actualiza `cantidad_aplicada = 20`.
- Anular/reabrir y dejar en 0: `delta = 0 − 18 = −18` → revierte. `cantidad_aplicada = 0`.

El signo final lo da el `tipo` de la guía (entrada → `+`, salida → `−`); el `cantidad_aplicada` razona siempre en **magnitud**, y el delta del kardex se firma según ámbito/tipo.

### 2.3 Idempotencia — clave única
Dos defensas, ambas en la tabla del kardex:

1. **Por evento de negocio**: `ref_id` codifica `GUIA:<id_guia>:<linea>:v<version>`. El `version` se incrementa en cada cierre. Así, recerrar genera un `ref_id` nuevo (un movimiento delta nuevo, con su saldo) pero **nunca pisa** el del cierre anterior; y un reintento del **mismo** cierre (mismo version) choca con el unique y se ignora (dedup).
   - Para ventas: `ref_id = VENTA:<id_venta>:<linea>`.
   - Para ajuste: `ref_id = AJUSTE:<id_ajuste>`.
   - Para auditoría: `ref_id = AUDITORIA:<id_auditoria>:<cod_barra>`.

2. **Por reintento offline**: `local_id` (uuid que genera el cliente). Un doble-tap / replay de cola offline manda el **mismo** `local_id` → choca con el unique → se devuelve el movimiento ya existente (no se duplica).

**Índice único:** `unique (ambito, zona_id, ref_id)` **+** `unique (local_id) where local_id is not null`.
La RPC de registro hace `insert ... on conflict do nothing` y, si no insertó, devuelve `{ok:true, dedup:true, ...}` con la fila existente (patrón idempotente del proyecto, igual que el muelle / `crear_venta_directa`).

> El cableo de `cantidad_aplicada` al flujo de cierre de guía de ZONA (y la propuesta para WH) es **fase posterior**. Esta fundación solo crea la columna + la RPC de registro INERTE.

---

## 3. AJUSTE y AUDITORÍA (set absoluto) → movimiento delta

Ambos llegan como **valor absoluto** ("el stock real es N"), pero el kardex es un **log de deltas**. La traducción:

```
delta = nuevo_absoluto − saldo_actual_kardex
```
- `saldo_actual_kardex` = `saldo_despues` del último movimiento de ese `(ambito, zona_id, cod_barra)` (o 0 si no hay).
- `saldo_despues = nuevo_absoluto` (por construcción el saldo queda clavado al conteo).
- `tipo = AUDITORIA` (conteo físico) o `AJUSTE` (corrección manual). El signo del delta sale solo.

Ejemplo real (ZONA-02, cod `7755019000123`, auditoría 2026-04-04): kardex traía 0, conteo real 19 → `delta = +19`, `saldo_despues = 19`, `tipo = AUDITORIA`. Coincide con `me.auditorias.diferencia = 19`.

La auditoría set-absoluto **es la fuente de verdad del saldo**: clava el kardex al físico y arrastra cualquier descuadre previo a un único movimiento auditable.

---

## 4. Derivación del stock (saldo corrido) + reconciliación nocturna

### 4.1 Saldo corrido
El stock de un `(ambito, zona_id, cod_barra)` es `saldo_despues` del **último** movimiento (orden `fecha`, desempate `id`). Como cada fila trae su saldo (dato, no recálculo), no hay recálculo hacia atrás (evita el "saldo fantasma" del cutover WH).

`Σ delta` (suma de todos los deltas) **debe** ser igual al `saldo_despues` del último. Es el invariante de consistencia.

### 4.2 Reconciliación nocturna (propuesta de cron, no se aplica aún)
Un job nocturno (estilo `97_mos_cron_nocturno.sql` / `72_wh_cron_nocturno.sql`) compara, por `(ambito, zona_id, cod_barra)`:
```
stock_real     = me.stock_zonas.cantidad   (zona)  |  wh.stock.cantidad (almacén)
stock_kardex   = saldo_despues del último mov  =  Σ delta
descuadre      = stock_real − stock_kardex
```
- `descuadre = 0` → OK.
- `descuadre ≠ 0` → alerta + (opcional) auto-genera un movimiento `AUDITORIA` que cuadra el kardex al `stock_real` (set absoluto, §3), dejando rastro. Esto reusa exactamente la lógica de §3.

Esto es **lo mismo** que `wh.auditar_cuadre_stock` / `73_wh_cuadre_corte_delta.sql` ya hacen para almacén; el diseño centralizado lo extiende a zona con la misma plantilla.

---

## 5. Lectura de historial — shape paritario con WH

`getHistorialStock` (WH) devuelve por movimiento (campos que el front consume):
```
{ idGuia, fecha, tipo, tipoOperacion, esIngreso, cantidad, saldo, stockAntes,
  usuario, origen, estado, fuente('guia'|'ajuste'), aplicado, lote/lotesConsumidos... }
```
La RPC de zona (`me.zona_kardex_historial`) devuelve **el mismo shape** (mismos nombres de campo) para que el card del módulo zona sea idéntico al de WH:
```
{ ok, data: { zona, codBarra, skuBase, movimientos: [ {idGuia, fecha, tipo, tipoOperacion,
   esIngreso, cantidad, saldo, stockAntes, usuario, origen, estado, fuente, aplicado, idLote} ] },
   _fresh... }
```
Orden `fecha desc` (más reciente primero), igual que WH.

### 5.1 Reconstrucción cuando el kardex arranca vacío ⭐
`me.stock_movimientos` arranca en 0 filas. Para que el dueño **ya vea historial** desde el día 1, la RPC de historial:
1. Si **hay** movimientos materializados para ese `(zona, cod_barra)` → los lee directo (saldo = dato).
2. Si **no hay** → **reconstruye** el historial leyendo las fuentes crudas de zona por `cod_barra + zona`, en orden `fecha`:
   - `me.auditorias` → eventos `AUDITORIA` (set absoluto; clava saldo = `cant_real`).
   - `me.guias_detalle ⋈ me.guias_cabecera` → eventos de guía (signo por `tipo`: `SALIDA_*` = `−`, entradas = `+`).
   - `me.ventas_detalle ⋈ me.ventas` → eventos `SALIDA_VENTA` (`−`), **solo** ventas no anuladas.
   - Calcula el **saldo corrido** sobre la marcha (no es dato porque no hay material), ancla en la auditoría set-absoluto más reciente cuando existe.

> ⚠️ **Doble-conteo guía-vs-venta**: en ZONA-02 hoy conviven, para el mismo código, filas en `guias_detalle` (tipo `SALIDA_VENTAS`) **y** en `ventas_detalle`. Frecuentemente documentan **el mismo** flujo físico (la guía de salida de ventas es el respaldo de las ventas del día). En la **reconstrucción** esto se maneja con una regla de **una sola fuente de salida por defecto** para no descuadrar el saldo corrido:
> - **Default (aplicado en la RPC):** usar `me.ventas_detalle` como fuente de SALIDA_VENTA y las `guias_detalle` de tipo `SALIDA_VENTAS` se muestran como **informativas** (no suman al saldo corrido) — `aplicado:false`, `fuente:'guia'`. Las guías de otro tipo (`SALIDA_JEFA`, traslados, entradas) **sí** suman.
> - Esto es **conservador y reversible**: cuando se cablee el kardex materializado real (fase posterior), el flujo de cierre escribirá el movimiento canónico una sola vez y la reconstrucción deja de usarse para ese código.
> - La RPC expone un parámetro `incluirGuiasVenta` (default false) por si el dueño quiere ver ambas fuentes para auditar.

La reconstrucción es **solo de lectura** — no escribe en `me.stock_movimientos`. Es un "as-of view". El día que se cablee el registro real, los movimientos materializados toman precedencia (rama 1).

---

## 6. PROPUESTA de alineamiento de WH (NO aplicada — para revisión del dueño)

> ⚠️ Nada de esto se ejecuta en esta entrega. `wh.stock_movimientos` y su flujo vivo quedan intactos.

Para que WH use la **misma plantilla** sin romper su flujo (6777 movs en prod, `getHistorialStock` activo), propongo un **ALTER aditivo** + una **vista compat**, en una sesión que el dueño apruebe:

**Paso A — columnas aditivas (nullable, default seguro):**
```sql
alter table wh.stock_movimientos
  add column if not exists ambito   text default 'ALMACEN',
  add column if not exists zona_id  text,          -- siempre null en almacén
  add column if not exists ref_tipo text,           -- backfill desde tipo_operacion
  add column if not exists ref_id   text,           -- backfill desde origen
  add column if not exists local_id text;
```
Nada se rompe: el dual-write de GAS y `getHistorialStock` siguen leyendo `cod_producto/stock_antes/stock_despues`.

**Paso B — vista canónica común (la "plantilla" lógica):**
```sql
create or replace view public.kardex_unificado as
  select id_mov as id, coalesce(ambito,'ALMACEN') ambito, zona_id,
         cod_producto as cod_barra, null::text id_lote, tipo_operacion as tipo,
         delta, stock_antes as saldo_antes, stock_despues as saldo_despues,
         ref_tipo, ref_id, usuario, fecha, origen, local_id
    from wh.stock_movimientos
  union all
  select id::text, ambito, zona_id, cod_barras, id_lote, tipo,
         delta, saldo_antes, saldo_despues, ref_tipo, ref_id, usuario, fecha, origen, local_id
    from me.stock_movimientos;
```
Una sola vista para reportes/reconciliación cross-app.

**Paso C — adoptar `cantidad_aplicada` + idempotencia en `cerrar_guia` de WH:**
WH ya tiene el riesgo de re-aplicar al reabrir/recerrar (`35_wh_cerrar_guia.sql` / `36_wh_reabrir_guia.sql`). La propuesta es migrar su `wh.guia_detalle` a guardar `cantidad_aplicada` y aplicar `delta = nueva − aplicada` (§2), más el unique `(ambito, ref_id)`. **Requiere revisión cuidadosa del FIFO de lotes de WH** (cada cierre consume lotes; el incremental debe consumir/devolver solo el delta de lotes, no recomputar todo). Por eso queda **fuera** de esta fundación: es un cambio al flujo vivo de dinero/inventario de WH que el dueño debe revisar línea a línea.

**Paso D — unificar el clasificador de UI:** mover `_clasificar()` de `getHistorialStock` a una función SQL `kardex_label(tipo, delta)` reusada por ambos historiales. Aditivo, opcional.

---

## 7. Qué queda INERTE vs qué falta cablear (fase posterior)

**Aplicado en esta entrega (ZONA, aditivo, INERTE salvo lectura):**
- `me.stock_movimientos` re-alineada a la plantilla (tabla vacía → recreada con el esquema nuevo + índices + RLS).
- `me.guias_detalle.cantidad_aplicada` (columna nueva, default 0) — soporte anti-duplicado.
- RPC `me.zona_kardex_registrar(p)` — INERTE (nadie la llama; el cableo es fase posterior).
- RPC `me.zona_kardex_historial(p)` — lectura, con reconstrucción. **Sí** se puede llamar (solo lee).
- Wrapper `mos.zona_kardex_historial(p)` (+ `mos.zona_kardex_registrar` por simetría, INERTE).

**Falta cablear (fase posterior, la revisa el dueño):**
1. Llamar a `me.zona_kardex_registrar` desde el flujo real de cierre de guía / venta / auditoría de ZONA (con `cantidad_aplicada` y `version`).
2. El front del módulo zona consumiendo `mos.zona_kardex_historial` en el card de historial.
3. La reconciliación nocturna de zona (cron) — diseñada en §4.2, no creada.
4. La propuesta WH (§6) — toda, tras revisión.

**No se tocó (por regla):** `api.js`, `app.js`, `version.json`, `sw.js`, ningún flujo/tabla/RPC vivo de WH, ningún commit.
