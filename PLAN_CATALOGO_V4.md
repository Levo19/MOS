# PLAN CATÁLOGO V4 — canónico + satélites (dibujo aprobado 3812eb03 v4)

> **Estado**: ✅ COMPLETADO Y EN VIVO · v2.43.487 · 2026-07-12
> Parte 3 ✅: browsercheck prod (CERO GAS runtime, 21/21 marcadores v4, versión servida OK),
> smoke 427 (toggle membretes OFF=0/ON=1/ausente=1), SQL smoke 25/25 + estrés 7/7, cron horario vivo.
> DESVIACIÓN CONSCIENTE vs dibujo (money-safe, hallazgo senior M3): un PACK ya NO ofrece
> "+equivalente" — el modelo cuelga equivalencias del sku del GRUPO, un "equivalente de pack"
> resolvería al canónico y se cobraría 1 unidad en vez de 12. El ＋ del pack lo explica con toast.
> Pendiente de uso real: prueba física de cámara/impresión en el equipo del dueño.
> **Dibujo aprobado**: https://claude.ai/code/artifact/3812eb03-f9e2-4d6a-a8f8-c7d30f176aac (v4)
> **Punto de retoma**: cada fase marca ✅ al cerrarse con su revisión senior. Si se corta la sesión, retomar en la primera fase sin ✅.

## DIRECTRICES (orden del dueño — no negociables)

1. **CERO GAS + CERO FALLBACK A GAS**: todo lo nuevo llama RPC/Edge/Storage directo. Sin rama `gas`, sin `_conFallbackMOS` en endpoints nuevos (fallo → toast + caché local, jamás GAS). En código tocado, eliminar rastros GAS que queden huérfanos.
2. **CÓDIGO LIMPIO**: eliminar código muerto confirmado (lista §F7). Nada de basura nueva.
3. **MODERNO + ANIMACIONES**: nada del dibujo se pierde — ni un color, ni una animación (inventario visual §ANEXO-A).
4. **NO ROMPER LA CADENA factor=1**: los canónicos siguen siendo el índice; derivados se registran con su propio grupo (así aparecen como canónicos en búsquedas — comportamiento actual INTOCABLE).
5. **Optimista + idempotente**: locks frontend, tolerar dobles clicks (regla de la casa).
6. Deploy: bump `sw.js` VERSION + `version.json` + `?v=` pins de app.js/api.js; `node -c`; commit + push verificado con `git log origin/main..HEAD`.

## TERRENO VERIFICADO (inventario 2026-07-12, 2 agentes)

- Catálogo YA cero-GAS en runtime (`_conFallbackMOS` neutralizado api.js:274-284; escrituras `_sbRpcMOSWrite` puras).
- Escáner existente: `cpnAbrirScanner` app.js:3818 (BarcodeDetector + ZXing CDN + linterna) → se generaliza, NO se agrega html5-qrcode.
- Buscador YA puntúa por codigoBarra + equivalentes (`_catScoreInfo` app.js:2567) y ya existe `matchExactoCls` en el card → solo falta: botón cámara en la barra + animación de pulso del match + estilo moderno.
- `modalPrecioRapido` vivo (cards → app.js:3005/3044); `modalPrecio` viejo MUERTO (cero callers).
- Modal producto: `setProdTipo` 4 botones; SUNAT expone 4 campos (`prodTipoIGV`+`prodCodTributo`+`prodIGV`+`prodCodSUNAT`) + `sunatResumen`; autogen `NMLEV...`; validación duplicado SOLO `S.productos` (gap equivalencias).
- Equivalencias: RPCs directas `crear_equivalencia`/`actualizar_equivalencia`/`equivalencias_lista` (soft-delete por activo).
- Tramos: `actualizar_segmentos_precio` (SQL 170) exige KGM+canónico; editor embebido en modal producto (`_segState`).
- Rotación: `wh.rotacion_semanal` (SQL 11) EN VIVO sobre `wh.guias(fecha,tipo,estado,id_zona)` + `wh.guia_detalle(cod_producto,cant_recibida,observacion)`; NO usa zona; sin cache (lentitud = cálculo en vivo, TTL 15min, failsafes 20-25s).
- Analítica: `mos.analitica_producto` (SQL 119) lee `me.ventas` (tiene `zona_id` indexada) + `me.ventas_detalle(sku,cod_barras,cantidad,unidad_medida)`; NO suma equivalencias/derivados.
- Normalización: `mos._venta_canonico` (SQL 138) — peso directo / NIU × factor, resuelve equivalencias.
- `publicar_precio` → delega en `actualizar_producto` (atómico + historial + bump trigger 290 no-bloqueante) + hooks 339b/c (membrete/cambio).
- Membrete: `assets/membrete/membrete-modal.js` → menú MOS 2 opciones (ME góndola / WH andamio) → Edge `print-adhesivo` mode `crear-membrete` (kill-switch GAS solo si server responde `*_OFF`).
- Foto: Storage directo (bucket producto-fotos). Eliminar: kebab master → cesta purga clave 8 díg (se conserva la clave, cambia el ícono).
- pg_cron patrón: SQL 130 (unschedule idempotente + wrapper exception + `mos.cron_log`); pg_cron corre en UTC (Perú = UTC-5).
- Siguiente SQL: **424**.

