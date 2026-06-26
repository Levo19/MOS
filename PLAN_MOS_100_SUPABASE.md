# PLAN — MOS 100% Supabase (cero GAS, cero fallback, cero rastro)

> ## 🔖 PUNTO DE RETOMA (pausado 2026-06-26)
> **Pausado para una sesión de REPARACIONES.** Retomar esta lista cuando el usuario lo pida.
> **VIVO y verificado esta sesión:** #2 Auth dispositivos · #6 SUNAT (MOS+ME, confirmado en device) ·
> #5 Editor adhesivos (prendido, falta 1 impresión física) · S1+clase de fugas anon CERRADA (240/242/244/245) ·
> #8-turno RPC (money-exact, falta cablear) · **revisión 500x (2 rondas) hecha → 7 fixes funcionales + 18 revokes
> de seguridad, todo desplegado** (MOS 2.43.348 / ME 2.8.73).
> **PRÓXIMO al retomar:** (a) #8-turno wiring (turno.html→RPC + Edge Z-cierre, toca el cierre de caja=money) ·
> (b) #7 horario (security-entangled) · (c) #8-liquidacion (motor de evaluación) · (d) hardening residual
> (_claim_ok no-empty + Admin_PIN fuera del catálogo + clave-admin en actualizar_segmentos_precio).
> **Pendiente físico del usuario:** impresión de prueba #5 + device-tests de 2c/#3/#4.


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
- [x] **S1 + clase COMPLETA cerrada (2026-06-25, SQL 240/242/244/245 · revisión 500x).** La raíz era `mos._claim_ok()=jwt_app() in ('','MOS')`: el `''` (anon sin JWT) pasaba el gate → toda función secdef+grant-anon era anon-bypassable con solo la key pública. Revocado `anon` en TODAS las que filtraban datos sensibles (los apps minean → siguen OK; verificado anon→42501 / mint→OK en cada una): **240** catalogo_pos_rls (PII clientes+Admin_PIN); **242** personal_master_lista/estaciones_lista/impresoras_lista (PINs); **244** personal_dia_lista (PII nómina), actualizar_segmentos_precio (**WRITE anon a tabla de plata**), series_lista (SUNAT), zonas/categorias/equivalencias_lista, nombres_por_codigos, espia_purgar + 5 lecturas me.*; **245** config_publico. **SE MANTIENEN anon** (login pre-mint): registrar/verificar/consultar_estado_dispositivo, aprobar/revocar (gated por clave bcrypt), get_flags. **Residual (hardening futuro):** arreglar `_claim_ok` para no aceptar app vacío (defensa-en-prof) + sacar Admin_PIN del catálogo + gate de clave-admin en actualizar_segmentos_precio.
- [x] **S1-orig (histórico).** Verificado que el ÚNICO consumidor de `catalogo_pos_rls` es ME, y que lo llama con **mint-token** (Edge mint-me) que PostgREST resuelve como `current_user='authenticated'` (diagnóstico `_dbg_role` confirmó role+claims). **Revocado el grant `anon`** → ME (authenticated) sigue OK; atacante con solo la anon key → `42501 permission denied`. Verificado en vivo (A: mint devuelve catálogo; B: anon-only bloqueado). 218 actualizado para no re-abrir anon. **Residual menor** (hardening futuro): un device autenticado aún ve todo el PII+Admin_PINs → separar a RPC restringida (no urgente, devices semi-confiables).
- [~] **S1-orig. `mos.catalogo_pos_rls` (y el path de descarga de catálogo) con grant `anon` expone PII + secretos.**
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
  - [x] **2-prep. Dispatcher flag-aware DESPLEGADO (2026-06-25, clasp push 36 files OK, INERTE).** `_resembrarDispositivosJob` ahora lee `mos.config['MOS_DISPOSITIVOS_DIRECTO']` (helper `_mosDispositivosDirecto`, best-effort default OFF, mismo patrón que `_mosSyncOffTablas`): **OFF (actual)** → Hoja→Sombra idéntico a hoy; **ON** → reverse Sombra→Hoja. Flag **sembrado en `mos.config` = '0' (OFF)** → push es NO-OP hasta flipear. Con esto el cutover de #2 pasa a ser **100% config (sin clasp)**.
  - [x] **2-prep-verif. Mapa de pisado COMPLETO (3 paths) + reverse-sync verificado headless 100x:**
    1. `_resembrarDispositivosJob` (barrido 15min) → **flag-aware** ✅ (este flag).
    2. `migrarCatalogoCompartido`/`syncCatalogoSupabase` (barrido horario) → **ya honra `MOS_SYNC_OFF_TABLAS`** (MigracionCatalogo.gs:197/202) → al cutover se agrega `dispositivos` al CSV.
    3. `_dualWriteCAT('dispositivos',·)` → per-row solo en escrituras GAS a la hoja (deseado, NO barrido) → se deja.
    - Fuente `mos.dispositivos`: **147 filas, todas con estado, fresca** (ult. conexión hoy). Mapa `_DISP_MAP_F4`: **27 cols, completo** incl. TODAS las de seguridad (desbloqueo_temporal_hasta, fecha_caducidad, razon_bloqueo, bloqueado_desde, alerta_seguridad, forzar_horario_hasta) → un write directo a sombra propaga a la hoja que leen los crons Seguridad/Horarios. **Sin gaps de columna.**
  - [x] 2a. **dryRun CORRIDO (usuario, 2026-06-25):** `{"ok":true,"dryRun":true,"sombra":147,"actualizados":144,"agregados":3,"sinCambio":0,"errores":[]}`. Mecanismo de reverse-sync ✅ (write-side OK, sin excepción). `actualizados:144` = normalización de formato de timestamps en la 1ª pasada (esperado, baja a ~0 en la 2ª). `agregados:3` = drift sombra-no-en-hoja (additivo, nunca borra).
  - [x] **2-prereq DESBLOQUEADO (2026-06-25, clasp push 36 files OK, INERTE).** Migrados a dual-write TODOS los writers GAS de estado de dispositivo (23 sitios + 2 borrados especiales), reusando `_dualWriteDispositivo` + nuevo `_dualDeleteDispositivo`. Diseño: el reverse-sync posee las columnas de CONTROL (Estado/Forzar_*/Bloqueado/Suspendido/Desbloqueo/Cancelado/Inactivo/ReVerify/Wizard/Push/Permisos) y NO pisa las de ACTIVIDAD (ultima_conexion/zona/estacion/sesion → las mantiene el heartbeat en la hoja); un batch forward-activity (update-only) en el mismo resembrado mantiene la actividad fresca en la sombra para el panel. Sitios: Config.gs (crear/actualizar/extenderHorario/registrarSesion×5/consultarEstado/forzarPush/limpiarFlag/registrarPermisos/marcarWizard/forzarWizard/purgar/aprobar/rechazar/forzarReVerify/alertarInactivos/cancelarPendientes/limpiarPendientesMOS-DELETE/vincularBrowser-DELETE+rekey), Liquidaciones.gs (cierreNocturno/marcarLogoutHonrado), SeguridadAlerts.gs (desbloquearTemporal/revertirDesbloqueos/reactivarSuspendido). **Revisión adversarial 100x: SAFE (0 bugs, 0 sitios de control sin espejar, vars en scope, orden de vincular correcto).** INERTE: con flag OFF el resembrado sigue Hoja→Sombra; los dual-writes solo ADELANTAN la sombra (idempotente, no rompen nada).
  - [ ] **2-BLOQUEO (RESUELTO por 2-prereq): NO flipear el reverse-sync hasta migrar los writers GAS de estado a la sombra.** `_propagarDispositivoSombra` (Config.gs:1727) espeja SOLO identidad en aprobación (id/estado-ACTIVO/app/nombre/UA), NO mutaciones de estado. Los writers de `Forzar_Logout`/`Desbloqueo_Temporal_Hasta`/`Bloqueado_Desde`/`Forzar_Horario_Hasta`/`Alerta_Seguridad`/`Suspendido_Desde` están **dispersos en ~30+ `setValue` sin chokepoint** (Config.gs `actualizarDispositivo`/`extenderHorarioDispositivo`/`forzarPushDispositivo`/`consultarEstadoDispositivo`/`registrarSesionDispositivo` + crons Bloqueos.gs/SeguridadAlerts.gs/Horarios.gs) y escriben **hoja-only**. Con reverse-sync ON, la sombra (vieja en esas columnas) los **pisaría en ≤15min** → un logout/bloqueo forzado podría auto-revertirse. **Prerequisito de Fase 7:** espejar TODOS esos writers a `mos.dispositivos` (dual-write) ANTES de invertir el barrido. Es refactor dedicado, security-critical, 40x por sitio.
  - [x] 2a-final. **dryRun PARIDAD PERFECTA (2026-06-25):** `{actualizados:0, agregados:3, sinCambio:144, errores:[], diffPorColumna:{}}`. Diagnóstico por-columna confirmó que los 139 previos eran 100% churn de formato (ts Date-vs-string mismo instante + permisos_json JSONB key-order), CERO drift de estado/forzar. Fix: comparador semántico `_f4DiffHoja` (instante para ts, json canónico) + `_f4JsonCanon` → el barrido ya compara VALORES, no formatos.
  - [x] 2b. **FLIP APLICADO EN VIVO (2026-06-25):** `MOS_DISPOSITIVOS_DIRECTO='1'` + `dispositivos` agregado a `MOS_SYNC_OFF_TABLAS`. El resembrado invierte a Sombra→Hoja (no-op: +3 agregados, 0 cambios) + el catálogo deja de barrer dispositivos. Reversible al instante (flag a '0' = fail-open a Hoja→Sombra). La sombra ya es la VERDAD; los dual-writes GAS la adelantan, el reverse-sync mantiene la hoja como espejo para los ~13 lectores GAS.
  - [ ] 2c. **(pendiente, increment posterior):** Prender `dispositivosDirecto`/`deviceAuthDirecto` en el FRONT (escritura directa a sombra, saltando GAS) + deploy (SW bump). Hoy las escrituras van front→GAS→hoja+dualWrite-sombra (coherente, sombra-authoritative); 2c las hace front→sombra directo. Es cambio de frontend + su propio device-test.
  - [x] 2b-FIX. **Causa raíz del 1er flip fallido (2026-06-25): clasp PUSH actualiza HEAD (triggers ✓) pero NO el deployment versionado que llama el front.** El front (MOS/ME/WH) pega `aprobarDispositivoPendiente`/heartbeats al web-app `AKfycbxalFhPdiVi.../exec` (era @433, código viejo SIN dual-write) → aprobó la hoja pero no la sombra → el reverse-sync (HEAD, código nuevo) la revirtió. **Fix:** `clasp deploy -i AKfycbxalFhPdiVi... → @434`. Verificado: aprobar 1a3dca47 → sombra=ACTIVO en segundos (dual-write disparó). MOS/ME/WH device-auth TODOS apuntan a ese deployment (confirmado en los 3 index.html). Flag re-flipeado a '1'. **Lección: para cambios en endpoints web que el front consume, `clasp deploy -i <id>`, no solo push (ya estaba en memoria WH).**
  - [ ] 2d. **(usuario: validar bajo el flip)** Aprobá uno de los 2 pendientes restantes → debe QUEDAR (no volver). Probá también bloquear/desbloquear si querés. Si algo raro → aviso y revierto el flag a '0' (1 seg).
  - NOTA: lo headless-seguro de #2 está HECHO y verificado. Solo faltan tus 2 toques: **2a (correr dryRun 1 vez)** y **2d (test en device)**. El resto (2b/2c) es mío y es config + front.
