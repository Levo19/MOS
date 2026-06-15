# B6 — Cutover de warehouseMos (encender lo migrado, módulo por módulo, con rollback)

> TODO lo migrado nació INERTE con fallback total a GAS. El cutover activa por fases, de MENOR a MAYOR riesgo,
> validando con OPERACIÓN REAL en cada una. Rollback siempre = apagar el flag → vuelve a GAS al instante.
> Regla: activar en 1 dispositivo de prueba primero; recién si valida, extender. Nunca dos fases el mismo día.

## Flags (dónde se prenden)
- **Lectura navegador**: `localStorage 'wh_lectura_navegador'='1'` (por dispositivo) o `WH_CONFIG.lecturaNavegador` (server).
- **Escritura navegador** (incluye fotos+IA): `localStorage 'wh_escritura_navegador'='1'`.
- **Autorización directa**: Script Property `WH_AUTH_DIRECTO='1'` (GAS WH).
- **Escritura de stock por RPC** (server, kill-switch fino): `mos.config` `WH_<OP>_DIRECTO='1'` — crear_ajuste, crear_guia,
  agregar_detalle_guia, cerrar_guia, reabrir_guia, auditar_producto, aprobar_preingreso, registrar_envasado, registrar_merma,
  actualizar_preingreso, actualizar_foto_guia. Apagarlos → la RPC devuelve `*_OFF` → el cliente cae a GAS.

## Orden de activación (cada fase: activar → validar real → OK sigue / falla rollback)
### ✅ Fase 1 — LECTURA — EJECUTADA Y VALIDADA EN PROD (2026-06-14)
1. `wh_lectura_navegador='1'` activado en 1 dispositivo (deploy v2.13.195 / cache warehouse-v2.13.195 confirmado).
2. VALIDADO: Network mostró `stock_enriquecido_rls` + `leer_tabla_rls` ×10 todas **200** (RLS autoriza, no cae a GAS);
   el usuario confirmó paridad VISUAL (stock/guías/dashboard idénticos a GAS). Sin errores.
3. PENDIENTE: dejar en soak (uso real unas horas/1 día) en este dispositivo → si OK, extender a todos. Rollback: borrar el flag.
   REGLA: no activar Fase 2 el mismo día.

### Fase 2 — AUTORIZACIÓN
1. `WH_AUTH_DIRECTO='1'`.
2. Validar: una acción admin (reabrir guía) pide clave 8díg → autoriza directo (`mos.verificar_clave_admin`) + queda en `mos.auditoria_admin`.
3. Verificar que un admin NO puede una acción master-only (NIVEL_INSUFICIENTE). Rollback: flag a '0' → HTTP-MOS.

### Fase 3 — FOTOS + IA (van con escritura navegador, pero NO mueven stock → bajo riesgo)
1. `wh_escritura_navegador='1'` en 1 dispositivo (con stock-flags aún en 0 → solo fotos/IA pasan; el resto cae a GAS por `*_OFF`).
2. **OCR**: aplicar `63_wh_guardar_ocr_guia.sql` (con token nuevo) + `WH_GUARDAR_OCR_GUIA_DIRECTO='1'`. Subir foto de una FACTURA real
   a una guía → verificar que persisten ocr_estado/igv_recuperable/etc. en wh.guias. Kill-switch para probar fotos SIN IA: `localStorage 'wh_ocr_off'='1'`.
3. Validar: subir una foto (aparece en Storage `wh-fotos/...`, se ve el preview), analizar una lista sombra (IA), imprimir (PrintNode Edge).
4. Rollback: borrar el flag.

### ✅ RESUELTO — bug del cruce de fallback (hallazgo 40x del contrato GAS↔Supabase) — v2.13.195
**Era**: la cola offline reintentaba SIEMPRE a GAS; GAS dedupea por su SYNC_LOG (que Supabase no comparte) → una RPC que
COMMITEA pero pierde la respuesta (timeout) caía a GAS → **DUPLICADO** (doble-stock).
**FIX aplicado (inerte con flag OFF — camino actual idéntico)**:
1. `post()`: `_postDirecto`→`null` = la RPC NO commiteó → GAS seguro; `_postDirecto` LANZA (timeout) = pudo commitear →
   NO GAS, encolar para reintento DIRECTO (idempotente por el id sembrado del localId).
2. `sincronizar()` (offline.js): si `API._escrituraDirectaActiva()` → reintenta vía `API._postCola(item.params)` (post()
   directo, dedupea por M_/G_+lid); si OFF → `fetch(gasUrl)` legacy (idéntico a antes).
3. `_fromQueue`: guard anti-re-encolado en los 2 puntos (timeout directo + `_doFetchWithRetry`) → sin loop/doble-cola.
**Verificado 40x**: default `return null` (línea 830) → acción no migrada va a GAS (sin loop); TODAS las escrituras-INSERT
están en `_IDEMPOTENT_ACTIONS` (localId estable → dedup); UPDATE/DELETE idempotentes naturales; guard de carga `window.API`.
`node -c` OK (api.js + offline.js). LECTURA/catálogo/auth/FOTOS nunca tuvieron este bug → Fases 1-3 ya estaban OK.