---

## PARTE 1 · FASES

### F1 — Backend SQL (424, 425, 426) ✅ (aplicado a prod + smoke 25/25 + estrés 7/7 + revisión senior DOBLE con 13 fixes aplicados: dedup conv, frescura 2h, equivalencias en conv, COALESCE cod_barras/sku, ANULADO%, clamp 8 sem, derivado→padre, semana parcial fuera de promedios, GUC bypass backfill, advisory locks, RLS, sku_base en triggers. Cron horario vivo.)
**424_wh_rotacion_cache.sql**
- Tabla `wh.rotacion_cache(cod_producto text, semana text, id_zona text, unidades numeric, kg_equiv numeric, refrescado_en timestamptz)` PK (cod_producto, semana, id_zona). `id_zona=''` = total.
- `wh.rotacion_cache_refrescar()`: recalcula ventana 8 semanas ISO (misma lógica SQL 11: SALIDA% + CERRADA/AUTOCERRADA + observacion<>ANULADO), CON id_zona, kg_equiv vía lógica `_venta_canonico` (peso → cant; NIU → cant × factor_conversion_base si derivado, × factor si presentación). Delete+insert en tx.
- Job pg_cron `wh-rotacion-cache-horaria` cada hora (`5 * * * *`) con wrapper exception + log `mos.cron_log`. Ejecutar refresh inicial al aplicar.
- `mos.wh_rotacion_semanal` (wrapper 380) se REDEFINE para leer de la cache (misma firma/shape `{etiquetas, productos}` → el frontend viejo sigue funcionando); + campo nuevo `porSemanaKg`/`kgSem` por producto. Si cache vacía (primer minuto) → calcula en vivo UNA vez (fallback Supabase↔Supabase, jamás GAS).
**425_mos_analitica_grupo.sql**
- `mos.analitica_grupo(p jsonb)` params `{idProducto|skuBase, semanas default 8, alcance? (codigos[])}`.
- Resuelve GRUPO EXTENDIDO: canónico + presentaciones (sku_base) + equivalencias activas + DERIVADOS (`codigo_producto_base` = cb del granel) + presentaciones de derivados.
- Fuente ALMACÉN: `wh.rotacion_cache` (por semana, por zona destino, kg_equiv + unidades por forma).
- Fuente ZONAS: `me.ventas`(zona_id, forma_pago<>ANULADO) + `me.ventas_detalle` match por grupo extendido; kg-equiv con regla 138 (unidad_medida peso → cantidad; NIU → × factor del producto vendido; derivado → × factor_conversion_base; pack de derivado → × factor × porción).
- Zona sin ventas ME (ej. zona01): bloque `estimada:true` con `despachadoKgSem` (cache por id_zona) + `diferenciaKgSem` (total almacén − suma zonas con data) → `consistente` bool (desvío <25%).
- Insight: stock actual grupo (wh.stock por códigos), cobertura semanas, `sugerenciaPedidoKg` = max(0, round(promedio 4 sem × 1.2 − stock)).
- Return `{ok, data:{ etiquetas, grupo:{codigos, formas}, almacen:{kgSem, porSemana, porForma, valorSem, tendenciaPct}, zonas:[{zona, real|estimada, kgSem, porSemana, porForma, ...}], insight }}`. Grant authenticated+service_role. SIN GAS.
**426_mos_codigo_unico.sql**
- `mos.codigo_barra_disponible(p jsonb {codigoBarra, ignorarIdProducto?, ignorarIdEquiv?})` → `{ok, disponible, conflicto:{tipo:'producto'|'equivalencia', id, descripcion}}` (una consulta a ambas tablas, case-insensitive, activos).
- Guard server-side: `crear_producto`/`actualizar_producto` rechazan cb que exista en `mos.equivalencias` activas (y `crear_equivalencia` ya deduplica contra equivalencias → añadir chequeo contra `mos.productos`). Redefinir SOLO la validación (wrapper al inicio), sin tocar el resto de la lógica 78/376.
**Pruebas F1**: smoke en tx-rollback (savepoints para guards), estrés: 200 llamadas concurrentes a cache-read + refresh simultáneo; analitica_grupo con grupo ajonjolí real; codigo_unico con colisiones cruzadas. **Revisión senior 2 pases.**

