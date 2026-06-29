# Análisis + diseño — SUPER TABLA de asistencia + jornal + auditoría (ME + WH)

> Solo DISEÑO / dibujo (decisión del usuario: "solo dibujo por ahora"). 100% Supabase, cero-GAS. No se implementa nada hasta tu OK.

## Descubrimiento clave: la "super tabla" YA EXISTE (casi entera)
`mos.liquidaciones_dia` ya es **una fila por persona por día** con casi todo lo que pediste:
```
mos.liquidaciones_dia  (HOY = 1 fila/persona/día — la base de la super tabla)
  id_dia          LDIA-20260628-OP002      (clave día+persona, idempotente)
  fecha, id_personal, nombre, rol, app_origen
  monto_base      80.00 / 50.00 / 0.00     ← SUELDO FIJO (de mos.personal.monto_base)
  pago_envasado   33.50                     ← productos_envasados × tarifa_envasado
  tarifa_envasado 0.10                       ← costo por producto envasado
  bono_meta       0                          ← COMISIÓN por excedente de meta (ME)
  bonificacion / bonificacion_motivo         ← ajuste manual + por qué
  sancion / sancion_motivo                   ← descuento + por qué
  total_dia       33.50                      ← lo que se le paga ese día
  presente        true                       ← ¿asistió?
  auditado, evaluaciones_count, score_final  ← AUDITORÍA diaria (ya fusionada acá)
  estado          PENDIENTE | PAGADA | VETADA ← VETADA = queda registrado, NO se paga
  id_pago, ts_creado, ts_actualizado
```
**Conclusión:** no falta la tabla. Falta (1) **la capa de asistencia en tiempo real** (a qué hora entró + polling de última conexión) y (2) que se **alimente al INGRESAR**, no de noche por un cron.

## El modelo de pago (lo que me explicaste) — mapeado a campos reales
**ME (vendedores/cajeros) = FIJO + COMISIÓN proporcional**
- Fijo → `monto_base` (en `mos.personal`, ej. cajero 50).
- Comisión → `bono_meta`. Fórmula:
  ```
  pool_zona   = 5% × MAX(0, venta_cobrada_zona − meta_ZONA)   (config: evalComisionExcedentePct=5)
  comisión_i  = pool_zona × (venta_del_usuario_i / venta_total_zona)
  ```
  - **`meta_ZONA` es UN número por zona** (DECIDIDO), no la suma de metas por rol.
  - Se reparte entre **TODOS** los usuarios de la zona (vendedores + cajeros), **proporcional a lo que vendió cada uno**. Quien vendió 0 recibe 0 (la proporción lo maneja sola).
  - Ej.: pool = 100. Zona con 3 usuarios: v1 vendió 50% → **50**; cajero vendió 50% → **50**; v3 vendió 0% → **0**.
  - Se reparte SOLO sobre lo ya cobrado (efectivo + virtual + mixto).
  - *(Las metas por rol `evalMetaCajero=1500` / `evalMetaEnvasador=500` se usan para `progreso_venta_pct` individual, NO para el pool de comisión.)*

**WH (envasador / almacenero) = FIJO + POR PRODUCTO ENVASADO**
- Por producto → `pago_envasado = productos_envasados × tarifa_envasado` (tarifa 0.10).
- Fijo → `monto_base` (almacenero 80; envasador 0).
- Ej. real verificado: envasador OP002 → 335 u × 0.10 = `pago_envasado` 33.50, `monto_base` 0, `total_dia` 33.50.
  Almacenero OP001 → `monto_base` 80 + 0 envasado = `total_dia` 80. *(Si el almacenero envasa 100 u → 80 + 10 = 90.)*

## Por qué falla hoy (causa raíz, confirmada)
1. `liquidaciones_dia` la construye un cron NOCTURNO (`mos-snapshot-liq-semana`, 04:30) a partir de `mos.jornadas` del día ANTERIOR → **hoy siempre está vacía** hasta la madrugada siguiente.
2. La jornada nace asimétrica: **WH = `AUTO_LOGIN`** (al conectarse ✓) pero **ME = `AUTO_VENTA`** (solo si vende ✗) → vendedor que entra y no vende = **no existe** en jornadas → no entra al snapshot.
3. ME no tiene asistencia histórica: `me.presencia` es solo-vivo (se borra al desconectar). No hay "a qué hora entró / última conexión".

