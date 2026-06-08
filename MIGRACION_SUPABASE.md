# 🚀 Migración a Supabase — Plan Maestro v2 (documento vivo)

> **Estado global:** 🟦 FASE 1 en preparación · **App piloto:** MosExpress (ME)
> **Última actualización:** 2026-06-07 (v2 — tras 5 pasadas de revisión senior)
> **Leyenda:** ⬜ Pendiente · 🟦 En progreso · ✅ Hecho · ⏸️ Pausa · ❌ Descartado

---

## 0. Decisiones confirmadas por el usuario

| # | Decisión | ✅ |
|---|----------|:--:|
| 1 | Pagar **Supabase Pro (~$25/mes)**. El free no sirve (500 MB + se suspende tras 1 semana de **inactividad**). | ✅ |
| 2 | **Migrar en paralelo** con los Sheets vivos (sombra + doble escritura). Sheets = fuente de verdad hasta el cutover. Nada se rompe. | ✅ |
| 3 | **Archivos (fotos/audio/excel) se quedan en Google Drive, bien ordenado.** En Postgres solo la URL. | ✅ |
| 4 | Empezar por **FASE 1**, app por app, con lista detallada y progreso marcado. | ✅ |
| 5 | **Orden de apps:** 1º ME (POS) → 2º WH → 3º MOS. Excepción: el **catálogo compartido se migra temprano** (ver §3 y §17). | ✅ |

---

## 1. Principios rectores (las reglas que NO se rompen)

1. **Sheets nunca deja de funcionar** durante toda la migración. Es el plan B permanente hasta el cutover.
2. **La doble escritura sigue ACTIVA incluso después de voltear la lectura**, hasta el cutover final. Esto garantiza que un rollback (volver a leer de Sheets) **no pierda** las escrituras hechas mientras se leía de Supabase. (Riesgo detectado en revisión: rollback que pierde datos.)
3. **Orden de doble escritura: Supabase primero, Sheets después.** Si Supabase falla → se aborta y NO se escribe a Sheets (evita drift "dato en Sheets que nunca llegó a Postgres"). Si Supabase OK y Sheets falla → se registra para reconciliar. *Durante la fase de sombra pura (antes de cualquier flip) puede invertirse para máxima seguridad de negocio; decisión por endpoint, documentada.*
4. **Toda escritura a Supabase es idempotente** (clave natural + `Prefer: resolution=merge-duplicates`). El ecosistema reintenta mucho; sin esto se duplican filas.
5. **Lectura con fallback automático a Sheets:** si Supabase no responde en ~4s, el endpoint cae a Sheets y sigue operando. El negocio nunca se cuelga esperando a Supabase.
6. **Reconciliación diaria obligatoria** antes de cualquier flip: conteos + sumas + checksum. Cero drift por ≥7 días = requisito para voltear.
7. **Un flip coordinado por app** con flag `FUENTE_DATOS_<APP>`. El stock compartido (WH↔ME) exige cuidado especial (ver §11).
8. **Códigos SIEMPRE como `text`** (codigoBarra, SKU, Documento, DNI/RUC, IDs, correlativos, tokens, deviceId, printNodeId). Nunca `numeric`.
9. **Deletes nunca por SQL crudo vía PostgREST** (un `DELETE` sin `WHERE` borra la tabla). Se hacen vía funciones Postgres (`rpc`) con validación.
10. **Datos sensibles:** audio/GPS/espía **NO se migran como blobs** (se quedan en Drive con solo la URL) y con política de retención. (PINs: en Fase 1 se migran tal cual porque GAS sigue validando; el hasheo se hace en Fase 2 — ver §31.)
11. **Fidelidad de forma de respuesta:** en Fase 1 el frontend NO cambia → GAS devuelve respuestas **idénticas** (mismas keys camelCase, tipos, fechas string). La conversión Postgres→legacy ocurre en GAS. (ver §25)
12. **Nunca un `UrlFetch` a Supabase dentro de un lock** (`_conLock`/`LockService`): alarga el lock y causa contención. La escritura va fuera del lock. (ver §26)

---

## 2. Conexión GAS ↔ Supabase (Fase 1)

GAS no tiene SDK de Supabase. Se usa la **REST API (PostgREST)** vía `UrlFetchApp` con la `service_role key` (omite RLS en Fase 1; RLS llega en Fase 2).

```
GET/POST/PATCH/DELETE  https://<proyecto>.supabase.co/rest/v1/<tabla>
Headers: apikey: <service_role_key>
         Authorization: Bearer <service_role_key>
         Content-Type: application/json
         Prefer: resolution=merge-duplicates   (para upsert idempotente)
```

### Contrato del helper `_sb(metodo, tabla, opts)` — a implementar
- **Retorno uniforme:** `{ ok, code, data, error }`.
- **Timeout:** 25 s (bajo el límite de 30 s de UrlFetchApp).
- **Reintentos con backoff exponencial** solo para `5xx` y `429` (lee header `Retry-After`); **nunca** reintenta `4xx` (excepto 429). Cap 30 s.
- **`muteHttpExceptions: true`** + parseo defensivo (respuesta no-JSON → error legible, igual que el fix de `postToWarehouse`).
- **Idempotencia:** modo upsert con `merge-duplicates` por clave natural. ⚠ **Requiere constraint `UNIQUE`/PK** en esa clave; sin ella PostgREST inserta duplicado en silencio. Crear las constraints **antes** de activar la doble escritura. `409 Conflict` se trata como éxito.
- **Deletes:** prohibido el `DELETE` directo; se exponen funciones Postgres y se llaman vía `/rest/v1/rpc/<fn>`.
- Helpers derivados: `_sbInsert`, `_sbUpsert`, `_sbUpdate`, `_sbSelect`, `_sbRpc`, `_sbCount`, `_sbPing` (diagnóstico de latencia/región).
- **Credenciales** en Script Properties de cada GAS (`SUPABASE_URL`, `SUPABASE_SERVICE_KEY`). La service_role key **jamás** llega al PWA ni se loguea. Acceso al proyecto GAS restringido (ver §12).

---

## 3. Arquitectura de la base (un Postgres, 3 esquemas + catálogo compartido)

```
SUPABASE (1 proyecto Pro)
├── schema "mos"  → catálogo maestro, personal, seguridad, finanzas
├── schema "me"   → ventas, cajas, correlativos del POS
├── schema "wh"   → guías, stock, lotes, envasados, portal cliente
└── COMPARTIDAS/MAESTRAS (en schema mos, migradas TEMPRANO — todo lo read-mostly que ME/WH consumen):
       mos.productos · mos.equivalencias · mos.categorias · mos.personal
       · mos.estaciones · mos.impresoras · mos.series_documentales · mos.zonas · mos.dispositivos
       → leídas por me y wh (eliminan los bridges y el catálogo duplicado)
       (las tablas TRANSACCIONALES de MOS —jornadas, gastos, liquidaciones, etc.— migran en la fase de MOS)
```

