# Cutover de la AUTENTICACIÓN DE DISPOSITIVOS a 100% Supabase — DISEÑO (no implementar)

> Auditoría del flujo GAS actual + diseño de RPCs directas + caveats de hooks + plan por fases.
> Generado 2026-06-16. **SEGURIDAD CRÍTICA** (auth = quién entra a apps de dinero). Ejecutar con 40x adversarial por fase.
> Integra el diseño previo `DISENO_auth_dispositivos.md` (cache-first optimista + denylist). Este documento es el SUPERSET que lleva la fuente de verdad de la HOJA a Supabase.

---

## 0. Resumen ejecutivo (qué se puede y qué no)

**Se puede hacer 100% Supabase YA (el core de auth):** registrar / verificar / aprobar / revocar / reactivar dispositivos, todo directo a `mos.dispositivos`, sin GAS ni hoja en el camino. La pieza más sensible (validar clave admin con bcrypt) **ya existe** (`mos.verificar_clave_admin`, SQL 51) y la pieza de emisión de token (`mint-mos`) **ya lee `mos.dispositivos`**. El frontend ya tiene el plumbing anon-key (`_sbFetchTimeout`, `get_flags`) en `js/api.js`. El gap es: faltan 4 RPCs (registrar/verificar/aprobar/revocar) y re-cablear `device-auth.js` para que pegue a esas RPCs en vez de a GAS.

**NO se resuelve solo con las RPCs (requiere migración adicional o queda sin efecto):** los HOOKS que GAS dispara hoy alrededor de la auth — push de aprobación, alertas a `SEGURIDAD_ALERTAS`, purga 7d, reversión de desbloqueos/extensiones, y **los consumidores cruzados** (mint de WH/ME que leen la HOJA MOS, panel de dispositivos, bloqueo por usuario, espía/audio que joinean por `Ultima_Sesion`). Si la auth va directa pero la hoja deja de escribirse, **esos lectores se rompen** salvo que se migren o se mantenga la hoja sincronizada en sentido inverso.

**Decisión de fondo (gate de todo el cutover):** la HOJA `DISPOSITIVOS` hoy es leída por ~40 funciones en 3 apps. No se puede "apagar la hoja" de un día para otro. El cutover seguro es: **hacer de `mos.dispositivos` la fuente de escritura del core de auth, y mantener un sync `mos.dispositivos → HOJA` (inverso al actual)** mientras se migran los lectores cruzados uno por uno. Es el mismo aprendizaje que el cutover de escritura de módulos (memoria `architecture_mos_cutover_escritura_requiere_apagar_sync`): **escritura directa + sync en el MISMO sentido = pisado/duplicación**. Acá el sync debe invertirse, no apagarse de golpe.

---

## 1. Auditoría del flujo de auth GAS actual

### 1.1 Funciones core (registro / verificación / aprobación / revocación)

| Función | Ubicación | Gate hoy | Lee/Escribe | Hooks que dispara |
|---|---|---|---|---|
| `registrarSesionDispositivo` | `Config.gs:901` | **anon** (boot) | HOJA DISPOSITIVOS: crea row PENDIENTE_APROBACION en device nuevo; si existe, solo refresca `Ultima_Conexion` (heartbeat). MOS-app: NO crea PENDIENTE, solo refresca. | `_enviarPushTodos` (push a master, device MOS nuevo) · `_crearAlertaSeg('DISPOSITIVO_PENDIENTE_MOS'/'_PENDIENTE')` |
| `consultarEstadoDispositivo` | `Config.gs:1230` | **anon** (boot) | Lee Estado + flags (Forzar_Wizard/Logout/Push/ReVerify, Logout_Auto_Ts, Desbloqueo_Temporal_Hasta, Suspendido_Desde); escribe heartbeat `Ultima_Conexion`; limpia `Suspendido_Desde` si reaparece. Normaliza TS a ISO-UTC. | ninguno (read + heartbeat) |
| `aprobarDispositivoEnSitu` | `Config.gs:1766` | **clave admin 8díg** · MOS = **MASTER only** (`if esAppMOS && rol!=='MASTER'`), WH/ME = admin o master | HOJA: Estado→ACTIVO, Nombre_Equipo, App, Ultima_Conexion. Auditoría vía `verificarClaveAdmin`→AUDITORIA_ADMIN | `_notificarAprobacionDispositivo` (push admin) · `_propagarDispositivoSombra` (**upsert SÍNCRONO a `mos.dispositivos` + read-back** — v2.43.223) |
| `aprobarDispositivoPendiente` / `rechazarDispositivoPendiente` | `Config.gs:1587 / 1882` | admin (pre-verificado por front) | Estado→ACTIVO / soft-delete; LockService | push aprobación / — |
| `reactivarDispositivoSuspendido` | `SeguridadAlerts.gs:338` | **clave admin 8díg** (obligatoria desde v2.43.201) | HOJA: Estado→ACTIVO, Suspendido_Desde='', refresca Ultima_Conexion (evita re-suspensión esa noche) | `_propagarDispositivoSombra` (v2.43.224) |
| `revocarDispositivo` | `Config.gs:1476` | clave admin 8díg | HOJA: Estado→INACTIVO | ninguno (device ve INACTIVO en próximo heartbeat) |
| `_propagarDispositivoSombra` | `Config.gs:1706` | hook interno | **Upsert a `mos.dispositivos`** (id, estado, ultima_conexion, app, nombre_equipo, user_agent) + read-back ACTIVO. Cierra la ventana de 1h del sync horario para que `mint-mos` emita token al instante. | — |

