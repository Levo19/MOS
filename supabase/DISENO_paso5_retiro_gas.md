# PASO 5 — Retiro de GAS de warehouseMos (plan de arquitectura)

> Estado base (al cerrar la sesión 2026-06-13): PASO 3 (11 lecturas LIVE vía GAS→Supabase, paridad verificada) +
> PASO 4 (7 RPCs de escritura atómicas, inertes, validadas 77 casos + 2 auditorías 40x + integridad de stock).
> El PASO 5 es un REDISEÑO (no ejecución lineal): mover auth + lectura + escritura + orquestación al frontend/Edge
> para que GAS deje de ser necesario. Requiere decisiones del usuario y se ejecuta por bloques, cada uno con 40x.

## Por qué GAS sigue siendo necesario HOY (lo que el PASO 5 debe reemplazar)
1. **Auth**: el frontend WH no tiene JWT propio de Supabase. Hoy GAS es quien habla con Supabase (service_role).
2. **Lecturas**: el frontend pide a GAS (`API.get`), GAS lee Supabase/Sheets. El navegador no toca Supabase.
3. **Escrituras**: idem — GAS orquesta y escribe (Sheets + dual-write). Las 7 RPCs existen pero gated por service_role.
4. **Orquestadores**: envasado, aprobar_preingreso, auditar_producto, agregar_detalle_guia — lógica + catálogo en GAS.
5. **Catálogo**: validación de productos (PRODUCTOS_MASTER/EQUIVALENCIAS) vive en MOS Sheets, leída por GAS.
6. **Infra GAS-only**: cola offline de escrituras, impresión PrintNode (ZPL), subida de fotos a Drive, push a MOS.

## Bloques del PASO 5 (orden por dependencia, más fundacional primero)
### B1 — Auth propia de WH ✅ HECHO Y VALIDADO 40x (2026-06-13)
`mintSupabaseTokenWH` (Fase2AuthWH.gs) + endpoint `mintTokenWH` + `wh.ping_auth` (38_wh_ping_auth.sql).
Validado empíricamente: estructural (payload app=warehouseMos), FUNCIONAL (PostgREST acepta la firma →
`wh.ping_auth` devuelve app=warehouseMos), y rechazo (deviceId inexistente). `SUPABASE_JWT_SECRET` configurado en WH.
PENDIENTE menor: gate horario (defense-in-depth, ME lo tiene), deploy a los 5 IDs (hoy en 1, validación). NO usado aún.

**DIAGNÓSTICO (2026-06-13):** `me.jwt_app()` YA EXISTE y es GENÉRICA (lee el claim `app` del JWT) → **reutilizable
para WH**, solo comparar con `'warehouseMos'`. NO crear `wh.jwt_app()`. Los 7 flags `WH_*_DIRECTO` ya están en mos.config.
**FALTA SOLO:**
1. `mintSupabaseToken` en el GAS de WH (HS256, exp 5min, claim `app='warehouseMos'`, sub=deviceId), validando deviceId
   contra DISPOSITIVOS (ACTIVO, App warehouseMos) + ventana horaria. **Replicar de `Fase2Auth.gs` de ME.**
2. ⚠️ **PRE-REQUISITO DE CONFIG**: `SUPABASE_JWT_SECRET` en las Script Properties de WH (mismo proyecto
   rzbzdeipbtqkzjqdchqk → mismo secret que ME). VERIFICAR/CONFIGURAR antes de implementar el mint. (No verificable
   por SQL; lo confirma el usuario o se setea desde el editor de Apps Script de WH.)
3. Endpoint liviano en WH GAS para que el frontend pida el token. Validar: mint → llamar una RPC `wh.*` con el token
   → `me.jwt_app()` devuelve 'warehouseMos'.
- Referencia: `16_fase2_rls_ventas_zona.sql` (ME) + `Fase2Auth.gs` (ME `mintSupabaseToken`).

### B2 — RLS en las RPCs de escritura ✅ HECHO Y VALIDADO (2026-06-13)
Helper `wh._claim_ok()` (service_role/sin-claim O claim `warehouseMos`) agregado tras el flag check en las **12**
RPCs + `grant ... authenticated`. Validado: claim `mosExpress`→APP_NO_AUTORIZADA; `warehouseMos`→pasa; service_role
(GAS)→sigue; funcionalidad intacta. Todas siguen INERTES (flags en 0). DECISIÓN del usuario: **GAS cero** (objetivo).