- [ ] **3. Wizard de permisos** (`marcarWizardMostrado`, `registrarPermisosDispositivo`, index.html:19920/19970) → Supabase.
- [ ] **4. `consultarEstadoDispositivo`** (re-wizard, index.html:18737/19992) → Supabase + quitar URL GAS hard-codeada.
- [~] **5. Editor de adhesivos** (`EditorAdhesivos.abrir backendUrl`, index.html:19367) → backend Supabase/Edge. Audit: `AdhesivosPersonalizados.gs` (880 líneas) = CRUD plantillas + TSPL2 gen + PrintNode. 3 stages.
  - [x] **5-S1. Capa de datos (SQL 235, APLICADO + verificado, INERTE).** Tablas `mos.adhesivo_plantillas` (espejo de ADHESIVOS_PLANTILLAS: id/nombre/desc/tamano_canvas/json-jsonb/creado_por/fechas/activo, índice único nombre-activo ci) + `mos.adhesivo_iconos`. RPCs `adhesivo_plantillas_listar` / `adhesivo_plantilla_guardar` / `adhesivo_plantilla_eliminar` / `adhesivo_iconos_listar` — shape camelCase idéntico al GAS, grants authenticated (NO anon). Validador `mos._adh_validar` = port EXACTO de `_adhValidar` (6 tipos de capa, rangos), **con fix throw-free `jsonb_typeof='number'`** (el `::numeric` directo lanzaba con garbage). Round-trip 40x OK (válida/dup/inválida/garbage/listar/eliminar). Nadie lo llama aún → cero riesgo.
  - [x] **5-S2. Edge de impresión DESPLEGADO + VERIFICADO BYTE-A-BYTE (2026-06-25).** `tspl.mjs` = port de `_adhJson2tspl` (fuente única: lo testea `_verify_tspl_adhesivo.mjs` corriendo el algoritmo del GAS vs el port sobre 3 plantillas × 4 offsets cubriendo los 6 tipos de capa → **12/12 byte-idénticos**). Edge `print-adhesivo-plantilla` (verify_jwt app∈{MOS,mosExpress,warehouseMos}, body {idPlantilla,cantidad,dryRun}). RPC `mos.adhesivo_print_data` bundlea json+iconos+printerId(IMP004 75515047)+calib en 1 round-trip; `mos.adhesivo_inc_prints` para el drift. **24 iconos seedeados** desde iconos.js (hexTSPL, 288B c/u = los mismos que el GAS). Calib en mos.config (gap=3 existente + density/speed/offset/drift/prints seedeados). **E2E dryRun OK** (942B/2 etiquetas, TSPL correcto). Solo falta el envío físico (impresión de prueba del dueño valida calibración real del rollo).
  - [~] **5-S3. Front CABLEADO + desplegado (MOS 2.43.347, INERTE con gate OFF).** Contrato resuelto: `API.post` hace `d.data`+throw → ROMPERÍA al editor (que consume shape RAW {ok,plantillas}). Por eso NO se usa API.post; se hizo un **adaptador dedicado** `API.adhesivoEditorBackend(action,params)` que devuelve shape RAW (CRUD→RPCs `_sbRpcMOS('adhesivo_plantilla_*')`, imprimir/test→Edge `print-adhesivo-plantilla`), gate `mos_adhesivos_edge`/`adhesivosEdge` default OFF → **GAS RAW = idéntico a hoy**, con GAS de red de seguridad. index.html cablea `window.MOS_API={post:…adhesivoEditorBackend}` antes de abrir el editor (el editor ya delega ahí). Con gate OFF el editor opera EXACTO como hoy. **Falta el GO-LIVE:** (a) backfill de plantillas existentes (hoja ADHESIVOS_PLANTILLAS → mos.adhesivo_plantillas — necesita los datos de la hoja); (b) agregar `adhesivosEdge` a get_flags + flag '1'; (c) **impresión de prueba física**.
  - [x] **5-S3-recipe (histórico).**
  - [x] **5-FLIP (2026-06-25): `adhesivosEdge='1'` en get_flags (SQL 239).** Backfill dio 0 plantillas (no había) → flip seguro. El editor MOS ya lee/guarda/imprime por Supabase. Falta solo la validación física: crear 1 plantilla + imprimir (valida calibración real gap/offset; gap=3 es el de IMP004 que WH ya usa OK). KILL-SWITCH: `MOS_ADHESIVOS_EDGE='0'`. **#5 LIVE (pend. 1ª impresión de validación).** Hallazgo: `editor.js::_apiPost` ya delega en `window.MOS_API.post(action,params)` si existe (sino cae al `backendUrl`=GAS). Las 5 acciones (guardar/eliminar/listar/imprimir/testImpresion) pasan por ese chokepoint. Pasos: (1) exponer `window.MOS_API = API` en MOS index.html antes de abrir el editor; (2) agregar las 5 acciones al router `post` de api.js (~2321) con `_conFallbackMOS(direct, gas, _mosAdhesivosEdge)`: listar→`adhesivo_plantillas_listar`, guardar→`adhesivo_plantilla_guardar`, eliminar→`adhesivo_plantilla_eliminar`, imprimir/test→Edge `print-adhesivo-plantilla`. Las RPCs YA devuelven el shape camelCase del GAS ({ok,plantillas}/{ok,idPlantilla,creado}/{ok,eliminado}) → contrato directo con los callbacks del editor (verificar que API.post NO re-desempaquete esa respuesta). Gate `mos_adhesivos_edge` default OFF = idéntico a hoy. SW bump + deploy. (3) **Backfill de plantillas existentes** desde la hoja ADHESIVOS_PLANTILLAS a mos.adhesivo_plantillas (las que el dueño ya creó). (4) **Impresión de prueba física** del dueño valida calibración. Cuidado del shape contract: revisar 40x antes de exponer window.MOS_API (no romper el editor).
