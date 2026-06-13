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
⏳ **B3-FRONTEND (resta)**: toca el **`index.html`/`js/api.js` de WH**. Pasos:
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