### F2 — Fundaciones frontend ✅ (scanCodigo generalizado sobre motor cpn existente; genCodigoUnico N-/WH-/P- validado local+server; prodValidarCodigoBarra v2 cruza equivalencias; _svgIcon 9 íconos; CSS animaciones+reduced-motion; API codigoBarraDisponible/getAnaliticaGrupo directas puras + gates)
- `MOS.scanCodigo(targetInputId|callback)`: generaliza `cpnAbrirScanner` (BarcodeDetector+ZXing+linterna) a overlay reutilizable; al detectar → set value + evento input + beep + cierra. Botón cámara = clase `.btn-cam-scan` (SVG cámara).
- Generador de códigos con prefijo: `_genCodigoPrefijo(pref)` → `pref + base36(ts) + rand` (N- canónico, WH- derivado, P- presentación), SIEMPRE validado con `codigo_barra_disponible` (regenera hasta 3 intentos).
- `prodValidarCodigoBarra` v2: chequeo local (S.productos + S.equivMap) instantáneo + confirmación server debounced (RPC 426). Mensajes claros ("pertenece a X como equivalente").
- CSS (index.html bloque catálogo): keyframes `hitpulse`, `shimmer`, `sheenmove`, `breathe` (ya existe respiración foto — verificar y reusar), `.rot-chip` (+skeleton), `.abtn` SVG botonera, `.popt-hero` borde degradado, hover-lifts, `@media (prefers-reduced-motion)`. Colores del dibujo: esmeralda #34d399/#059669, ámbar #fbbf24, azul #7cb3f0, violeta #b79bff, rojo #fb7185, indigo #8b9cf5.
- Íconos SVG inline (helper `_svgIcon(nombre)`): billete, barras, impresora, tacho, rollo-adhesivo (círculo+etiqueta saliendo), rotación ↻, góndola (fachada), andamio (estantería), cámara, lápiz (solo leyenda). **Revisión senior.**

### F3 — Buscador + card ✅ (cámara en barra + scanBuscarCatalogo con scroll al hit; cat-hit-exacto animado; nombre tocable=editar en canónico y satélites; botonera SVG con 💰 solo canónico + 🗑 master directo a purga + ＋ contextual; chip rotación por nivel kg/u/packs por semana + equivalentes solo en canónico + skeleton + localStorage SWR)
- Barra: botón cámara integrado (`scanCodigo` → set query); estilo moderno (focus ring esmeralda, ícono animado al escanear).
- Match exacto: reusar `matchExactoCls` + animación `hitpulse` + badge "✓ código exacto"; scroll al card; resolver satélite→canónico (ya lo hace `_catScoreInfo`).
- Card botonera → SVG: toggle (queda), ~~✏️~~ (nombre tocable: subrayado punteado, onclick stopPropagation → `abrirModalProducto`; `_catCardClick` sigue expandiendo en el resto del área), 💰 SOLO canónico (quitar de filas presentación app.js:3005), 📈 (SVG barras) → analítica, 🖨 (SVG impresora) → membrete, 🗑 (SVG, master) → `abrirCestaPurga(id,{idProductoFiltro})` directo (reemplaza kebab del card), ＋ contextual (F4).
- Chip rotación `.rot-chip` junto al precio: canónico granel "X kg/sem" (kg_equiv), NIU "X u/sem", presentación "X packs/sem" (unidades/factor). Fuente: `S._rotacionSemanalCache` (ahora instantánea por cache SQL) + **persistir cache en localStorage** (stale-while-revalidate: pinta al abrir, refresca detrás). Skeleton shimmer solo sin dato. Click chip → analítica fusionada. El sparkline 8-barras se MUDA al modal de rotación/analítica (no muere: se quita del card, vive en detalle).
- Filas satélite: toggle + 🖨 + ＋; precio visible; SIN 💰. **Revisión senior.**