- [~] **6. `meConsultarCliente`** SUNAT/RENIEC → Edge function (HTTP externo, sin GAS).
  - [x] 6a. Edge `consultar-documento` ESCRITA (port exacto de Catalogo.gs APISPeru, mismo shape, secret APISPERU_TOKEN). functions/consultar-documento/index.ts.
  - [x] 6b-deploy. **Edge `consultar-documento` DESPLEGADO (2026-06-25, yo).** Falta solo el secret: `supabase secrets set APISPERU_TOKEN=<token> --project-ref rzbzdeipbtqkzjqdchqk` **(usuario)** — hasta entonces el Edge devuelve TOKEN_NO_CONFIGURADO (inocuo, nada lo llama con el flag OFF).
  - [x] 6c. **api.js CABLEADO + desplegado (MOS 2.43.346, INERTE).** `meConsultarCliente`: tras miss de sombra, el live-lookup va al Edge si `_mosSunatEdge()` (gate `mos_sunat_edge`/`sunatEdge`, default OFF) está ON, con GAS como red de seguridad; con OFF va recto a GAS = IDÉNTICO a hoy. Helpers `_meConsultarClienteEdge` (mint app=MOS + POST {doc}; devuelve success/not_found, null en error de infra→GAS) + `_mosSunatEdge` (mirror exacto del precedente `_mosImpresorasPNEdge`). Shape verificado contra app.js:26593/26706 (`r.nombre||r.razon_social` + `r.direccion`; el Edge trae nombre+direccion). node -c OK.
  - [x] **6-CROSS-APP (2026-06-25, ME 2.8.72): ME también migrado.** El usuario detectó que ME (MosExpress) hace su PROPIO lookup DNI/RUC (3 sitios: buscarClienteAPI + adminBuscarCliente + adminEditCliBuscar, vía su GAS `?accion=consultar_cliente`). Migrados al MISMO Edge vía helper `_meBuscarClienteDoc` (mint-me claim `mosExpress` — **verificado E2E** —, gate `MOS_SUNAT_EDGE` mismo interruptor global, GAS de red de seguridad, doc incompleto→GAS conserva 'validacion'). `me.get_flags` expone `MOS_SUNAT_EDGE` (SQL 237). **WH NO consulta DNI/RUC** (almacén, verificado) → #6 cero-GAS en TODO el ecosistema. Deploy ME 2.8.72.
  - [x] **6-golive. PRENDIDO Y COMPLETO (2026-06-25).** (1) `APISPERU_TOKEN` seteado en Supabase secrets (token del dueño, válido — verificado contra APISPeru directo). (2) Edge verificado **E2E**: mint MOS (device real ACTIVO) → `consultar-documento` → RUC 20131312955 = SUNAT `success`+dirección, DNI = `success`+nombre. (3) Flag global: SQL 236 agrega `sunatEdge` a `get_flags` (+ seed `MOS_SUNAT_EDGE='1'`, 22 keys preservadas). Front 2.43.346 lo consume → meConsultarCliente va al Edge, GAS solo de red de seguridad. **KILL-SWITCH:** `update mos.config set valor='0' where clave='MOS_SUNAT_EDGE'`. **#6 ✅ CERO GAS en SUNAT/RENIEC.**