**Composición del PIN admin (regla en piedra):** 8 dígitos = 4 GLOBAL (`CONFIG_MOS.ADMIN_GLOBAL_PIN`) + 4 PERSONAL (`PERSONAL_MASTER.pin`). Permite determinar **qué admin** autorizó → auditoría. Validador único `verificarClaveAdmin` (`Seguridad.gs:189`). Ya replicado en Supabase como `mos.verificar_clave_admin` (bcrypt, niveles cascada, auditoría única — SQL 51, INERTE).

### 1.2 Triggers instalados (`setupTodoSeguridad`, SeguridadAlerts.gs)

| Trigger | Handler | Schedule | Efecto sobre DISPOSITIVOS |
|---|---|---|---|
| Purga inactivos | `purgarDispositivosInactivos7d` | diario 23:15 | ACTIVO→SUSPENDIDO si Ultima_Conexion >7d; `_crearAlertaSeg` + push master |
| Alerta 2-7d | `alertarDispositivosInactivos2a7d` | diario 23:30 | escribe Inactivo_Alerta_Ts; alerta + push |
| Cancelar pendientes viejos | `cancelarPendientesAntiguos20h` | diario 23:45 | PENDIENTE>20h → CANCELADO_AUTO |
| Revertir desbloqueos | `revertirDesbloqueosVencidos` | cada 1h | si NOW>Desbloqueo_Temporal_Hasta → SUSPENDIDO + limpia campo |
| Revertir extensiones | `revertirExtensionesDiarias` | diario 0:00 | PERSONAL_MASTER.horarioCustom + CONFIG_HORARIOS_APPS (no DISPOSITIVOS directo) |
| Notif apertura | `procesarNotificacionesApertura` | cada 15min | lee aperturas, push |

### 1.3 Esquema de la HOJA DISPOSITIVOS (paridad con la sombra)

Columnas base + `_DISP_COLS_EXTRA` (`Config.gs:515`): `ID_Dispositivo, Nombre_Equipo, App, Estado, Ultima_Conexion, Ultima_Zona, Ultima_Estacion, Ultima_Sesion, Permisos_JSON, Permisos_LastUpdate, Forzar_Wizard, Suspendido_Desde, Forzar_Logout, Logout_Auto_Ts, Forzar_Push, Forzar_ReVerify, Inactivo_Alerta_Ts, Cancelado_Auto_Ts, Fecha_Caducidad, Desbloqueo_Temporal_Hasta`.

**Buena noticia:** `mos.dispositivos` (01_schema_compartido.sql:179) **ya tiene paridad casi total** — todas esas columnas existen (tipadas: timestamptz / boolean / jsonb), salvo **`Fecha_Caducidad` y `Desbloqueo_Temporal_Hasta`**, que NO están en la tabla sombra (son las 2 columnas "extendidas" que GAS auto-agrega a la hoja). **Hay que agregarlas a `mos.dispositivos` antes del cutover** (`fecha_caducidad timestamptz`, `desbloqueo_temporal_hasta timestamptz`). El resto migra 1:1.

### 1.4 Quién LEE la HOJA DISPOSITIVOS (lo que se rompe si deja de escribirse)

**Hot-path de auth (cross-app, CRÍTICO):**
- `warehouseMos/gas/Fase2AuthWH.gs:20` `mintSupabaseTokenWH` — lee la HOJA MOS para validar Estado=ACTIVO+App antes de mintear JWT WH.
- `MosExpress/gas/Fase2Auth.gs:373` `mintSupabaseToken` — idem para ME.
- `MosExpress/gas/Catalogo.gs:260,292` `verificarDispositivo` — bloquea boot ME + escribe heartbeat en la HOJA MOS.
- `Code.gs:42` `_gateDispositivoMOS` — gate de endpoints sensibles (setConfig, tarjeta WA).