### F4 — Modales de creación + el ＋ contextual ✅ (menú ＋ por matriz con porqués; modalSatelite único shell con 4 bodies: derivado WH- + guardián porción-vs-nombre, presentación P- + sugerencia N×precio, tramo min/max/ajustePct + escalera viva sobre el modelo REAL, equivalente solo-escanear; +producto: toggle envasable en creación + SUNAT un selector con derivados en "avanzado"; herencia tributaria del padre en los 4)
- ＋ contextual (botón verde en card canónico y filas satélite): menú flotante según tipo — granel: [🥄 Derivado, 🧱 Presentación, 📊 Tramo, 🏷️ Equivalente]; canónico normal: [🧱, 🏷️]; derivado: [🧱, 🏷️]; presentación: [🏷️]. Con micro-descripciones (los "porqués" del dibujo van al title/subtítulo del menú).
- Modal +producto (header) SIMPLIFICADO: solo canónico — descripción, código (autogen N- + ⚡ regenerar + 📷), unidad, precio, categoría, marca, **toggle "⚗️ Es granel envasable"** (reemplaza la barra de 4 tipos EN CREACIÓN; sugiere KGM al prender), **SUNAT UN selector** (`prodTipoIGV` visible; `prodCodTributo`/`prodIGV`/`prodCodSUNAT` pasan a hidden + línea "Auto: Tributo 1000 · IGV 18%" en `sunatResumen` — la lógica `prodOnTipoIGVChange` ya deriva todo). EN EDICIÓN el modal conserva secciones según el tipo real (setProdTipo sigue para editar).
- Modal +derivado (nuevo, enfocado): contexto padre, herencia visible (chip), nombre, porción (guardián `_pesoDesdeNombre` reusado), precio, código autogen WH- + 📷. Crea vía `crearProducto` (esEnvasable=0, codigoProductoBase, factorConversionBase, factor=1).
- Modal +presentación (nuevo): contexto, herencia, nombre, "¿cuántas agrupa?", precio con sugerencia (N × precio unit), código autogen P- + 📷. Crea vía `crearProducto` (skuBase, factorConversion=N).
- Modal +tramo (nuevo): desde/hasta/S/kg + escalera visual en vivo (reusa `_segState`/validador; persiste `actualizarSegmentosPrecio`).
- Modal +equivalente (nuevo enfocado; el embebido del modal producto se conserva para edición): SOLO escanear/escribir + 📷 (SIN autogen), nota opcional. `crearEquivalencia`.
- Los 5 validan código con F2. **Revisión senior.**

### F5 — Cascada de precio ✅ (_qpBuildRows 3 tipos + nivel 2 recalcula sobre precio aceptado del derivado; tramos banner AUTO — el modelo ajustePct los mueve solos; toggle imprimirMembretes por fila; mini-cascada del derivado gratis — su card 💰 muestra solo sus packs; fix render inicial presDer sin DOM)
- `modalPrecioRapido` v2 (solo se abre desde canónico): secciones ①raíz ②tramos AUTO % (chip con preview "0-100g: 32→38.40 · ..."; al publicar → `actualizarSegmentosPrecio` escalado por el mismo %; sin confirmación por tramo) ③satélites: derivados (porción × precio/kg), presentaciones (× factor), packs de derivado (nivel 2, indentado, recalcula sobre precio aceptado del derivado — listener en vivo). Cada fila: AUTO (verde) / tocar precio → MANUAL (ámbar) / toggle excluir (reusa `_qpToggleExcluida`/`_qpInputTocado` extendidos).
- Publicar: `Promise.all` de `publicarPrecio` por fila aceptada (patrón actual de `guardarPrecioRapido`) + tramos. Toggle "🖨 imprimir membretes de los que cambien" → hook 339b (`imprimirMembretes`) por fila.
- Satélites: su precio vive en editar (abrir modal editar con focus en precio); al guardar precio de derivado con packs → mini-cascada (mismas filas, solo sus packs).
- Sonidos `_qpBeep` se conservan + tick al alternar AUTO/MANUAL. **Revisión senior.**

