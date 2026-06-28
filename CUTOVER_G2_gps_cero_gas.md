# G2 — GPS tracking de dispositivos → 100% Supabase (cero-GAS)

**Fecha:** 2026-06-27 · **Estado:** CONSTRUIDO + DESPLEGADO · **INERTE** (flag `GPS_DIRECTO` OFF). **NO auto-activado** (a diferencia de G1) por el prerequisito del sin-señal (abajo).

## Qué se migró
El subsistema GPS anti-robo (Gps.gs / hoja `UBICACIONES_HISTORIAL`): WH (`_gpsRegistrarWH`, cada 5 min) y ME
(`_gpsRegistrar`) escriben lat/lng/accuracy/bateria; el admin master ve última posición + ruta 24h.

## Qué se construyó
- **Backend** (`supabase/279_mos_gps_ubicaciones.sql`, aplicado + verificado en vivo):
  - Tabla `mos.dispositivos_ubicaciones` (id_ubic, device_id, ts, lat, lng, accuracy, bateria, usuario_logueado).
  - `mos.registrar_ubicacion(p)` — WRITE anon (insert). `mos.ultima_ubicacion_dispositivo(p)` + `mos.ubicaciones_dispositivo(p)` — READS admin. Shape camelCase paritario con Gps.gs.
  - **pg_cron `mos-gps-purga`** (03:30 diario) reemplaza `limpiarUbicacionesViejas` (TTL 7 días). NACE ACTIVO (no-op mientras la tabla está vacía).
- **Frontend** (INERTE):
  - WH 2.13.363: `API.registrarUbicacionDirecto` + `_gpsRegistrarWH` Supabase-first.
  - ME 2.8.95: `_gpsRegistrar` Supabase-first (perfil mos).
  - MOS 2.43.368: lector admin `getUltimaUbicacionDispositivo`/`getUbicacionesDispositivo` con directos dedicados (sin gate `_fresh`) + routing en `get:` y `post:`, gated por `_mosLecturaDirecta` (ON prod) + el flag server-side.

## Kill-switch (cutover atómico)
UN flag server-side **`GPS_DIRECTO`** en `mos.config` controla writes Y reads a la vez:
- `!= '1'` (default) → todo por GAS (INERTE, cero cambio). **HOY ESTÁ ASÍ.**
- `= '1'` → writes y reads por Supabase. Coherente (no hay ventana write-aquí/read-allá).

## ⚠ PRE-REQUISITO antes de activar (por esto NO se auto-activó)
El trigger GAS **`verificarSinSenal`** (alerta a master si un equipo activo no reporta GPS >24h) lee la hoja
`UBICACIONES_HISTORIAL`. Con `GPS_DIRECTO='1'` los writes se van a Supabase → la hoja deja de crecer → ese
trigger creería que **TODOS** los equipos están sin señal → **spam de push a master**.

**Antes de poner `GPS_DIRECTO='1'`:**
1. **DESACTIVAR el trigger GAS `verificarSinSenal`** (en el proyecto Apps Script de MOS, Triggers → eliminar el
   horario de `verificarSinSenal`). Sin esto NO activar.
2. (Opcional, para conservar el alerta) portar el sin-señal a Supabase — pendiente: necesita la ruta de push
   (Edge/FCM). Alternativa simple: pg_cron que inserte en `mos.seguridad_alertas` (que el panel ya lee).

## Pasos de activación (cuando el sin-señal esté manejado)
1. Desactivar el trigger GAS `verificarSinSenal` (paso 1 de arriba).
2. `insert into mos.config(clave,valor) values('GPS_DIRECTO','1') on conflict (clave) do update set valor='1';`
3. Observar: en un equipo WH/ME ver que el POST va a `…/rpc/registrar_ubicacion` (200, ok:true) y desaparece el
   POST GAS `registrarUbicacion`. En el panel admin (master), abrir 📍 de un dispositivo → la última ubicación +
   ruta deben verse (vienen de Supabase). Verificar el shape: lat/lng/bateria/accuracy/timestamp OK.
4. **Rollback instantáneo:** `update mos.config set valor='0' where clave='GPS_DIRECTO';` → vuelve a GAS (y
   re-activar el trigger sin-señal si se desactivó).

## Verificación pendiente al activar
- El lector admin (espía GPS modal + verUltimaUbicacionDispositivo) con datos reales — el shape se verificó contra
  el código de los callers (r.lat/r.timestamp/ult.bateria) pero no contra el panel en vivo.