> **Dependencia de orden (detectada en revisión):** ME y WH leen el catálogo de MOS. Por eso el **catálogo compartido (`mos.productos`, `equivalencias`, `categorias`, `personal`) se crea y se backfillea TEMPRANO** (en Fase 0 / inicio de Fase 1), con doble escritura desde MOS, aunque el resto de MOS migre al final. Mientras tanto, ME/WH pueden seguir leyendo el catálogo por el bridge actual sin cambios. Así nadie queda sin catálogo.

---

## 4. Reglas de modelado (DDL) — checklist transversal

> Estas reglas se aplican al diseñar el DDL de CADA tabla. Salieron de la revisión de esquema (pasada 2).

### 4.1 Tipos
- [ ] **Códigos como `text`:** codigoBarra, SKU/skuBase, Documento, DNI, RUC, idProducto, idVenta, idGuia, idCaja, correlativo, token cliente, deviceId, printNodeId, idReserva.
- [ ] **Montos:** `numeric(12,2)`.
- [ ] **Booleanos:** `boolean` puro. **Mapear en el backfill** los valores legacy `'1'/'0'`, `1/0`, `'SI'/'NO'`, `'true'/'false'`, `''`/`undefined` → `true/false` (el código actual los acepta todos de forma defensiva).
- [ ] **JSON embebido → `jsonb`:** `historialCambios` (ME), `items` (LISTAS_SOMBRA, PEDIDOS_PROVEEDOR), `payload_zona`/`payload_almacen`/`diferenciasJson` (DEVOLUCIONES_ZONA), `configJson`/`cajaActivaJson` (DEVICE_STATE), `horarioJson` (CONFIG_HORARIOS_APPS), `payload`/`resultado` (OPS_LOG), `ice_candidates`/SDP (RTC_SIGNALING/espía). Índices GIN solo si se consulta dentro del JSON.
- [ ] **Enums** con `CREATE TYPE` (o `CHECK`): estados de guía (ABIERTA/CERRADA), forma de pago ME (EFECTIVO/VIRTUAL/MIXTO/CREDITO/POR_COBRAR — ANULADO va en estado_envio, NO en forma_pago), estado de venta, lista sombra (DISPONIBLE/EN_USO/COMPLETADA), devolución (EN_TRANSITO/RECEPCIONADO/RECONCILIADO/ANULADA), estado de item devuelto (BUEN_ESTADO/ROTO/VENCIDO/...), ops_log (APPLIED/FAILED), etc.

### 4.2 Zona horaria Perú (CRÍTICO — espeja `architecture_wh_dia_tz_peru`)
- [ ] Fechas como `timestamptz`. En el backfill, **inyectar zona explícita** a las fechas legacy (Perú = UTC-5) para no desfasar el día.
- [ ] Toda agrupación Hoy/Ayer/cierre usa `AT TIME ZONE 'America/Lima'`. Crear helper SQL `hoy_lima()`.
- [ ] Validar que el cierre 21:00 Lima cae en el día correcto (no rueda al día siguiente en UTC).

### 4.3 Claves primarias y atomicidad
- [ ] **Riesgo de colisión:** IDs tipo `"V-"+Date.now()` colisionan si dos ocurren en el mismo ms. Estrategia: PK = el id legacy como `text UNIQUE` + columna interna `id bigserial`. Para nuevos IDs evaluar `ulid`/uuid.
- [ ] **Correlativos SUNAT (sin gaps, atómico):** reemplazar el `LockService`+lectura de Sheets por **`UPDATE me.correlativos SET siguiente=siguiente+1 WHERE serie=$1 RETURNING siguiente`** bajo transacción. ⚠ **NO usar `SEQUENCE`**: deja huecos en rollback y SUNAT exige numeración contigua. Validar que NubeFact reciba numeración sin gaps. Coexistir con la pre-reserva (RESERVAS_CORRELATIVOS) durante la sombra.

### 4.4 Integridad referencial
- [ ] **FKs reales** donde hoy hay relación por texto/nombre (zona, usuario, estación). Pre-migración: tabla lookup nombre→id y normalización en el backfill.
- [ ] Listar las FKs por tabla en el diccionario de datos (§ deliverable).

### 4.5 Columnas RLS-ready desde Fase 1 (evita refactor en Fase 2)
- [ ] Toda tabla transaccional incluye desde ya: `zona_id`, `dispositivo_id` (o NULL si global), `created_at`, `updated_at`, `created_by`. Índices en `zona_id` y `dispositivo_id`. Así la RLS de Fase 2 no exige `ALTER TABLE` masivo.

### 4.6 Retención / purga (datos de alto volumen)
- [ ] Definir política por tabla (cron de purga, ver §8):

| Tabla | Retención sugerida | Nota |
|-------|--------------------|------|
| `wh.ops_log` | 90 días | alto volumen; migrar solo últimos 90d |
| `wh.sync_log` | rolling 2000 filas | espeja la poda actual |
| `mos.audio_chunks` | 30 días auto-purge | + blob en Drive, no en PG |
| `mos.ubicaciones_historial` | 90 días | GPS; alto volumen |
| `mos.alertas_log` / `auditoria_admin` | 180–365 días | logs |
| `me.ventas_fantasma` | ≥1 año | auditoría de rechazos |

---

## 5. Organización de Google Drive (punto #3)

> Mover archivos en Drive **no rompe URLs** (el `fileId` persiste). Nuevos archivos nacen ordenados.

```
📁 MOS-Ecosistema/
├── 📁 01-Catalogo-Fotos/              (fotos de productos — MOS)
├── 📁 02-Proveedores-Imagenes/
├── 📁 03-WH-Archivos/AAAA-MM/{preingresos,guias,mermas,productos-nuevos}/
├── 📁 04-WH-PortalCliente/{token-cliente}/   (foto/audio/excel)
├── 📁 05-MOS-Seguridad-Audios/        (escucha remota / espía; retención 30d)
└── 📁 99-Backups-Sheets/             (snapshots de respaldo)
```
- [ ] Crear carpetas y guardar `folderId` en Script Properties por app
- [ ] Reapuntar la subida de archivos NUEVOS a las carpetas nuevas (sin tocar lógica de negocio)
- [ ] (Opcional) Mover archivos históricos; verificar URLs vivas

---

## 6. Roles: qué haces TÚ vs qué hago YO

> Tú haces lo que requiere tu cuenta/tarjeta/consola; yo hago el código y los scripts.

| TÚ (usuario) | YO (asistente) |
|--------------|----------------|
| Crear cuenta en supabase.com + proyecto **Pro ($25/mes)** | Diseñar DDL (tablas, índices, enums, funciones) |
| Elegir **región** (recomendado `sa-east-1` São Paulo; alterno `us-east-1`) | Crear los 3 esquemas + catálogo compartido |
| Copiarme las **3 claves** (URL, anon, service_role) a un lugar seguro | Escribir helper `_sb()` + `_sbPing()` en GAS |
| Pegar las claves en **Script Properties** de cada GAS (te guío) | Escribir scripts de backfill reanudable |
| Confirmar **facturación activa** | Doble escritura + flags + fallback + reconciliación |
| Tener **clasp** logueado (ya lo usas) | Pruebas A/B, monitoreo, runbook de rollback |
| Aprobar cada flip tras ver el cuadre | Diccionario de datos + bitácora |

