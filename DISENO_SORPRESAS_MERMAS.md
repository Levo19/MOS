# 🎯 Productos Sorpresa + ♻️ Tratamiento de Mermas — Diseño (VIVO)

> Libro de detalles para el implementador — que NADA se pierda al codear.
> Mockup navegable: `scratchpad/sorpresas_mermas.html` (artifact d4cc280d).
> Estado: **DISEÑO en revisión con el dueño. NO codear hasta aprobación.**
> Principio compartido: el sistema refleja la realidad física, no el papel.

---

## 1) 🎯 PRODUCTOS SORPRESA (auditoría de escaneo real)

### Concepto
El admin altera físicamente un envío (quita o agrega unidades de una línea de la guía
de salida a zona) y lo registra como "sorpresa". El operador de zona, si escanea de
verdad, registrará la cantidad FÍSICA (corregida); si copia el papel, registrará la
impresa → FALLÓ. Evaluación 100% automática.

### Reglas de negocio
- Delta puede ser **negativo (quitar) o positivo (mandar de más)**. Varios por día o ninguno.
- **La sorpresa ES la corrección**: al registrarla, el server ajusta `cant_esperada`
  de la línea (5→4) y anota la línea como SORPRESA. No hay guía de ajuste ni reingreso:
  stock y dinero cuadran solos, auditado.
- **Invisibilidad al operador (regla de oro)**: la línea corregida NO muestra el esperado
  al rol operador en la recepción de zona (ni pista de que hubo sorpresa). El ticket impreso
  conserva la cantidad original (esa es la trampa). Solo admins ven la anotación
  `4 un (−1 🎯 sorpresa)` en el detalle de guía (MOS → Zona → Guías).
- **Evaluación automática** al cerrar la recepción en zona:
  - registrado == esperado_corregido → ✅ PASÓ (escaneó/contó de verdad)
  - registrado == cantidad_original (papel) → ❌ FALLÓ (copió la hoja)
  - otro valor → ⚠️ DISCREPANCIA (ni papel ni real — revisar; cuenta como fallo suave)
  - Push instantáneo al admin con el veredicto. Se acumula en **score de confiabilidad**
    por operador (se integra al motor de evaluación del día, como auditorías).

### Quién y dónde
- **Solo MASTER/ADMIN + ascendidos (acceso_mos, ej. Jorgenis)**. Gate en frontend Y en RPC.
- **WH**: botón `🎯 Sorpresa` en la vista de guía de salida (SALIDA_ZONA, ABIERTA).
  Invisible para operadores.
- **MOS**: módulo Zona → card ALMACÉN → botón `🎯 Sorpresas` (panel: registro rápido +
  sorpresas del día + score por operador 30d + historial completo).
- Registro en 3 toques: (1) guía — escaneo del nº o pick de guías ABIERTAS del día;
  (2) producto — cámara o tap en la línea; (3) delta con stepper ±. Confirmar.

### Datos (nuevo)
`wh.sorpresas`: id_sorpresa PK · id_guia · cod_producto · delta (±num) ·
cant_original · cant_corregida · admin (nombre) · ts · estado (ESPERANDO/PASO/FALLO/DISCREPANCIA) ·
operador_evaluado · cant_registrada · ts_resultado · id_zona.
RPC `wh.registrar_sorpresa` (gate admin/ascendido; corrige guia_detalle atómico + inserta fila).
Hook en el cierre de recepción de zona: si la guía tiene sorpresas → evaluar + push.

---

## 2) ♻️ TRATAMIENTO DE MERMAS

### Concepto
Producto dañado que solo Almacén procesa: recuperar todo, parte o nada, con SLA.
Base EXISTENTE a reusar: tabla `wh.mermas` (tiene cantidad_original/pendiente/reparada/
desechada, responsable, estado, foto, id_guia, id_guia_salida, fecha_resolucion),
RPCs `registrar_merma` (31) / `resolver_merma` (66), guía `INGRESO_DEVOLUCION_ZONA`.