- [ ] **7. `setHorarioApp`** — quitar el disparo GAS; requiere que WH/ME lean el horario de Supabase (cross-app, nota).
- [~] **8. `liquidacion.html` / `turno.html`** — auditar su capa GAS y migrar.
  - [x] **8-turno-RPC (2026-06-25): `me.datos_turno(p_id_caja)` LISTO + VERIFICADO 40x (SQL 241).** Port money-exact de `Cajas.gs::datosTurno` (cajas/ventas/detalle/movimientos_extra/estaciones/impresoras/auditorias/jornadas + totales efectivo/virtual/MIXTO/extras/credito/anulados + correlativos + vendedores + meta/comisión). Todas las fuentes en Supabase (me.* + mos.*). **Verificación triple:** (1) harness replica la lógica GAS vs RPC = exacto en 6 cajas reales (incl. MIXTO + extra virtual + cajón negativo); (2) cómputo SQL independiente de montoFinalEfe coincide (106.7, 319.3); (3) shape `data.totales.*` == GAS (Cajas.gs:72) == turno.html (`const t=data.totales`, línea 305). INERTE (nadie lo llama aún).
  - [ ] **8-turno-WIRING (recipe):** (1) ME (`index.html` ~12900, flujo de cierre — money-critical, 40x) pasa a turno.html `&sb=<SB_URL>&anon=<ANON>&tok=<_mintTokenSB()>` además de `&api`; (2) turno.html: si hay sb+tok (+gate), `POST ${sb}/rest/v1/rpc/datos_turno {p_id_caja}` con el token → devuelve `{ok,data}` (mismo shape, `render(json.data)` directo), si no GAS. (3) **Edge Z-cierre** para `imprimirTicketZCierre` (ESC/POS PrintNode) + **impresión de prueba física**. El RPC (lo difícil/money) ya está; falta el cableado del path de cierre + el Edge de impresión.
  - [ ] **8-liquidacion:** bloqueado en portar el motor de evaluación (`getResumenDia`) a SQL — proyecto aparte.

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