> **Punto de espera de Fase 0:** confirmas (a) proyecto Pro creado, (b) facturación activa, (c) claves pegadas, (d) `_sbPing()` responde OK. Recién ahí arranca el backfill.

---

## 7. Mecánica defensiva (sombra, backfill, reconciliación, rollback)

> De las pasadas 3 y 4. Esto es lo que evita que la migración corrompa datos.

### 7.1 Backfill reanudable (límite 6 min de GAS)
- [ ] Estado en `BACKFILL_STATE` (hoja o Property): `{app, tabla, ultimaFila, cutoff, estado, intentos}`.
- [ ] Leer en bloques (p.ej. 5k filas) y subir en sub-lotes (~100 por POST, array).
- [ ] Guardar checkpoint cada sub-lote; si se acerca a 6 min, salir y reanudar en el siguiente trigger.
- [ ] **Idempotente:** upsert por clave natural → re-correr no duplica.
- [ ] **Cutoff:** el backfill procesa hasta `ahora − 5 min`; lo nuevo entra por doble escritura (dedup por clave natural). Correr de noche.

### 7.2 Idempotencia de la doble escritura
- [ ] Cada tabla con **clave natural única** (`Ref_Local`/`localId`/`idVenta`+linea) → `UNIQUE` constraint.
- [ ] `Prefer: resolution=merge-duplicates`; `409` = OK.

### 7.3 UPDATES y DELETES (no solo inserts)
- [ ] Anulaciones (venta, guía), ediciones de cantidad, cambios de estado → **replicar como UPDATE** a Supabase.
- [ ] Purgas (sync_log, etc.) → DELETE en ambos lados, vía función Postgres.

### 7.4 Reconciliación y detección de drift
- [ ] `verificarCuadre<APP>()`: compara **conteo + suma de montos + checksum** (no solo conteo) Sheets vs Postgres, excluyendo anulados de forma consistente.
- [ ] Corre diario post-cierre; registra divergencias en `*_drift_log` y **alerta**.
- [ ] **Regla de flip:** 0 divergencias por ≥7 días.

### 7.5 Rollback sin pérdida
- [ ] La doble escritura **permanece activa tras el flip** → Sheets siempre actualizado → rollback = cambiar flag, sin pérdida.
- [ ] Antes de cada flip: snapshot de respaldo.

### 7.6 Fallback ante caída de Supabase
- [ ] Lectura con timeout corto (~4s) → cae a Sheets automáticamente.
- [ ] Flag `SUPABASE_ESTADO=OFFLINE` tras N fallos seguidos + alerta; reintento periódico.

---

## 8. Inventario de CRONS / triggers → destino

> Detectados 12+ en GAS (pasada 5). **Tarea: confirmar la lista exacta por app** y decidir destino. Riesgo: cron duplicado (GAS + pg_cron) = doble cierre/conteo.

- [ ] **Construir la matriz definitiva** (grep de `ScriptApp.newTrigger` y `setupTodo*` en los 3 repos).

Matriz inicial a verificar:

| Cron (aprox.) | Frec. | App | Escribe datos? | Destino propuesto |
|---|---|---|---|---|
| cierre nocturno / liquidaciones | 23:00 | MOS | sí | Mantener en GAS Fase 1; evaluar pg_cron Fase 2 |
| resumen diario (push) | 22:00 | MOS | no (lee) | GAS |
| salud stock WH | 22:30 | WH | sí (alertas) | GAS Fase 1 |
| cierre semanal jornales | semanal | MOS | sí | GAS (ver `project_mos_cierre_semanal`) |
| escalación etiquetas | 1 h | MOS | sí | GAS |
| heartbeat impresoras | 15 min | MOS | no | GAS (PrintNode) |
| limpiar buffer espía | dom 03:00 | MOS | sí (purga) | GAS / pg_cron |
| purgar push tokens viejos | mensual | MOS | sí (purga) | pg_cron |
| seguridad: 4 triggers (`setupTodoSeguridad`) | varios | MOS | sí | GAS (ver `project_seguridad_sistema`) |
| rotación PIN admin | 30 d | MOS | sí | GAS (ya notifica) |
| `alertasOperativasDiarias` | 07:00? | MOS | sí | **Verificar si está instalado** (es la función-trigger huérfana del último audit) |

**Regla:** un cron solo vive en UN lugar. Flag `CRON_EN_POSTGRES` para apagar el de GAS cuando su gemelo pg_cron quede validado.

---

## 9. Backups y recuperación (DR)

- [ ] **Antes de tocar nada:** snapshot de los 3 Sheets a `99-Backups-Sheets/`.
- [ ] **Supabase Pro:** confirmar **PITR (7 días)** activo.
- [ ] Snapshot nocturno de tablas críticas (export) durante la migración.
- [ ] **Probar un restore** en Fase 0 (no asumir que funciona).
- [ ] RPO objetivo = 0 (es dinero/stock); RTO < 2 h.

---

## 10. Observabilidad y costo

- [ ] Endpoint `verificarCuadre<APP>()` + tablero simple (en una hoja) con conteos/sumas/latencias.
- [ ] **Alertas** (push/FCM ya existente): drift > 0, latencia p95 de endpoint clave > umbral, % de fallos de doble escritura > 5%.
- [ ] **Costo:** evitar `SELECT *` sin `WHERE`; rate-limit en pollings (portal cliente → Realtime en Fase 2). Revisar el panel de uso de Supabase semanalmente las primeras semanas.

---

## 11. Criterios de éxito (Definition of Done) por fase

Una app se considera migrada (Fase 1) cuando, por ≥7 días seguidos:
- [ ] **Exactitud:** `verificarCuadre` = 0 divergencias (conteo + suma + checksum).
- [ ] **Velocidad:** el endpoint pesado mejora de forma medible (ej. `estadoCajas` de ~3–5 s a < 800 ms con flag=supabase).
- [ ] **Confiabilidad:** 0 errores no controlados de doble escritura; fallback a Sheets probado.
- [ ] **Rollback probado:** cambiar el flag restaura el 100% en < 5 min, sin pérdida.
- [ ] **Stock compartido (WH/ME):** sin desfases entre apps tras el flip coordinado.

---

## 12. Seguridad

- [ ] `service_role key` solo en Script Properties del backend; **nunca** en el PWA ni en logs. Restringir quién edita los proyectos GAS.
- [ ] **Deletes vía funciones Postgres** (`rpc`), nunca `DELETE` crudo por PostgREST (evita el borrado total accidental sin `WHERE`).
- [ ] **PINs/claves hasheados** en Postgres (no plaintext).
- [ ] **Audio/GPS/espía:** blobs se quedan en Drive (solo URL en PG) + retención (§4.6). No exfiltrar más de lo necesario a un tercero.
- [ ] Fase 2: reemplazar service_role por **anon key + RLS + JWT** (PIN/deviceId/rol/zona).