### Puertas de entrada (solo 2, nunca libre)
- **A · Desde guía INGRESO_DEVOLUCION_ZONA**: en el DETALLE de ese tipo de guía, cada
  línea tiene botón `♻️ a mermas` → modal: cantidad (todo o parte; el resto ingresa sano),
  **culpa** (2 botones grandes: la ZONA que devolvió / ALMACÉN "se envió dañado"),
  foto obligatoria. Ej: "hoy 15 un Nakamitos culpa Zona 02".
- **B · Hallazgo en andamio**: desde la cesta, `+ agregar` → escaneo o búsqueda manual
  (códigos ilegibles) → culpa = **ALMACÉN fija** (sin guía previa no hay culpa de zona),
  cantidad + foto obligatoria.

### SLA y estados
- **3 días hábiles completos** para procesar. Vencida → 🔴 badge en el ícono de cesta
  (contador) + push al admin. Chips SLA visibles por fila: 🟡 2d restantes → ⏳ vence
  en 1d → 🔴 VENCIDA −Nd.
- Estados: PENDIENTE → (proceso iterativo) PARCIAL (cantidad_pendiente>0) →
  RESUELTA (recuperada total / parcial+resto eliminado / eliminada) · TRANSFORMADA.

### Procesar (modal TODO · PARTE · NADA)
- **TODO**: cantidad_pendiente vuelve al stock (reingreso).
- **PARTE**: input cantidad → recupera N; el resto SIGUE PENDIENTE en la cesta
  (proceso iterativo: "mientras voy solucionando voy reparando"). El SLA del resto continúa.
- **NADA/Eliminar**: se desecha → **guía de salida automática** (usa id_guia_salida existente).
- **🔄 Transformación** (al recuperar todo o parte): toggle "¿se transforma?" → picker de
  producto destino del catálogo (ej: Harina Blanca Flor granel → Harina Inca suelta) →
  genera **guía de TRANSFORMACIÓN automática** (sale original N, entra destino N; atómica,
  auditable, tipo nuevo TRANSFORMACION).
- **Batch**: checkboxes multi-selección → `🗑 Eliminar seleccionadas` → UNA guía de salida
  automática con todas + fotos.

### Vistas
- **WH (cesta)**: solo pendientes/parciales + resueltas de los **últimos 15 días**.
  Layout de filas con chip SLA + botón Procesar + checks batch.
- **MOS**: módulo Zona → card ALMACÉN → botón `♻️ Mermas` (REEMPLAZA al botón Guías de ese
  card — Almacén no vende; las zonas de venta conservan Guías). Muestra **TODO el historial**:
  quién ingresó, desde qué guía, culpa, quién procesó, a qué (todo/parte/nada/transformó),
  fotos, guías vinculadas (GT_/GS_), filtros (estado/culpa/zona/producto/rango) y
  **KPIs de dinero**: S/ mermado vs S/ recuperado (%) del mes + culpa por zona
  (para conversar con la zona que más devuelve dañado). Badge rojo con vencidas.

### Datos (delta sobre lo existente)
- `wh.mermas`: + columna `culpa` (ZONA-XX/ALMACEN — o reusar `responsable` normalizado),
  + `id_guia_transformacion`, + `costo_unitario` (valorización al costo del momento).
- RPC `resolver_merma` (66) extender: transformación (crea guía + mueve stock destino),
  parcial iterativo (ya soporta cantidad_reparada/pendiente), batch eliminar.
- Cron/SLA: cálculo días hábiles (L-S; domingo no cuenta) + push vencidas (pg_cron existente).

---

## 3) Preguntas abiertas para el dueño
1. Sorpresa — ¿el ❌ FALLÓ debe descontar en la liquidación del día del operador
   (como sanción automática) o solo score informativo + tú decides?
