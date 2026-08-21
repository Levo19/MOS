# 🧠 ZONAS · Leyenda viva de INSIGHTS y MATICES de prioridad

> **Qué es esto.** El módulo Zonas (RIZ = Reposición en Zona) no reparte a todos los productos por
> igual: cada producto tiene una **naturaleza logística** distinta según su tipo y su puesto (Almacén /
> Zona 1 / Zona 2). Este documento es la **fuente de verdad** de esas reglas. Cada regla es un
> **INSIGHT**, y cada insight se traduce en un **MATIZ**: un modificador que **sube (↑) o baja (↓) la
> prioridad** del producto en la lista de reposición.
>
> **Para qué sirve.** (1) Que cualquier admin entienda *a qué se enfrenta* con cada producto y por qué
> uno es urgente y otro no. (2) Que nosotros **agreguemos features sin equivocarnos**, sabiendo qué toca
> qué. Antes de tocar prioridad / meta / demanda / cuadrantes, **leer este archivo**.
>
> **Cómo agregar un insight.** Copiar la plantilla del final, darle un ID `I-NN`, decir a qué **puesto**
> aplica, su **matiz** (↑/↓/neutral y cuánto), su **estado**, y **qué código afecta**. Nunca borrar un
> insight: si se invalida, marcarlo `❌ INVALIDADO` con la fecha y el porqué.

Última actualización: **2026-08-20** · Versión app en curso: **2.43.919** · Relacionado:
`PUNTO_DE_RETOMA_cero_gas.md`, memoria `architecture_riz_*`, `architecture_catalogo_envase_insumo`.

---

## 0) Glosario del modelo de datos (VERIFICADO en DB 2026-08-20)

Sin esto los matices no se entienden. Todo confirmado contra `mos.productos` en prod.

| Concepto | Dónde vive | Qué significa |
|---|---|---|
| **tipo_producto** | `mos.productos.tipo_producto` (enum) | `CANONICO` · `DERIVADO` · `PRESENTACION`. (Las **equivalencias** viven aparte en `mos.equivalencias`: mismo producto, otro código de barra, factor 1.) |
| **Granel** | canónico con `unidad='KGM'` | Se mueve/vende por **peso**. Ej: `00028` OREGANO ENTERO GRANEL, `WHORLIRO` OREGANO MOLIDO GRANEL. |
| **Granel ENVASABLE** | granel KGM que es `codigo_producto_base` de ≥1 DERIVADO | El granel que existe **para ser envasado** en derivados. Su movimiento real NO es despacho a zona → es **envasado**. |
| **DERIVADO** | `tipo='DERIVADO'`, NIU, tiene `codigo_producto_base` (sku del granel padre) | Producto envasado con **stock propio**. Consume padre + envase. Ej: `WHORLIRO050GR` OREGANO MOLIDO PIZERO 50GR. |
| **`factor_conversion_base` (fcb)** | `mos.productos.factor_conversion_base` (numeric) | **kg de granel que consume 1 unidad del derivado.** Verificado: 50GR→0.05, 100GR→0.10, 250GR→0.25, 500GR→0.50. **Éste es el "factor" del insight de graneles.** |
| **`factor_conversion` (fc)** | `mos.productos.factor_conversion` | Factor de la **presentación** sobre su padre. `<1` = fracción (25gr de granel → 0.025), `>1` = pack (Sibarita x66 → 66). |
| **PRESENTACIÓN de un granel** | `tipo='PRESENTACION'`, comparte `sku_base` con el granel, `fc<1` | **Es fracción del granel mismo. SIN stock propio.** Al venderse, `cant×fc` se descuenta del **granel canónico** (regla `mos._venta_canonico`). Ej: `P-ORGENT-D40` 25gr y `P-ORGENT-F60` 60gr comparten `LEV025` con `00028`. |
| **INSUMO / envase** | `es_insumo=true`; `mos.productos.envase_sku` = sku del insumo | Celofán/bolsa. `wh.registrar_envasado` lo **consume por MILLAR** (uds/1000). Nunca se despacha a zona. 34 celofanes. Ej: `LEV1007`, `LEV1051`. |
| **Stock efectivo por código** | front `_zonaEffStock(p)` | Suma de stocks **positivos** por código (negativo por código = 0). NUNCA sumar y luego truncar. MAGGI −203+145 = **145**, no −58. |
| **Regla peso vs unidad** | `mos._venta_canonico(cod,cant,um)` | Venta por **peso** (KGM/GR/…) → va al canónico **sin factor**. Venta por **unidad** (NIU) → `×factor`. |
| **Demanda del granel** | (deriva de lo anterior) | Granel envasable no se "pide a proveedor por unidad": lo que falta es **Σ(faltante_derivado × fcb) + ventas directas del propio granel**. Se parece al "modal de proveedores donde se suma". |

