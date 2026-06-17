# RUNBOOK — Cutover ESCRITURA DIRECTA de PROVEEDORES (piloto)

> Estado al entregar: **INERTE**. Todo construido con el gate OFF por defecto. El deploy de `js/api.js`
> NO cambia el comportamiento: con los flags en su valor actual ('0' / ausentes), `crearProveedor` y
> `actualizarProveedor` siguen yendo 100% por GAS, bit-idéntico a hoy. Activación = manual, abajo.

---

## 0) ⚠️ LEE ESTO ANTES DE ACTIVAR — riesgo real ya vivido

El enfoque **"apagar el sync + escritura directa por flag"** YA se intentó en vivo con PROVEEDORES el
2026-06-15 y **se revirtió en minutos** (ver `PUNTO_DE_RETOMA_cutover_escritura.md`):

- Un dispositivo en versión **vieja** del frontend (SW sin actualizar) ignora el flag de servidor y sigue
  escribiendo por **GAS→Hoja**. Con el sync de proveedores **apagado**, ese dato escrito en la Hoja **NO
  llega a la sombra Supabase** → se pierde para las lecturas directas → incoherencia / "duplicación".
- Por eso el proyecto cambió de estrategia a **DUAL-WRITE** (escritura por GAS para todos + GAS espeja la
  sombra al instante; el sync NO se apaga; solo la LECTURA se activa por flag).

**Implicación honesta:** este runbook (escritura-directa-pura) SOLO es seguro si **toda la flota** está en
la versión nueva del frontend (`js/api.js` con este cambio desplegado y SW propagado a todos los devices).
Mientras exista UN device viejo escribiendo por GAS, NO actives este cutover — usá el dual-write.

Si igual querés correr el piloto (p.ej. un único device controlado, fuera de horario de operación), seguí
los pasos. El riesgo está acotado porque proveedores **no es dinero**.

---

## DUAL-WRITE (modo SEGURO y RECOMENDADO) — sin apagar el sync

> **Este es el camino preferido.** No apaga ningún sync, no exige que la flota actualice, un device viejo
> NO rompe nada. Construido INERTE: gate `mos_proveedores_dualwrite` / `proveedoresDualWrite` OFF por
> defecto. Con el flag OFF, `crearProveedor`/`actualizarProveedor` van **bit-idéntico a hoy** (solo GAS).

### Qué hace (vs el directo-puro de las §1–§4)

| | Directo-puro (`mos_proveedores_directo`) | **Dual-write (`mos_proveedores_dualwrite`)** |
|---|---|---|
| Escribe la Hoja (verdad) | ❌ NO (solo Supabase) | ✅ SÍ, por GAS, **primero** |
| Escribe la sombra Supabase | sí (única fuente) | GAS la espeja (`_dualWriteMOS`) **+** upsert directo best-effort |
| Requiere apagar el sync | ✅ SÍ (o se pisa) | ❌ **NO** |
| Device viejo (GAS→Hoja) | rompe (pierde el dato) | inocuo (la Hoja sigue siendo verdad) |
| Retorno al front | shape de la RPC | **shape de GAS** (idéntico a hoy) |

**Flujo exacto (gate ON):**
1. `_postMOS` llama a **GAS primero** (`_fetch('POST',…)`), `await`, y **devuelve ese resultado** al front
   (shape/behaviour idéntico a hoy; GAS escribe la Hoja = verdad y corre su `_dualWriteMOS` a la sombra).
2. **Solo si GAS devolvió ok:** best-effort fire-and-forget `_postDirectoMOS('crear/actualizarProveedor', p)`
   → upsert directo a la **misma** RPC `mos.crear_proveedor` / `mos.actualizar_proveedor`, para que la sombra
   quede fresca aunque el `urlfetch` de GAS hubiera fallado por cuota. Si este paso falla, **se traga el error**
   (`.catch`), **no** afecta el retorno ni lanza (el sync/GAS reconcilia).
3. **Orden crítico:** GAS primero, Supabase después → la sombra **nunca queda adelante** de la Hoja. Si GAS
   **falla**, se propaga el error (igual que hoy) y **NO se escribe directo**.

**Triple seguridad (igual que el directo-puro):** flag de cliente OFF (default) · sin token Edge → upsert
no-op · kill-switch server `MOS_PROVEEDORES_DIRECTO='0'` → la RPC del espejo responde `*_OFF` → no-op. En
los tres casos GAS ya hizo el trabajo; el espejo es puramente resiliencia.

### ACTIVAR dual-write

**Solo prender el flag** — NO apagues el sync, NO toques `MOS_PROVEEDORES_DIRECTO` (directo-puro).