## Descubrimiento 2: WH ya tiene su "super tabla" (ME no)
`wh.desempeno` es **1 fila/persona/día** con TODO lo de WH (y enlaza `id_sesion` → `wh.sesiones`):
```
wh.desempeno  (rollup diario WH — el modelo que ME NO tiene)
  id_personal, id_sesion, fecha
  minutos_activos, horas_trabajadas          ← ASISTENCIA (de wh.sesiones)
  guias_creadas, guias_cerradas
  envasados_registrados, unidades_envasadas  ← PRODUCCIÓN (insumo pago_envasado)
  mermas_registradas
  auditoria_ejecutadas                        ← AUDITORÍAS HECHAS (vs evalMetaAuditorias=30)
  preingreso_creados, ajustes_realizados
  total_actividades, actividades_por_hora
  puntuacion, calificacion                    ← SCORE de desempeño
  monto_base, monto_bonus, monto_total        ← PAGO
  estado
```
**La asimetría de fondo:** WH = `wh.sesiones` (asistencia) + `wh.desempeno` (rollup rico) → `mos.liquidaciones_dia` (pago). **ME = `me.presencia` (solo-vivo) + ventas → jornadas → liquidaciones_dia.** ME no tiene ni asistencia histórica ni tabla de desempeño. Por eso el vendedor "no existe" si no vende.

## Las fuentes de cada dato (mapa completo)
```
ASISTENCIA      WH: wh.sesiones        ME: me.presencia (solo-vivo, sin histórico) ✗
PRODUCCIÓN      WH: wh.envasados.unidades_producidas (por usuario/fecha)
AUDITORÍAS      WH: wh.auditorias (por usuario, meta=30)   ME: me.auditorias (vendedor/zona)
VENTA (progreso) ME: ventas por vendedor vs meta de zona (evalMetaCajero=1500)
EVALUACIÓN      mos.evaluaciones (limpieza_pct, control_checks, aplica_comision/bono, sancion, bonificacion)
ROLLUP DIARIO   WH: wh.desempeno     ME: (no existe) ✗
PAGO FINAL      mos.liquidaciones_dia (1 fila/persona/día, estado PENDIENTE/PAGADA/VETADA)
CONFIG (metas)  mos.config (evalMeta*/evalComisionExcedentePct) — vía API.get('getConfig') ⚠ verificar Supabase-directo
```

