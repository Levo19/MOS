# Inventario — lectores/escritores de la hoja DISPOSITIVOS (FASE 4: auth 100% puro)

> Mapa exhaustivo para migrar el auth de dispositivos a sombra única `mos.dispositivos` (sin GAS/hoja).
> Generado 2026-06-16 por barrido de los 3 repos. **50 call-sites** (la memoria estimaba ~40).
> ⚠️ FASE 4 = SESIÓN DEDICADA (delicada). Este doc es el insumo; NO se ha tocado nada.

## Conteo por archivo
- MOS `Config.gs`: 25+ funciones (el grueso)
- MOS `Bloqueos.gs`: 3 · `SeguridadAlerts.gs`: 4 · `EspiaWebRTC.gs`: 3 · `Audio.gs`: 1 · `Gps.gs`: 2 · `Horarios.gs`: 1 · `Liquidaciones.gs`: 2 · `Evaluaciones.gs`: 1 · `Code.gs`: 1 gate
- WH `Fase2AuthWH.gs`: 2 (`_validarDispositivoMOS` lee la hoja VIVA de MOS para mint WH)
- ME `Catalogo.gs`: 1 (`verificarDispositivo` lee hoja MOS, autoritativa)

## AUTH-CORE (lo primero a migrar — ya hay RPCs equivalentes en SQL 100)
- `_gateDispositivoMOS` (Code.gs:42) LECTURA — gate POST sensibles
- `getDispositivos` (Config.gs:623) · `getDispositivosPendientes` (1218) · `consultarEstadoDispositivo` (1230) LECTURA
- `aprobarDispositivoPendiente` (1580) · `aprobarDispositivoEnSitu` (1766) · `rechazarDispositivoPendiente` (1874) · `forzarReVerifyDispositivo` (1916) R/W
- `revocarDispositivo` (1476) · `vincularBrowserDispositivo` (2316) R/W

## SYNC CRÍTICO (el que hay que INVERTIR)
- **`_propagarDispositivoSombra` (Config.gs:1706)** ESCRITURA — copia fila HOJA → `mos.dispositivos`. Se invoca tras aprobar/rechazar/bloquear/liberar/revocar. **Punto de sync hoja→sombra. La FASE 4 lo invierte (sombra→hoja) + apaga este.**

## PANELES ADMIN / FLAGS
- `crearDispositivo` (667) · `actualizarDispositivo` (689) · `extenderHorarioDispositivo` (799) · `forzarPushDispositivo` (1327) R/W
- `registrarPermisosDispositivo` (1407) · `forzarWizardDispositivo` (1449) R/W
- `_garantizarColumnasDispositivos` (563) · `_garantizarColumnasDispositivosExtendidas` (SeguridadAlerts 160)

## HEARTBEAT / SESIÓN (alta frecuencia — clave para espía/audio/eval que joinean por Ultima_Sesion)
- `registrarSesionDispositivo` (Config.gs:901) — Ultima_Sesion/Zona/Estacion/Conexion + flags Forzar_*
- `registrarConexionDispositivo` (1213) · `reportarQuotaDispositivo` (598)

## BLOQUEOS / SEGURIDAD
- `bloquearDispositivosDeUsuario` (Bloqueos 434) · `liberarDispositivoBloqueado` (523) · `getDispositivosBloqueados` (607)
- `desbloquearTemporalDispositivo` (SeguridadAlerts 230) · `reactivarDispositivoSuspendido` (338)
- `alertarDispositivosInactivos2a7d` (Config 1954) · `purgarDispositivosInactivos(7d)` (1505/1576)

## CONSUMIDORES TRANSVERSALES (joinean por deviceId / Ultima_Sesion)
- Espía: `espiaSubirChunk` (324) · `diagnosticarDeviceEspia` (729) · push-diag (1626) — LECTURA
- Audio: `_pushComandoDispositivo` (59) — LECTURA FCM_Token
- GPS: `getUltimaUbicacionDispositivo` (67) · `getUbicacionesDispositivo` (82) — LECTURA
- Horarios: verificarHorario (482) lee Desbloqueo_Temporal_Hasta/Forzar_Horario_Hasta
- Liquidaciones: `cierreNocturnoTodos` (1885) escribe Forzar_Logout=1 a TODOS
- Evaluaciones: heartbeat status (1605) lee Ultima_Sesion del día

## MINT CROSS-APP
- `mint-mos` (Edge): valida deviceId contra `mos.dispositivos` (sombra) — YA en la sombra ✓
- WH `_validarDispositivoMOS` (Fase2AuthWH 18): lee hoja VIVA MOS → migrar a sombra
- ME `verificarDispositivo` (Catalogo 249): lee hoja VIVA MOS → migrar a sombra

## Estrategia FASE 4 (resumen, a detallar en la sesión dedicada)
1. **Invertir sync**: `mos.dispositivos → HOJA` (RPC/trigger) + APAGAR `_propagarDispositivoSombra` y el HOJA→sombra. No coexisten (lección rollback).
2. **Poblar en la sombra** las columnas que hoy solo viven en la hoja: Ultima_Sesion/Zona/Estacion, Forzar_*, FCM_Token, Permisos_JSON, Alerta_Seguridad, Bloqueado/Razon.
3. **Migrar lectores** uno por uno (auth-core → paneles → heartbeat → espía/audio/gps/horarios) a RPCs de lectura sobre la sombra, con fallback.
4. **Quitar el doble-check** GAS en las 3 apps (sombra = fuente única).
5. Validar que TODOS los devices reales entran. Limpiar devices no usados (ya efectivo sin sync que pise).