### Fase 4 — ESCRITURA DE STOCK (mayor riesgo — uno por uno, validando stock; el bloqueante del cruce ya se resolvió)
Con `wh_escritura_navegador='1'` ya activo, prender los `WH_<OP>_DIRECTO` de a UNO en mos.config. **26 flags en total** (el frontend cae a GAS por `*_OFF` mientras estén en '0' — activar TODOS para GAS-cero; activar parcial = convivencia parcial OK pero recordar que lo no-activado sigue en GAS).
**Grupo A — NO tocan stock (activar primero, bajo riesgo):** WH_ACTUALIZAR_FOTO_GUIA_DIRECTO, WH_ACTUALIZAR_PREINGRESO_DIRECTO, WH_ACTUALIZAR_GUIA_DIRECTO, WH_ACTUALIZAR_FECHA_VENCIMIENTO_DIRECTO, WH_GUARDAR_OCR_GUIA_DIRECTO, WH_MARCAR_ALERTA_REVISADA_DIRECTO, WH_CREAR_PREINGRESO_DIRECTO, WH_MARCAR_PREINGRESO_PROCESADO_DIRECTO, WH_CREAR_AUDITORIA_DIRECTO, WH_GET_O_CREAR_GUIA_DIA_DIRECTO, WH_ADD_CARGADOR_DIA_DIRECTO, WH_REMOVE_CARGADOR_DIA_DIRECTO. (⚠️ cargadores: antes verificar que wh.cargadores_log histórico tenga `fecha` a medianoche Lima.)
**Grupo B — MUEVEN stock (uno por uno, comparar stock antes/después con `compararStockWH`, probar reintento NO duplica):** WH_CREAR_AJUSTE_DIRECTO → WH_CREAR_GUIA_DIRECTO + WH_AGREGAR_DETALLE_GUIA_DIRECTO + WH_CERRAR_GUIA_DIRECTO + WH_REABRIR_GUIA_DIRECTO (ciclo de guía) → WH_ACTUALIZAR_CANTIDAD_DETALLE_DIRECTO + WH_ANULAR_DETALLE_DIRECTO (edición guía cerrada) → WH_REGISTRAR_MERMA_DIRECTO + WH_RESOLVER_MERMA_DIRECTO → WH_AUDITAR_PRODUCTO_DIRECTO + WH_ACEPTAR_TEORICO_ALERTA_DIRECTO → WH_APROBAR_PREINGRESO_DIRECTO → WH_REGISTRAR_ENVASADO_DIRECTO + WH_CORREGIR_ENVASADO_DIRECTO + WH_ANULAR_ENVASADO_DIRECTO.
**Grupo C — cross-domain (NO se activan en WH):** WH_MARCAR_PRODUCTO_NUEVO_APROBADO_DIRECTO (lo orquesta MOS).
Rollback de cualquiera: su flag a '0' → esa op cae a GAS, el resto sigue directo. El cruce ya es seguro (ítems en vuelo se reintentan directo por `_viaDirecta`, no a GAS).

### Fase 5 — APAGAR GAS
- Cuando TODOS los módulos corran directo y estables N días (sugerido 3-7), reducir GAS al mínimo.
- GAS residual SOLO si algo no se migró (ej. OCR boleta si no se cableó). Si todo está directo, GAS se apaga del todo.

## Validaciones críticas durante el cutover
- **Stock**: tras cada escritura directa de stock, el número debe cuadrar EXACTO (es lo que más vigilar).
- **Idempotencia**: doble-tap / reintento por mala señal NO debe duplicar (ya probado en validación, confirmar en vivo).
- **Offline**: con `navigator.onLine=false`, todo cae a la cola GAS (no se rompe). Probar perder señal a propósito.
- **Fotos**: que la foto suba a Storage y se VEA (preview + original). Que las fotos VIEJAS de Drive sigan viéndose.

## Pendiente que NO bloquea el cutover (se puede activar todo lo demás sin esto)
- **OCR boleta/factura** (IA con imagen) — cablear con cuidado (datos SUNAT), ver `architecture_wh_escritura_directa_paso4` / IA.gs.
- **eliminarFoto** (Storage delete por path), **etiquetas → API.imprimirDirecto** (portar armado ESC/POS/ZPL), **aprobar_producto_nuevo** (cross-domain MOS).
- Estos quedan en GAS hasta cablearse; el resto ya corre directo.

## Higiene post-cutover
- Borrar secrets sin uso: `GOOGLE_SA_JSON`, `WH_FOTOS_ROOT` (con Storage ya no se usan).
- Rotar el token Supabase y la key Anthropic que se pegaron en el chat.
- Backportar fix date-only si aplica. Considerar limpiar fotos huérfanas de Storage (las de RPC fallida) periódicamente.