## El rediseño — UNA super tabla, alimentada AL INGRESAR (tiempo real)
Mantener `mos.liquidaciones_dia` como **la** super tabla (1 fila/persona/día), pero:
- **Crearla al LOGIN** (WH y ME), no de noche → aparece apenas el empleado entra.
- **Agregarle la capa de asistencia** (campos nuevos, cada uno explicado):
```
mos.liquidaciones_dia  (EXTENDIDA — asistencia + jornal + auditoría, todo junto)
 ── IDENTIDAD ─────────────────────────────────────────────────────────────────
  id_dia            clave día+persona (idempotente, 1 fila/persona/día)
  fecha             día Lima
  app_origen        mosExpress | warehouseMos
  id_personal       FK mos.personal · NULL si temporal de zona ME
  es_temporal       true = vendedor/cajero de zona (usuario plantilla, sin id fijo)
  nombre, rol, zona, device_id
 ── ASISTENCIA (NUEVO, tiempo real) ───────────────────────────────────────────
  hora_ingreso      ts del PRIMER login del día            ← "a qué hora entró"
  ultima_conexion   ts del último heartbeat/polling        ← "sigue conectado?"
  hora_salida       ts logout o cierre forzado 11pm
  minutos_activos   acumulado de actividad
  estado_sesion     ACTIVA | CERRADA | FORZADA_11PM | AUTOCIERRE
  reconexiones      cuántas veces volvió a entrar en el día
 ── PRODUCCIÓN / VENTA / AUDITORÍA (insumos del pago, de wh.desempeno + ventas) ──
  productos_envasados   u envasadas en el día (WH)         ← insumo pago_envasado
  venta_cobrada         S/ cobrado por la persona (ME)     ← insumo comisión
  venta_zona, meta_zona S/ y meta de la zona (ME)          ← para el pool de comisión
  progreso_venta_pct    venta_cobrada / meta × 100         ← "cuánto vendió vs su meta"
  auditorias_hechas     productos auditados en el día      ← de wh.auditorias / me.auditorias
  meta_auditorias       cuota dinámica (config evalMetaAuditorias=30, por rol)
  cumplio_auditorias    auditorias_hechas >= meta_auditorias  ← afecta bono/sanción
  guias_creadas, guias_cerradas, mermas, ajustes           ← actividad WH (de wh.desempeno)
  puntuacion, calificacion                                 ← score de desempeño del día
 ── PAGO (ya existen) ──────────────────────────────────────────────────────────
  monto_base        sueldo fijo (mos.personal.monto_base)
  tarifa_envasado   costo por producto (0.10, de config)
  pago_envasado     = productos_envasados × tarifa_envasado
  bono_meta         = comisión proporcional (fórmula ME de arriba)
  bonificacion / bonificacion_motivo   ajuste manual +
  sancion / sancion_motivo             descuento −
  total_dia         = monto_base + pago_envasado + bono_meta + bonificacion − sancion
 ── AUDITORÍA (ya existen, fusionada) ──────────────────────────────────────────
  presente          ¿asistió?
  auditado          ¿el admin ya lo revisó?
  evaluaciones_count, score_final
  estado            PENDIENTE | PAGADA | VETADA   ← VETADA = registrado pero NO se paga
  id_pago, ts_creado, ts_actualizado
```
**De esta única tabla salen los 4 usos sin duplicar lógica:**
- Presencia en vivo = `ultima_conexion` reciente + `estado_sesion=ACTIVA`.
- Personal del día = todas las filas de `fecha` (entró o no vendió, igual aparece).
- Jornal/liquidación = `total_dia` por persona (asistencia real, no ventas).
- Auditoría = histórico por empleado, con veto/sanción/bono.

### Grano y actualización (DECIDIDO)
**1 sola tabla, 1 fila por persona por día** (no hay log crudo aparte). Esa fila se **actualiza en TIEMPO REAL**:
- El envasador registra envasados → `productos_envasados` sube → `pago_envasado` y `total_dia` suben **al instante** (lo ve crecer su pago en vivo).
- El polling actualiza `ultima_conexion`.
- La **auditoría del admin va en la MISMA fila** del usuario de ese día (el admin no tiene límite de ajustes: `bonificacion`/`sancion`/`estado`/`auditado` se editan sobre la propia fila cuantas veces haga falta).
*(Las reconexiones del día solo mueven `ultima_conexion`/`reconexiones`; siguen siendo 1 fila.)*

## Cierre forzado 11pm (tu acotación) — encaja
`pg_cron` 23:00 Lima: cierra toda sesión `ACTIVA` → `estado_sesion=FORZADA_11PM`, sella `hora_salida`+`minutos_activos`, marca `forzar_logout` en `mos.dispositivos` (flag ya existe) → re-login obligatorio mañana. Doble beneficio: asistencia diaria limpia (1 ingreso/persona/día) + seguridad (sin sesiones abiertas de noche). Los `autocierre-inactividad` (cada 15 min) se mantienen.

## Lo que se unifica / deprecación
- `me.presencia` (solo-vivo) → reemplazado por asistencia en la super tabla (+ log crudo opcional).
- `wh.sesiones` → se vuelve el log crudo unificado (o migra a `mos.sesiones_personal`).
- Jornal ME: `AUTO_VENTA` → `AUTO_LOGIN` (igual que WH); la venta solo alimenta `venta_cobrada`/comisión.
- Push duplicado (`mos.push_tokens` + `mos.dispositivos.fcm_token`) → 1 solo lugar (recomiendo push_tokens).
- Snapshot nocturno deja de ser quien "crea" el día; pasa a solo CERRAR/consolidar (la fila ya existe desde el login).
- `wh.desempeno` se vuelve el rollup universal (WH **y** ME), o sus campos se absorben en la super tabla diaria. ME estrena por fin su desempeño (hoy no tiene).

