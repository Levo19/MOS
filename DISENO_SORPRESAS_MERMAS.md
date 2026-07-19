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
- Pendiente fino: batch eliminar genera N guías (una por merma) — refinamiento futuro: una sola.
