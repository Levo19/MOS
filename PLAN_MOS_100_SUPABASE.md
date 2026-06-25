# PLAN — MOS 100% Supabase (cero GAS, cero fallback, cero rastro)

Directriz: **100% Supabase. Sin GAS. Sin fallback. Sin rastro.** Orden seguro: migrar cada path a Supabase directo sólido PRIMERO; quitar los fallbacks AL FINAL (para no dejar huecos sin red en una app de dinero). Revisión 40x por paso, integral al cerrar cada bloque.

Directiva adicional: **revisión 40x senior por CADA implementación, siempre.**

## BLOQUE A — Dinero (primero)
- [~] **1. `liquidaciones_pagos` — hueco de pagos de jornal.** Hoy: escritura GAS (`MOS_PAGOS_JORNAL_DIRECTO=0`) + sync OFF + lectura directa → pago hecho no aparece → riesgo doble pago.
  - [x] 1a. `mos.anular_pago` YA verifica la clave admin server-side ([227], línea 22). El comentario en api.js:488 estaba desactualizado.
  - [x] 1b. `mos.marcar_pagos` [227] YA acepta `fechas[]` y reconstruye `dias[]` desde `liquidaciones_dia` (server-truth, rechaza si no materializado).
  - [x] 1b-bis. Front YA cableado directo-puro (api.js:1632/1646, idempotente por localId, clave admin en anular).
  - [x] 1-test. Smoke 40x end-to-end (rollback): 9/9 ✅ (paga, día→PAGADA, gasto, dedup, anula-clave-mala rechazada, kill-switch). Transición: 0 días descuadrados = sin riesgo de doble pago.
  - [x] 1c. **`MOS_PAGOS_JORNAL_DIRECTO=1` PRENDIDO en vivo** (2026-06-25, confirmado por usuario). get_flags=1.
  - [x] 1d. Coherencia verificada: DIRECTO=1 + SYNC_OFF + lectura directa → pagos de jornal 100% Supabase, cero GAS.
  - NOTA: queda la línea de fallback `if(out==null) return null` (api.js:1638/1650) → se quita en Bloque C (paso 10).
  - **#1 COMPLETO** ✅

## HALLAZGOS / FIXES DESPLEGADOS (2026-06-25)
- [x] **H1. `mos.listar_dispositivos` no estampaba frescura → panel de dispositivos caía SIEMPRE a GAS.**
  RPC de la Fase 4.1 (archivo 102), escrita antes del patrón `|| mos._frescura_sombra()`. Devolvía solo
  `{ok,data}` → `_fresh` ausente → el gate `_getListaDirectaMOS` (api.js:545) nunca pasaba → fallback GAS
  permanente y silencioso (`heartbeat=undefined` en consola). **Fix SQL 170 aplicado en vivo** (mergea
  frescura; con el latido pg_cron 168 el `_fresh` queda true). Verificado: 147 dispositivos, `_fresh:true`.
  Desplegado MOS v2.43.337.
- [x] **H2. Auditoría de clase del bug H1:** revisadas las 47 RPCs que el frontend consume con gate `_fresh`
  (vía `_getListaDirectaMOS`/`_getObjDirectoMOS`/helpers). Resultado: **ninguna otra** carece de frescura.
  `listar_dispositivos` era la única. No hay más fallbacks silenciosos de esta clase.
- [x] **H3. Cosmético consola MOS:** meta `mobile-web-app-capable` (el `apple-` estaba deprecado) + favicon/
  apple-touch-icon a `icons/icon-192.png` (corta el 404 de favicon.ico). Desplegado v2.43.337.