### B3 — Lecturas directas desde el navegador
✅ **B3-BACKEND HECHO (2026-06-13)**: wrappers `wh.stock_enriquecido_rls` / `wh.rotacion_semanal_rls` (45_wh_rls_lecturas.sql)
con gate `_claim_ok` + grant authenticated, validados 5/5. **El backend completo del PASO 5 está listo** (B1+B2+B3-backend).
🟡 **B3-FRONTEND — INFRAESTRUCTURA HECHA + 2 lecturas (2026-06-13, INERTE)**: en `js/api.js` se agregó el cliente
directo a Supabase, **inerte** por defecto (gate `_whLecturaDirecta()` = `localStorage 'wh_lectura_navegador'==='1'`
o `WH_CONFIG.lecturaNavegador`). Piezas (replican el patrón probado de ME): `_SB_URL`/`_SB_ANON` (públicos),
`_sbTok` cache + `_mintTokenWH()` (POST a GAS `mintTokenWH`, dedup in-flight, re-mint 30s antes de exp, timeout 6s),
`_sbRpcWH(fn,args)` (apikey+Bearer token+Content/Accept-Profile: wh, timeout 12s), `_callDirecto(params)`. `call()`
intenta directo SOLO si flag on + online + acción mapeada; **fallback TOTAL a GAS ante cualquier fallo**. Cableadas:
`getStock`→`wh.stock_enriquecido_rls` (shape `{ok,data:[...]}` idéntico) y `getRotacionSemanal`→`wh.rotacion_semanal_rls`.
Validado: `node -c` OK; PostgREST expone `wh` (ping_auth HTTP 200); `stock_enriquecido_rls` con anon→`permission denied`
(CORRECTO: grant es a `authenticated`; el frontend usa el token role=authenticated, no el anon). SW 2.13.194.
🟢 **B3-FRONTEND — 2da tanda (2026-06-13): RPC genérica + transformador en front.** Backend: `46_wh_leer_tabla_rls.sql`
= `wh.leer_tabla_rls(p_tabla)` con whitelist (10 tablas) + `jsonb_agg ... order by PK` (1 request, SIN límite db-max-rows,
orden = `_leerTablaWH`/pk.asc) + gate `_claim_ok` (validado 16/16: 10 tablas ok, whitelist+inyección rechazadas,
claim ajeno→APP_NO_AUTORIZADA, claim vacío/GAS pasa). Front (`js/api.js`): portado FIEL de `_sbRowsToObjsWH`/`_sbValToSheet`
(`_WH_SPECS_LEC` subset + `_sbValFront` + `_fmtFechaLima` en-CA TZ Lima + `_sbLeerTablaWH`). Cableadas en `_callDirecto`
las 5 lecturas SIMPLES con filtros idénticos a GAS: getMermas, getAuditorias, getAjustes, getProductosNuevos, getPreingresos.
Validado 10/10 contra datos reales (1209 auditorías/473 ajustes/…): cero typo de porte, fechas yyyy-MM-dd, nums numéricos.
**Total directo hoy: 7 lecturas** (stock+rotación por RPC propia + estas 5). Todo INERTE (flag `wh_lectura_navegador`).
⏳ **B3-FRONTEND — RESTA**: (a) cablear las lecturas con LÓGICA DERIVADA (replicar su post-proceso JS sobre `_sbLeerTablaWH`):
getProductosNuevosRecientes (tipoAprobacion+corte fecha), getLotesVencimiento (diasRestantes+filtros), getMermasEnProceso
(diasEnProceso/vencida+sort), getMermasVencidas (shape {count,mermas}), getGuias (agrupación día TZ Perú), getStockMovimientos
(filtro cod_producto); (b) **validación e2e con token real** (mint→RPC→datos) = parte de B6; (c) deploy + activar flag.
Plan original de pasos (referencia):
1. **Cliente Supabase en el front**: agregar supabase-js (o fetch directo a `/rest/v1/rpc/`). Helper `_sbDirect(fn,args)`
   que manda `apikey: <anon>` + `Authorization: Bearer <token B1>` + `Accept-Profile: wh`. El token se pide a GAS
   (endpoint `mintTokenWH`, ya existe) y se cachea ~4min con re-mint en heartbeat (igual que ME).
2. **RLS de LECTURA**: hoy las RPCs de lectura (`wh.stock_enriquecido`, `wh.rotacion_semanal`) son `service_role`.
   Para lectura directa del navegador → `grant ... to authenticated` + gate `wh._claim_ok()` (igual que B2). Para
   lectura de TABLAS `wh.*` directo → habilitar RLS con policy `me.jwt_app()='warehouseMos'`. Stock PAGINADO.
3. **Patrón en `api.js`**: `API.get(action)` → si flag `WH_LECTURA_NAVEGADOR` on y hay token → `_sbDirect`; si falla → fallback a GAS.
   Las 11 lecturas ya tienen paridad verificada → el riesgo es auth/RLS, no datos.