---

## 13. TABLERO DE PROGRESO GLOBAL

| Bloque | Estado | Notas |
|--------|:------:|-------|
| Fase 0 — Preparación global | ⬜ | Proyecto, claves, helper, backups, catálogo compartido |
| Fase 1 — MosExpress (ME) | ⬜ | Piloto |
| Fase 1 — warehouseMos (WH) | ⬜ | Tras validar ME |
| Fase 1 — MOS (master) | ⬜ | Conecta catálogo compartido |
| Fase 2 — Acceso directo (PWA→Supabase) | ⬜ | Fuera de alcance hasta cerrar Fase 1 |

---

## 14. FASE 0 — Preparación global (una vez)

- [ ] (TÚ) Crear proyecto Supabase **Pro**, elegir región, facturación activa
- [ ] (TÚ) Copiar claves; (TÚ+YO) pegarlas en Script Properties de los 3 GAS
- [ ] (YO) Crear esquemas `mos`/`me`/`wh`
- [ ] (YO) Helper `_sb()` + `_sbPing()` + diagnóstico de conexión/latencia
- [ ] (AMBOS) `_sbPing()` responde OK desde los 3 GAS
- [ ] (TÚ) Snapshot de los 3 Sheets a `99-Backups-Sheets/`
- [ ] (YO) **Catálogo compartido temprano:** crear y backfillear `mos.productos`, `equivalencias`, `categorias`, `personal` + doble escritura desde MOS
- [ ] (AMBOS) Probar un restore de backup
- [ ] (YO) Convención de nombres header-Sheet → columna snake_case (inicio del diccionario de datos)

---

## 15. FASE 1 — MosExpress (POS) 🟦 PILOTO

### 15.A0 — Inventario exhaustivo de hojas de ME (verificación)
- [ ] Grep de todos los `getSheetByName` en el GAS de ME y confirmar la lista completa. Conocidas: `VENTAS_CABECERA`, `VENTAS_DETALLE`, `CAJAS`, `MOVIMIENTOS_EXTRA`, `CLIENTES_FRECUENTES`, `GUIAS_CABECERA`, `GUIAS_DETALLE`, `CORRELATIVOS`, `RESERVAS_CORRELATIVOS`, `CREDITOS_COBRO_ASIGNADO`, `VENTAS_FANTASMA`, `STOCK_ZONAS`, `RADIO_CONFIG`, **`AUDITORIAS`**, **`CAJA_ALERTAS_EFECTIVO`**, **`PICKUPS_PENDIENTES_ENVIO`**, `PROMOCIONES` (verificar si es de ME o se lee de MOS). Las maestras (PRODUCTOS_MASTER, EQUIVALENCIAS, ESTACIONES, ZONAS_CONFIG, PERSONAL_MASTER, DISPOSITIVOS) **se leen del catálogo compartido**, no se duplican.
- [ ] Decidir por hoja: migrar / dejar en Sheets / purgar (logs de bajo valor).

### 15.A — Diseño del esquema `me` (aplicando §4)
- [ ] `me.ventas`, `me.ventas_detalle` (+ `historialCambios` jsonb o tabla audit)
- [ ] `me.cajas`, `me.movimientos_extra`
- [ ] `me.clientes_frecuentes` (Documento `text`)
- [ ] `me.guias_cabecera`, `me.guias_detalle`
- [ ] `me.correlativos` (atómico vía UPDATE…RETURNING, NO SEQUENCE), `me.reservas_correlativos`
- [ ] `me.creditos_cobro_asignado`, `me.ventas_fantasma`, `me.stock_zonas`
- [ ] `me.auditorias`, `me.caja_alertas_efectivo`, `me.pickups_pendientes_envio`
- [ ] `me.radio_config`, `me.promociones` (si aplica)
- [ ] Columnas RLS-ready (§4.5) + índices por patrón de lectura (estadoCajas, detalleVenta, ventasHoyZona)
- [ ] DDL completo + crear en Supabase + diccionario de datos de ME

### 15.B — Backfill + verificación
- [ ] `migrarME_backfill()` reanudable (§7.1), de noche
- [ ] `verificarCuadreME()` (conteo + suma + checksum)

### 15.C — Doble escritura (sombra)
- [ ] `registrarVenta` → `me.ventas` + `me.ventas_detalle`
- [ ] abrir/cerrar/forzar caja → `me.cajas`; movimientos extra → `me.movimientos_extra`
- [ ] correlativo/reserva (atómico) → `me.correlativos`/`me.reservas_correlativos`
- [ ] alta cliente → `me.clientes_frecuentes`; guía de salida al cierre → `me.guias_*`
- [ ] crédito/por cobrar → `me.creditos_cobro_asignado`
- [ ] **anulaciones/ediciones** → UPDATE (§7.3); rechazos → `me.ventas_fantasma`
- [ ] Todo en `try/catch`; correr 3–5 días en sombra con cuadre diario

### 15.D — Voltear lecturas (flip)
- [ ] Flag `FUENTE_DATOS_ME` + fallback a Sheets
- [ ] `estadoCajas()` (el gran cuello) → `SELECT WHERE` indexado
- [ ] `detalleVenta`, `ventasHoyZona`, `getCajaActivaZona`, `radio_config`/`top_productos_hoy`
- [ ] A/B por endpoint + flip gradual

### 15.E — Cierre Fase 1 ME
- [ ] DoD §11 cumplido ≥7 días (doble escritura sigue activa)
- [ ] Marcar **ME Fase 1 = ✅**

---

## 16. FASE 1 — warehouseMos (WH) ⬜

### 16.A0 — Inventario exhaustivo de WH (verificación)
- [ ] Confirmar lista. En Setup: CONFIG, CATEGORIAS, PRODUCTOS, STOCK, LOTES_VENCIMIENTO, PROVEEDORES, PREINGRESOS, GUIAS, GUIA_DETALLE, MERMAS, AUDITORIAS, AJUSTES, ENVASADOS, PRODUCTO_NUEVO, ZONAS, PERSONAL, SESIONES, DESEMPENO, SYNC_LOG, PICKUPS, OPS_LOG, CARGADORES_LOG. Adicionales detectadas: **ALERTAS_STOCK, STOCK_MOVIMIENTOS, LISTAS_SOMBRA, DEVOLUCIONES_ZONA, LOTES_ADHESIVO, LOTES_HISTORIAL, TICKETS_IMPRESOS, DIAGNOSTICO_TESTS**, portal cliente: **Clientes, PedidosCliente, PedidosClienteItems, PedidosClienteAdj**. Maestras compartidas (PRODUCTOS_MASTER, EQUIVALENCIAS, PERSONAL_MASTER, etc.) vía catálogo compartido.

