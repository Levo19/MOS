# 🛠️ Runbook de Ejecución — Migración Supabase

> Guion paso a paso para ejecutar la migración sin sorpresas. Compañero de `MIGRACION_SUPABASE.md` (estrategia) y `MIGRACION_SUPABASE_DICCIONARIO.md` (mapeo de datos).
> **Regla de oro:** Sheets nunca deja de funcionar. Cualquier paso es reversible.
> **Última actualización:** 2026-06-07

---

## 0. Leyenda de responsables

- 👤 **TÚ** (Luis): acciones en la consola de Supabase / Google / facturación.
- 🤖 **YO** (asistente): DDL, scripts GAS, backfill, validaciones, documentación.
- 🔵 **AMBOS:** verificación conjunta / punto de aprobación.

---

## 1. Orden maestro de ejecución (respeta las dependencias)

```
FASE 0  Preparación
  1. 👤 Crear proyecto Supabase Pro + región + facturación
  2. 👤+🤖 Cargar claves en Script Properties
  3. 🤖 Crear esquemas mos/me/wh + helper _sb() + _sbPing()
  4. 🔵 _sbPing() OK desde los 3 GAS
  5. 👤 Snapshot de los 3 Sheets → Drive 99-Backups-Sheets/
  6. 🤖 Proyecto Supabase Free (STAGING) para ensayar DDL/backfill
  7. 🤖 MAESTRAS COMPARTIDAS temprano (productos, equivalencias, categorias, personal, estaciones, impresoras, series_documentales, zonas, dispositivos — ver plan §3)
        → crear, backfillear, doble escritura desde MOS
        (ME/WH lo siguen leyendo por bridge hasta que activen su flag)

FASE 1  App por app (ME → WH → MOS), cada una con el ciclo A→E (sección 3)
        ⚠ ME y WH comparten stock: su flip de stock es COORDINADO (sección 6)

CUTOVER  Cuando las 3 apps estén estables: apagar doble escritura por app, archivar Sheets
```

**Dependencias duras (no saltar):**
- Constraints `UNIQUE` creadas **antes** de activar doble escritura (si no, no hay idempotencia).
- Catálogo compartido existe **antes** del backfill transaccional de ME/WH (FKs lógicas).
- Una app **no flipa lectura** hasta 7 días de cuadre 0.
- ME y WH **no flipan stock por separado** (sección 6).

---

## 2. FASE 0 — Preparación (detalle) · ARTEFACTOS YA CREADOS

> Ya están en el repo: `supabase/01_schema_compartido.sql`, `gas/Supabase.gs` (helper),
> `gas/MigracionCatalogo.gs` (backfill). Esta sección es la secuencia exacta para activarlos.

### 2.1 👤 Crear el proyecto
- supabase.com → New project → **Plan Pro**.
- **Región:** `South America (São Paulo) sa-east-1`. Nombre: `mos-ecosistema`. Guardar la **DB password**.
- ✅ Verificar después: Settings → General → Region = São Paulo · Billing → Plan = **Pro** 🔵
- Settings → API → copiar: `Project URL`, `anon public key`, `service_role key`.

### 2.2 🤖 Correr el DDL
- Supabase → SQL Editor → pegar y ejecutar **`supabase/01_schema_compartido.sql`** (idempotente, re-ejecutable).
- Crea esquemas mos/me/wh + catálogo + `mos.backfill_audit` + helper `mos.hoy_lima()`.

### 2.3 👤 **Exposed schemas (PASO BLOQUEANTE — sin esto PostgREST da 404/406)**
- Supabase → **Settings → API → "Exposed schemas"** → agregar `mos`, `me`, `wh` (junto a `public`). Guardar, esperar ~10 s.

### 2.4 👤+🤖 Cargar credenciales en Script Properties (MOS primero)
- En el GAS de MOS: Project Settings → Script Properties:
  - `SUPABASE_URL` = Project URL
  - `SUPABASE_SERVICE_KEY` = service_role key (⚠ solo backend, nunca al PWA ni a logs)
  - `SPREADSHEET_ID` = ID del Sheet maestro de MOS (de la URL `/spreadsheets/d/<ID>/`) — **requerido por `getSheet()`; sin él el backfill no abre las hojas.**
- (ME y WH reciben sus propias keys cuando llegue su fase.)

