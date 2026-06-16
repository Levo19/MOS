# DISEÑO FASE 4 — Auth de dispositivos a 100% Supabase puro

> Diseño detallado para el cutover de la autenticación de dispositivos (3 apps) a sombra única `mos.dispositivos`, retirando GAS/hoja. Generado 2026-06-16. **No ejecuta nada** — es el plano para la sesión dedicada.
> Insumos: `INVENTARIO_lectores_dispositivos_fase4.md` (50 call-sites) · esquema `01_schema_compartido.sql` · RPCs `100_mos_auth_dispositivos.sql` · sync actual `Config.gs::_propagarDispositivoSombra`.

---

## 0. Estado actual (de dónde partimos)

- **Hoja DISPOSITIVOS (MOS)** = fuente de verdad. La sombra `mos.dispositivos` se alimenta de la hoja vía `_propagarDispositivoSombra` (Config.gs:1706) — pero ese sync **solo espeja al APROBAR** y solo 5 campos (`id_dispositivo/estado/app/nombre_equipo/ultima_conexion`). El resto de operaciones (bloquear, heartbeat, permisos, alertas…) **NO** llegan a la sombra.
- WH y ME ya **verifican auth directo contra la sombra** (`mos.verificar_dispositivo`) **con doble-check a GAS** — el doble-check existe JUSTAMENTE porque la sombra puede estar stale (el sync no cubre todo). MOS sigue 100% por GAS.
- RPCs auth ya construidas (SQL 100, anon, lockout, bcrypt): `registrar_dispositivo`, `verificar_dispositivo`, `aprobar_dispositivo`, `revocar_dispositivo`, `verificar_clave_admin`.

**Meta FASE 4:** la sombra es la **única** fuente de auth (lectura y escritura), sin GAS/hoja en el camino. Quitar el doble-check. Que el bloqueo de un device sea efectivo sin que el sync lo pise.

---

## 1. GAP de esquema (hoja vs sombra) — lo primero a cerrar

Columnas que la HOJA tiene y la sombra `mos.dispositivos` **NO** (los lectores las necesitan):

| Columna hoja | Usada por | Acción |
|---|---|---|
| **FCM_Token** | push, audio, espía (`_pushComandoDispositivo`, `forzarPushDispositivo`, espía) | **add column `fcm_token text`** (CRÍTICO — sin esto push/audio/espía se rompen) |
| **Alerta_Seguridad** / **Alerta_Seguridad_Revisada** | `alertarDispositivosInactivos2a7d`, `_marcarAlertaSegRevisadaPorDispositivo` | add `alerta_seguridad text`, `alerta_seguridad_revisada boolean` |
| **Forzar_Horario_Hasta** | Horarios.gs verificarHorario | add `forzar_horario_hasta timestamptz` |
| **Razon_Bloqueo** / **Bloqueado_Desde** | Bloqueos.gs (panel + auditoría) | add `razon_bloqueo text`, `bloqueado_desde timestamptz` |
| **Aprobado** (flag) | algunos paneles | Evaluar: probablemente redundante con `estado='ACTIVO'`. **Verificar en vivo** si algún lector lo lee separado; si no, NO migrar (derivar de estado). |

> El estado BLOQUEADO ya se puede representar en `estado` (la sombra ya tiene ACTIVO/SUSPENDIDO/etc.). Bloqueado/Razon/Desde se modelan como `estado='BLOQUEADO'` + `razon_bloqueo` + `bloqueado_desde`.

**Entregable Etapa A:** un SQL `101_mos_dispositivos_columnas_fase4.sql` con los `add column if not exists` (idempotente, INERTE — agregar columnas no cambia comportamiento).

---

## 2. Estrategia: DUAL-WRITE ampliado (NO invertir el sync)

El plan viejo decía "invertir sync sombra→hoja". **Se descarta** por la misma lección del rollback (dos syncs en direcciones opuestas se pisan) y porque el **dual-write ya probó ser robusto** en FASES 1-3. Patrón elegido:

> **La escritura de auth sigue por GAS→hoja (verdad) Y espeja a la sombra al instante (dual-write).** Los lectores migran a la sombra uno por uno. Cuando TODOS leen sombra → se quita el doble-check. Recién al final (4.2) se mueve la escritura a RPCs directas y se apaga GAS→hoja.

Ventaja: en ningún momento hay dos fuentes peleando. La hoja siempre tiene la verdad; la sombra es espejo fresco; los lectores migran sin downtime; todo reversible por flag.

---

## 3. Etapas (cada una INERTE hasta su flag; kill-switch en cada una)

### FASE 4.1 — Sombra siempre fresca + lecturas puras (quitar doble-check) — RIESGO MEDIO

**A. Completar esquema** (SQL 101) — add columns. INERTE.

**B. Ampliar el dual-write de auth en GAS.** Hoy `_propagarDispositivoSombra` solo cubre aprobar/5-campos. Crear `_dualWriteDispositivo(deviceId, patch)` que espeje a la sombra TODA mutación de la hoja, e invocarlo en las ~20 funciones R/W del inventario:
   - aprobar/rechazar/revocar/reactivar · crear/actualizar · bloquear/liberar · desbloquear-temporal/extender-horario · registrar-sesion/conexion (heartbeat) · registrar-permisos · forzar-wizard/push/reverify · alertas · cierre-nocturno (forzar_logout masivo).
   - Best-effort, byte-coherente, try/catch (igual que `_dualWriteMOS`). Mapea cada columna hoja→sombra (incl. las nuevas).

**C. Backfill inicial.** `resembrarDispositivosDesdeHoja()` una vez → sombra == hoja al 100% (arranca fresco). Comparador `compararDispositivosMOS()` (sombra vs hoja, como los otros semáforos).

**D. RPCs de lectura faltantes** (anon donde aplique, o service_role+token):
   - `mos.listar_dispositivos(p)` (paneles admin: filtros app/estado) · `mos.dispositivos_pendientes()` · `mos.dispositivos_bloqueados()`
   - `mos.consultar_estado_dispositivo(p)` (heartbeat panel — quizá ya cubierto por verificar_dispositivo)
   - `mos.fcm_token_dispositivo(p)` (push/audio/espía leen FCM)
   - `mos.verificar_horario_dispositivo(p)` (lee desbloqueo_temporal/forzar_horario)
   - GPS (`get_ubicaciones`) si aplica.

**E. Migrar lectores a la sombra, por categoría (orden de menor a mayor frecuencia/riesgo):**
   1. Paneles admin (getDispositivos/pendientes/bloqueados) — baja frecuencia, fácil rollback.
   2. Consumidores transversales (push/audio/espía/gps/horario) — leen FCM/flags.
   3. Heartbeat de estado (consultarEstadoDispositivo) — alta frecuencia.
   4. El gate de POST sensibles (`_gateDispositivoMOS`).
   Cada lector: gateado por flag `MOS_DISP_LECTURA` (maestro) + fallback a hoja si la RPC falla (igual patrón que FASE 1).

**F. Quitar el doble-check** en device-auth.js (las 3 apps). Con el dual-write ampliado la sombra está siempre fresca → la verificación directa-ACTIVO ya no necesita confirmar BLOQUEO contra GAS. **Validar primero** unos días que `compararDispositivosMOS()` da paridad sostenida.

> **Resultado 4.1:** las 3 apps LEEN auth 100% de la sombra; el bloqueo es efectivo al instante (el dual-write lo espeja); GAS sigue escribiendo (hoja+sombra). **El doble-check se va.** Limpieza de devices ya “pega”.

### FASE 4.2 — Escritura pura (retirar GAS del camino) — RIESGO ALTO

**G. Mover las escrituras de auth a RPCs directas** (registrar/aprobar/revocar ya existen; construir bloquear/liberar/heartbeat/permisos/etc. como RPCs). El frontend/admin llama la RPC directo; GAS deja de ser intermediario.