> ⚠️ WH y ME **no tienen hoja propia**: leen la HOJA DISPOSITIVOS de MOS como fuente única. Pero **`mint-wh`/`mint-mos` (Edge) ya leen `mos.dispositivos`** — los `mintSupabaseToken*` de GAS son el camino VIEJO. Si la sombra es fresca, las Edges ya cubren el hot-path cross-app sin la hoja.

**Cold-path (paneles / mantenimiento / features):**
- `Config.gs:625` `getDispositivos` + `1220` `getDispositivosPendientes` — paneles admin.
- `Bloqueos.gs:442/539/637` — bloqueo/desbloqueo masivo por usuario (joinea por `Ultima_Sesion`).
- `Audio.gs:65` `_pushComandoDispositivo`, `EspiaWebRTC.gs:324` — comandos/espía (joinean por `Ultima_Sesion`).
- `Gps.gs:105`, `Horarios.gs:482`, `Liquidaciones.gs:1892` (cierre nocturno → Forzar_Logout), `Evaluaciones.gs:1605` (heartbeat impresoras).

---

## 2. Diseño de las RPCs Supabase (100% directo)

> Convención del proyecto (obligatoria): `security definer` + `set search_path = ''` + revoke public + grants explícitos + fail-closed. Funciones que tocan `extensions.crypt`/`gen_salt` deben calificarlas (`extensions.`). Toda tabla nueva post-04 necesita `enable row level security` explícito (regla de la memoria de roles). `mos.dispositivos` ya tiene RLS.

### 2.1 `mos.registrar_dispositivo(p jsonb)` — anon-callable (pre-auth)

Reemplaza `registrarSesionDispositivo`. El device aún no tiene token (igual que `mint-mos`), así que es **anon, sin gate de claim**.

- **Entrada:** `{ id_dispositivo, app, user_agent, nombre_equipo? }`.
- **Lógica:** `insert ... on conflict (id_dispositivo) do update set ultima_conexion=now(), user_agent=...` — **idempotente**. Si la fila es nueva → `estado='PENDIENTE_APROBACION'` (salvo `app='MOS'`, que NO se auto-crea PENDIENTE, igual que GAS: el master MOS se aprueba in-situ). Si ya existe → solo refresca `ultima_conexion`; **NO sobrescribe `estado`** (un device ACTIVO/INACTIVO no se "re-pendientea" por reconectar). Caso CANCELADO_AUTO→PENDIENTE al reconectar = explícito.
- **Devuelve:** `{ ok, estado, autorizado, ... }` (shape que el front ya espera de `_consultarBackend`).
- **Gate:** anon. **Search_path=''**, security definer (anon no tiene grant de tabla).
- **Rate-limit / anti-spam (CRÍTICO, es anon-callable):**
  1. Validación estricta de `id_dispositivo` (formato UUID/longitud acotada) → rechaza basura.
  2. **Cuota de devices PENDIENTE por ventana**: contar `where estado='PENDIENTE_APROBACION' and ultima_conexion > now()-interval '1 hour'`; si supera N (p.ej. 20) → no crear más PENDIENTE nuevos (devolver genérico). Evita que un atacante infle la tabla con miles de filas pendientes (DoS de almacenamiento + ruido en el panel del admin).
  3. Respuesta **genérica** ante cualquier fallo (anti-enumeración, igual que mint-mos).
  4. `insert on conflict` = no duplica aunque el front reintente (idempotencia real por PK).
- **Auditoría:** registro PENDIENTE no necesita auditoría admin (no hubo acción privilegiada); opcional log ligero.

### 2.2 `mos.verificar_dispositivo(p jsonb)` — anon-callable (boot)

Reemplaza `consultarEstadoDispositivo`. Boot + heartbeat.

- **Entrada:** `{ id_dispositivo, app }`.
- **Lógica:** lee la fila; **escribe heartbeat** `ultima_conexion=now()`; limpia `suspendido_desde` si reapareció (igual que GAS). Devuelve `estado` + flags (`forzar_wizard, forzar_logout, forzar_push, forzar_reverify, logout_auto_ts, desbloqueo_temporal_hasta, suspendido_desde`) + `verify_version` + `fecha_hoy_lima`.
- **`verify_version`**: hoy GAS lo sirve para invalidar cache de flota. En Supabase = una clave en `mos.config` (`DEVICE_VERIFY_VERSION`) leída por esta RPC. Bumpearla fuerza re-verify de toda la flota (kill global de cache). **Integra con la denylist** (ver §3.3).
- **Gate:** anon. Fail-closed: si el device no existe → `estado='NO_REGISTRADO'` (no error que enumere). Si la RPC falla → el front cae a su cache (fail-soft) **pero la denylist server lo puede revocar igual** (§3.3).
- **Idempotencia:** el heartbeat es idempotente por naturaleza (set now()).