### F6 — Imprimir 3 opciones + analítica fusionada + eliminar ✅ (hero adhesivo envasado SOLO derivados con sheen + stepper ×6 → API.adhesivoImprimirEdge mode:'crear' reserve-first CERO GAS; analítica fusionada en viewAnalitica: tabs Almacén/zonas-reales/zonas-ESTIMADAS doble vía + SIN_ZONA explícito + ZONA_MOCK_FALLBACK filtrado + barras semanales + formas + insight pedido; eliminar = tacho master→cesta purga clave intacta)
- membrete-modal.js (MOS): menú producto → 3 opciones con SVG nuevos (góndola ámbar / andamio azul / rollo esmeralda); la 3ra SOLO si `producto.codigoProductoBase` (derivado): stepper cantidad (1-99, default 24) → Edge `print-adhesivo` (verificar mode exacto del adhesivo envasado WH y reusar payload; si el mode es exclusivo WH, extender el Edge con origen MOS — cero GAS). Opción hero: borde degradado + sheen animado.
- Analítica fusionada: en `viewAnalitica`, bloque superior nuevo "GRUPO" con tabs [🏭 Almacén | 🏪 Zona 02 | 🏪 Zona 01 ESTIMADA] (zonas dinámicas de la data), stats (kg/sem, valor, tendencia), barras semanales ×8, conciliación (flujo almacén→zonas→estimada con doble vía + badge consistente ✓/⚠), breakdown por forma (kg-equiv), insight pedido semanal. Data: `API.get('getAnaliticaGrupo')` → RPC 425 directa PURA (sin `_conFallbackMOS`). Chips de alcance [Grupo completo | canónico | por satélite] filtran (param codigos). Lo existente (KPIs producto, charts) queda debajo como "SOLO ESTE PRODUCTO".
- Eliminar: tacho SVG master en card (F3) → cesta purga existente (clave intacta). **Revisión senior.**

### F7 — Limpieza + deploy ✅ (borrados: #modalPrecio HTML + abrirModalPrecio/publicarPrecio(front) + onTipoCheck/onEnvasableCheck + setCatTab + _renderRotacionSparkline, cero referencias; revisión senior frontend DOBLE → 11 fixes: imprimirMembretes real (api+SQL 427), codigoProductoBase a membrete, DOM viejo cascada, equivalente-de-pack bloqueado money-safe, carreras B1/B2/B3, DIRECT_REQUIRED cero-fallback; bump 2.43.487 + pins + push verificado)
- BORRAR: `#modalPrecio` HTML (index.html:17903-17930) + `abrirModalPrecio` + `publicarPrecio` de app.js (18170-18209) + export; `onTipoCheck`/`onEnvasableCheck` + export (verificar turno.html/liquidacion.html antes); `setCatTab` si sin callers; `_renderRotacionSparkline` del card si quedó huérfano tras F3 (verificar modal rotación).
- Verificar cero rastro GAS en rutas tocadas (grep script.google + ramas gas huérfanas en lo editado).
- `node -c` app.js/api.js; bump sw.js + version.json + ?v=; commit descriptivo + push + `git log origin/main..HEAD` vacío. **Revisión senior global de la parte 2.**