### 16.A–E (patrón §15, aplicando §4 y §7)
- [ ] DDL `wh.*` (lotes FIFO, stock + stock_movimientos, envasados, mermas, preingresos, listas_sombra jsonb, devoluciones_zona jsonb, pickups, sesiones, desempeno, ops_log+purga, sync_log+purga, cargadores_log, alertas_stock, lotes_adhesivo, lotes_historial, tickets_impresos, portal cliente)
- [ ] Backfill reanudable (ops_log/sync_log solo últimos 90 d) + verificación (incluir **stock total por código**)
- [ ] Doble escritura: `crearGuia`/`agregarDetalleGuia`/`cerrarGuia` (+stock), `_actualizarStock` (+movimientos), envasados, mermas, preingresos, lotes FIFO, listas/pickups/devoluciones, portal cliente, sesiones/desempeño/ops_log/cargadores. Mantener `_conLock` en Fase 1; reconciliación de stock como red de seguridad.
- [ ] Flip `FUENTE_DATOS_WH` + fallback; **coordinar con ME por el stock compartido**
- [ ] DoD §11 → marcar **WH Fase 1 = ✅**

---

## 17. FASE 1 — MOS (master) ⬜

### 17.A0 — Inventario exhaustivo de MOS (verificación)
- [ ] Confirmar lista. Setup: CONFIG_MOS, PRODUCTOS_MASTER, EQUIVALENCIAS, PROVEEDORES_MASTER, HISTORIAL_PRECIOS, PEDIDOS_PROVEEDOR, PAGOS_PROVEEDOR, CONEXIONES, ALERTAS_LOG, ZONAS, ESTACIONES, IMPRESORAS, SERIES_DOCUMENTALES, PERSONAL_MASTER, JORNADAS, GASTOS, CATEGORIAS, LIQUIDACIONES. Dinámicas/adicionales: AUDIO_SESIONES, AUDIO_CHUNKS, AUDITORIA_ADMIN, DISPOSITIVOS, UBICACIONES_HISTORIAL, BLOQUEOS_USUARIO(S), DEVICE_STATE, EVALUACIONES, LIQUIDACIONES_DIA, PUSH_TOKENS, NOTIFICACIONES_CONFIG/LOG (verificar), ETIQUETAS_PENDIENTES (verificar), MEMBRETES_ME_PENDIENTES, **RTC_SIGNALING**, **SEGURIDAD_ALERTAS**, **DIAGNOSTICO_ESPIA**, **CIERRE_NOCT_LOG**, **CONFIG_HORARIOS_APPS**, **PROVEEDORES_PRODUCTOS**, **PURGAS_HISTORICAS**, **QUOTA_DISPOSITIVOS_LOG**, HORARIOS_DISPOSITIVO. (Las VENTAS_*/GUIAS_*/STOCK_ZONAS/PRESENTACIONES/PRODUCTO_BASE que aparecen en el GAS de MOS son **lecturas cross-app** de ME/WH por SS_ID, no tablas propias de MOS.)

### 17.A–E (patrón §15)
- [ ] DDL `mos.*` (con purga para logs/ubicaciones/audio; espía/RTC evaluar si migra o se queda en GAS por ser efímero)
- [ ] Backfill + verificación
- [ ] Doble escritura en endpoints de escritura de MOS (incluye verificar `aplicarRespuestaJefa` + propagación de precios contra Postgres)
- [ ] Flip `FUENTE_DATOS_MOS`
- [ ] **Conectar catálogo compartido:** ME y WH dejan de copiar `PRODUCTOS_MASTER` y leen `mos.productos`; **retirar bridges** progresivamente
- [ ] DoD §11 → marcar **MOS Fase 1 = ✅**

---

## 18. Qué se QUEDA en GAS (no migra a Postgres)

- 🖨️ PrintNode (tickets ESC/POS, etiquetas TSPL/ZPL)
- 🧾 NubeFact (CPE SUNAT)
- 🤖 Claude/Anthropic (OCR facturas, parseo pedidos)
- 🔔 FCM (push)
- ⏰ Crons/triggers (ver §8; algunos a pg_cron en Fase 2)
- 🗂️ Google Drive (subida/lectura de archivos)

---

## 19. Deploy / clasp (impacto)

- [ ] Cambios de GAS en los 3 proyectos (helper `_sb`, doble escritura, flags) → `clasp push` + crear versión.
- [ ] **WH: redeploy de TODOS los deployment IDs versionados** que MOS consume (regla del ecosistema), no solo HEAD. (`feedback_wh_redeploy_todos_los_ids`)
- [ ] MOS: `clasp deploy -i AKfycbxalFhPdiVi…` (deployment estable que usa el frontend). (`reference_clasp_mos`)
- [ ] ME: usar el deployment ID que consume el frontend. (`reference_clasp_mosexpress`)
- [ ] Validar con `node -c` cualquier refactor con `await` antes de deploy.

---

## 20. Estimación de esfuerzo (rangos, no compromiso)

| Fase | Calendario | Horas activas (YO) |
|------|-----------|--------------------|
| Fase 0 | 1–2 días | ~4–6 h |
| Fase 1 ME | ~2 semanas (incluye 5–7 d de sombra pasiva) | ~12–16 h |
| Fase 1 WH | ~2–3 semanas (más complejo) | ~16–22 h |
| Fase 1 MOS | ~2 semanas | ~12–18 h |
| **Fase 1 total** | **~6–8 semanas** | **~45–60 h** |
| Fase 2 (futuro) | ~4–6 semanas | — |

> La mayor parte del calendario es **observación/sombra pasiva**, no trabajo continuo.

---

## 21. Costos

| Concepto | Costo |
|----------|-------|
| Supabase Pro | ~$25/mes (8 GB datos incl.; sobra años) |
| Google Drive | gratis 15 GB; si llena → One 100 GB $2/mes / 2 TB $10/mes |
| **Total** | **~$25–35/mes** |

---

## 22. Fase 2 (futuro, fuera de alcance)

- PWA directo a Supabase (supabase-js) → velocidad sub-segundo
- **RLS + JWT** (PIN/deviceId/rol/zona) — habilitado por las columnas RLS-ready de Fase 1
- **Realtime** reemplaza polling (portal cliente, stock, bloqueos)
- Crons a `pg_cron` donde convenga
- Reescritura de `api.js` por app

---

## 23. Entregables de documentación

- [x] **Diccionario de datos** (`MIGRACION_SUPABASE_DICCIONARIO.md`): ✅ ME completo y verificado contra código (16 tablas + enums + COLUMNAS_TEXTO + backfill_audit); WH/MOS en andamiaje (se completan al iniciar su fase). ⚠ Pendiente confirmar enum `forma_pago` y headers de `JORNADAS` en Fase 0.
- [x] **Runbook de ejecución** (`MIGRACION_RUNBOOK.md`): ✅ orden maestro, Fase 0 detallada, ciclo A–E por app, pre-flight, criterios de aborto + métrica de drift, stock coordinado ME↔WH, rollback, limpieza post-cutover.
- [ ] **Matriz de crons** (§8) final → tarea de Fase 0 (grep de triggers).