### 2.5 🤖 Asegurar que los 3 archivos GAS están en el proyecto MOS
- `Supabase.gs`, `MigracionCatalogo.gs` y el `Code.gs` existente (que define `getSheet`/`_sheetToObjects`).
- Vía `clasp push` (verificar que suben los .gs nuevos) o pegándolos en el editor web. Sin `Supabase.gs`, el backfill falla con `_sbUpsert is not defined`.

### 2.6 🔵 Validar conexión + permisos
- Ejecutar **`_sbPing()`** desde el editor de Apps Script (MOS) → debe loguear:
  `✓ GET mos.config OK` + `✓ WRITE mos.config OK` (la tabla vacía `[]` es normal). Latencia objetivo < ~300 ms.
- Si falla GET → revisar Exposed schemas / DDL / key. Si falla WRITE → permisos / key.

### 2.7 👤 Backups
- Duplicar los 3 spreadsheets a `MOS-Ecosistema/99-Backups-Sheets/`.
- Confirmar **PITR (7 días)** activo (Supabase Pro).

### 2.8 🤖 (Recomendado) Staging
- Un 2º proyecto Free para ensayar DDL/backfill sin tocar prod. Mismo `01.sql`.

### 2.9 🔵 **Validar headers del catálogo ANTES del backfill (evita "0 filas" silencioso)**
- `migrarCatalogoCompartido({dryRun:true})` → revisar el log:
  - cada tabla debe mostrar `filasValidas > 0` y una `muestra` con campos poblados (no todo null).
  - si `productos` da `filasValidas:0` o muestra todo null → los headers de la hoja no coinciden con `_CAT_SPECS` → corregir el spec antes de seguir.

### 2.10 🤖 Backfill del catálogo + cuadre
- `migrarCatalogoCompartido()` (real, idempotente por upsert).
- `verificarCuadreCatalogo()` → cada tabla `cuadra:true` (sheet == supabase). ⚠ Si una da `sheet:0/supabase:0` revisar que NO sea un falso OK por headers mal mapeados (cruzar con 2.9).
- (Opcional) auditar `codigo_producto_base` que apunte a `id_producto` inexistente → registrar en `backfill_audit` antes de activar la FK.

### 2.11 🤖 Activar FKs (post-backfill)
- Descomentar y ejecutar la sección POST-BACKFILL de `01_schema_compartido.sql` (self-FK productos + estaciones/impresoras/series → zonas/estaciones).

**✅ Salida de Fase 0:** `_sbPing` OK (GET+WRITE) · DDL aplicado · esquemas expuestos · catálogo cuadrando · backups + staging listos.

### ⚠️ GOTCHAS REALES (de la ejecución 2026-06-07 — aplican a WH/MOS)
1. **Llave:** usar la `service_role` LEGACY (JWT `eyJ…`), NO la `sb_secret_…` (da 401 "secret key in browser" desde GAS).
2. **Grants:** los esquemas custom dan 403 hasta correr el bloque de GRANTS (ya incluido al final de `01_schema_compartido.sql`).
3. **HEAD:** UrlFetchApp no lo soporta; `_sbCount` usa GET.
4. **Dedup:** el backfill deduplica por PK (las hojas pueden tener IDs repetidos).
5. Confirmar "Enable Data API" ON + esquemas en Exposed schemas.

### Estado real Fase 0
- ✅ Proyecto, DDL, exposed schemas, grants, `_sbPing`, backfill catálogo (10 tablas) + cuadre.
- ⬜ Activar FKs post-backfill · doble escritura catálogo desde MOS · snapshot Sheets/PITR.

---

## 3. Ciclo por app (A → E)

> Se aplica a ME primero. Mismo ciclo para WH y MOS.

### A. Inventario + DDL
- 🤖 Grep del router → enumerar **TODOS** los endpoints de escritura (la lista del plan no es exhaustiva).
- 🤖 Extraer headers reales de cada hoja (como se hizo con ME) → completar el diccionario.
- 🤖 Escribir DDL en **staging**: tipos del diccionario, PK (`id bigserial` + id legacy `UNIQUE`), FKs, índices, enums, columnas RLS-ready, constraints de idempotencia (`UNIQUE(ref_local…)`).
- 🔵 Revisar DDL → aplicar en prod.