### 2.3 `mos.aprobar_dispositivo(p jsonb)` — clave admin (REUSA verificar_clave_admin)

Reemplaza `aprobarDispositivoEnSitu`. **Esta es la RPC más sensible.**

- **Entrada:** `{ id_dispositivo, clave_admin, app, nombre_equipo?, es_reactivar? }`.
- **Lógica (server-side, en una sola RPC, atómica):**
  1. **Llamar `mos.verificar_clave_admin(p_clave := clave_admin, p_accion := 'APROBAR_DISPOSITIVO_INSITU_MOS' | 'APROBAR_DISPOSITIVO', p_app, p_device := id_dispositivo, ...)`** — bcrypt + niveles cascada + auditoría única, SERVER-SIDE. La clave **nunca** se compara en el cliente.
  2. Solo si `autorizado=true` → `update mos.dispositivos set estado='ACTIVO', nombre_equipo=coalesce(...), suspendido_desde=null, ultima_conexion=now() where id_dispositivo=...`.
  3. **Eco del deviceId** aprobado en la respuesta (`{ aprobado_por, device_id, estado:'ACTIVO' }`) — defensa contra desfase (el front confirma que activó el id correcto, igual que el read-back actual).
  4. **Nivel de la acción (cascada):** `APROBAR_DISPOSITIVO_INSITU_MOS` está marcada **master-only** en `mos.permisos_accion` (SQL 50, memoria roles). `verificar_clave_admin` ya rechaza admin<master con `NIVEL_INSUFICIENTE` → **se preserva la regla MOS=MASTER-only** sin lógica nueva. WH/ME usan `APROBAR_DISPOSITIVO` (admin OK).
- **Gate (CHICKEN-AND-EGG — caveat central):** `verificar_clave_admin` hoy está gateada por `wh._claim_ok() OR mos._claim_ok()`, que **exige un JWT** (claim app). Pero el device que se aprueba in-situ puede ser:
  - **MOS (master):** se aprueba a sí mismo. El navegador del master **ya tiene token** si su propio device está ACTIVO. Pero el **primer** device MOS (bootstrap) NO tiene token → no puede llamar una RPC gateada por claim. **Solución:** `aprobar_dispositivo` debe ser **anon-callable** (como mint-mos), y mover el control de acceso ADENTRO: la seguridad real es la **clave admin bcrypt** (8 díg), no el claim del token. El claim del JWT no aporta seguridad acá (cualquiera con anon-key puede pedir token de un device ACTIVO de todos modos). → **Diseño: `aprobar_dispositivo` = anon-callable; la única barrera es `verificar_clave_admin` server-side.** Para que esa llamada interna funcione bajo una RPC anon, `verificar_clave_admin` se invoca como `security definer` desde dentro de `aprobar_dispositivo` (que también es definer) → el gate `_claim_ok()` se evalúa con el contexto del invocador anon = **false** → bloquearía. **Por eso `aprobar_dispositivo` NO debe llamar la RPC gateada tal cual**; debe **factorizar la lógica de validación de clave en una función interna sin gate de claim** (`mos._validar_clave_admin_core(...)`) que ambas RPCs usen, y dejar `verificar_clave_admin` (la gateada) como wrapper para los llamadores con token. Así la validación bcrypt + auditoría se reusa SIN el gate de claim que rompería el bootstrap anon.
  - **Trade-off de seguridad de esto:** hacer `aprobar_dispositivo` anon expone la **superficie de fuerza-bruta del PIN de 8 díg** a internet (10^8 combinaciones, pero bcrypt es lento). **Mitigación obligatoria:** (a) rate-limit por `id_dispositivo` e IP (contar intentos fallidos en una tabla `mos.auth_intentos`, lock exponencial tras 5 fallos); (b) la auditoría única ya registra cada intento; (c) considerar exigir que el `id_dispositivo` a aprobar **exista en estado PENDIENTE/SUSPENDIDO** (no se puede aprobar un id arbitrario inventado → reduce el espacio). Esto es **estrictamente igual o mejor** que hoy: el endpoint GAS `aprobarDispositivoEnSitu` ya es anon (sin gate de claim) y solo protegido por la clave. No se degrada; se endurece con rate-limit.