- **Piloto un device:**
  ```js
  localStorage.setItem('mos_proveedores_dualwrite','1'); location.reload();
  ```
- **Flota entera (server `mos.config`, lo lee `get_flags` y expone como `proveedoresDualWrite`):**
  ```sql
  insert into mos.config (clave,valor) values ('mos_proveedores_dualwrite','1')
    on conflict (clave) do update set valor='1';
  ```
  (confirmá que `mos.get_flags` mapea esta clave a `proveedoresDualWrite`).

> NOTA sobre el kill-switch server: el upsert-espejo pasa por la **misma** RPC que el directo-puro, así que
> si `MOS_PROVEEDORES_DIRECTO='0'`, el espejo será un **no-op** (la RPC responde `*_OFF`). Eso NO rompe nada
> (GAS ya espejó vía `_dualWriteMOS`); solo desactiva la capa extra de resiliencia. Si querés el espejo
> activo, poné `MOS_PROVEEDORES_DIRECTO='1'` — es SEGURO en dual-write porque GAS sigue escribiendo la Hoja.

### VERIFICAR dual-write

1. En la consola: `API._sb.proveedoresDualWrite();` → `true`.
2. Creá/editá un proveedor. En Network: **debe ir el POST a GAS** (`script.google.com`) Y, después, un POST
   a `…supabase.co/rest/v1/rpc/crear_proveedor` (el espejo). El front se comporta igual que hoy.
3. La Hoja `PROVEEDORES_MASTER` **se actualiza** (a diferencia del directo-puro): GAS la escribe. La sombra
   `mos.proveedores` también queda fresca.
4. Cortá el espejo a propósito (kill-switch server en `'0'` o token caído) → la operación **sigue OK** (GAS).

### REVERTIR dual-write

Trivial y sin reconciliación (la Hoja nunca se desfasó): **apagar el flag**.
```js
localStorage.removeItem('mos_proveedores_dualwrite'); location.reload();   // device
```
o flota: `update mos.config set valor='0' where clave='mos_proveedores_dualwrite';`

Con el flag OFF, vuelve a ser 100% GAS (idéntico a hoy). **No hay que reconciliar la Hoja** porque GAS
nunca dejó de escribirla.

### DUAL-WRITE extendido a otros módulos (mismo patrón, gate dedicado por módulo)

El patrón dual-write de proveedores se replicó (INERTE, gate OFF) a los módulos de escritura que ya tienen
RPC directa cableada en `_postDirectoMOS`. **Cada módulo tiene su flag dedicado** (default OFF → 100% GAS,
bit-idéntico a hoy). Activar/revertir = idéntico a proveedores (prender/apagar el flag; NO apagar el sync).
La clave server `mos.config` (`get_flags` la expone como el cfgKey) y la clave localStorage del device:

| Módulo | Flag server (`mos.config`) | cfgKey / `localStorage` | Diagnóstico `API._sb.*` | Actions (dual-write) |
|---|---|---|---|---|
| proveedores | `mos_proveedores_dualwrite` | `proveedoresDualWrite` | `proveedoresDualWrite()` | `crearProveedor`, `actualizarProveedor` |
| pedidos | `mos_pedidos_dualwrite` | `pedidosDualWrite` | `pedidosDualWrite()` | `crearPedido` |
| proveedor-producto | `mos_provprod_dualwrite` | `provprodDualWrite` | `provprodDualWrite()` | `agregarProductoProveedor`, `actualizarProductoProveedor` |
| gastos ⚠️DINERO | `mos_gastos_dualwrite` | `gastosDualWrite` | `gastosDualWrite()` | `registrarGasto`, `eliminarGasto` |
| jornadas ⚠️DINERO | `mos_jornadas_dualwrite` | `jornadasDualWrite` | `jornadasDualWrite()` | `registrarJornada`, `eliminarJornada`*, `rehabilitarJornada`* |
| evaluaciones | `mos_eval_dualwrite` | `evalDualWrite` | `evalDualWrite()` | `crearEvaluacion` |

\* `eliminarJornada`/`rehabilitarJornada` son FORWARD-LOOKING: el front no las llama hoy (usa
`vetar`/`desvetarLiquidacionDia`), pero el case GAS + el branch del dispatcher existen → quedan inertes hasta
que se usen.

**Notas de seguridad del lote:**
- `crearEvaluacion`: seguro en dual-write — GAS sigue corriendo `_liqDiaRecomputar`/`_liqDiaSetBonSan` (hooks
  de liquidación/DINERO). El espejo es puramente aditivo a la sombra. (El directo-PURO se los saltaría; por eso
  ese modo NO se habilita para evaluaciones.)