**H. Apagar la escritura GAS→hoja.** La hoja DISPOSITIVOS queda **archivada** (read-only de respaldo). Los lectores ya no la tocan (4.1) y los escritores tampoco (G).

**I. pg_cron de mantenimiento de seguridad** (no opcional): purga inactivos 7d, reversión de desbloqueos temporales vencidos, cancelar pendientes viejos, revertir extensiones de horario — hoy son triggers GAS (`setupTodoSeguridad`). Migrar a `cron.schedule` (como Fase E).

---

## 4. Seguridad (no relajar lo ya logrado)

- Las RPCs de **lectura** de paneles exigen token/claim admin (no anon) salvo `verificar_dispositivo` (anon, ya existe, fail-closed). `listar/pendientes/bloqueados` exponen toda la flota → **NO anon**.
- Aprobar/revocar/bloquear ya exigen `_validar_clave_admin_core` (bcrypt, lockout) — reusar, no duplicar.
- MOS = master-only para aprobar MOS (tier 3); WH/ME tier 2. Preservar.
- RLS en `mos.dispositivos`: hoy se accede por SECURITY DEFINER. Mantener; nunca exponer la tabla cruda a anon.
- **Rate-limit por IP** (riesgo residual del SQL 100): hoy lockout es por-device; un atacante con muchos UUIDs paraleliza. Acotar en 4.2 (cuota por IP en registrar/verificar).

---

## 5. Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| Migrar 50 lectores rompe uno y deja gente afuera | Flag maestro + fallback a hoja en CADA lector (rollback por flag, como FASE 1). Migrar por categoría, validar entre cada una. |
| FCM_Token no migrado → push/audio/espía mudos | Etapa A agrega `fcm_token`; Etapa B lo espeja; D expone RPC. Validar push antes de quitar doble-check. |
| Sombra stale en la ventana de transición | Dual-write ampliado (B) la mantiene fresca; comparador (C) la vigila; doble-check NO se quita hasta paridad sostenida. |
| Bloqueo de device no “pega” (lo pisa el sync) | Con dual-write (no sync inverso), el bloqueo se escribe a hoja+sombra a la vez; no hay sync que lo revierta. |
| Apagar GAS→hoja (4.2) y descubrir un lector olvidado | Hoja queda archivada (read-only); un lector olvidado leería dato viejo pero NO rompe; el comparador final (paridad 0) es el gate para apagar. |
| Auth lockout global por bug en RPC | Las RPCs ya nacen con kill-switch implícito (fallback a GAS mientras el flag de lectura esté en modo dual). |

---

## 6. Orden de ejecución + gates de validación

```
A. SQL 101 columnas            → INERTE (solo schema)
B. _dualWriteDispositivo en GAS → INERTE (espeja, no cambia lectura) · deploy
C. resembrar + comparador      → 🔴 correr compararDispositivosMOS() varios días → paridad sostenida
D. RPCs lectura                → INERTE (nadie las llama aún)
E. migrar lectores x categoría → flag MOS_DISP_LECTURA por categoría · 🔴 validar cada una
F. quitar doble-check          → 🔴 validar que las 3 apps entran · device blocks efectivos
   ── fin 4.1: lecturas puras ──
G. RPCs escritura + cablear    → dual-write→directo, módulo por módulo
H. apagar GAS→hoja             → 🔴 gate: comparador paridad 0 sostenida
I. pg_cron mantenimiento       → migrar triggers de seguridad
   ── fin 4.2: auth 100% puro ──
```

**Estimación de construcción (mi parte):** Etapa A (1 SQL corto) · B (~20 call-sites GAS, el grueso) · D (~6 RPCs) · G (~10 RPCs). Es la fase más grande del cierre — por eso “sesión dedicada”. Todo reversible por flag y validado con comparador antes de cada gate.

**Tu parte:** correr `compararDispositivosMOS()` unos días (C/H), validar físicamente que cada categoría de lector entra/funciona (E/F), aprobar el apagado de GAS→hoja (H).
