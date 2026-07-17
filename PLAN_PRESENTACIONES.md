# PLAN — Presentaciones (packs ×N y fracciones ÷N) · progreso vivo

Meta: presentación = FACTOR sobre un producto NIU (pack ×N o fracción ÷N), con nombre compuesto
"BASE · DESCRIPTOR", código auto que refleja el factor, precio propio, adhesivo góndola, y habilitada
también sobre DERIVADOS. Uniformizar códigos existentes de forma SEGURA (alias, sin romper adhesivos ni ventas).

## Reglas confirmadas por el dueño
- Presentación NIU (tripack, octavo…) → PRECIO PROPIO (tripack más barato). El factor solo baja stock.
- Granel (KGM) vendido directo → precio del padre por TRAMOS (menor/mayor). No se toca.
- Padre de una presentación puede ser CANÓNICO o DERIVADO; hereda de él y baja SU stock × factor.
- Presentación = solo TIENDA/GÓNDOLA. Nunca andamio.
- Uniformización de códigos = ALIAS (nuevo limpio primario + viejo como equivalencia) → cero rotura.
- Código: esquema uniforme X{N} (pack) / D{N} (fracción). (Alternativa 8AV/4TO si el dueño lo pide.)

## Motor ya verificado (NO tocar)
- ME lee los 4 tipos y cobra bien (presentación NIU = precio propio). `procesarEscaneoOBusqueda`/`elegirPresentacion`.
- Stock al cierre: `mos._venta_canonico` resuelve al miembro factor=1 del grupo × factor. Derivado tiene stock propio.
- Catálogo `mos.catalogo_pos_rls` emite cada P-/WH- con su precio+factor; equivalencias aparte.
- Guardarraíl KGM: `elegirPresentacion` ignora precio propio en granel (usa padre×kg) — por eso fracciones van sobre NIU.

## Los 18 puntos (checklist)
- [x]  1. Fracciones (factor<1) habilitadas — picker + guardarSatelite (quitado "min 2") ✅ browser-verificado
- [x]  2. Packs (factor>1) — integrados al picker ✅
- [x]  3. Picker 2 familias (Pack ×N / Fracción ÷N) + "Otro" ✅ browser-verificado (screenshot rv_pres_picker.png)
- [x]  4. Contenido auto (250 g) desde magnitud del padre — `_presContenidoAuto`
- [x]  5. Nombre compuesto BASE·DESCRIPTOR — `_presNombreCompuesto`
- [x]  6. Código auto por factor — `_presCodigoSufijo` (X{N}/D{N})
- [x]  7. Regla cambio-de-factor con historial (aviso en edición, no bloquea) ✅ node --check
- [x]  8. Precio propio NIU — motor OK (sin cambio)
- [x]  9. Presentación sobre DERIVADO — ya wired (rama else + card ＋); desc actualizada ✅ browsercheck
- [x] 10. Factor relativo al padre inmediato — motor OK
- [ ] 11. Adhesivo = góndola SOLO (verificar ruteo; ya reusa auto-fit)
- [ ] 12. Descriptor resaltado en adhesivo (opcional)
- [x] 13. "Limpiar nombre" viejas → PLEGADO en la migración 18 (nombres recompuestos) ✅
- [x] 14. Granel directo por tramos — intacto (sin cambio)
- [x] 15. Guardarraíl KGM — existente (sin cambio)
- [x] 16. Herencia tributos/categoría — existente (sin cambio)
- [x] 17. Stock decimal en divisibles — aviso en el picker (fracción) ✅ node --check
- [x] 18. APLICADO 2026-07-17: 522 productos + 668 filas ventas_detalle reescritas. Códigos ≤13
       chars (scannable, verificado), nombres depurados, rotación intacta. Reversa en _migracion_pres_plan.json.
       Script: supabase/_migracion_pres_codigos_dryrun.js (--apply). PENDIENTE frontend deploy (picker).
- [~] 18orig. Uniformizar códigos existentes — DECISIÓN FINAL: reescribir codigo_barra en
       mos.productos + me.ventas_detalle (1:1, misma tx). SIN alias (el alias resolvería
       como equivalente=factor1 → distorsiona rotación de packs). La rotación (me._riz_ventas_base,
       mos.rotacion_productos) une por cod_barras contra el catálogo actual, por eso hay que
       reescribir también la referencia histórica en ventas_detalle. Verificado: kardex 0 movs
       de presentación, stock_zonas 0 → stock NO se toca. 522 presentaciones (todas PRE###,
       144 con ventas). Dry-run (antes/después) + mapa de reversa + correr con cajas cerradas
       (post 11pm) + reimprimir adhesivos. Escanear equivalencias por si alguna apunta a un PRE###.

## Hallazgos de datos (BD 2026-07-17)
- 522 presentaciones, TODAS con código PRE### (uniforme pero opaco). 144 ya tienen ventas.
- FRACCIONES YA EXISTEN (factor 0.5/0.25/0.6) → el motor ya las maneja; el picker las hace fáciles.
- Nombres actuales = solo descriptor ("TRIPACK 3UN","500GR") sin base → eso se compone al depurar.
- ventas_detalle: nombre+precio DENORMALIZADOS (historial de tickets no se rompe).
- Rotación une por cod_barras (coalesce cod_barras, sku) → por eso el punto 18 reescribe ventas_detalle.

## Avance
- FASE 1b ✅ picker UI en app.js (rama 'presentacion' del modal satélite + handlers _pres* + guardarSatelite
  usa _satState.presFactor + generador _presGenCodigo/_presSlugPadre). Quitado dead code _satSugerirPrecioPack.
  node --check OK. BROWSERCHECK REAL (Playwright) OK: tripack→"…· Tripack (3 un)"/P-OSTAVN3150-X3/S6.00;
  octavo→"…· Octavo (19 g)"/P-OSTAVN3150-D8/19g. Screenshot browsercheck/rv_pres_picker.png. Refino precio
  auto (_presPrecioManual) para actualizar sugerencia al cambiar modelo sin pisar precio tecleado.
  SIGUIENTE: punto 9 (habilitar ＋Presentación sobre derivado) · 7 (regla cambio-factor) · 11-13 · 17 · 18.
- FASE 1a ✅ helpers puros (`_presDescriptorSugerido/_presCodigoSufijo/_presContenidoAuto/_presNombreCompuesto`
  + `_PRES_PACKS/_PRES_FRACC/_presDenominador/_presFmtContenidoKg`) en app.js tras `_pesoDesdeNombre` (~línea 15423).
  node --check OK. Stress 34/34. Marcador `[pres-v1]`.
- SIGUIENTE: Fase 1b — picker UI en `abrirModalSatelite` rama 'presentacion' (~línea 17072) + `guardarSatelite` (~17437+len).

## Método de revisión por punto (pedido del dueño)
node --check · consultas BD · browsercheck (Playwright real + screenshot) en catálogo local · stress en dinero/stock.
Al final: revisión integral 100x con estrés. Uniformización (18) con dry-run antes de aplicar.