4. **Validación B3**: con el token real, llamar cada RPC/tabla desde un script que simule el navegador (apikey+Bearer)
   y comparar contra GAS (gate). Flag por módulo + fallback. 40x: token expirado, sin token, claim ajeno, paginación stock.

### B4/B5/B6 (resumen; requieren su sesión)
- **B4**: el front compone los orquestadores (aprobar_preingreso, auditar, envasado) llamando las RPCs atómicas (B2).
- **B5 (GAS cero)**: Edge Functions (Deno) para PrintNode (ZPL), IA, y proxy de fotos de Drive (Supabase como
  intermediario, el usuario lo pidió). `supabase functions deploy` — OJO: el deploy de Edge falló antes en esta
  máquina (login no-TTY); el usuario deployó ME con token. Mismo camino.
  - ✅ **B5-PrintNode (2026-06-13): RESUELTO POR REUSO**. La Edge `imprimir` (ProyectoMOS/supabase/functions/imprimir)
    ya existía (proxy genérico PWA→PrintNode con PRINTNODE_API_KEY secret). Se hizo MULTI-APP (`APPS_OK={mosExpress,warehouseMos}`)
    → WH la reusa. Formato: POST {printerId, title, content(raw_base64), } → PrintNode 201. FALTA: **el usuario re-deploya**
    (`supabase functions deploy imprimir --project-ref rzbzdeipbtqkzjqdchqk`) + wiring front WH (api.js: imprimirBienvenida/
    cajas/etiquetas → llamar la Edge con token en vez de GAS). El ESC/POS/ZPL lo arma el front (ya lo hace GAS, portar).
  - ⏳ **B5-fotoDrive**: Edge nueva que suba/sirva fotos. GAS usa `_subirFotoMerma`/Drive. Necesita service account de Google
    (secret) + el código. O migrar a Supabase Storage (el usuario dijo mantener Drive + proxy).
  - ⏳ **B5-IA**: Edge para OCR boleta / parser listas. GAS llama la IA (ver Claude/key). Necesita key (secret) + código.
- **B6**: cutover por módulo (lectura→escritura→orquestación) con flag + fallback + validación de operación REAL
  (operario usando el almacén), luego apagar GAS. Conservar GAS solo si algo de B5 no migró.

### B4 — Orquestadores (los que quedaron en GAS)
- Opción A (recomendada): el FRONTEND los compone llamando varias RPCs atómicas (crear_guia + agregar_detalle_guia
  + cerrar_guia + crear_ajuste). Falta crear las RPCs chicas: `agregar_detalle_guia` (catálogo+auto-suma+lote),
  `get_o_crear_guia_dia`, `marcar_preingreso_procesado`, `crear_auditoria`, y la de envasado.
- Opción B: dejar los orquestadores en un Edge Function (Deno) que reemplace al GAS orquestador.
- Catálogo: el frontend valida productos leyendo `mos.productos`/`mos.equivalencias` directo (RLS lectura).

### B5 — Infra GAS-only → mover/reemplazar
- **Cola offline**: el frontend ya tiene `pendingSales`-style; reapuntar a RPCs directas con idempotencia (las RPCs
  ya son idempotentes por id). 
- **PrintNode (ZPL/etiquetas)**: hoy GAS proxy. Mover a una Edge Function `imprimir` (como ME ya tiene) o mantener
  un GAS mínimo solo para impresión.
- **Fotos a Drive**: mover a Supabase Storage, o mantener GAS mínimo. **Push a MOS**: Edge o mantener.

### B6 — Cutover gradual + apagado de GAS
- Flag `WH_DIRECTO_TOTAL` + fallback a GAS por módulo. Activar módulo por módulo (lectura → escritura → orquestación),
  validando operación real en cada uno. GAS queda como fallback hasta confirmar estabilidad N días.
- Apagar GAS recién cuando todos los módulos corran directo y estables. Conservar el GAS mínimo de impresión/fotos
  si no se migraron a Edge.

## Riesgos / decisiones del usuario
- ¿Migrar PrintNode y fotos a Edge/Storage, o mantener un GAS mínimo? (define si GAS se apaga del todo o queda residual).
- Offline: el frontend WH debe soportar cola offline contra Supabase directo (hoy depende de GAS).
- Es un proyecto de varias sesiones; cada bloque con su 40x. NO empezar sin decidir el alcance (¿GAS cero, o GAS mínimo?).

## Lo YA listo que el PASO 5 reutiliza
- 7 RPCs de escritura atómicas (inertes, validadas, auditadas 40x) — B2 solo les cambia el gate.
- 11 lecturas con paridad verificada — B3 solo cambia quién las llama (navegador vs GAS).
- Integridad de stock (índice único) — base sólida para escritura directa concurrente.
- Patrón de auth/flags/cutover de ME (probado en producción) — plantilla para B1/B6.
