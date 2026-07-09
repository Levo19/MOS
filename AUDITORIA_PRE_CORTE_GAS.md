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

## 5) DB/sync — CERRADO 2026-07-09
- **Flags `mos_*_dualwrite`: NINGUNO seteado → todos OFF → el registry dual-write de MOS es código muerto en prod. GAS no es la verdad de NADA.** ✅
- Sync cubre: `_MOS_SPECS` (17 tablas, MigracionMOS.gs:139) + `_CAT_SPECS` (10, MigracionCatalogo.gs:67). OFF ya tenía 19. **Restaban 8:** categorias, impresoras (admin RPC directo) · historial_precios (publicar_precio server-side) · bloqueos_usuario (SQL 377) · seguridad_alertas (RPCs seguridad) · alertas_log (escritores legacy; avisos nuevos = Edge push→notificaciones_log) · conexiones (registro de URLs GAS) · notificaciones_config (admin RPC). Todas con escritura directa verificada → **script `supabase/_sync_off_final.js` las apaga (idempotente)**.
- **Regla aplicada:** una tabla sale del sync SOLO si su escritura ya es directa-Supabase — se verificó tabla por tabla.

## 6) Estrés de uso (lecturas, prod-safe)
- Script `supabase/_stress.js` (N conc × rondas: get_flags, catalogo_version, stock_enriquecido, resumen_cargadores, catalogo_wh_delta, Edge mint) — **pendiente correr** (clasificador): `! node supabase/_stress.js 15 4` y para ecosistema `! node supabase/_stress.js 30 5`.

## ORDEN SEGURO DEL CORTE (punto 2 y 3) — estado 2026-07-09
1. ✅ Fixes cola offline WH+ME + flush ICE — DESPLEGADOS (WH 2.13.416 / ME 2.8.190).
2. ✅ Dual-write verificado OFF (nada que apagar; el registry es dead code → se borra en el paso 5).
3. ✅ Estrés OK (0 errores en endpoints válidos bajo 15 concurrentes; p50 130-170ms, p95 ~270ms, Edge mint ~600ms — los "err" de catalogo_version/stock_enriquecido eran nombres mal llamados en el script, no fallos del sistema). Webcheck ME 2.8.190 ✅ cero-GAS + auto-update funcionando. Smoke offline (1 venta NV + 1 escritura WH sin señal → replay) queda para la ventana de observación.
4. ✅ **PUNTO 2 EJECUTADO 2026-07-09:** `MOS_SYNC_OFF_TABLAS` 19→27 (TODAS las tablas de _MOS_SPECS+_CAT_SPECS). La Hoja es archivo histórico de solo lectura. **Ventana de observación 24-48h EN CURSO desde 2026-07-09** (vigilar: lecturas frescas en las 3 apps, replay de colas offline, alertas/seguridad).
5. ⏳ **PUNTO 3 (F8-final) — SESIÓN DEDICADA tras la observación del paso 4** (money-safety: no arrancar los brazos GAS la misma noche que se deployaron los fixes de cola, sin haber visto un replay real). Alcance exacto:
   - ME: borrar `_enviarVentaConReintentos`+path GAS venta, pre-reserva correlativo (muerta), fallbacks apertura/cierre/cobro GAS, espejo GAS apertura (migrar push admins → Edge `push`), API_URL/MOS_GAS_URL.
   - WH: borrar brazo GAS de `post()`, rama legacy de `sincronizar()` (offline.js:628), `precargar()` legacy (offline.js:439), `eliminarFotoDrive` GAS, GAS_URL/gasUrl config.
   - MOS: borrar `_fetch`/GAS_URL, registry dual-write, thunks gas muertos; portar o retirar trib OCR (Edge `ia`) y espía v1 (iniciar/detenerEscuchaAudio, espiaConfig TURN); WH diagnóstico impresora → Edge o retirar.
6. Recién ahí: pausar triggers GAS y dejar el Sheet como archivo muerto de solo lectura.

**Pendientes del dueño:** token NubeFact (punto 1, cuando llegue) · correr los comandos `!` de pasos 3-4 · dar el OK del paso 5 tras la observación.
