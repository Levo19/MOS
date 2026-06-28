# G1 — Estado de bloqueo + heartbeat de WH → 100% Supabase (cero-GAS)

**Fecha:** 2026-06-27 · **Estado:** CONSTRUIDO + DESPLEGADO + REVISADO (40x adversarial) · **INERTE** (flag OFF).

## Qué se migró
El poll de WH `BloqueoRemoto._check` (cada **120s**, todo el turno) que pegaba al GAS `getEstadoBloqueoUsuario`.
Ese endpoint era la **peor fuga GAS recurrente** (consumía cuota urlfetch y frenaba los POST de operaciones).
Hacía DOS cosas en una llamada:
1. **Lee** el estado de bloqueo del usuario (merge de `PERSONAL_MASTER.estado` + `BLOQUEOS_USUARIO`).
2. **Heartbeat**: actualiza `DISPOSITIVOS.Ultima_Conexion/Sesion/Zona/Estacion` + `PERSONAL_MASTER.Ultima_Conexion`
   (para que el panel admin vea el equipo/operador "en línea").

## Qué se construyó
- **Backend:** `supabase/278_mos_estado_bloqueo_usuario.sql` → RPC anon `mos.estado_bloqueo_usuario(p jsonb)`.
  Replica el shape EXACTO de `getEstadoBloqueoUsuario` (`{bloqueado, inactivo, unlockHasta(ms), unlockVigente,
  msRestantes(ms), motivo, idPersonal, nombre}`) + hace el heartbeat (dispositivo + personal) en la misma llamada.
  Helper `mos._norm_app(text)`. **Aplicado y verificado en vivo** (shape correcto, heartbeat + auto-estación Almacén).
- **Frontend WH (v2.13.362):**
  - `js/api.js` → `_whBloqueoDirecto()` (gate cliente, default ON) + método `API.estadoBloqueoUsuarioDirecto(params)`
    (Supabase-first; devuelve `null` si flag OFF / opt-out / offline / error → caller cae a GAS).
  - `js/app.js` → `BloqueoRemoto._check` ahora intenta el directo primero; si `null`, **fallback GAS idéntico al
    legacy** (mismo querystring, mismo side-effect, mismas transiciones de `_state`).

## Kill-switch (cutover sin redeploy)
Flag **server-side** `WH_BLOQUEO_DIRECTO` en `mos.config`:
- `!= '1'` (default / ausente) → el RPC devuelve `{ok:false, error:'WH_BLOQUEO_DIRECTO_OFF'}` → WH cae a GAS **al
  instante**. **HOY ESTÁ ASÍ (INERTE).**
- `= '1'` → WH usa Supabase para el bloqueo + heartbeat; solo cae a GAS si Supabase falla.
- Opt-out por dispositivo (debug): `localStorage 'wh_bloqueo_navegador'='0'`.

## ✅ Prerequisito de lockstep — YA SATISFECHO
Con el flag ON, el heartbeat de WH escribe en `mos.dispositivos`/`mos.personal` (Supabase) y **deja** de escribir la
Hoja GAS. Para que el admin NO vea los equipos WH congelados en "hace Nh", el panel debe leer la presencia desde
Supabase. **Verificado:** `getDispositivos` (MOS `js/api.js:2581`) rutea por `_mosLecturaDirecta`, que **está ON en
prod** (anotado en `js/api.js:412`). → el admin ya lee `ultima_conexion` desde `mos.dispositivos`. **El cutover es
seguro.** (Confirmar que el dispositivo-admin no tenga `mos_lectura_navegador='0'` localmente.)

## Pasos para ACTIVAR (cuando se decida)
1. (Opcional, verificación) En el equipo admin de MOS abrir el panel de dispositivos y confirmar que las
   `Ultima_Conexion` se ven frescas (lectura directa ON).
2. Poner el flag: `update mos.config set valor='1' where clave='WH_BLOQUEO_DIRECTO';`
   (si no existe la fila: `insert into mos.config(clave,valor) values('WH_BLOQUEO_DIRECTO','1');`)
3. Observar 1–2 ciclos (≤4 min) en un equipo WH: el candado sigue funcionando, y en el admin la `Ultima_Conexion`
   del equipo WH se refresca. Revisar que NO haya errores en Network (el directo responde `{ok:true,data}`).
4. **Rollback instantáneo si algo falla:** `update mos.config set valor='0' where clave='WH_BLOQUEO_DIRECTO';`
   → WH vuelve a GAS en el siguiente poll, sin redeploy.

## Divergencias conocidas (deliberadas, NO bugs — del review 40x)
- **Fallback por nombre:** el RPC compara nombre COMPLETO (`nombre||' '||apellido`); GAS compara solo el nombre de
  pila. WH manda `idPersonal` siempre → el path real es idéntico; la divergencia solo aplica si idPersonal NO
  matchea (raro). El full-name es más correcto.
- **Fila de bloqueos:** GAS toma la última fila física; el RPC ordena "unlock vigente → fecha_bloqueo más reciente".
  Idéntico con 1 fila por usuario/app (lo común).
- **`unlock_hasta`:** GAS lee epoch-ms crudo; el RPC deriva de `timestamptz` → puede diferir <1s (el countdown lo
  tolera). Verificar que la sombra guarde `unlock_hasta` a full precisión.
- **Costo INERTE:** mientras el flag esté OFF, WH hace 1 RPC extra/poll (recibe OFF, cae a GAS). Al activar, el poll
  GAS desaparece y la carga NETA baja.

## Lo que NO entra en G1 (siguen en GAS — pasada futura)
- **G2** `registrarUbicacion` (GPS): falta tabla `mos.dispositivos` lat/lng/bateria + RPC + migrar el lector
  espía/tracking del admin (`getUltimaUbicacionDispositivo`/`getUbicacionesDispositivo` NO tienen path Supabase).
- **G4** `getAdminPinsCache` (PINs admin para verificación offline): auth-sensible.
- ME usa el mismo `getEstadoBloqueoUsuario` (`index.html:13228`) — puede migrarse al MISMO RPC
  `mos.estado_bloqueo_usuario` (es genérico por app) en una tanda aparte.