2. Mermas — ¿días hábiles = lunes a sábado (domingo no corre) correcto?
3. Mermas — ¿la culpa ZONA le descuenta algo a la zona/vendedor o es solo estadística?
4. Transformación — ¿misma cantidad 1:1 siempre, o puede variar (25kg sucios → 18kg limpios
   ya lo cubre el "parte"; pero ¿18kg Blanca → 18kg Inca siempre 1:1)?
5. Sorpresa en MOS: ¿además del card Almacén, quieres acceso rápido desde el detalle de
   guía de cada zona (botón admin)?

## Changelog
- 2026-07-18: diseño v1 + mockup navegable (4 vistas) verificado 390px sin overflow.

---

## 4) PLAN DE IMPLEMENTACIÓN (fases)

**F0 · SQL Sorpresas — ✅ HECHA (516, aplicada 2026-07-18, smoke ROLLBACK previo):**
wh.sorpresas + wh.registrar_sorpresa (gate clave admin central → honra acceso_mos; guardia
PRODUCTO_NO_EN_GUIA; corrige cant_recibida de la línea; stock atómico si guía CERRADA;
SORPRESA_TARDE si la zona ya recibió; idempotente por localId) + wh.sorpresas_lista +
TRIGGER trg_evaluar_sorpresas sobre me.zona_traslado_verificacion (PASO/FALLO/DISCREPANCIA
+ push MASTER/ADMIN). El hook NO toca el RPC de dinero 146.

**F1 · SQL Mermas:** extender wh.mermas (+culpa, +id_guia_transformacion, +costo_unitario) ·
extender resolver_merma (transformación → crea guía TRANSFORMACION + stock destino atómico;
cantidad destino editable default=recuperado; batch eliminar → 1 guía salida) · RPC
merma_desde_guia (línea de INGRESO_DEVOLUCION_ZONA → merma con culpa) · cron SLA 3 días
CORRIDOS → push vencidas (pg_cron existente).

**F2 · WH frontend:** botón 🎯 en el CARD de guías SALIDA_ZONA (solo admin/ascendido — gate
frontend con clave cacheada 5min) + modal escaneo corrediza con guardia-alerta · botón
"♻️ a mermas" en detalle INGRESO_DEVOLUCION_ZONA · cesta renovada (SLA chips, checks batch,
procesar TODO/PARTE/NADA + transformación, badge rojo vencidas). Deploy git push (Pages
/warehouseMos-/) + bump SW.

**F3 · MOS frontend:** Zona → card ALMACÉN: botones 🎯 Sorpresas (panel: registro + hoy +
score 30d + historial) y ♻️ Mermas (REEMPLAZA Guías de ese card; historial total + KPIs S/
mermado vs recuperado + culpa por zona + filtros). Observación con monto en la vista de
evaluación del día (join wh.sorpresas por operador/fecha — NO toca liquidaciones_dia).

**F4 · Verificación integral:** browsercheck + screenshots vs mockup por fase; prueba E2E
real: sorpresa en guía de prueba → recepción simulada → veredicto + push.

## Estado — TODO IMPLEMENTADO 2026-07-18
- F0 ✅ SQL 516 (sorpresas + trigger evaluación + push) — prod.
- F1 ✅ SQL 517 (mermas v2: culpa, SLA 3d corridos, parcial iterativo, transformación con
  guía automática CERRADA, batch, stock_descontado para coexistir con filas viejas,
  mermas_lista wh/mos, cron 8am — detectó 3 vencidas reales) — prod, smoke E2E ROLLBACK.
- F3 ✅ MOS 2.43.576: Zona→ALMACÉN alterna Guías ↔ 🎯(solo admins)+♻️(badge=3 real);
  panel Mermas (KPIs S/, 6 filtros, SLA chips, culpa, fotos, guías vinculadas) y panel
  Sorpresas (registro cámara+clave server-side+guardias, score por operador) — screenshots
  sm1/sm2/sm3 vs mockup.