---

---

# ════════ v3 — Hallazgos de 10 pasadas senior adicionales ════════

> Las secciones 25–34 son refinamientos de detalle sobre lo anterior. No reemplazan; precisan.

## 25. Fidelidad de la forma de respuesta (CRÍTICO — Fase 1)

> En Fase 1 **el frontend NO se toca**. Por lo tanto, la capa GAS debe devolver respuestas **idénticas** a las de hoy aunque los datos vengan de Postgres.

- [ ] **Principio:** la conversión Postgres → forma legacy ocurre EN GAS. El PWA debe recibir las **mismas keys (camelCase), mismos tipos, fechas como string, y `null→''`/`'—'` donde hoy se espera**.
- [ ] **Riesgo #1 de pantalla blanca:** PostgREST devuelve snake_case y `null` explícito. Si eso llega crudo al front, rompe renders y dedup de `pendingSales` (matching por `idVenta`).
- [ ] **Dos caminos (elegir):** (a) nombrar las columnas Postgres igual que las keys legacy, o (b) un mapeador en `_sb()`/cada endpoint. Recomendado (b) por limpieza del DDL.
- [ ] `API.post/get` (MOS) espera `{ ok, data, error }` y devuelve `d.data`. El helper `_sb()` debe normalizar SIEMPRE a esa forma.
- [ ] **Endpoints de forma sensible a validar:** `estadoCajas`, `detalleVenta`, `descargarCatalogo`/`descargarMaestros` (shape cacheado en localStorage), `consultarEstadoDispositivo` (keys `existe`/`estado`), portal cliente (`clienteInboxPolling`, estado de pedido).
- [ ] **Versionado de caché:** incluir `cacheVersion` en `descargarCatalogo`; si cambia el shape, el front purga localStorage.

## 26. Escritura a Supabase y locks (concurrencia)

- [ ] **Regla:** la escritura a Supabase NO debe ocurrir dentro de `_conLock`/`LockService` si implica un `UrlFetch` largo → alargaría el lock varios segundos y dispararía contención/timeouts. Mantener la sección crítica del lock mínima; hacer el POST a Supabase **antes o después** del lock, o encolarlo.
- [ ] **Reentrancia:** usar el flag `_lockHeld` (WH) para que la doble escritura ocurra **una sola vez** (en el nivel externo), evitando POST duplicados en llamadas anidadas (p.ej. `aprobarPreingreso→crearGuia→cerrarGuia`).
- [ ] **Helpers `_garantizarColumnas*`** y similares: idempotentes (no duplicar columnas/filas si se llaman dos veces).

## 27. Cobertura COMPLETA de endpoints de escritura

> Las listas de §15–17 NO son exhaustivas. **Primera tarea de cada app: grep del router** y enumerar TODOS los `case`/acciones que mutan datos.

Endpoints adicionales detectados que faltaban (agregar a doble escritura):
- [ ] **MOS:** `crear/actualizar/eliminarPromocion` (PROMOCIONES) · `bloquearVendedorME`/`desbloquearUsuarioTemporal`/`bloquearDispositivosDeUsuario`/`liberarDispositivoBloqueado` (BLOQUEOS_USUARIO) · `syncDeviceState` (DEVICE_STATE) · `agregar/actualizar/eliminar/upsertProductoProveedor` (PROVEEDORES_PRODUCTOS) · adhesivos personalizados (`guardar/eliminarAdhesivoPlantilla` → ver `project_editor_avisos`) · `actualizarCostoPorSku`.
- [ ] **WH:** `marcarAlertaRevisada`/`aceptarTeoricoAlerta` (ALERTAS_STOCK) · `addCargadorDia`/`removeCargadorDia` (CARGADORES_LOG) · verificar si `crear/actualizarProducto` local de WH sigue en uso (posible duplicado del catálogo).
- [ ] **ME:** `SYNC_DEVICE_STATE` (proxy a MOS DEVICE_STATE).
- [ ] **Espía/RTC (MOS):** `espiaCrearSesion`/`espiaSubirOferta`/`espiaSubirRespuesta`/`espiaSubirReneg*`/`espiaAgregarIce`/`espiaPushBatch` → **decisión §31: se quedan en GAS** (efímero, no migrar a Postgres).

**Operaciones MULTI-TABLA que exigen atomicidad** (función Postgres/transacción, no dos POST sueltos):
- [ ] `aplicarRespuestaJefa` (**PRODUCTOS_MASTER canónico + presentaciones + HISTORIAL_PRECIOS** — corregido: es actualización de precios con propagación, NO toca GUIAS/STOCK) · WH `cerrarGuia` (GUIAS + STOCK) · WH `cerrarPickupConDespacho` (PICKUPS + GUIAS) · ME `procesarVenta` (VENTAS_CABECERA + VENTAS_DETALLE) · ME `cerrar_caja` (CAJAS + guía salida + MOVIMIENTOS_EXTRA) · ME `COBRAR_CREDITO_CON_EXTRA` (VENTAS_CABECERA + MOVIMIENTOS_EXTRA) · WH `registrarEnvasado` (2 guías + 2 stocks + ENVASADOS).

## 28. Estrategia de STOCK (el dato más peligroso)

- [ ] **Distinguir snapshot mutable de log append-only:** `STOCK`/`STOCK_ZONAS` = snapshot; `STOCK_MOVIMIENTOS` = log.
- [ ] **Anti-doble-conteo:** backfillear el snapshot de stock a un **cutoff** (p.ej. cierre del día) y aplicar por doble escritura **solo los deltas posteriores** al cutoff. Nunca backfill snapshot + replay de deltas del mismo período.
- [ ] **Validación de cuadre de stock:** `stock_actual == stock_inicial + Σ(deltas)` en `verificarCuadre`.
- [ ] **ME sin log hoy:** `generarGuiaSalidaVentas` descuenta `STOCK_ZONAS` sin registrar movimiento → en la doble escritura, agregar log a `me.stock_movimientos` para trazabilidad/reconciliación.
- [ ] **Lotes FIFO:** decidir modelo → `wh.lotes(cantidad_inicial, cantidad_consumida)` (auditable) en vez de solo `cantidadActual` mutable. Normalizar presentaciones al canónico por factor al ingresar.
- [ ] **AJUSTE idempotente:** `crearAjuste` no deduplica hoy → clave natural (usuario+motivo+minuto) + UNIQUE.
- [ ] **Stock compartido ME↔WH = flip COORDINADO (mismo cutover), nunca secuencial.** ME descuenta `STOCK_ZONAS`, WH repone; si una flipa y la otra no, el stock diverge en horas. Pre-flip: validar transitividad `Σ(pickups ME) ≈ Σ(ingresos WH por pickup)`; si hay gap, AJUSTE para alinear.

## 29. Modelo de catálogo (precisiones de DDL)

