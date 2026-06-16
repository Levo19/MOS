# Rediseño Auth/Aprobación de Dispositivos — Ecosistema MOS (DISEÑO, sin implementar)

> Auditoría + arquitectura + mockups + plan por fases. Generado 2026-06-16. Ejecutar con 40x por fase.

## Hallazgo central
Las 3 apps YA comparten **un solo módulo** `assets/auth/device-auth.js` (servido desde levo19.github.io/MOS, `window.DeviceAuth`) = ya es DRY. Pero cada app conserva lógica inline duplicada/muerta + pins `?v=` mentirosos. **El sistema NO está roto en seguridad** (doble-gate Sheet+sombra, heartbeat, fail-closed). Está **lento al boot** (cache no-optimista) y **fragmentado**.

## Auditoría por app
| Dimensión | MOS | WH | ME |
|---|---|---|---|
| device-auth compartido | Sí (fuente, 1.0.14) | Sí, pin ?v=1.0.12 mentiroso | Sí, pin 1.0.12 mentiroso |
| deviceId resiliente | 3 stores (LS+IDB+Cache) | delega al módulo | módulo + cookie 2a + IDB |
| Endpoint boot | MOS GAS | **MOS GAS** | **MOS GAS** |
| Aprobación→sombra | Sí (read-back) | delega a MOS | delega a MOS |
| Duplicados/muertos | reactivar_LEGACY (Config.gs:1914) | **modal in-situ huérfano app.js:1877-2051** | **bloque if(false) 1405-1527 + _verificarDispositivoRed_LEGACY:8454** |
| Cache TTL | día-Lima (no optimista) | día-Lima | **12h hardcodeada (comentario "<1h" MENTIROSO) → revocación ~1h** |
| Revocación rápida | No (heartbeat 10min) | No (10min) | No (re-verify 1h) |

## CAUSA RAÍZ de la lentitud (device-auth.js:764-789)
El cache EXISTE pero NO autoriza optimista: *"siempre verificamos server PRIMERO antes de quitar pre-block"* → el overlay "Verificando" se mantiene hasta el round-trip a MOS GAS (cold-start 5-8s) + resolver deviceId (race 3 stores hasta 3s). ME ya parchó con cache-first 12h pero POR FUERA del módulo, con TTL divergente.

## Arquitectura diseñada
1. **Cache-first optimista** (boot instantáneo): si cache fresco + deviceId coincide → `onAuth()` inmediato + re-verify en BACKGROUND (sin overlay). Si background revoca → cierra app en caliente. Marca de cache en los 3 stores. TTL día-Lima + techo absoluto 8-12h configurable por init() (no hardcode).
2. **Revocación distribuida (denylist)**:
   - **Opción A (recomendada arrancar):** extender `mos.get_flags()` (ya existe, refresco ~2min, lo leen las 3 apps) con `dispositivos_revocados[]` + `verify_version`. Front chequea su UUID en cada refresco + visibilitychange → bloqueo ≤2min. Costo cero. Fail-safe: endpoint caído ≠ puerta abierta.
   - **Opción B (futuro óptimo):** Supabase Realtime suscrito a mos.dispositivos filtrado por UUID → revocación instantánea (push). Requiere sbAnon en 3 apps + reconexión.
3. **Escrituras de estado en background** (ultima_conexion/permisos/wizard nunca bloquean boot). Excepción: propagación a sombra en aprobación in-situ (con read-back) sí es síncrona (la confirmación depende).
4. **Centralización total**: migrar lógica inline de WH/ME al módulo, borrar duplicados/muertos, versionado honesto (DeviceAuth.VERSION logueado al boot), init() unifica TTL/heartbeat/modo-revocación/animaciones.

## Mockups UX (flujo moderno) — reglas: sin nativos, triple feedback (sonoro WebAudio iOS-safe + visual + háptico vibrate), no dvh, prefers-reduced-motion, transiciones
- **Estado 0** boot cache-fresco (99%): SIN overlay, app instantánea + chip discreto "verificando en segundo plano" que fade-out 1.5s.
- **Estado 1** boot sin cache: overlay "Verificando" spinner + dots pulse + watchdog 10s (no cuelga).
- **Estado 2** no autorizado: 🔒 + UUID visible/copiable (tap=copiar+✓+vibrate+tick) + "Activar aquí" + polling 15s (aprobación remota auto-detecta).
- **Estado 3** modal in-situ: nombre equipo + **clave 8 casillas OTP** (auto-avanza, inputmode numeric, auto-submit) + submit optimista; clave mala → shake rojo + vibrate([30,40,30]) + buzz; defensa echo-deviceId.
- **Estado 4** revocado/fail-closed: ⛔ shake + vibrate([50,30,50]) + tono grave; no deja ver la app.
- **Estado 5** éxito: check SVG que se traza (stroke) + vibrate(40) + acorde ascendente "ta-da" + transición fade-out overlay/fade-in app (sin reload duro si fue in-situ).

## Plan por fases (seguro→sensible, cada una con 40x)
- **Fase 0** (cero riesgo): bump ?v= real en WH/ME + DeviceAuth.VERSION logueado; borrar duplicados/muertos (reactivar_LEGACY MOS, modal huérfano WH, bloque if(false)+legacy ME); unificar cache de ME al módulo + corregir comentario "<1h".
- **Fase 1** (boot instantáneo): cambiar _verificarReal() a cache-first optimista + re-verify background. Marca en 3 stores. **GATE: NO mergear sin Fase 2** (cache-first sin revocación rápida amplía ventana). Ir juntas o detrás de flag.
- **Fase 2** (revocación denylist opción A): get_flags devuelve dispositivos_revocados[]+verify_version; front bloquea su UUID ≤2min; heartbeat backstop. **40x: fail-safe (endpoint caído≠abierto), UUID en lista bloquea aunque cache diga ACTIVO, verify_version cierra flota.**
- **Fase 3** (UX moderno): reescribir modales/overlays del módulo con animaciones+triple feedback+OTP+check. Las 3 apps heredan. Validar iOS/Android/tablet/TV reales.
- **Fase 4** (background + limpieza): confirmar 0 escrituras bloqueantes; consolidar heartbeats en módulo (borrar intervalos Vue ME). Opcional: Realtime (B) detrás de flag.

## Trade-offs a aceptar
- Cache largo + boot instantáneo = rapidez a cambio de revocación vía denylist (≤2min) en vez de síncrona. Aceptable CON denylist, NO sin ella.
- Centralizar = tocar 3 apps (blast-radius) → Fase 0 (limpieza+versionado) primero, todo detrás de flags/gates.
- Denylist no secreta (UUIDs opacos, sin PII) → ok servir por flags.

## Archivos clave
device-auth.js (boot 764-789, heartbeat 959-1013, cache 218-236, in-situ 535-720, 3-store 173-213) · Config.gs (aprobarDispositivoEnSitu 1766, _propagarDispositivoSombra 1706, consultarEstadoDispositivo 1230, legacy 1914) · SeguridadAlerts.gs (reactivar 338 activo) · mint-mos/index.ts (deviceOk 63-80) · WH index.html 5126-5181 + app.js 1877-2051 · ME index.html 1343/8742-8755/6688-6724/1405-1527 · js/api.js get_flags 104.