### B. Auditoría de datos + Backfill (dry-run → full)
- 🤖 **Auditoría previa** (escribe en `backfill_audit`): JSON truncado/ inválido, filas huérfanas (cabecera↔detalle), ceros perdidos (longitud DNI/RUC), fechas no parseables, headers que no matchean, booleanos raros.
- 🔵 Resolver/decidir qué hacer con cada hallazgo (skip / reparar).
- 🤖 **Dry-run:** backfill con `DRY_RUN_FILA_MAX` (ej. 1 día / 1000 filas) en staging → validar cuadre.
- 🤖 **Backfill full** reanudable (checkpoint en `BACKFILL_STATE`), de noche, con `cutoff = ahora − 5 min`, upsert idempotente. Logs/ops solo últimos 90 d.
- 🔵 `verificarCuadre<APP>()`: conteo + suma (tolerancia ±0.01) + checksum de IDs → 0 divergencias.

### C. Doble escritura (sombra) — Sheets sigue mandando
- 🤖 En cada endpoint de escritura: tras Supabase, escribir a Sheets (o el orden definido en §1.3 del plan), **dentro de `try/catch`**, **fuera del lock** (§26), idempotente.
- 🤖 Cubrir INSERT, **UPDATE y DELETE** (anulaciones, ediciones, purgas).
- 🤖 Operaciones multi-tabla → función Postgres atómica (lista en §27).
- 🤖 Reconciliación diaria automática + alerta de drift.
- ⏳ Correr **3–5 días en sombra**. Objetivo: 0 divergencias sostenido.

### D. Flip de lectura (canary → global)
- 🤖 Flag `FUENTE_DATOS_<APP>` + fallback a Sheets (timeout ~4s).
- 🤖 **Canary:** `CANARY_SUPABASE_DISPOSITIVOS = [deviceId de prueba]` leen de Supabase. Monitorear ~4 h.
- 🔵 A/B por endpoint (mismo input → misma salida Sheets vs Supabase), empezando por `estadoCajas`.
- 👤 Aprobar flip global tras ver el cuadre. 🤖 voltea el flag.
- 🤖 Monitoreo intensivo 1ª hora, luego diario.

### E. Cierre de fase de la app
- 🔵 DoD (§11 del plan) cumplido ≥7 días con doble escritura **aún activa**.
- 🤖 Medir mejora real (p.ej. `estadoCajas` antes/después).
- ✅ Marcar la app en el tablero. **No** apagar la doble escritura todavía.

---

## 4. Checklist pre-flight (ejecutar la mañana de cada flip)

```
DATOS
☐ verificarCuadre<APP>() = 0 divergencias (conteo + suma + checksum)
☐ Las últimas 10 escrituras están en Supabase (query directa)
☐ Si la app comparte stock: el cuadre de la app pareja también está OK

CÓDIGO
☐ FUENTE_DATOS_<APP> = sheets (aún leyendo Sheets)
☐ Doble escritura = activa
☐ _sbPing() < 300 ms
☐ 0 errores de Supabase/fallback en la última semana de logs

ROLLBACK
☐ Snapshot de las tablas de la app → Drive 99-Backups-Sheets/
☐ Procedimiento de rollback a mano (sección 7), probado, < 2 min

COORDINACIÓN
☐ No hay otro flip el mismo día (salvo el cutover coordinado de stock ME↔WH)
☐ 👤 disponible para aprobar y observar

EJECUCIÓN
1. 👤 "OK para flip"
2. 🤖 canary 4h → si limpio → flip global
3. 🤖 monitoreo 1ª hora
```

---

## 5. Criterios de aborto y métrica de drift

- **Abortar/bloquear el flip** si `verificarCuadre` reporta drift > 0 (o suma fuera de tolerancia, o checksum distinto). Push de alerta + log; no se voltea sin **aprobación manual** tuya.
- **Backfill que falla 3 veces** → auto-aborta, deja checkpoint, 🔵 revisa antes de reintentar.
- **Métrica de drift (pseudocódigo):**
  ```
  sheet = filas(activas, excluyendo ANULADO/HUERFANA) 
  pg    = filas(activas, mismo criterio)
  drift = (count(sheet) != count(pg))
        OR (abs(sum(sheet.monto) - sum(pg.monto)) > 0.01)
        OR (md5(ids_ordenados(sheet)) != md5(ids_ordenados(pg)))
  ```

---