- [ ] **`tipo_producto` ENUM** (CANONICO/PRESENTACION/DERIVADO) calculado en el backfill + índice, en vez de recalcular en cada lectura.
- [ ] **Índices de escaneo:** `mos.productos(codigo_barra)` y `mos.equivalencias(codigo_barra) WHERE activo` — sin ellos el escaneo en WH/ME se vuelve lento.
- [ ] **Self-FK** `codigo_producto_base → productos(id_producto)` `ON DELETE RESTRICT` + índice; índice en `sku_base`.
- [ ] **Herencia de categoría:** desnormalizar `id_categoria` a presentaciones/derivados (o vista materializada) para no pagar el join en cada lectura (hoy `getCatalogoStockResumen` ~5-7s).
- [ ] **`factor_conversion numeric(10,4)` CHECK > 0**; documentar la fórmula de precio de presentación.
- [ ] **Cascada de estado:** al desactivar un canónico, desactivar sus presentaciones/derivados (trigger o lógica de app) — evita vender inactivos.
- [ ] **Regla WH en piedra:** WH solo canónicos (factor=1) + equivalentes activos; guías registran `codigoBarra` real, nunca `skuBase` → validación/CHECK.
- [ ] **ME/WH leen `mos.productos` directo** (decisión: sin copias locales `PRODUCTO_BASE`/`PRESENTACIONES`/`PRODUCTOS` de WH). Menos drift. Las copias actuales se retiran tras conectar el catálogo compartido.

## 30. Reglas financieras (precisiones)

- [ ] **Redondeo/tolerancia:** montos `numeric(12,2)`; reconciliación con tolerancia explícita (±0.01 por transacción) para absorber el float de Sheets y los splits MIXTO.
- [ ] **FormaPago = fuente de verdad del estado** (5 valores; anulación se detecta por FormaPago, no Estado_Envio) → enum + reconciliar por FormaPago. La doble escritura de cambios de FormaPago debe ser **inmediata** (no diferida) para no descuadrar el P&L. (`architecture_mos_formapago`)
- [ ] **POR_COBRAR debe ANULAR al cierre** (regla rígida ME): preservar; función Postgres que valide/no deje POR_COBRAR huérfano al cerrar. (`architecture_me_por_cobrar_anular`)
- [ ] **Cierre de caja atómico** (genera guía + cuadre + movimientos): función Postgres transaccional.
- [ ] **NubeFact write-back:** la venta vive en Postgres pero NubeFact (en GAS) actualiza `NF_Estado/NF_Hash/NF_Enlace` async → definir el camino de retorno (webhook/cron GAS → escribe a Postgres).
- [ ] **Liquidaciones:** histórico semanal inmutable una vez pagado (flag estado_pago; ediciones post-pago auditadas).

## 31. Secretos, auth y datos efímeros (precisiones)

- [ ] **Fase 1: secretos se migran TAL CUAL** (GAS sigue validando la clave 8 díg = global4 + personal4). **NO hashear todavía** — hay un cache de PINs en claro para verificación offline (`getAdminPinsCache`) que se rompería. El hasheo + RLS/JWT se diseñan juntos en **Fase 2**.
- [ ] **Rotación de PIN** (cron 30 d): se queda en GAS en Fase 1 (ya notifica). Atomicidad vía lock GAS; en Fase 2 evaluar función Postgres.
- [ ] **Verificación de dispositivo bloqueante** (`consultarEstadoDispositivo`/`registrarSesionDispositivo`): es el endpoint de arranque de las 3 apps. **No flipear su lectura temprano**; mantener autoridad en Sheets durante Fase 1, con timeout corto. Ante caída, **fail-safe de seguridad** (no permitir bypass), pero permitir operar con el último estado conocido.
- [ ] **Sistema de seguridad centralizado** (SEGURIDAD_ALERTAS, BLOQUEOS, HORARIOS + sus triggers de purga/revertir): triggers se quedan en GAS en Fase 1. Considerar consolidar `BLOQUEOS_USUARIO.unlockHasta` y `DISPOSITIVOS.Desbloqueo_Temporal_Hasta` (hoy dos fuentes) en el modelo Postgres.
- [ ] **Espía/RTC (RTC_SIGNALING, SDP/ICE):** **NO migrar** — datos efímeros TTL ~10 min, alta rotación, blobs ~15-45k. Se quedan en GAS (evitan ruido en Postgres). Audio/blobs en Drive.
- [ ] **PUSH_TOKENS sí migra** a `mos.push_tokens` (es dato); el ENVÍO FCM se queda en GAS.

## 32. Bridges e integraciones durante la transición

- [ ] **Los bridges siguen funcionando** porque llaman a ENDPOINTS GAS de la otra app (no a sus hojas), y esos endpoints ya hacen doble escritura. Mantener bridges sin cambios durante Fase 1.
- [ ] **Cuidado con lecturas cross-sheet directas por SS_ID** (`_abrirWhSheet`, lectura de PRODUCTOS_MASTER de MOS): esas SÍ leen Sheets directo → mientras MOS no flipe, deben seguir leyendo Sheets; el catálogo compartido en Postgres se consume por `_sb()` solo cuando el flag `USAR_CATALOGO_SUPABASE_<APP>` esté activo.
- [ ] **IMPRESORAS/ESTACIONES/SERIES** son catálogo compartido (se leen de MOS); PrintNode dispara desde GAS con el `printNodeId` (text, conservar formato). Evitar doble escritura asimétrica que cause IDs obsoletos.
- [ ] **`_validarClaveAdminViaMOS`** y `verificarPinEstacion`: validan contra maestras de MOS → migran con el catálogo compartido (temprano) para que ME/WH no queden desincronizados.
- [ ] **APISPeru (DNI/RUC):** su cache vive en `CLIENTES_FRECUENTES` → migra con esa tabla; evitar consultas duplicadas por desincronía.

## 33. Auditoría de datos PRE-backfill + backfill defensivo

> Edge cases del contenido real que rompen un backfill ingenuo. Correr una **auditoría de datos** antes de migrar y registrar hallazgos en una tabla `backfill_audit`.