## RONDA 2 · FEEDBACK DEL DUEÑO (7 puntos) — EN CURSO
**Harness sesión real FUNCIONANDO** (autorizado por el dueño):
- Device prueba: `mos.dispositivos` id `7e57c1a0-de1c-4a7e-b0de-c47a10906474` estado ACTIVO ("PRUEBA CLAUDE catalogo v4 (borrar al terminar)") — **BORRAR AL TERMINAR**.
- Escenarios: `browsercheck/v4_sesion.json` + `v4_s2.json` (localStorage: mos_device_id + MOS_SESSION rol MASTER "PRUEBA CLAUDE"; atravesar wizard permisos con botón "Entrar a MOS"; MOS.nav('catalogo'); filtrar 'ajonjoli').
- verificar_dispositivo exige param `id_dispositivo` + id UUID válido.
Estado de los 7: #4 crash analítica ✅ RESUELTO (SQL 428: sku_base es código de grupo, no id del padre — climb anulaba v_prod, 2373 productos). #7 botón nuevo producto ✅ EXISTE (screenshot). Chips/botonera/cámara ✅ en vivo.
AVANCE R2 (v2.43.488 + fixes membrete pusheados): #1 ✅ derivados ANIDADOS (shot_s3, 446 hijos/217 badges, match del hijo fuerza al padre) · #2 ✅ CTA tramos fuera del card + sección fuera del modal producto + gestión (lista+borrar, _satTramoEliminar) en modal ＋tramo · #3 ✅ click nombre→editar FUNCIONA en harness (era caché SW viejo del equipo del dueño) · #4 ✅ SQL 428 verificado en UI (sin "Cannot read") · #5 ✅ NaN era un "+ +" unario PREEXISTENTE en membrete-modal.js:1402 (div sin cerrar anidaba el hero) + ms-btn width:auto — modal PERFECTO (shot_s4) · #6 ✅ cascada fiel al dibujo (shot_s5: tachado→AUTO verde, chip MANUAL al tocar, botón "Publicar raíz + N satélites") · #7 ✅ botón existe.
PENDIENTE ÚNICO R2: anGrupoSec (analítica fusionada) no pinta en el HARNESS — getAnaliticaGrupo posiblemente sin token mint con el device de prueba (¿mint-mos exige personal real?); verificar en el equipo del dueño o depurar mint. ＋contextual/modales satélite: código verificado, screenshot pendiente. Al cerrar TODO: borrar device 7e57c1a0-de1c-4a7e-b0de-c47a10906474 de mos.dispositivos.
PENDIENTES R2 (originales): #1 anidar DERIVADOS bajo el granel (hoy cards sueltos — gap real, screenshot shot_s2_ajonjoli.png). #2 quitar CTA "Agregar pricing por tramos" del card y sección del modal (gestión → modal ＋tramo con lista+borrar). #3 probar click-nombre→editar en harness. #5 modal imprimir deformado+NaN (probar MOS.abrirMembreteCard de un derivado en harness + screenshot). #6 cascada: números OK, restylear al dibujo (chips AUTO/MANUAL, antes→nuevo, botón "Publicar raíz+N"). Probar TODOS los botones/modales (orden del dueño). GAS ajeno detectado en runtime: ping + getProductosNuevosWH (módulo PN, fuera del alcance catálogo — anotar en reporte).

## PARTE 3 · INSPECCIÓN INTEGRAL ⬜
1. Browsercheck: catálogo real en Chromium (deviceId de prueba) — cero fetch GAS, consola limpia, screenshot card/buscador/modales/cascada/analítica.
2. Estrés SQL: refresh cache × lecturas concurrentes; analitica_grupo ×50; publicar lote 10 filas × 2 concurrentes (advisory/atómico); codigo_unico carreras.
3. Comparación dibujo↔implementado: checklist sección por sección del artifact v4 (01-09), color por color, animación por animación.
4. Reporte integral al dueño.

## ANEXO-A · Inventario visual del dibujo (nada se pierde)
- Colores: esmeralda #34d399/#059669 (acción/ok), ámbar #fbbf24 (ME/manual/estimada), azul #7cb3f0 (WH), violeta #b79bff (derivado), indigo #8b9cf5 (analítica), rojo #fb7185 (eliminar), grises #93a4c2/#28344c.
- Animaciones: hitpulse (match exacto), breathe (placeholder foto), shimmer (skeleton rotación), sheenmove (opción hero imprimir), spin lento (ícono ↻), hover-lift (cards/botones), slide 3px (opciones imprimir), reduced-motion global.
- Componentes: chip rotación, badge ESTIMADA, tabs fuente, barras semanales, flujo conciliación, breakdown barras, stepper cantidad, escalera tramos, filas cascada AUTO/MANUAL, subrayado punteado nombre, mini-📷 foto, borde degradado hero.

## ANEXO-B · Riesgos y mitigaciones
- `_catCardClick` vs nombre-tocable: stopPropagation en nombre; probar expandir/colapsar tras cambio.
- Redefinir wrapper 380 manteniendo shape → frontend viejo (WH/ME lectores cross-app) no se rompe; verificar quién más llama `mos.wh_rotacion_semanal`.
- Edge print-adhesivo modo envasado: confirmar payload real del flujo WH antes de cablear MOS.
- Modal producto simplificado en creación NO debe romper edición de derivados/presentaciones existentes (setProdTipo queda para edición).
- kg_equiv en cache: derivados guardan `factor_conversion_base` (porción) — cuidado con productos mal registrados (achiote 0.01): el guardián solo avisa, el cálculo usa el dato tal cual.