- F2 ✅ WH 2.13.447: 🎯 en CARD de guías SALIDA_ZONA (solo admin/ascendido; hoja con líneas,
  guardia código-ajeno con vibración, clave recordada en memoria); ♻️ "a mermas" por línea
  en INGRESO_DEVOLUCION_ZONA cerrada (culpa+foto obligatoria+stock-out); cesta v2 (culpa/SLA
  chips, ▶ Procesar TODO/PARTE/NADA + 🔄 transformación con cantidad destino editable,
  ☐/☑ batch eliminar, badge vencidas). Boot verificado sin errores (módulos vivos).
- ✅ Batch = UNA guía (SQL 518 wh.mermas_eliminar_batch, WH 2.13.448): línea trazable por merma, stock exacto por generación, idempotente por local_id. CERO pendientes.

## Revisión 100x senior (2026-07-19) — 30/30 ✅
Suite `supabase/_test_100x_sorpresas_mermas.js` (transacción + ROLLBACK; stub del validador de
clave SOLO dentro de la tx — S12 verifica que NO persiste). 3 BUGS REALES cazados y corregidos:
1. **SQL 519**: la recepción (146) AGREGA líneas por código → la evaluación comparaba contra la
   línea: guía con mismo producto en 2+ líneas daba DISCREPANCIA falsa al honesto. Ahora compara
   TOTALES por código; Σ deltas estable en corridas múltiples (ts_resultado=now() por tx).
2. **SQL 520**: la guía semanal GMERMA<lunes> puede existir CERRADA → filas viejas le agregaban
   líneas (unidades sin descontar + documento mutado). Ahora nueva ABIERTA con sufijo.
   ⚠ Bug LATENTE idéntico en 66/resolver_merma legacy (la UI nueva ya no lo usa).
3. **api.js MOS**: tribResumenMes/IGV* corrían en el prefetch ANTES del mint → fallback GAS.
   → _MOS_DIRECT_REQUIRED (null lanza; catch existente). CERO GAS re-verificado en todos los flujos.
Cobertura: clave real/stub, 7 guardias, dedups, stock por generación (ABIERTA/CERRADA/v2/vieja),
trigger PASÓ/FALLÓ/DISCREPANCIA + multilínea + multi-sorpresa, parcial iterativo, transformación
default, batch una-guía (mixto + omitidas), alcances wh-15d/mos-total, yaResuelta.
WH 2.13.449: labels/icono 🔄 para guías TRANSFORMACION.

## Ajustes de uso real (2026-07-19 · feedback del dueño, 5 puntos)
1. **SQL 521** — merma desde devolución: SOLO guías **ABIERTAS y DE HOY** (antes CERRADA — al
   revés). Semántica SPLIT: la parte dañada se resta de la línea → el cierre ingresa solo lo
   sano; sin tocar stock (nunca entró); recuperar SÍ acredita. Errores: GUIA_NO_ABIERTA /
   GUIA_NO_ES_DE_HOY. Suite adaptada: 32/32 ✅.
2. WH "+ Registrar merma" (hallazgo) recableado a v2 (culpa ALMACÉN + sale del vendible + foto).
3. **FIX botón 🎯 invisible**: `window.SorpresasWH` — una const global NO cuelga de window →
   `typeof`. esAdmin multi-fuente (rol de sesión → id → nombres de WH_CONFIG.usuario/wh_usuario
   en personal cache, rol admin o accesoMos). LECCIÓN para memoria.
4. Panel Mermas MOS: thumbnails con lightbox, vencidas borde rojo, agrupar 📅Fecha/🧭Estado.
5. Panel Sorpresas MOS: SOLO SEGUIMIENTO (registro solo en WH) — historial por fecha con
   alertas (FALLÓ rojo). MOS 2.43.578 · WH 2.13.450.

## Ronda 3 de feedback (2026-07-19) — MOS 2.43.579 · WH 2.13.451 · SQL 522
1. Botones NO se esconden: deshabilitados NOTORIOS (gris punteado + 🚫 + toast explicando) —
   ♻️ a mermas habilitado solo en devoluciones ABIERTAS de HOY; 🎯 solo en despachos de HOY.