- `gastos`/`jornadas` (DINERO): GAS escribe la Hoja exactamente como hoy; el upsert-espejo es idempotente por
  `local_id` + PK (anti-doble-registro en reintento) y best-effort.

**OMITIDOS (no se cablearon, faltan piezas — NO inventar):**
- `actualizarPedido` — **no existe `case 'actualizarPedido'` en el router GAS** (`Code.gs`). En dual-write GAS
  corre primero; respondería "acción no reconocida" → `_fetch` lanzaría → cambiaría el comportamiento. (La RPC
  `mos.actualizar_pedido_proveedor` y el branch del dispatcher existen forward-looking, pero NO en el mapa.)
- `eliminarProductoProveedor` — **no existe RPC `mos.eliminar_proveedor_producto`** ni branch en
  `_postDirectoMOS` (la sombra no se actualizaría; el espejo sería siempre no-op).
- `importarJornadasDesdeCajas` — **no existe RPC `mos.importar_jornadas`** ni branch en `_postDirectoMOS`.

Con cualquiera de estos tres flags OFF (default) las acciones omitidas van 100% por GAS, idéntico a hoy.

---

## 1) Qué se construyó (ya desplegado, INERTE)

- **`js/api.js`**:
  - `_mosProveedoresDirecto()` = `_mosLecturaDirecta() || _mosFlag('mos_proveedores_directo','proveedoresDirecto')`
    (espeja el patrón de `_mosCatalogoDirecto`; default OFF → INERTE).
  - `crearProveedor` y `actualizarProveedor` agregados a `_MOS_POST_DIRECTO`, **gated por `_mosProveedoresDirecto`**.
  - El despachador `_postDirectoMOS` ya mapeaba ambas acciones a las RPCs (no requirió cambios).
- **SQL** (ya en la DB, sin cambios míos — solo verificación): `mos.crear_proveedor(p jsonb)` /
  `mos.actualizar_proveedor(p jsonb)` en `supabase/81_mos_proveedores_pedidos_pagos.sql`. Kill-switch
  server-side `mos.config.MOS_PROVEEDORES_DIRECTO` = `'0'` (verificado). **No se completó ninguna RPC: la
  paridad de retorno con GAS ya era exacta** (probado con rollback, 14/14 PASS).

**Triple candado INERTE** (con CUALQUIERA en OFF → escribe por GAS):
1. flag de cliente `mos_proveedores_directo` / `MOS_CONFIG.proveedoresDirecto` OFF (default);
2. sin token (Edge `mint-mos` caída) → `_sbRpcMOSWrite` devuelve null → fallback GAS;
3. kill-switch server `MOS_PROVEEDORES_DIRECTO='0'` → la RPC responde `MOS_PROVEEDORES_DIRECTO_OFF` →
   `_desempacarCatalogo` lo trata como null → fallback GAS.

---

## 2) ACTIVAR (orden EXACTO)

> Prerrequisito: toda la flota en la versión nueva (ver §0). Hacelo fuera de horario de operación.

### (a) Apagar el sync de proveedores PRIMERO (server-side, atómico)
En el editor de Apps Script de MOS, corré:

```js
apagarSyncTablaMOS('proveedores');
// → setea mos.config.MOS_SYNC_OFF_TABLAS con 'proveedores' en el CSV.
//   _syncMOSImpl deja de PISAR mos.proveedores desde la Hoja. Idempotente.
```
Verificá el retorno `{ ok:true, off:'...proveedores...' }`.

**Por qué primero:** si prendés la escritura directa antes de apagar el sync, el sync Hoja→sombra puede
pisar lo recién escrito directo en la ventana entre ambos pasos.

### (b) Prender el kill-switch server-side de la RPC
En Apps Script (o por SQL):

```js
// vía GAS:
setConfigMOS && setConfigMOS('MOS_PROVEEDORES_DIRECTO','1');  // si existe helper
```
o por SQL (`node _apply_sql.js` con un archivo, o psql):
```sql
update mos.config set valor='1' where clave='MOS_PROVEEDORES_DIRECTO';
```

### (c) Prender el flag de cliente
Elegí UNA vía (el orden de precedencia en `_mosFlag` es: server `get_flags` || localStorage || `MOS_CONFIG`):

- **Piloto un device** (recomendado para empezar): en la consola del navegador del device:
  ```js
  localStorage.setItem('mos_proveedores_directo','1'); location.reload();
  ```
- **Flota entera** vía server (`mos.config`, lo lee `get_flags`):
  ```sql
  insert into mos.config (clave,valor) values ('mos_proveedores_directo','1')
    on conflict (clave) do update set valor='1';
  ```
  (la clave que `get_flags` expone al cliente debe ser `proveedoresDirecto` — confirmá el mapeo en la RPC
  `mos.get_flags` antes de usar esta vía a nivel flota).
