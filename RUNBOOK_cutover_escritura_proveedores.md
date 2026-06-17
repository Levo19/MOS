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
sin red de reconciliación automática, para PROVEEDORES en producción el camino robusto sigue siendo el
**DUAL-WRITE** (escritura por GAS + espejo a la sombra + lectura directa por flag), que NO requiere apagar
el sync ni depende de que la flota actualice. Este runbook de escritura-directa-pura queda disponible y
listo (INERTE) para un piloto controlado o para cuando la flota esté 100% en la versión nueva.