## ⚠ A verificar (lo que pediste: "que se lea de Supabase")
- Las metas/costos viven en `mos.config` (Supabase ✓): `evalMetaCajero=1500`, `evalMetaEnvasador=500`, `evalMetaAuditorias=30`, `evalComisionExcedentePct=5`, `tarifa_envasado=0.10`.
- PERO el front las lee vía `API.get('getConfig')` (app.js:15992/19404/38190…). **Falta confirmar que `getConfig` resuelve directo de `mos.config` y no por GAS.** Si va por GAS, es otra fuga cero-GAS a cerrar (la cuota de auditoría y la comisión deben leer Supabase directo). → punto para la fase de implementación.

## Decisiones tomadas (tus respuestas)
- Vendedores/cajeros ME = **siempre temporales** (no se gradúan a fijo). Su pago vive en `mos.personal` por rol (plantilla) → fijo + comisión.
- Jornal temporal = **tarifa de personal_master** (fijo) **+ comisión** (5% excedente, proporcional a venta).
- **Solo dibujo por ahora** — no implementar.

## Definiciones cerradas (tus respuestas — diseño COMPLETO)
1. **`meta_zona` = un número por zona** (no suma de metas por rol).
2. **1 sola tabla diaria** (1 fila/persona/día), **actualizada en tiempo real** (envasado sube el pago en vivo; auditoría del admin va en la misma fila, sin límite de ajustes). No hay log crudo aparte.
3. **Comisión = entre TODOS los de la zona, proporcional a lo vendido**; quien vendió 0 recibe 0.

> Diseño cerrado. Cuando des el OK para implementar, se hace 100% Supabase, INERTE primero, con revisión 500x (es ruta de dinero/pago).

---

# IMPLEMENTACIÓN — Fase 1 CONSTRUIDA + INERTE (2026-06-29)

## Qué se hizo (aditivo, money-safe, gateado por `MOS_ACCESOS_DIRECTO`=OFF)
- **SQL 287** (`287_mos_accesos_personal.sql`, aplicado):
  - 17 columnas nuevas en `mos.liquidaciones_dia` (asistencia/producción/auditoría) — aditivas, las RPC viejas las ignoran.
  - `mos.registrar_ingreso_personal(p)` — crea la fila del día AL INGRESAR (aparece de inmediato con su fijo). Idempotente. MASTER/ADMIN skipped.
  - `mos.heartbeat_personal(p)` — pulso (ultima_conexion + minutos_activos).
  - `mos.cerrar_sesiones_forzado_11pm()` + **pg_cron 23:00 Lima** (04:00 UTC).
  - helper `mos._fijo_personal` (fijo por persona real o plantilla de rol).
  - config `tarifa_envasado=0.10` centralizada en Supabase.
- **SQL 288** (`288_mos_accesos_hooks_login.sql`, aplicado): engancha el registro DENTRO de
  `me.registrar_presencia` (ME, login+heartbeat cada 60s, TEMPORAL) y `mos.login_pin_wh`
  (WH), a prueba de fallos (BEGIN/EXCEPTION → el login nunca se rompe).
- **WH frontend** (v2.13.367, desplegado): login manda `deviceId` + `API.heartbeatPersonalSB`
  cada 5min. ME **no necesita cambios** (ya manda `device_id` en presencia).

## Verificado (pruebas reales)
- INERTE: con flag OFF, las RPC devuelven `_OFF`, cero filas tocadas.
- Funcional (flag ON temporal, luego rollback): ingreso crea fila (almacenero fijo 80,
  hora ingreso, sesión ACTIVA); re-ingreso idempotente; heartbeat ok; cierre 11pm →
  FORZADA_11PM; reconexión cuenta; ADMIN skipped. Login WH/ME NO se rompe por el hook.