- **`es_reactivar=true`** → ruta `reactivarDispositivoSuspendido` (acción `REACTIVAR_DISPOSITIVO`, admin OK; SUSPENDIDO→ACTIVO + refresca ultima_conexion para no re-suspender esa noche).
- **Search_path='', security definer, fail-closed.**

### 2.4 `mos.revocar_dispositivo(p jsonb)` — clave admin

Reemplaza `revocarDispositivo`. Master pone INACTIVO/SUSPENDIDO.

- **Entrada:** `{ id_dispositivo, clave_admin, app, nuevo_estado:'INACTIVO'|'SUSPENDIDO' }`.
- **Lógica:** `_validar_clave_admin_core(... p_accion:='REVOCAR_DISPOSITIVO')` (master-only en catálogo) → `update estado=nuevo_estado`. Auditoría.
- **Integra denylist (§3.3):** además del UPDATE, **agregar el id a la denylist de `get_flags`** (o derivarla por query) para revocación ≤2min de la flota, sin esperar al heartbeat de 1h.
- **Gate:** este SÍ puede exigir token (el admin que revoca opera desde un device ACTIVO con JWT) → `verificar_clave_admin` gateada normal. Pero por consistencia y para el caso "revocar desde un panel sin token", también puede ser anon + clave (mismo patrón que aprobar). Recomendado: **anon + clave-admin** (homogéneo), con rate-limit.

### 2.5 Funciones internas / soporte

- `mos._validar_clave_admin_core(...)` — extrae el cuerpo de `verificar_clave_admin` SIN el gate `_claim_ok()`, reusable por las RPCs anon. `verificar_clave_admin` pasa a ser wrapper `(claim_ok? core : APP_NO_AUTORIZADA)`. **Cero cambio de comportamiento para los llamadores actuales con token.**
- Tabla `mos.auth_intentos(id_dispositivo, ip, ts, ok)` + índice — para rate-limit de aprobación. RLS habilitada, sin grants a anon (solo las RPCs definer la tocan).
- Extender `mos.config` con `DEVICE_VERIFY_VERSION` y la denylist (ver §3).
- `alter table mos.dispositivos add column fecha_caducidad timestamptz, add column desbloqueo_temporal_hasta timestamptz` (paridad de schema).

### 2.6 Tabla-resumen de gates

| RPC | Anon-callable | Barrera real | Rate-limit | Auditoría | Reusa verificar_clave_admin |
|---|---|---|---|---|---|
| `registrar_dispositivo` | sí | formato + cuota PENDIENTE | cuota/hora | no (registro) | no |
| `verificar_dispositivo` | sí | — (read + heartbeat) | natural (idempotente) | no | no |
| `aprobar_dispositivo` | sí (bootstrap) | **clave admin bcrypt** + device debe existir PENDIENTE/SUSPENDIDO | intentos/device+IP | sí (única) | sí (core) |
| `revocar_dispositivo` | sí | clave admin bcrypt (master-only) | intentos/device+IP | sí (única) | sí (core) |

---

## 3. Consumo desde las 3 apps (device-auth.js) + cache-first + denylist

`assets/auth/device-auth.js` (`window.DeviceAuth`, v1.0.14) es compartido por las 3 apps. Hoy `_consultarBackend` (línea 800) pega a `mosGasUrl?action=registrarSesionDispositivo`. El cutover:

### 3.1 Re-cableo a RPC directa
- `init()` recibe además `sbUrl` + `sbAnon` (ya hay `mintUrl`/`sbAnon` para el read-back in-situ — se reusa).
- `_consultarBackend` → `POST {sbUrl}/rest/v1/rpc/verificar_dispositivo` con headers `apikey:sbAnon, Accept-Profile:mos, Content-Profile:mos`, body `{ p:{ id_dispositivo, app } }`. Es **anon, igual que `get_flags` ya hace en api.js:104** (patrón ya probado). Idéntico mapeo de respuesta (estado/flags/verifyVersion).
- El primer registro (device nuevo) → `rpc/registrar_dispositivo`.
- In-situ (`_confirmarInSitu`, línea 625) → `rpc/aprobar_dispositivo` con `{ p:{ id_dispositivo, clave_admin, app, nombre_equipo, es_reactivar } }`. **El read-back `_confirmarMintListo` (línea 595) ya valida contra mint-mos** → se conserva tal cual (confirma que la sombra quedó ACTIVA y emite token). Coherencia perfecta: la RPC escribe `mos.dispositivos`, mint-mos lee `mos.dispositivos`, mismo dato.
- **Fallback durante transición:** detrás de un flag (p.ej. `DEVICE_AUTH_DIRECTO` en get_flags, default '0') — si la RPC falla, caer al GAS actual (igual que el patrón `WH_AUTH_DIRECTO` de la memoria de roles). Permite kill-switch instantáneo de flota.

