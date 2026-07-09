# AUDITORÍA PRE-CORTE GAS — 2026-07-08/09
**Objetivo:** cortar GAS+Sheets sin perder datos. 4 vistas: código estático (3 apps) · navegador real (browsercheck) · DB/flags · estrés de uso.
**Veredicto corto:** el corte es seguro DESPUÉS de los fixes de cola offline (ya aplicados, pend. deploy) + decisión de sync. Bloqueantes fiscales del CPE cerrados en código.

## 1) MOS admin — inventario GAS
- **Lecturas: CERO-GAS estructural.** `_conFallbackMOS` ya nunca cae a GAS (api.js:274-284; los thunks `gas` son argumentos muertos). Escrituras: dual-write registry (proveedores/pedidos/provprod/gastos/jornadas/evaluaciones) gated por flags `mos_*_dualwrite` — **verificar estado en prod** (si OFF → rama muerta; si ON → GAS=verdad para esas 10 acciones → APAGAR ANTES del corte).
- **GAS-ONLY reales:** `tribReprocesarOCR` (app.js:32269) y `tribOCRMasivo` (32456) — pipeline OCR server-side (Drive+Vision GAS); herramienta admin, NO dinero directo; queda rota al corte hasta portar a Edge `ia`+Storage. `espiaConfig` (29977, TURN — degrada a STUN sin romper). `iniciar/detenerEscuchaAudio` (canal comandos espía v1; v2 WebRTC no lo usa).
- **FALLBACK-PASIVO:** espía signaling master (`_ESPIA_RPC_MASTER` Supabase-first) · adhesivos crear/imprimirSub (Edge-primario, GAS solo si flag OFF) · trib Reintentar/Reconciliar CPE (Edge-first) · resto de _MOS_POST_DIRECTO con gate ()=>true.
- **MUERTO:** bloque device-auth if(false) YA eliminado (2.43.472) · thunks gas de lecturas.

## 2) ME (POS, dinero) — inventario GAS
- **Venta NV:** online=Supabase exclusivo; negocio bloquea (no GAS); infra→cola `direct:true`→replay Supabase. CERO-GAS total. ✅
- **Venta CPE:** online=Supabase+Edge; ~~infra→fallback GAS~~ / ~~offline→cola legacy→GAS~~ → **CORREGIDO 2026-07-09**: infra Y offline encolan `direct+cpe` → replay `_crearCPEDirecto` (idempotente por ref_local, reimpresión QR post-sync). Cierra task #20. El path `_enviarVentaConReintentos`→GAS queda solo para flags OFF (fallback-pasivo, borrable en el corte).
- **Cola offline `pendingSales`:** destino = Supabase para TODO ítem `direct` (NV y ahora CPE); legacy sin marca → GAS (solo nace con flags OFF).
- **Apertura caja:** Supabase=verdad + fire-and-forget GAS (espejo Hoja + **push admins** — ÚNICO efecto a migrar: Edge `push` al abrir). Cierre/cobros: Supabase-first, GAS pasivo.
- **Pre-reserva correlativo (18657-18708):** MUERTA con escritura directa ON.
- **Espía device:** signaling Supabase-first; flush ICE final **corregido** (antes GAS-only); chunks → Edge (F4).

## 3) WH (almacén, stock) — inventario GAS
- **Lecturas `call()`:** sin brazo GAS (directo→caché). ✅ Escrituras dinero/stock: TODAS en `_postDirecto`. ✅
- **⚠️ COLA OFFLINE (bloqueante #1) → CORREGIDO 2026-07-09:** ítems encolados SIN red no llevaban sello → `sincronizar()` los replayaba a GAS (guía/envasado/despacho sin señal = perdidos al morir GAS). Fix: sello `_viaDirecta:true` al encolar offline (api.js) → replay SIEMPRE `API._postCola`→directo.
- **GAS-ONLY menores:** diagnóstico impresora (iniciar/finalizarTest — decidir Edge mode o retirar panel) · `eliminarFotoDrive` fotos LEGADAS Drive (dato viejo) · `detenerEscuchaAudio`+beacon espía (vigilancia) · `asegurarTriggerLotes` (muere con GAS, aceptable).
- **A retirar en el corte:** `precargar()` rama legacy (offline.js:439-449 — puede envenenar caché con Hoja congelada) · brazo GAS de `post()`/`sincronizar()` (si queda URL muerta: 3 reintentos+timeout por acción; si se vacía: encole infinito).
- **Portales cliente:** 100% Supabase. ✅ Fotos legadas Drive: siguen visibles mientras exista el archivo en Drive (independiente de GAS).

## 4) Navegador real (browsercheck)
- MOS 2.43.478 ✅ boot cero-GAS, auto-update, sin pageerror. WH 2.13.415 ✅ red 100% SB-REST.
- ME: **pendiente 1 corrida** (`! node browsercheck/check.js browsercheck/gaskill_me.json`).

## 5) DB/sync
- Sync Hoja→Supabase LATIENDO (heartbeats 2026-07-08 23:40 · TTL mos=30min, catálogo=180min). `MOS_SYNC_OFF_TABLAS` ya cubre: proveedores, proveedores_productos, config_horarios_apps, gastos, pagos_proveedor, pedidos_proveedor, evaluaciones, jornadas, et… (lista completa + flags dualwrite = pendiente lectura, clasificador bloqueó).
- **Regla del corte de sync:** una tabla se saca del sync SOLO si su escritura ya es directa-Supabase (si no, la Hoja avanza y la sombra se congela = lecturas viejas). Con los inventarios de arriba: todas las escrituras de dinero/stock son directas → el sync es redundante SALVO para las acciones dual-write de MOS (si sus flags están ON).

## 6) Estrés de uso (lecturas, prod-safe)
- Script `supabase/_stress.js` (N conc × rondas: get_flags, catalogo_version, stock_enriquecido, resumen_cargadores, catalogo_wh_delta, Edge mint) — **pendiente correr** (clasificador): `! node supabase/_stress.js 15 4` y para ecosistema `! node supabase/_stress.js 30 5`.

## ORDEN SEGURO DEL CORTE (punto 2 y 3)
1. ✅ Fixes cola offline WH+ME + flush ICE (aplicados → deploy WH 2.13.416 / ME 2.8.190).
2. Verificar flags `mos_*_dualwrite` en prod; si alguno ON → apagarlo (la escritura directa+shadow-críticas ya cubren) → esas 10 acciones quedan directo-puro.
3. Correr estrés + webcheck ME (arriba). Smoke: 1 venta NV offline→replay, 1 escritura WH offline→replay.
4. Apagar sync restante tabla por tabla (agregar a MOS_SYNC_OFF_TABLAS) empezando por las ya-directas; 48h de observación con Hoja viva de solo-lectura.
5. F8-final: borrar brazos GAS (ME `_enviarVentaConReintentos`+path GAS, WH `post()` brazo+`sincronizar()` rama legacy+`precargar()` legacy, MOS `_fetch`/GAS_URL/dual-write registry) + decidir GAS-only menores (trib OCR→Edge ia; diagnóstico WH→Edge/retirar; espía v1→retirar).
6. Recién ahí: pausar/borrar GAS (dejar el Sheet como archivo muerto de solo lectura).

**Pendientes del dueño:** token NubeFact (punto 1, cuando llegue) · decisión fecha del corte de sync (paso 4).