**Puestos y su ritmo** (regla del dueño): **Almacén ≈ 1 semana** de rotación (se surte de proveedores /
envasa), **Zonas ≈ 1 día** (se surten del Almacén a diario). Almacén mide por **semana**, Zonas por **día**.
Todo **canónico + equivalentes** juntos.

---

## 1) INSIGHTS y sus MATICES

Leyenda de estado: ✅ implementado · 🟡 parcial · ⛏️ pendiente · 💡 idea · ❌ invalidado.
Leyenda de matiz: **↑↑** sube fuerte · **↑** sube · **=** neutral (regla de conteo, no de prioridad) ·
**↓** baja · **↓↓** baja fuerte. `[A]`=Almacén `[Z]`=Zona1/2.

### I-01 · Stock negativo = 0, **por código** (no en la suma)
- **Qué.** Un código con stock negativo cuenta como 0, pero **cada código por separado**. MAGGI con
  `−203` y `+145` = **145 disponibles**, no `−58`. Solo un negativo dentro del grupo no anula al resto.
- **Puesto.** `[A][Z]` ambos.
- **Matiz.** `=` (es base de cálculo, no un ± de prioridad). Alimenta a TODOS los demás matices.
- **Estado.** ✅ `_zonaEffStock(p)` (2.43.915). Banner "recontar negativos" (#2).
- **Afecta.** `_zonaEffStock`, `_zonaCuadDe`, `_zonaPrioridad`, `_zonaMetaDe`, medidor, plata inmovilizada.

### I-02 · Meta **inteligente** (tendencia de 4 semanas), explicada en el gráfico
- **Qué.** La meta no es "última semana": pondera 4 semanas y corrige por tendencia (📈 sube, 📉 baja,
  ➡️ estable). Con <2 semanas con datos → última×1.2. Tope anti-pico `maxPk×1.25`.
- **Puesto.** `[A]` por semana · `[Z]` por día.
- **Matiz.** `=` (define la meta; la brecha resultante es lo que prioriza).
- **Estado.** ✅ `_zonaMetaSmart` + `_zonaEsperadoRender` (2.43.916).
- **Afecta.** `_zonaMetaSmart`, `_zonaMetaDe`, brecha, medidor, cuadrante `pedir`.

### I-03 · Prioridad **dinámica**: si ya pedí, baja
- **Qué.** Los cuadrantes se ordenan por urgencia real y **en tiempo real**. En `pedir`: primero el que
  **más falta** (%), luego lo que falta y **hay en almacén**, luego lo que falta y **hay en la otra
  zona** (foquito). Si ya lo pedí / está en carrito → **baja**. Si me despachan a mediodía → deja de ser
  prioridad al instante.
- **Puesto.** `[A][Z]`.
- **Matiz.** `↓` si `pedidoEstado` o `_zonaCarritoCant>0`.
- **Estado.** ✅ `_zonaPrioridad` (2.43.913) + realtime (SQL 888).
- **Afecta.** `_zonaPrioridad`, orden de `renderZona`, triggers de realtime.

### I-04 · **Demanda insatisfecha (deuda)** en Almacén
- **Qué.** Un producto puede **no haber sido despachado** pero **sí haber sido solicitado** → se debe.
  "Deuda" = solicitado − despachado (nunca negativa). Es una **promesa de compra**. Se dibuja apilada
  junto a lo despachado ("demanda insatisfecha").
- **Puesto.** `[A]`.
- **Matiz.** `↑` — deuda acumulada sube la prioridad de compra (demanda real > lo que ves vender).
- **Estado.** ✅ `mos.almacen_demanda_semanal` (SQL 920) + `_zonaDemandaRender` (2.43.917).
- **Afecta.** RPC 920, `_zonaDemandaRender`, proyección/meta de almacén.

### I-05 · **Foquito** Zona 1 ↔ Zona 2
- **Qué.** Si a mi zona le falta y **Almacén no cubre**, avisar que **la otra zona tiene** — para no
  chocar entre zonas. Solo entre Zona1 y Zona2 (no mostrar almacén como "otra zona").
- **Puesto.** `[Z]`.
- **Matiz.** Reordena el faltante (3er nivel de urgencia dentro de `pedir`, tras "hay en almacén").
- **Estado.** ✅ `mos.zona_stock_cruzado` (SQL 921) + `_zonaCruzadoDe` (2.43.918).
- **Afecta.** RPC 921, `_zonaCruzadoEnsure/_zonaCruzadoDe`, `_zonaPrioridad`.

### I-06 · **Plata inmovilizada** en soles (muertos / sobrantes)
- **Qué.** En cuadrantes `muerto` y `sobra`, mostrar **S/ atrapados** = stock efectivo × costo
  catálogo. Ayuda a priorizar qué liberar.
- **Puesto.** `[A][Z]`.
- **Matiz.** `↑` dentro de `muerto`/`sobra`: más plata dormida = más urgente liberar.
- **Estado.** ✅ `_zonaCostoUnit` + `_plataTxt` (2.43.913).
- **Afecta.** `_zonaCostoUnit`, `_plataTxt`, orden de `muerto`/`sobra`.

### I-07 · Granel **ajustable en g/kg** (kardex siempre en kg)
- **Qué.** Los graneles se miden en **kilos**; el ajuste rápido acepta gramo o kilo (toggle), pero al
  kardex va **kilos** con su factor.
- **Puesto.** `[A][Z]`.
- **Matiz.** `=` (UX de ajuste; no cambia prioridad).
- **Estado.** ✅ chips `data-unit`, `zonaChipUnidad`, `zonaChipSave` (2.43.914).
- **Afecta.** `_zonaCodChipsHtml`, `zonaChipSave` (conversión g→kg).

---

### 🆕 Insights de esta ronda (2026-08-20) — envasado, insumos, mostrario, fracciones

### I-08 · Granel ENVASABLE en Almacén: **rotación ≈ 0 pero SÍ tiene demanda** (vía factor)
- **Qué.** Un granel con derivados casi no se "despacha a zona" → el gráfico de despacho lo ve **muerto**.
  Pero su movimiento real es el **envasado**. Si el derivado (ej. Nakamito 1kg) vende 100/sem, tengo 80 y
  mi meta es 120 → faltan 40 un, **pero no se piden 40 bolsas al proveedor**: lo que falta es
  **40 × fcb = 40 kg de Nakamito GRANEL** (porque lo envaso yo en almacén).
  **Demanda del granel = Σ(faltante_derivado × fcb) + ventas directas del propio granel.**
  Se alimenta de las **guías de envasado** (cuánto se envasa por día/semana), no de despachos a zona.
- **Puesto.** `[A]` **exclusivo** (no aplica a zona; ver I-10).
- **Matiz.** **↑↑** — **rescata al granel del cuadrante "muerto"**. Rotación cero + requerido para
  envasar = **prioridad EXTREMA de compra** (caso Nakamito Granel). Sin este matiz el sistema lo
  escondería como producto sin salida.
- **Estado.** ✅ **2.43.922 (COMPLETO)**. (a) Gráfico: `mos.almacen_demanda_semanal` v2 (SQL 924) suma
  `envasado` (guías `SALIDA_ENVASADO`) → segmento violeta + entra a la meta; `_zonaCuadDe` rescata de
  "muerto". (b) **META DEL GRANEL = Σ(faltante_derivado × fcb)** — `mos.granel_demanda_derivados` (SQL 925):
  por derivado `faltante = meta(Σ zona_esperado retail) − have(wh.stock + me.stock_zonas)`, `granel = faltante×fcb`;
  `granelNecesario = Σ`, `comprar = max(0, necesario − stock granel)`. El card carga la compra real
  (`_zonaGranelCargarVisibles` → "🧾 Comprar N a proveedor" / "✓ Derivados cubiertos") y el "¿Por qué?"
  muestra el desglose (`_zonaGranelBreakdownHtml`). **Lo que se compra al proveedor es el GRANEL.**
- **Afecta.** SQL 924+925, `_zonaDemandaRender`, `_zonaCuadDe`, `_zonaEsGranelEnvasable`, `_zonaGranelCargarVisibles`,
  `_zonaGranelBreakdownHtml`, `_zonaSecCargarPq`, `API.zona.granelDemanda`, `_zonaCardHtml` (botón `zGbuy-`).

### I-09 · **Insumos** (celofanes) en Almacén: demanda por **millares**, nunca despachados
- **Qué.** Un insumo (`es_insumo=true`, ej. Celofán 7×10×2) **nunca se despacha a zona** → rotación por
  despacho = 0. Pero **sí es demanda**: la cantidad usada al envasar. Los celofanes se **piden por
  millares** al proveedor (`wh.registrar_envasado` los consume por MIL = uds/1000).
  **Demanda del insumo = Σ(unidades envasadas que lo usan) / 1000.**
- **Puesto.** `[A]` **exclusivo**.
- **Matiz.** **↑** — rescata al insumo del cuadrante "muerto". Si `stock_MIL < demanda_MIL` → **comprar
  al proveedor** (en millares).
- **Estado.** ✅ **2.43.921** — unificado con I-08: las guías `SALIDA_ENVASADO` incluyen la línea del
  insumo (celofán consumido por MIL), así que el mismo `envasado` de SQL 924 lo cuenta. Detección
  `_zonaEsInsumo` (catálogo `esInsumo=='1'`); rescate de "muerto" + card "🧷 insumo · se compra por
  millares". (Bonus futuro: `stock_minimo` de celofanes para alerta.)
- **Afecta.** SQL 924 (mismo `envasado`), `_zonaEsInsumo`/`_zonaSeEnvasa`, `_zonaCuadDe`, `_zonaCardHtml`.

### I-10 · Graneles envasables **NO deberían vivir en Zona 1/2** (salvo mostrario limitado)
- **Qué.** Para eso se creó el derivado: en zona el cliente quiere el **envasado**, no el granel. Tener
  granel envasable en zona **en exceso es malo** (ese granel debería estar en almacén para envasar).
  Se permite un poco para **muestra / mostrario**, pero **limitado**.
- **Puesto.** `[Z]` **exclusivo** (contrapartida de I-08).
- **Matiz.** **↓↓** la prioridad de *reponer* el granel en zona. Y si `stock_zona > tope_mostrario` →
  marcar como **sobrante "devolver a almacén"** (no repartir a la otra zona vía foquito: el granel
  sobrante regresa al almacén para envasarse). **Mismo producto: EXTREMO en `[A]`, casi nulo en `[Z]`.**
- **Estado.** 🟡 **2.43.921** (parcial). En ZONA, `_zonaPrioridad` baja al granel envasable (mostrario, no
  prioridad) y el card muestra chip "🏭 mostrario · se envasa en almacén". Pendiente fino: `tope_mostrario`
  configurable + marcar el exceso como "devolver a almacén" y excluirlo del foquito zona↔zona.
- **Afecta.** `_zonaEsGranelEnvasable`, `_zonaPrioridad` (rama zona), `_zonaCardHtml` (chip mostrario).

### I-11 · Presentación de un granel = **fracción del granel mismo** (no cuenta doble)
- **Qué.** VERIFICADO: `P-ORGENT-D40` (25gr) y `P-ORGENT-F60` (60gr) son `PRESENTACION` con `sku_base`
  del granel `00028` y `fc<1`, **sin stock propio**. Su venta descuenta del **granel canónico** (regla
  `_venta_canonico`). Por tanto su demanda **ya está** en la del granel; **no** es un producto
  independiente que reponer, y **no se cuenta doble**.
- **Puesto.** `[A][Z]`.
- **Matiz.** `=` (regla de conteo). El riesgo sería tratar la fracción como ítem propio y duplicar
  demanda o mostrar un "muerto" fantasma. **Excluir presentaciones de granel del listado de
  reposición** (su padre ya las representa).
- **Estado.** ✅ **2.43.921** — `renderZona` filtra `_zonaEsPresentacionGranel` (presentación-huérfana:
  comparte sku pero SIN canónico propio). Verificado: solo 2 skus así en el panel (los canónicos basura
  PRE### de memoria) — no se listan.
- **Afecta.** `renderZona` (filtro), `_zonaEsPresentacionGranel`/`_zonaCanonSkuSet`.

### I-12 · **Estrella que falta despachar = urgente** (matiz en el botón Pickup)
- **Qué.** En el botón **Pickup del módulo Zona** (MOS), la lista de despacho ya se ordenaba por urgencia
  (deuda + veces pedido + días esperando + stock de almacén + 🆕 ingreso reciente). Ahora un producto
  **ESTRELLA** (lo que MÁS mueve la zona, `bcg` de `me.zona_esperado`) que la zona **aún debe despachar**
  (pendiente>0) **sube como urgente**: +35 al score, chip **⭐ estrella · urge despachar**, acento dorado
  y su nombre con ⭐. Funciona igual **en cada zona** y en las **pestañas Zona1/Zona2 del Almacén** (el
  BCG viene por-zona de la RPC, no del panel actual). La leyenda del pickup lo explica.
- **Puesto.** `[Z]` (y `[A]` viéndolo por pestañas de zona).
- **Matiz.** **↑** dentro de la lista de despacho.
- **Estado.** ✅ SQL 922 (`wh.zona_pickup_detalle` expone `bcg` por sku de la zona) + `_zpkRender`
  (2.43.919).
- **Afecta.** RPC `wh.zona_pickup_detalle` (join `me.zona_esperado`), `_zpkRender` (score/chips/clase),
  CSS `.zpk-chip.zc-estrella`/`.zpk-item.zpk-star`.

### I-13 · **Push proactivo de estrellas críticas** ("considera cargar")
- **Qué.** Un producto **ESTRELLA por agotarse EN LA ZONA** que **sí hay en almacén** (accionable) avisa
  solo a **admins/ascendidos** por MOS: *"⭐ Zona 1: Comino 1kg… — considera cargar."* No es un problema
  de compra (si NO hay en almacén, es otro carril): es un empujón para **cargar lo que ya existe**.
- **Puesto.** `[Z]` (alerta a la administración).
- **Matiz.** Es **alerta proactiva**, no un ± en la lista; complementa a I-12 (la app ordena, el push
  avisa sin abrir la app).
- **Estado.** ✅ SQL 923 — cron `mos-estrellas-criticas` (UTC 15/18/21/0 = Lima 10/13/16/19h) →
  `mos.cron_avisar_estrellas_criticas()`. **CRÍTICO** = `bcg=ESTRELLA` · zona retail · `esperado≥2` ·
  stock efectivo zona `≤ 20%` de la meta (negativo por código=0, I-01) · **stock de almacén > 0**. Push
  agrupado por zona (estilo precios "A, B, C… y N más") vía `mos.emitir_push` audiencia
  `roles:[MASTER,ADMINISTRADOR,ADMIN]` (rutea a MOS + ascendidos). **Dedup** por `(zona,sku,día)` en
  `mos.notif_estrella_log` → nunca spamea.
- **Afecta.** `mos.cron_avisar_estrellas_criticas`, tabla `mos.notif_estrella_log`, `cron.job`
  `mos-estrellas-criticas`, `mos.emitir_push`/`mos.push_tokens_para` (audiencia admin). Prueba manual:
  `select mos.cron_avisar_estrellas_criticas();` (⚠ envía push real).

### I-14 · **Botón 💡 Insights in-app** (la leyenda vive en el módulo, no en un doc)
- **Qué.** Junto al grupo **🛡 Control** del dock hay un botón **💡 Insights** que abre un overlay con
  estos mismos insights **en lenguaje claro**, agrupados por el **matiz** que afectan (⚙️ base · ⬆️ sube ·
  ⬇️ baja · 🔔 avisos), **distinto por puesto**: Almacén ve deuda/envasado/insumos; Zona ve
  foquito/estrella/push. Marca "en camino" los aún no codificados (I-08/09/10/11) para que el admin
  entienda la lógica completa. Fuente única: la constante `_ZONA_INSIGHTS` en app.js (mantener en
  sincronía con este archivo).
- **Puesto.** `[A][Z]` (contenido filtrado por puesto).
- **Matiz.** `=` (es documentación viva para el admin; de aquí entiende las prioridades).
- **Estado.** ✅ 2.43.920 — `zonaAbrirInsights`/`zonaCerrarInsights` + `_ZONA_INSIGHTS`/`_ZINS_SEC`,
  botón en grupo Control, CSS `.zins-*`.
- **Afecta.** `_ZONA_INSIGHTS` (app.js) es la fuente in-app; este `.md` es la fuente de ingeniería —
  **al agregar/cambiar un insight, actualizar AMBOS**.

### I-15 · **Clasificación por DEMANDA (todo el grupo almacén): muerto real vs aparente**
- **Qué.** La meta de CADA producto de almacén = **demand-flow** = despacho (🔵) + envasado (🟣) +
  deuda propia (🟡) + deuda de derivados (🟠), proyectada a **1 semana** (+20%). Un producto solo es
  **"muerto"** si NO tiene demanda de ningún tipo. Si se despacha, se envasa o **se DEBE** (demanda
  insatisfecha), está **VIVO** → entra a **"Pedir ya"** aunque su rotación por despacho sea 0. Así el
  admin se enfoca en lo que realmente falta y en lo que de verdad está muerto. **El celofán/insumo** es
  el caso completo: se despacha a zona, se gasta al envasar, se debe por sí mismo y se debe por los
  productos que lo usan — las 4 barras aplican.
- **Puesto.** `[A]` (en zonas la clasificación sigue por picos/venta diaria, sin cambios).
- **Matiz.** **↑↑** rescata de "Muertos" a todo lo que tiene demanda (deuda incluida).
- **Estado.** ✅ **2.43.924** — `mos.almacen_demanda_bulk` (SQL 927, meta demand-flow de los 669 productos
  con actividad) + `_zonaAlmDemAsegurar` (carga 1×, cache 2 min, re-render) + `_zonaMetaDe`/`_zonaCuadDe`
  reescritos para almacén (deuda>0 y no cubierto → 'pedir'; 'muerto' solo si NO hay demanda). Card: chip
  "🟡 demanda insatisfecha" (ya no "considera anular"). Gráfico: barras clickeables con texto por tipo.
- **Afecta.** SQL 927, `_zonaMetaDe`, `_zonaCuadDe` (rama almacén), `_zonaAlmTieneDeuda`,
  `_zonaAlmDemAsegurar`, `renderZona`, `_zonaCardHtml` (rotCeroChip/Hint), `API.zona.demandaBulk`.

---

## 2) Modelo de MATICES (cómo se combinan)

Prioridad final por producto = **prioridad base del cuadrante** ± **Σ matices aplicables al puesto**.
La clave del pedido del dueño: **el mismo producto puede tener prioridad opuesta según el puesto.**

```
prioridad(p, puesto):
  base = cuadrante_base(p)                 # pedir > sobra/muerto según naturaleza
  # --- matices que ya viven en código ---
  if pedir:   base += %faltante            # I-02/I-03  (más falta = más arriba)
              if ya_pedido: base -= K       # I-03
              if hay_en_almacen: nivel 2     # I-03
              if hay_en_otra_zona: nivel 3   # I-05 foquito  [Z]
  if sobra:   base += eff/esp               # I-06 (+ S/ inmovilizado)
  if muerto:  base += eff  (+ S/ inmovilizado)  # I-06
  # --- matices NUEVOS por puesto (I-08..I-11) ---
  if puesto == ALMACEN:
     if granel_envasable(p) and demanda_envasado(p) > stock(p):  base = MUY_ALTA   # I-08 (rescate)
     if insumo(p)          and demanda_millar(p)   > stock(p):  base = ALTA        # I-09 (rescate)
  if puesto in (ZONA1, ZONA2):
     if granel_envasable(p):                                     base -= GRANDE     # I-10 (casi nulo)
        if stock(p) > tope_mostrario(p):  marcar "devolver a almacén" (no foquito)
  if presentacion_de_granel(p):  EXCLUIR del listado              # I-11 (lo representa el padre)
```

Detección compartida (una sola función, la usan I-08/I-10/I-11):
- `granel_envasable(p)` = `tipo=CANONICO` ∧ `unidad='KGM'` ∧ existe DERIVADO con `codigo_producto_base = p.sku`.
- `presentacion_de_granel(p)` = `tipo=PRESENTACION` ∧ el padre (por `sku_base`) es granel KGM.
- `demanda_envasado(granel)` = `Σ_derivados max(0, meta_der − eff_der) × fcb_der` + ventas directas del granel.
- `demanda_millar(insumo)` = `Σ envasado_uds_que_usan_el_insumo / 1000`.

---

## 3) Backlog derivado de estos insights (orden sugerido por riesgo)

1. **Detección `granel_envasable` / `presentacion_de_granel`** (frontend, usa catálogo ya cargado). Base
   de I-08/I-10/I-11. Sin riesgo de dinero. → habilita I-11 (excluir fracciones) de inmediato.
2. **I-11** excluir presentaciones de granel del listado (barato, evita conteo doble).
3. **I-10** matiz `[Z]` "granel envasable casi nulo + devolver a almacén" (usa solo catálogo + stock).
4. **RPC `almacen_demanda_envasado`** (I-08) — money-adjacent (decide compras): sumar
   `faltante_derivado × fcb` + ventas directas, leyendo `SALIDA_ENVASADO`. **Revisar 10×** antes.
5. **RPC `almacen_demanda_insumo`** (I-09) — consumo de envase por millar desde `wh.envasados`.
6. **Matiz de rescate** en `_zonaCuadDe` para I-08/I-09 (que no caigan en "muerto").
7. **`tope_mostrario`** config por zona/producto (I-10) — default pequeño; editable admin.

---

## 4) Plantilla para nuevos insights

```
### I-NN · <título corto>
- **Qué.** <descripción; ejemplo real con números>
- **Puesto.** [A] y/o [Z] (¿exclusivo?)
- **Matiz.** ↑↑/↑/=/↓/↓↓ — <por qué sube o baja la prioridad>
- **Estado.** ✅/🟡/⛏️/💡/❌ + versión/SQL
- **Afecta.** <funciones, RPCs, render que tocaría — para no rompernos a futuro>
```