### 3.2 Cache-first optimista (del diseño previo, ahora sobre fuente directa)
El diseño previo (`DISENO_auth_dispositivos.md` §Arquitectura 1) ya define: si cache fresco + deviceId coincide → `onAuth()` inmediato + re-verify en background (sin overlay). Sobre RPC directa esto es **aún mejor**: la re-verify de background es un POST anon a `verificar_dispositivo` (rápido, sin cold-start de GAS de 5-8s). El boot deja de depender del cold-start de Apps Script → boot instantáneo real. TTL día-Lima + techo configurable.

### 3.3 Denylist + verify_version (revocación rápida) — INTEGRACIÓN
El diseño previo (Opción A) extiende `mos.get_flags()` con `dispositivos_revocados[]` + `verify_version`. **Sobre el cutover directo esto es la pieza de seguridad que sustituye al heartbeat lento de GAS:**
- `mos.get_flags()` (ya anon, refresco ~2min en las 3 apps) agrega: `device_verify_version` (de `mos.config`) y `dispositivos_revocados` (= `select id_dispositivo from mos.dispositivos where estado in ('INACTIVO','SUSPENDIDO') and ultima_conexion > now()-interval '30 days'` — acotado, UUIDs opacos sin PII, ok servir por flags).
- El front, en cada refresco de flags + `visibilitychange`, chequea **su propio UUID** contra `dispositivos_revocados`; si está → cierra la app en caliente (fail-closed). Revocación ≤2min sin esperar el heartbeat horario.
- **Fail-safe (40x):** get_flags caído ≠ puerta abierta → se conserva último flags bueno; el heartbeat de `verificar_dispositivo` es el backstop. Un UUID en la denylist bloquea **aunque el cache local diga ACTIVO**. Bump de `device_verify_version` invalida cache de toda la flota.
- **No reemplaza `verificar_dispositivo`**, lo complementa: denylist = revocación rápida push-like; verificar_dispositivo = verdad completa (estado + flags + heartbeat).

---

## 4. Caveats de los HOOKS (qué se migra, qué queda, qué se pierde)

> **Honestidad senior:** el core (registrar/verificar/aprobar/revocar) va 100% Supabase YA. Los hooks NO corren solos en Supabase. Cada uno necesita una decisión.