- **Coordinación de las 2 vistas**: ambas leen `mos.liquidaciones_dia`. "Personal del día"
  = roster del día (todos los estados). "Liquidación" = acumulado PENDIENTE por persona
  (agrupado por rango). Suman al total → coordinadas. El "desfase" que se veía = (a) hoy
  vacío + (b) vendedores nunca registrados (jornal ME nacía de AUTO_VENTA) → la Fase 1 lo arregla.
- **Sync no destructivo**: el sync Hoja→Supabase de `liquidaciones_dia` es UPSERT por
  `id_dia` (`_sbUpsert(..., onConflict)`), NO borra filas que solo están en Supabase →
  las filas que crea el login SOBREVIVEN; las columnas de asistencia (no están en la Hoja)
  se preservan. No hay conflicto con la escritura directa.
- **11pm**: ya existe `cierreNocturnoTodos()` en GAS (cierra sesiones WH/cajas ME + forza
  logout de dispositivos). El cron nuevo lo COMPLEMENTA para la columna `estado_sesion`.

## Activación (cuando el dueño quiera) — 1 paso
```sql
update mos.config set valor='1' where clave='MOS_ACCESOS_DIRECTO';
```
A partir de ahí, cada login de ME/WH registra al empleado en "personal del día" al
instante, con asistencia y cierre 11pm. Rollback: poner el flag en '0'.

## FASE 2 — MOTOR DE PAGO EN VIVO: CONSTRUIDO + PROBADO + INERTE (2026-06-29)
**Modelo confirmado por el dueño:** vendedor/cajero = FIJO (config `evalFijoVendedor`/
`evalFijoCajero`=50) + COMISIÓN 5% AUTOMÁTICA (sin requerir auditoría) que REEMPLAZA el
bono fijo 8/15. Comisión = `pct% × max(0, venta_zona − metaDiaria)` repartido proporcional
a lo cobrado (EFECTIVO+VIRTUAL+MIXTO, sin crédito). `pct`+`metaDiaria` de `mos.zonas.politica_json`.
Envasador = unidades×0.10. Almacenero = fijo 80 + envasado. Admin suma/resta en la auditoría
(bonificacion/sancion) → SE PRESERVAN.

- **SQL 289** (aplicado): `mos.recomputar_dia` / `recomputar_zona_dia` + helpers
  (`_norm_nom`, `_fijo_personal` con config, `_meta_zona`, `_comision_pct`,
  `_venta_cobrada_*`). Money-safe (preserva manual + recalcula total). INERTE.
- **SQL 291** (aplicado): triggers en `wh.envasados` y `me.ventas` → recompute EN VIVO,
  gateados + a prueba de fallos (no rompen el registro de envasado/venta).
- **Verificado (rollback):** envasador 335×0.10=**33.50** ✓; almacenero fijo **80**+17 aud ✓;
  comisión zona (venta 4000, meta 3000, exced 1000, pool 5%=50): V1 2500→**31.25**+50=**81.25**,
  V2 1500→**18.75**+50=**68.75**, crédito excluido ✓; trigger: envasar 200u → pago sube a 20 al
  instante; flag OFF = inerte y no rompe inserts.

## ACTIVACIÓN COMPLETA (Fase 1 + 2) — pasos del dueño
1. **Anti-flapping:** GAS `_liqDiaSync` recomputa `bono_meta` con el modelo VIEJO (8/15) cada
   hora → al activar, hay que evitar que pise el nuevo. Opción: agregar `liquidaciones_dia` a
   `MOS_SYNC_OFF_TABLAS` (que GAS deje de upsertear esa tabla) — el server pasa a ser dueño.
2. Prender el flag: `update mos.config set valor='1' where clave='MOS_ACCESOS_DIRECTO';`
3. (Opcional) Backfill del día: `select mos.recomputar_zona_dia(...)` por zona / recompute por persona.
   Rollback: flag a '0' (+ quitar liquidaciones_dia de SYNC_OFF).

## Pendiente menor
- **Revisar ticket de cierre de caja (HTML + impreso)**: confirmar que auditorías/progreso/
  comisión salgan automáticas y consistentes con el jornal (la comisión 5% ya se computa ahí
  en Cajas.gs; alinear el wording/valores con el nuevo modelo del jornal).
- Verificar que `getConfig` lea las metas/fijo directo de `mos.config` (no GAS).