- [ ] **JSON truncado (>50k chars en celda):** Sheets ya trunca (espía cap 45k). Escanear celdas jsonb (`historialCambios`, `items`, `payload_*`, `configJson`, `resultado`, SDP/ICE) → `JSON.parse` con try/catch; marcar VALIDO/TRUNCADO/PARSE_ERROR; resolver antes de migrar.
- [ ] **Filas huérfanas:** venta sin detalle / detalle sin cabecera / guía sin items → violan FK. Pre-auditar (`id NOT IN (...)`) y decidir skip o reparar (ME ya tiene `HUERFANA_LIMPIADA`).
- [ ] **Ceros a la izquierda ya perdidos** (celdas que nacieron sin formato `@`): validar por longitud esperada (DNI=8, RUC=11) y reportar sospechas; no asumir reparación automática.
- [ ] **Fechas mixtas** (Date nativo vs string vs texto): normalizar a ISO con TZ Lima; loguear formatos inesperados; guardar opcional `fecha_original` para debug.
- [ ] **Headers frágiles** (espacios/acentos/orden, `Nombre` vs `Nombre_RazonSocial`, `Documento`): mapeo header→columna con `trim`+normalización; validar 100% de headers vs schema antes de procesar filas.
- [ ] **NULL vs 0 vs '':** vacío→NULL, `0`→`0` numérico. Importa en montos/cantidades para reconciliación.
- [ ] **Booleanos legacy** (`'1'/'0'/1/0/'SI'/'NO'/''`) → mapeo central a boolean; enums numéricos (`Tipo_IGV` '1'/'2'/'3') como CHECK, no boolean.
- [ ] **Backfill defensivo:** siempre `JSON.parse` con try/catch (skip+log si falla), validar booleanos/FKs antes de insert, upsert idempotente.

## 34. Runbook de ejecución (cómo correrlo sin sorpresas)

> Entregable separado recomendado: `MIGRACION_RUNBOOK.md`. Resumen:

- [ ] **Orden y dependencias:** crear constraints UNIQUE **antes** de la doble escritura; **catálogo compartido en Fase 0** antes del backfill transaccional de ME/WH; ME/WH leen catálogo por bridge hasta que activen `USAR_CATALOGO_SUPABASE_<APP>`.
- [ ] **Staging:** un **2º proyecto Supabase Free** para validar DDL + backfill + rollback sin tocar prod; luego promover el DDL probado al Pro.
- [ ] **Dry-run del backfill:** parámetro `DRY_RUN_FILA_MAX` (p.ej. 1 día / 1000 filas), validar conteos/checksum en staging antes del full.
- [ ] **Canary del flip:** flag `CANARY_SUPABASE_DISPOSITIVOS = [deviceId…]` → esos dispositivos leen de Supabase; monitorear ~4 h; recién entonces flip global.
- [ ] **Ventanas (TZ Lima):** ME opera ~06:00–23:00; backfill de noche post-cierre (~23:05–00:30); WH pre-apertura (~04:00–05:00); catálogo ~02:00–03:00. Confirmar horarios reales en `Horarios.gs`.
- [ ] **Criterios de aborto:** `verificarCuadre` con drift>0 → **bloquea el flip** + alerta push; backfill que falla 3× → auto-aborta y registra. Flip global solo con **aprobación manual** tuya tras ver el cuadre.
- [ ] **Checklist pre-flight por app** (datos: cuadre 0 + últimas N filas presentes; código: flags correctos, `_sbPing`<200ms, 0 errores de fallback la última semana; rollback: snapshot a Drive + script probado <2 min; coordinación: WH/ME no flipan el mismo día salvo el cutover de stock).
- [ ] **Limpieza post-cutover:** doble escritura **se mantiene activa** hasta que las 3 apps estén estables; recién entonces apagar por app, y archivar hojas transaccionales a `99-Backups-Sheets/` (mantener maestras y plan C).
- [ ] **Métrica de drift (pseudocódigo):** excluir anuladas de forma consistente en ambos lados; comparar conteo + suma (con tolerancia) + checksum de IDs ordenados.

---

## 24. Bitácora de avance

| Fecha | App | Hito | Notas |
|-------|-----|------|-------|
| 2026-06-07 | — | Plan v1 creado | Documento maestro inicial |
| 2026-06-07 | — | Plan v2 | Integradas 5 pasadas senior: completitud de tablas, modelado (TZ/PK/correlativos/jsonb/bool), mecánica (backfill reanudable, idempotencia, updates/deletes, reconciliación), adversarial (rollback sin pérdida, fallback, flip coordinado, seguridad), operativa (crons, backups, DoD, roles TÚ/YO, RLS-ready, deploy) |
| 2026-06-07 | — | Plan v3 (§25–34) | +10 pasadas: fidelidad de forma de respuesta, escritura fuera del lock, cobertura completa de endpoints + multi-tabla atómicas, estrategia de stock (snapshot/movimientos/cutoff/flip coordinado), precisiones de catálogo (tipo_producto/índices/herencia/cascada), reglas financieras (tolerancia/FormaPago/POR_COBRAR/NubeFact), secretos sin hashear en Fase 1 + RTC se queda en GAS, bridges en transición, auditoría de datos pre-backfill (JSON truncado/huérfanas/ceros/fechas), runbook (staging/dry-run/canary/ventanas/abort/pre-flight/limpieza) |
| 2026-06-07 | — | FASE 0 · revisión senior exhaustiva (2 rondas + convergencia, 16 lentes) | Bugs corregidos: tipo_producto con factor=0→CANONICO; `_bfJson` garantiza objeto (no string→jsonb doble-encode); `_bfNum` respeta números; filtro PK no descarta '0'; lote 100 + guard payload 10M chars; **`dispositivos` agregado al backfill** (faltaba); `_sbPing` self-test en `backfill_audit` (no contamina cuadre); DELETE sin filtros bloqueado en `_sbOnce_`; Retry-After NaN→backoff; `verificarCuadre` usa header del PK robusto. Paridad SQL↔backfill: perfecta (10 tablas). node -c OK. **Convergencia: última ronda sin bugs nuevos (solo endurecimiento).** Listo para ejecutar. |
| 2026-06-07 | — | FASE 0 artefactos + revisión senior (4 lentes) | Creados `supabase/01_schema_compartido.sql`, `gas/Supabase.gs` (helper), `gas/MigracionCatalogo.gs` (backfill). node -c OK. Bugs corregidos en review: enum filtrado por schema, Retry-After case, _sbCount HEAD, _sbDelete con guard, _sbPing valida WRITE. Runbook §2 reescrito con pasos bloqueantes (Exposed schemas, SPREADSHEET_ID, dry-run de headers, archivos GAS). Pendiente: acción del usuario en consola Supabase. |
| 2026-06-07 | — | Diccionario + Runbook + correcciones v3.1 | Entregables creados. +10 pasadas de verificación contra código: **forma_pago RESUELTO** (EFECTIVO·POR_COBRAR·CREDITO·VIRTUAL·MIXTO string; YAPE/PLIN/etc son sub-tipos de VIRTUAL); **correlativos = UPDATE…RETURNING, NO SEQUENCE** (gaps SUNAT); **aplicarRespuestaJefa corregido** (PRODUCTOS_MASTER+presentaciones+HISTORIAL_PRECIOS, no GUIAS/STOCK); idempotencia = id_venta (ref_local es opcional/vacío); ventas_detalle necesita col `linea`; PK = id legacy; merge-duplicates exige UNIQUE; creditos +2 cols (Horas_TTL/Reasignaciones); JORNADAS estructura inferida (hoja compartida con MOS); ZONAS_CONFIG agregada (híbrida→vista); estado_caja +CERRADA_AUTO; catálogo compartido alineado a 9 maestras; free tier = inactividad. Diccionario ME verificado ~95%→correcto. |