| Hook GAS (hoy) | Qué hace | Opción Supabase | Si NO se migra |
|---|---|---|---|
| **Push de aprobación** (`_notificarAprobacionDispositivo`) | FCM push "✅ aprobado" a admins | **Edge Function** invocada por la RPC (pg_net → Edge → FCM), o **el front muestra el éxito local** (toast+sonido, ya existe en device-auth.js). | El admin NO recibe push, pero el device aprobado **sí entra** (el éxito es local). Pérdida menor (cosmética). **Recomendado: front-only al inicio**, Edge después. |
| **Alertas `SEGURIDAD_ALERTAS`** (device pendiente avisa al admin) | row en hoja + push master | `mos.registrar_dispositivo` hace `insert into mos.seguridad_alertas` (**la tabla YA existe**, 04_schema_mos.sql:192) → el panel admin la lee directo por RPC. Push opcional vía Edge. | El admin **no se entera** de un device pendiente salvo que abra el panel y lo vea en la lista de PENDIENTES (que sí existe). Aceptable si el panel de pendientes se migra (§4 paneles). **Recomendado: escribir la alerta en la tabla Supabase desde la RPC** (barato, sin Edge). |
| **Purga 7d** (`purgarDispositivosInactivos7d`, trigger diario) | ACTIVO→SUSPENDIDO si >7d inactivo | **pg_cron** (ya hay precedente: `mos_cron_nocturno.sql` SQL 97, `wh_cron_nocturno` SQL 72). Función `mos.purgar_dispositivos_inactivos()` agendada diaria. | Devices inactivos **nunca se auto-suspenden** → la flota acumula ACTIVOS viejos (riesgo: un device perdido sigue ACTIVO indefinidamente). **Debe migrarse a pg_cron** — es seguridad, no cosmética. |
| **Reversión desbloqueos** (`revertirDesbloqueosVencidos`, 1h) | si NOW>desbloqueo_temporal_hasta → SUSPENDIDO | pg_cron horario sobre `mos.dispositivos.desbloqueo_temporal_hasta` (tras agregar la columna §2.5). | Un desbloqueo temporal **nunca expira** → device queda ACTIVO fuera de horario. Riesgo de seguridad. Migrar a pg_cron. |
| **Reversión extensiones horario** (`revertirExtensionesDiarias`, 0:00) | revierte horarioCustom/CONFIG_HORARIOS_APPS | Esto NO toca `mos.dispositivos` (toca personal/horarios). **Queda en GAS** — fuera del scope de auth-de-dispositivos. | Sin efecto sobre el cutover de auth (es de horarios, otro dominio). |
| **Cancelar pendientes >20h** (`cancelarPendientesAntiguos20h`, diario) | PENDIENTE>20h → CANCELADO_AUTO | pg_cron + complementa el anti-spam de `registrar_dispositivo`. | La tabla acumula PENDIENTES viejos (ruido en panel). Migrar a pg_cron (barato). |
| **`permisos_json`** | permisos cámara/mic por device | **Ya está en `mos.dispositivos.permisos_json` (jsonb)** + `registrarPermisosDispositivo` puede ser una RPC anon trivial. | Si no se porta esa RPC, los permisos no se persisten directo (siguen por GAS). No bloquea auth. |
| **Columnas extendidas** (Fecha_Caducidad, Desbloqueo_Temporal_Hasta) | expiración/desbloqueo temporal | **Agregar a `mos.dispositivos`** (§2.5). El resto de columnas ya existen. | Sin estas 2, las features de caducidad/desbloqueo temporal no funcionan directo. |
| **Mint cross-app WH/ME** (`mintSupabaseTokenWH`, `mintSupabaseToken`, `verificarDispositivo` ME que leen la HOJA MOS) | validan device contra la HOJA | **Las Edges `mint-wh`/`mint-mos` ya leen `mos.dispositivos`**. Si la sombra es la fuente fresca, el hot-path cross-app **ya está cubierto** por las Edges; los `mintSupabaseToken*` de GAS quedan como fallback legacy. | Si la HOJA deja de escribirse Y WH/ME siguen usando el camino GAS-lee-hoja, se rompen. **Por eso WH/ME deben mintear SOLO por Edge** (verificar que ya lo hacen; la memoria de migración dice mint-wh está activo). |
| **Paneles GAS que leen la HOJA** (`getDispositivos`, `getDispositivosPendientes`, Bloqueos, Espía/Audio por `Ultima_Sesion`) | listas admin, bloqueo por usuario, comandos | Migrar lecturas a RPC de lectura sobre `mos.dispositivos` (patrón `catalogo_wh_rls`). Bloqueo/espía joinean por `Ultima_Sesion` → debe poblarse en la sombra (la columna existe). | **Quedan rotos o leen datos viejos** si la hoja deja de escribirse. Estos son la razón del **sync inverso** (§5): mantener la hoja sincronizada DESDE Supabase hasta migrar cada panel. |

**Veredicto de hooks:** **2 se pueden dejar front-only/diferir** (push aprobación), **1 va a tabla Supabase directo barato** (alertas SEGURIDAD_ALERTAS), **3 DEBEN ir a pg_cron por seguridad** (purga 7d, reversión desbloqueos, cancelar pendientes), **los paneles/bloqueo/espía requieren sync inverso + migración gradual de lectores**.

---

## 5. Plan por fases (core primero, hooks después) con gates de seguridad

### Fase A — Cimientos en Supabase (cero impacto, INERTE)
1. `alter table mos.dispositivos add fecha_caducidad, desbloqueo_temporal_hasta`.
2. Crear `mos._validar_clave_admin_core` (factorizar de verificar_clave_admin SIN gate de claim); convertir `verificar_clave_admin` en wrapper (cero cambio para llamadores con token).
3. Crear las 4 RPCs (`registrar_/verificar_/aprobar_/revocar_dispositivo`), `mos.auth_intentos` (RLS on), seed `DEVICE_VERIFY_VERSION`.
4. **40x:** search_path='', grants (anon solo en las 4 RPCs + get_flags; tabla sin grant directo), fail-closed, rate-limit probado, RLS en tablas nuevas, paridad de campos vs GAS, auditoría única no duplica, no enumera (respuestas genéricas).
5. **Gate:** todo INERTE — nadie lo llama (flag `DEVICE_AUTH_DIRECTO='0'`).