2. Puerta B (hallazgo en andamio) VIVE en: WH → nav Mermas (cesta) → botón rojo "+ Registrar
   merma" (además FAB 🗑+ en esa vista y botón en el KPI mermas del Dashboard). Motor v2.
3. SQL 522: registrar_sorpresa exige guía DE HOY (server) + modal muestra NOMBRE del producto
   (enriquecido del catálogo; antes salía el código dos veces). Suite 33/33 ✅.
4/5. MOS: orden DESCENDENTE estricto por fecha en mermas y sorpresas (última fecha primero,
   también dentro de grupos por estado); guía referenciada visible por fila.

## Ronda 4 — UNIFICACIÓN (2026-07-19 · WH 2.13.452 · SQL 523)
HALLAZGO: WH tenía DOS sistemas de mermas paralelos. La "Cesta 🗑" del topbar (F2.5,
js/mermas.js) guardaba en la HOJA vía GAS (getMermasCesta/agregarAMermas/solucionarMerma/
procesarEliminacionMermas) — datastore paralelo a wh.mermas → por eso "0 pendientes" en el
topbar vs 3 reales en MOS. ELIMINADO completo (−392 líneas: botón topbar, 3 sheets, mermas.js,
wrappers abrirCesta/procesar/abrirProcesarMermas/actualizarBadgeMermas). ÚNICA cesta = vista
♻️ Mermas (nav) con v2. Ícono unificado ♻️ (= botón de guías de devolución). Alta Puerta B al
mockup: culpa ALMACÉN FIJA visible, sin select Responsable. Resueltas muestran el CÓMO
(✓ rec · 🔄 transformada+guía · 🗑 elim+guía · culpa). SQL 523: solucionadas 7 días en WH.
Suite 34/34 ✅. Boot verificado sin errores.

## Ronda 5 — CAUSA RAÍZ "Pendientes (0)" + cero-rastro (2026-07-19 · WH 2.13.453 · SQL 524)
BUG REAL reportado en vivo: vista Mermas WH vacía ("Sin mermas pendientes 🎉") con 3 pendientes
visibles en MOS, y crash `sel is not defined` al abrir "+ Registrar merma".
CAUSA RAÍZ (verificada con el pipeline exacto del cliente: mint-wh → REST rpc/mermas_lista):
el RPC SÍ devolvía las 4 filas, pero las 3 mermas legacy de la era Hoja (M001-M003) tenían
estado PENDIENTE/PROCESADA y la vista filtraba por el string EN_PROCESO → invisibles. MOS las
veía porque filtra por cantidadPendiente > 0, no por estado.
FIX doble:
- SQL 524: normalización NOMINAL de los 3 estados legacy → EN_PROCESO (por id, con guard pend>0).
- WH `_estadoCanon(m)`: el estado se DERIVA de cantidades (pend>0→EN_PROCESO; solo desechada→
  DESECHADA; resto→RESUELTA) en los 6 puntos que filtraban por string. A prueba de datos viejos.
CRASH sel: bloque huérfano del select Responsable (eliminado en Ronda 4) seguía en nueva() → fuera.
cargar(): si v2 Y legacy fallan → estado de ERROR visible + "↻ Reintentar" (nunca más el 🎉 engañoso).
CERO-RASTRO mermas (respuesta a "¿todo mermas es 100% Supabase?"): SÍ en runtime —
mermas_lista/procesar_merma/mermas_eliminar_batch/merma_desde_guia/merma_alta_manual (+foto a
Storage) todo RPC directo; fallback getMermas también es Supabase (leer_tabla_rls security definer).
Eliminado el código muerto restante: abrirResolver/balancearResolucion/confirmarResolver +
sheetResolverMerma (UI legacy sin callers) y las ramas/exports api.js registrarMerma/resolverMerma/
getMermasEnProceso/getMermasVencidas; registrarMerma/resolverMerma sellados en _WH_NO_GAS
(un replay de cola vieja jamás cae a GAS). Pendiente menor: purgar las funciones GAS-side
(getMermasCesta etc.) del Apps Script — ya sin ningún caller frontend.
Verificación: mint-wh + rpc → ok:true, 4 filas (3 EN_PROCESO vencidas 🔴 + 1 RESUELTA).