## BLOQUE S — Seguridad (NUEVO · detectado en la retrospectiva 500x del 2026-06-25)
- [ ] **S1. `mos.catalogo_pos_rls` (y el path de descarga de catálogo) con grant `anon` expone PII + secretos.**
  La RPC es `SECURITY DEFINER` + grant a `anon`, y devuelve sin filtro de tenant: **`me.clientes_frecuentes`
  (DNI/RUC + RazónSocial + Dirección = PII), el `Admin_PIN` de estaciones, series documentales y PrintNode IDs.**
  Cualquiera con la URL + anon key (pública por diseño en estas apps) extrae el catálogo COMPLETO + PII de
  clientes + PINs de admin. **Pre-existente** (no lo introdujeron las reparaciones de hoy), pero es real.
  - Por qué NO se tocó headless: revocar `anon` puede romper la lectura del catálogo en ME si ME llama con la
    anon key (no con token mint). Mover el `Admin_PIN`/PII a una RPC aparte gateada por sesión es lo correcto.
  - Va atado al **cutover de auth (Bloque B #2)**: cuando ME pase a mint-token/authenticated, revocar `anon` y
    separar el PII. Verificar primero CÓMO llama ME hoy a `catalogo_pos_rls` (anon vs mint).

## BLOQUE B — Migrar lo que sigue en GAS a Supabase
- [~] **2. Auth de dispositivos = Fase 7 (corte de Sheets de dispositivos).** Investigado a fondo: RPCs anon ✅ funcionan (verificado 40x), path Supabase del front ✅ construido, `MOS_AUTH_SIN_DOBLECHECK=1` ✅. PERO el ciclo completo requiere reverse-sync (la escritura directa la pisa el resembrado hoja→sombra) + 13 lectores GAS + 5 crons.
  - [x] 2-keystone. `resembrarDispositivosDesdeSombra()` (reverse-sync sombra→hoja, con dryRun) ESCRITO + sintaxis OK (Fase4Dispositivos.gs). Reemplaza al resembrado hoja→sombra.
  - [ ] 2a. Deploy clasp + `resembrarDispositivosDesdeSombra({dryRun:true})` → revisar counts → correr real → `compararDispositivosMOS` paridad. **(usuario: clasp + correr)**
  - [ ] 2b. Apagar hoja→sombra: `quitarTriggerResembrarDispositivos()` + quitar llamada en syncMOSReciente:473 + sacar `dispositivos` de `_CAT_SPECS` + instalar trigger del reverse-sync.
  - [ ] 2c. Prender `dispositivosDirecto` + `deviceAuthDirecto` en MOS_CONFIG + deploy front (SW bump).
  - [ ] 2d. **Test en dispositivo real** (autorizar/bloquear/aprobar + seguridad/horarios siguen). **(usuario: device test)**
  - NOTA: el go-live de #2 necesita tus manos (clasp deploy + test en device) — es fail-closed, no se valida headless.
- [ ] **3. Wizard de permisos** (`marcarWizardMostrado`, `registrarPermisosDispositivo`, index.html:19920/19970) → Supabase.
- [ ] **4. `consultarEstadoDispositivo`** (re-wizard, index.html:18737/19992) → Supabase + quitar URL GAS hard-codeada.
- [ ] **5. Editor de adhesivos** (`EditorAdhesivos.abrir backendUrl`, index.html:19242) → backend Supabase/Edge.
- [~] **6. `meConsultarCliente`** SUNAT/RENIEC → Edge function (HTTP externo, sin GAS).
  - [x] 6a. Edge `consultar-documento` ESCRITA (port exacto de Catalogo.gs APISPeru, mismo shape, secret APISPERU_TOKEN). functions/consultar-documento/index.ts.
  - [ ] 6b. Deploy: `supabase secrets set APISPERU_TOKEN=<token>` + `supabase functions deploy consultar-documento`. **(usuario)**
  - [ ] 6c. Cablear api.js meConsultarCliente: fallback → Edge (no GAS) + SW bump + deploy front.
- [ ] **7. `setHorarioApp`** — quitar el disparo GAS; requiere que WH/ME lean el horario de Supabase (cross-app, nota).
- [ ] **8. `liquidacion.html` / `turno.html`** — auditar su capa GAS y migrar.

## BLOQUE C — Quitar fallbacks y rastro de GAS (solo después de B)
- [ ] **9. Lecturas:** quitar el fallback GAS de `_conFallbackMOS` (todas las lecturas directas).
- [ ] **10. Escrituras:** quitar el fallback GAS de DIRECTO-PURO (null→GAS) y DUAL-WRITE.
- [ ] **11.** Eliminar `GAS_URL`/`_fetch`/toda referencia a `script.google.com` del código MOS.

## BLOQUE D — Limpieza / consistencia
- [ ] **12.** Sincronizar `index.html` `MOS_CONFIG` con los flags reales del server (o eliminarlo).
- [ ] **13.** Borrar código muerto (bloque `if(false)` device-auth y similares).

---
## QUÉ FALTA Y POR QUÉ ESTÁ BLOQUEADO (necesita tus manos)
El resto de la lista NO es headless-seguro — verificado leyendo el código 2026-06-25:
- **#2/#3/#4 (device-auth):** `_verificar()` (index.html:18791) es el gate que **bloquea toda la UI**. Migrar
  la lectura/escritura headless sin test en dispositivo real puede dejar equipos bloqueados fuera (fail-closed,
  app de dinero). Las escrituras (marcarWizardMostrado, aprobarDispositivoEnSitu, permisos) además las pisa el
  resembrado hoja→sombra hasta apagarlo (#2b). **Requiere: clasp deploy + correr `resembrarDispositivosDesdeSombra`
  + test en device.** Es la Fase 7 dedicada.
- **#5 (adhesivos):** Edge `print-adhesivo` + SQL 206-208 ya construidos INERTES (gated `_whLoteAdhesivoDirecto`).
  Falta el **cutover del dueño**, no código.
- **#6 (SUNAT/RENIEC):** Edge `consultar-documento` escrita. Falta `supabase secrets set APISPERU_TOKEN` +
  `supabase functions deploy` (tu token).
- **#7 (setHorarioApp):** cross-app, requiere que WH/ME lean el horario de Supabase primero.
- **#9-11 (quitar fallbacks):** por diseño van AL FINAL, después de B. No tocar todavía.

- **S1 (seguridad PII/anon):** atado al cutover de auth (#2). No revocar `anon` sin antes confirmar que ME usa
  mint-token y mover el PII/Admin_PIN a una RPC gateada — si no, se rompe la lectura del catálogo en ME.

Estado: #1 ✅ + H1/H2/H3 ✅ (2026-06-25). NUEVO pendiente **S1 (seguridad, alta prioridad)**. El resto sigue
bloqueado en device-test / tokens / cutover del dueño.

> Nota: entre el #1 y el S1, hubo una SESIÓN DE REPARACIONES (UI/UX, cero GAS) — ver `PENDIENTES_REPARACIONES.md`
> (tramos, adhesivo granel, wizard iOS, pickup, membretes, propagación catálogo/estado, etc.). Toda esa sesión
> mantuvo la directriz 100% Supabase y NO tocó este plan de migración; el S1 salió de su retrospectiva 500x.