- **server-wide en código**: `index.html` → `window.MOS_CONFIG = { ..., proveedoresDirecto: true }` (requiere
  deploy + propagación de SW; NO recomendado para el piloto).

---

## 3) VERIFICAR que funciona

1. En el device piloto, abrí Proveedores → creá uno nuevo y editá uno existente.
2. En la consola del navegador:
   ```js
   API._sb.proveedoresDirecto();   // → true (gate ON)
   ```
   Y mirá la pestaña Network: el POST de `crearProveedor` debe ir a
   `…supabase.co/rest/v1/rpc/crear_proveedor` (NO a `script.google.com`).
3. En la DB, confirmá la fila en la **sombra**:
   ```sql
   select id_proveedor, nombre, local_id from mos.proveedores order by id_proveedor desc limit 5;
   ```
4. Idempotencia: doble-tap / reintento del mismo gesto → **una sola fila** (dedup por `local_id`).
5. La Hoja `PROVEEDORES_MASTER` quedará **desfasada** a propósito (el sync está off): es esperado durante
   el cutover. Las lecturas de proveedores deben venir de la sombra (activá `mos_proveedores_lectura='1'`
   si querés que el panel lea directo; si no, GAS lee la Hoja vieja).

---

## 4) REVERTIR (rollback) si algo sale mal

Orden inverso. **El paso (c) es el delicado** — leé la advertencia.

### (a) Gate de cliente OFF (corta la escritura directa de inmediato)
```js
localStorage.removeItem('mos_proveedores_directo'); location.reload();   // device piloto
```
o a nivel flota: `update mos.config set valor='0' where clave='mos_proveedores_directo';`

### (b) Kill-switch server OFF (cinturón y tirantes)
```sql
update mos.config set valor='0' where clave='MOS_PROVEEDORES_DIRECTO';
```
Con esto, aunque un device tenga el flag de cliente ON, la RPC responde `MOS_PROVEEDORES_DIRECTO_OFF` →
el front cae a GAS. La escritura vuelve a ser 100% GAS.

### (c) Reconciliar la Hoja ANTES de re-encender el sync ⚠️
Mientras el cutover estuvo activo, hubo escrituras directas que la Hoja NO vio. Si reactivás el sync sin
reconciliar, **el sync Hoja→sombra PISARÁ** esas escrituras directas (la Hoja es la fuente del sync) →
se pierden.

```js
// 1) primero en seco, para ver cuántas filas faltan en la Hoja:
resembrarHojaDesdeSombra('proveedores', { dryRun:true });
//    → { faltan: N, muestra:[...] }

// 2) si N > 0 y querés bajar los ALTAS a la Hoja:
resembrarHojaDesdeSombra('proveedores');   // append-only
```

**LIMITACIÓN HONESTA de `resembrarHojaDesdeSombra`:** es **append-only**. Solo agrega a la Hoja las filas
cuya PK (`id_proveedor`) NO existe en la Hoja. **NO reconcilia EDICIONES**: si durante el cutover se hizo
`actualizarProveedor` sobre un proveedor que YA existía en la Hoja, ese cambio está solo en la sombra y
`resembrar` NO lo bajará a la Hoja. Para esos casos:
- revisá manualmente los proveedores editados durante la ventana (comparalos sombra vs Hoja), o
- editalos de nuevo por GAS (ya con todo revertido) para que la Hoja quede al día,
- o usá el comparador de drift (`reconciliacionMOS`/`_MOS_PARIDAD_CLAVE.proveedores` incluye
  `nombre,ruc,estado,forma_pago,numero_cuenta,cci`) para detectar qué cambió.

### (d) Re-encender el sync
Solo después de (c):
```js
prenderSyncTablaMOS('proveedores');   // quita 'proveedores' del CSV → el sync vuelve a cubrir la sombra
```

---

## 5) Recomendación

Dado el incidente del 2026-06-15 y que la limitación de `resembrar` (append-only) deja las **ediciones**
sin red de reconciliación automática, para PROVEEDORES en producción el camino robusto es el **DUAL-WRITE**
(ver la sección **DUAL-WRITE** arriba): escritura por GAS (Hoja = verdad) + espejo best-effort a la sombra +
lectura directa por flag. NO requiere apagar el sync ni depende de que la flota actualice, y revertir es
solo apagar el flag. **Usá ese modo.** Este runbook de escritura-directa-pura (§1–§4) queda disponible y
listo (INERTE) para un piloto controlado o para cuando la flota esté 100% en la versión nueva.