## Ronda 6 — UX cesta + verificación de STOCK (2026-07-19 · WH 2.13.454)
Feedback del dueño en uso real:
- Card pendiente ahora muestra lo que RESTA (−pend con "de N") — procesar 10/50 dejaba el card en 50.
  Chips de progreso en el pendiente parcial: "✓ n ya recuperadas · 🗑 n ya eliminadas".
- Pestañas-ASPECTO con contador en las 3: la merma PARCIAL aparece en Pendientes Y en
  Solucionado/Descartado (con "⏳ n aún pendientes") — antes el parcial recuperado no dejaba rastro
  visible en Solucionado.
- Lightbox de fotos in-app: zoom + ‹ › entre fotos de la pestaña + swipe + flechas + Esc (fuera window.open).
- Carga OPTIMISTA: warm start pinta el cache al instante y refresca en background (fuera el repintado).
- Responsive total: móvil 1 col ancha / tablet-PC cards 300-340px / thumb 72px.
- Dashboard: KPI "Mermas por procesar" (conteo real) + anillo rojo pulsante + chip "⚠ N +3d" si hay
  vencidas; panel expandible con días/pend y tap→vista. FIX: getDashboard filtraba estado legacy
  'PENDIENTE' (inexistente tras 524) → canon por cantidad.
VERIFICACIÓN DE STOCK pedida por el dueño — suite `_test_stock_mermas.js` 24/24 ✅ (tx+ROLLBACK):
alta manual SEPARA stock al entrar (flag stock_descontado) · recuperar RE-HABILITA (+stock) ·
eliminar → guía salida SIN doble descuento (v2 documental; legacy descuenta al eliminar) ·
desde-guía split nunca entra al vendible y recuperada SÍ entra · transformación destino entra /
origen no vuelve. Balance neto por unidad correcto en los 4 caminos.

## Ronda 7 — Dashboard: alertas sobre su módulo + vista Por vencer (2026-07-19 · WH 2.13.456)
- Sección "🚨 Alertas" (kpiGrid + 4 panels expandibles) ELIMINADA. Cada alerta = badge SOBRE el
  acceso rápido de su módulo: ♻️ Merma (N por procesar, dqb-danger pulsante si >3d), ⚡ Envasador
  (por envasar), 📅 Por vencer NUEVO (críticos rojo / ≤30d ámbar). Stock bajo → chip Estado del día
  → productos filtrados 'bajo'.
- Vista Vencimientos moderna (view-vencimientos, VencimientosView): 4 KPIs tap-filtro, default
  "⚠ En riesgo", tile grande de días con severidad (VENCIDO/CRÍTICO≤7/ALERTA≤30/OK, config
  DIAS_ALERTA_VENC*), tap → modal lotes FIFO, carga optimista, responsive.
- INCIDENTE solicitudes: 7 "Sin nombre" PENDIENTE_APROBACION fueron los Playwright de Claude
  (perfil fresco → UUID nuevo → auto-registro 1ra visita, BY DESIGN del fix deadlock). Se
  borraron nominal y existe TEST-CLAUDE-WH (7e57c1a0-…-c47a10906475, ACTIVO) + regla: todo
  escenario browsercheck WH lleva localStorage wh_device_id fijo.

## Ronda 8 — Semáforo vencimientos + historial de lote (2026-07-19 · WH 2.13.457 · MOS 2.43.580 · SQL 525-526)
- FIX historial modal Lotes: wh.lotes_historial era cascarón (0 filas, sin escritores). SQL 525:
  get_historial_lote SINTETIZA desde fuentes reales (INGRESO de lotes_vencimiento + MERMAS por
  lote + CONSUMO acumulado FEFO inicial−actual + legacy union).