### Fase B — Sync INVERSO (la hoja deja de ser maestra, sin romper lectores)
1. **Invertir el sync:** hoy GAS escribe la hoja y un trigger la copia a la sombra. Cambiar a: **Supabase es maestra de auth; un sync `mos.dispositivos → HOJA`** (job GAS o pg→GAS) mantiene la hoja fresca para los ~40 lectores cross-app que aún la usan.
2. **Apagar el sync viejo HOJA→sombra** de las columnas de auth (mismo principio que `architecture_mos_cutover_escritura_requiere_apagar_sync`: no pueden coexistir los dos sentidos o se pisan).
3. **Gate (40x):** verificar que WH/ME mintean SOLO por Edge (no por `mintSupabaseToken*`-lee-hoja). Confirmar `Ultima_Sesion`/`Ultima_Zona` se pueblan en la sombra (espía/bloqueo dependen). Cuadre hoja↔sombra antes de invertir.

### Fase C — Cutover del core (flip de flota)
1. Re-cablear `device-auth.js`: `verificar_dispositivo` / `registrar_dispositivo` / `aprobar_dispositivo` directo (anon-key), **detrás de `DEVICE_AUTH_DIRECTO`** (default '0') con fallback a GAS.
2. Cache-first optimista + denylist en get_flags (§3.2/3.3) — **van JUNTAS** (cache largo sin denylist = ventana de revocación ancha; gate del diseño previo).
3. **Flip:** `DEVICE_AUTH_DIRECTO='1'` (piloto por device vía localStorage → luego flota vía get_flags). Kill-switch: poner '0'.
4. **40x:** revocación ≤2min funciona (denylist), bootstrap del primer device MOS (anon aprobar) funciona, rate-limit de PIN aguanta fuerza bruta, fail-soft offline honra cache, in-situ + read-back mint-mos coherente, NO se puede aprobar un id arbitrario inventado.

### Fase D — Hooks
1. **pg_cron (seguridad, prioritario):** purga 7d, reversión desbloqueos, cancelar pendientes. Patrón SQL 97/72.
2. **Alertas SEGURIDAD_ALERTAS** directo desde `registrar_dispositivo` (tabla ya existe) + panel admin lee por RPC.
3. **Push de aprobación:** front-only al inicio; Edge (pg_net→FCM) opcional después.
4. **Migrar lectores cold-path** (paneles, bloqueo, espía) a RPC de lectura sobre la sombra, uno por uno → cuando el último deje de leer la HOJA, **retirar el sync inverso** y la hoja queda muerta (catálogo-lectura, como el resto de la migración MOS).

### Riesgos de fondo (honestidad)
- **Auth = quién entra a apps de dinero.** Un bug en `aprobar_dispositivo`/`verificar_dispositivo` = acceso indebido o lockout de flota. De ahí el flag + fallback + 40x por fase.
- **`aprobar_dispositivo` anon** expone el PIN a fuerza bruta de internet (no peor que hoy, pero ahora medible) → rate-limit + lockout exponencial **no es opcional**.
- **El sync inverso es el verdadero trabajo:** el core son 4 RPCs, pero los ~40 lectores cross-app de la HOJA son la masa. Subestimarlos = romper WH/ME/espía/bloqueo. El cutover "100% sin hoja" es el **final** de la Fase D, no el principio.
- **No apagar el sync en el sentido viejo y prender el nuevo a la vez sin tx/orden** repite el bug documentado de pisado/duplicación.

---

## 6. Archivos clave (referencia)
- Core GAS: `gas/Config.gs` (registrarSesionDispositivo 901, consultarEstadoDispositivo 1230, aprobarDispositivoEnSitu 1766, revocarDispositivo 1476, _propagarDispositivoSombra 1706) · `gas/SeguridadAlerts.gs` (reactivar 338, triggers 145+, _crearAlertaSeg 58) · `gas/Code.gs` (router + _gateDispositivoMOS 42) · `gas/Seguridad.gs` (verificarClaveAdmin 189).
- Cross-app lectores HOJA: `warehouseMos/gas/Fase2AuthWH.gs:20` · `MosExpress/gas/Fase2Auth.gs:373` + `Catalogo.gs:260` · `gas/Bloqueos.gs:442` · `gas/Audio.gs:65` · `gas/EspiaWebRTC.gs:324`.
- Supabase existente: `supabase/01_schema_compartido.sql:179` (mos.dispositivos) · `74_mos_claim_ok_f0a.sql` (gate) · `51_mos_verificar_clave_admin.sql` (bcrypt+auditoría) · `95_mos_get_flags.sql` (flags anon) · `functions/mint-mos/index.ts` (valida device, emite JWT).
- Frontend: `assets/auth/device-auth.js` (boot 764, in-situ 625, read-back mint 595, heartbeat) · `js/api.js` (anon-key 86, get_flags 104, mint 163).