## 6. Caso especial: stock compartido ME ↔ WH

- ME descuenta `STOCK_ZONAS` al vender; WH repone vía pickup. Si una app lee de Supabase y la otra de Sheets, el stock diverge.
- **Regla:** el flip de **lectura de stock** de ME y WH es **un solo cutover coordinado** (ambos flags en el mismo momento), no secuencial.
- Pre-cutover: validar transitividad `Σ(pickups enviados por ME) ≈ Σ(ingresos por pickup en WH)`; si hay gap, AJUSTE en WH para alinear, y recién entonces voltear.
- Doble escritura de stock sigue activa en ambas tras el cutover (rollback sin pérdida).
- ⚠ Requiere que la doble escritura de Fase 1.C cree el log `me.stock_movimientos` / `wh.stock_movimientos` (hoy ME no lo tiene) ANTES de validar la transitividad; sin el log no hay forma de reconciliar `stock = inicial + Σ(movimientos)`.

---

## 7. Rollback (sin pérdida de datos)

> Posible porque la doble escritura **se mantiene activa** después del flip → Sheets siempre está actualizado.

1. 🤖 `FUENTE_DATOS_<APP> = sheets` (vuelve a leer de Sheets al instante).
2. 🔵 Verificar que la app opera normal (las escrituras recientes están en Sheets por la doble escritura).
3. 🤖 Diagnosticar la causa en Supabase sin presión (la operación ya está a salvo en Sheets).
4. Reintentar el flip cuando esté resuelto.

> Si por algún motivo se hubiera apagado la doble escritura (post-cutover) y hace falta volver: ejecutar `syncSupabaseToSheets(desde_fecha)` para traer a Sheets lo escrito solo en Postgres antes de leer de Sheets.

---

## 8. Crons / triggers (matriz a confirmar en Fase 0)

- 🤖 Grep `ScriptApp.newTrigger` + `setupTodo*` en los 3 repos → matriz definitiva (nombre, frecuencia, app, ¿escribe?, destino).
- **Regla:** cada cron vive en UN solo lugar. Flag `CRON_EN_POSTGRES` para apagar el de GAS cuando su gemelo `pg_cron` esté validado.
- En Fase 1, la mayoría se queda en GAS. Candidatos a `pg_cron` (Fase 2): purgas (ops_log, sync_log, audio_chunks, ubicaciones), y posiblemente rotación de PIN.
- ⚠ Verificar si `alertasOperativasDiarias` tiene trigger instalado (función-trigger detectada como posible huérfana).

---

## 9. Limpieza post-cutover

```
Día 1–7 tras el flip de cada app:
  - Doble escritura ACTIVA (Sheets = réplica viva, plan B).
  - Monitoreo diario de drift/latencia/errores.

Cuando las 3 apps llevan ≥7 días estables:
  - 👤 confirma "no hay razón para volver a Sheets".
  - 🤖 apagar doble escritura por app (ahorra escrituras).
  - Hojas transaccionales → archivo de lectura (no borrar).

Día 30+:
  - Mover hojas transaccionales a 99-Backups-Sheets/.
  - Mantener maestras + plan C.
  - Registrar en bitácora el cutover completado.
```

---

## 10. Qué NO se migra (se queda en GAS)

PrintNode · NubeFact (+ write-back de NF_Estado a Postgres) · Claude/IA · FCM (envío; tokens sí migran) · Drive (archivos) · RTC_SIGNALING/espía (efímero) · crons (Fase 1) · validación de clave admin (Fase 1, sin hashear).

---

## 11. Estado de ejecución (marcar en vivo)

| Paso | Estado | Fecha | Nota |
|------|:------:|-------|------|
| F0.1 Proyecto Pro | ⬜ | | |
| F0.3 Esquemas + _sb() | ⬜ | | |
| F0.5 Backups | ⬜ | | |
| F0.6 Staging | ⬜ | | |
| F0.7 Catálogo compartido | ⬜ | | |
| ME · A Inventario+DDL | ⬜ | | |
| ME · B Backfill | ⬜ | | |
| ME · C Doble escritura | ⬜ | | |
| ME · D Flip | ⬜ | | |
| ME · E Cierre | ⬜ | | |
| WH · A–E | ⬜ | | |
| MOS · A–E | ⬜ | | |
| Cutover + limpieza | ⬜ | | |