- SQL 526 wh.vencimientos_lista: semáforo UNIFICADO server-side (claim wh O mos): VENCIDO /
  CRÍTICO ≤7 / ALERTA ≤30 / URGENTE ≤90 (categoría NUEVA del dueño: zonas no deberían tener
  producto a <3 meses) / SANO. Umbrales wh.config (DIAS_ALERTA_VENC_URGENTE def 90). GRANT
  authenticated explícito.
- WH: VencimientosView consume el RPC (severidad server), 5 KPIs + chip ≤90d + sv-urg amarillo.
- MOS: botón 📅 Por vencer en zona ALMACÉN (junto a 🎯/♻️, solo visualización) + badge rojo
  (vencidos+críticos) + modalVencimientos con el mismo semáforo.
- FEFO confirmado: getLotesFIFO y el picking ordenan por fecha_vencimiento asc ("vence primero,
  sale primero") — es FEFO real, cubre el caso "el último en llegar vence antes".
- PENDIENTE FASE 2 (diseño abajo): lote-en-guía de salida (las 2446 líneas SALIDA_ZONA de 30d
  llevan 0 id_lote) → asignación FEFO al cerrar + ledger wh.zona_lotes → vistas Por vencer en
  ZONA-01/02 con inferencia de restos ("te mandé 20 que vencen el X; vendiste 10, jefe 2 → debes
  tener 8"). Toca cierre de despacho + ventas ME (money-path) → diseñar con calma antes de tocar.

## Ronda 9 — FASE 2 FEFO POR ZONA (2026-07-19 · MOS 2.43.581 · SQL 527-529 · suite 24/24 ✅)
CAUSA de la muerte del sistema de lotes: TODO vivía en GAS cerrarGuia (Guias.gs
_consumirLotesFIFO + propagar_lotes_zona_cierre). El cutover cero-GAS del cierre (~16-jun) lo
dejó sin caller: lotes WH congelados, me.zona_lotes sin ingresos desde el 18-jun, rotación en
zona (RIZ Capa 5) nunca cableada, y BONUS: me.zona_recibir_lote gateaba mos._claim_ok — las
llamadas con claim warehouseMos/mosExpress morían en silencio (en la era GAS todo era
service_role '').
REVIVIDO EN SERVER (hooks SIEMPRE blindados — jamás tumban dinero):
- wh._consumir_lotes_fefo: consumo FEFO WH + escribe wh.lotes_historial (¡primer escritor!).
- me.zona_consumir_fefo_cod: rotación FEFO zona por cod_barras (fallback sku_base×factor).
- Hooks en wh.cerrar_guia_idempotente + wh.crear_despacho_rapido: salida consume FEFO;
  SALIDA_ZONA hereda lote+vencimiento a la zona (propagar, idempotente); devolución descuenta
  el libro de la zona.
- me.cerrar_guia_zona_idempotente: SALIDA_JEFA consume; SALIDA_MOVIMIENTO hereda al destino
  (gate anti-dedup igual que el saldo).
- Trigger tg_zona_lotes_venta en me.ventas_detalle: la venta rota FEFO (zona de ventas.zona_id).
- Reconciliación 529: 16,096 uds / 161 productos consumidas FEFO (drift del hueco del cutover),
  auditadas id_guia='RECON20260719'; drift restante 0. Semáforo real: 4V/1C/1A/3U/176 sanos.
- vencimientos_lista v2 con p.zona → me.zona_lotes de esa zona, mismo semáforo.
- MOS: botón 📅 en TODAS las zonas (almacén = WH; zonas = libro), badge por alcance, título
  dinámico. Suite `_test_fefo_zona.js` 24/24 (tx+ROLLBACK): FEFO WH, herencia, venta, jefa,
  traslado, devolución, idempotencia, huérfano blindado.
NOTA: el libro de zonas arranca con lo heredado de HOY en adelante (lo pre-existente en zona
sin lote queda como huérfano informativo — el consumo huérfano no rompe nada).
