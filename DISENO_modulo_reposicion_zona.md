# Módulo de Reposición Inteligente por Zona (RIZ) — Diseño completo

> **Estado:** Diseño / sin código. Pensado 100% Supabase (frontend directo + RPCs + pg_cron + Edge IA + PrintNode).
> **App host:** MOS (admin). **Usuarios:** administradores de zona, en celular/tablet + papel 80mm.
> **Fecha:** 2026-06-17. Análisis multironda (arquitecto · ingeniero senior · diseñador senior).
> **Regla de oro del dominio:** se razona por **producto base (skuBase)**, NO por presentación ni por código de barra. Un tripack = 3 unidades del base (se normaliza por `factor_conversion`). Un producto puede tener varios códigos de barra (propio + equivalentes) → todos son el mismo producto.

---
---

# PARTE 0 — CAPTURA FIEL DE LA IDEA (sin perder nada)

**Problema.** A zona (ej. Zona 2) le falta stock de productos que el cliente quiere (ej. 20un Ajinomoto 1kg). El pickup automático al cerrar caja repone *incrementalmente* (lo que se vendió/venció), pero **no cubre los picos de demanda**. Hay clientes "pico" (ej. el cliente X compra ~20un de Ajinomoto casi todos los miércoles). Si zona no está preparada, se pierde la venta.

**Idea central — "espacio deseado" (cantidad esperada).** Para cada producto×zona debe existir un **stock objetivo** que represente *cuánto debería haber siempre en el andamio* para satisfacer la demanda pico:

```
   cantidad_esperada(producto, zona) = PICO_AJUSTADO × 1.20   (redondeado hacia arriba)

   donde PICO_AJUSTADO sale del análisis de TENDENCIA de las semanas cerradas:
     - se toma el PICO DIARIO de cada semana (el día que más se vendió ese producto en esa zona)
     - se observa la serie de picos semanales:  s1=15  s2=16  s3=18  s4=21
     - según la tendencia se proyecta el pico de la próxima semana
   y se le suma 20% de colchón (configurable).
```

Ejemplo: el miércoles se vendieron 21un (cliente X 20 + cliente Y 1). Pico = 21. Esperada = 21 × 1.2 = **26un**. Esos 26 deben estar listos *todos los días* esperando al posible cliente grande.

**Los 4 casos de tendencia** (clasificación por producto×zona):

```
 1) ASCENDENTE  (15→16→18→21)  → esperada SUBE casi-automático. Informar al admin "consigue más".
 2) DESCENDENTE (21→14→9→5)    → esperada BAJA cada semana. Evitar sobre-stock. Informar.
 3) ESTABLE / SUBE-Y-BAJA      → esperada casi fija (banda). Caso tranquilo.
 4) ROTACIÓN CERO en zona      → nunca se vendió/venció. Informar para: promocionar / mover a góndola
                                  visible / rematar / eliminar. (Tener algo que no rota = puro gasto.)
```

> En todos los casos el sistema **INFORMA, no decide**. El admin es quien actúa.

**La brecha y el qué-hacer.** En la tabla de stock de zona, junto a `stock` se guarda `esperado`. La diferencia dispara la acción:

```
   brecha = esperado − stock_zona        (cuántos faltan para estar preparado)
   si brecha > 0  → el admin debe CONSEGUIR esa cantidad:
        1) pedir a ALMACÉN (si almacén tiene)         → botón "pedir" (reusa pickup ME→WH)
        2) si almacén no alcanza → COMPRA EXTERNA      → va a la lista de compras del lunes
        3) ajustar stock si el conteo estaba mal       → editar stock de zona en el card
```

**Escenario "almacén no tiene".** Al vender 21un el miércoles, almacén despacha lo que tiene (ej. 10). El día siguiente se venden 2 y despacha 2... esos ~11 de diferencia **nunca se despachan**. Almacén ya trackea lo que "debe" por su lista de pickup (eso está bien para almacén) — **pero la problemática es del ADMIN DE ZONA**, que necesita verlo y resolverlo proactivamente.

**Comunicación.** Zona habla **solo con almacén** (en ambos sentidos). **Nunca zona↔zona** (se elimina a propósito para evitar roces/disputas). Fuentes de datos del módulo: **catálogo + stock de zona + stock de almacén**. NO el stock de otras zonas.

**El card del producto (en el módulo de zona).** Para cada producto el admin ve y puede:
- ver `stock_zona`, `esperado`, `brecha`, la **tendencia** (mini serie semanal), `stock_almacen`;
- **ajustar el stock** de zona ahí mismo (si el conteo estaba mal: decía 5, en realidad hay 4);
- **sugerencia IA** dentro del card: "te faltan 22un para evitar problemas; almacén tiene 18 → [pedir]; los otros 4 consíguelos por fuera";
- botón **"pedir a almacén"** → manda el pedido a almacén (reusa el flujo pickup);
- lo que almacén no cubre → entra a la **lista de compra externa**.

**Compra externa (caja de zona).** "Pedir en otro lugar" = comprar con la **caja de la propia zona**. Debe ser organizado: **un solo día (lunes)** se emite la lista de compras. El admin recibe **impresa automáticamente los lunes** la lista de externos a conseguir — solo productos que **almacén no pudo satisfacer Y que sí se venden** (no comprar lo que nunca se vende).

**El proceso MANUAL diario (para llegar a stock confiable + lista de compras).** Las semanas analizadas (3–4) tuvieron, p.ej., 70 productos base distintos vendidos. Se **divide por día**: cada día, al abrir tienda, se **imprime automáticamente un ticket de ~10 productos**. El ticket muestra por producto:
```
   A. Nombre del producto (Ajinomoto)
   B. Stock en zona (5un)            ← el admin VERIFICA si es real; si no, AJUSTA
   C. Tendencia (s1=16 s2=18 s3=21 ↑)
   D. Cuántos faltan para satisfacer demanda (18)
   E. Stock de almacén (14)
```
Trabajo del admin: leer **A**, verificar **B** (ajustar si está mal), pensar el comportamiento **C**, y si hace falta **pedir ya** usando **E** y **D**; si no pide, deja el stock ajustado. **El domingo en la noche** el programa analiza todo (con el stock ya actualizado, porque de lunes a domingo el stock fluctúa en zona y almacén) y arma la **lista de compras del lunes**. Así, día a día hasta cubrir todos los productos, el admin siempre está informado de su tienda: productos frescos, stock real, todo al día.

**Panel / IA.** El admin se "informa" en un **módulo de Zona** con el comportamiento de cada producto. Puede filtrar por tendencia (sube / baja / nula rotación) y por `esperado/stock` (cuántos faltan pedir). Un **panel de sugerencias (puede ser IA)** con estos parámetros ayuda al admin: qué pedir, qué rematar, qué promocionar.

---
---

# DECISIONES CERRADAS (respuestas del dueño, 2026-06-17)

1. **Factor (VERIFICADO en datos):** ME registra el **conteo de la presentación** (ej. 4 tripacks = `cantidad 4`), NO unidades base. Normalización correcta = **`base = cantidad × factor_conversion`** (4×3=12), agregando todas las presentaciones + equivalentes al **skuBase**. No se cambia ME. ⚠️ Las RPCs existentes (rotacion_productos/insights_stock/etc.) NO normalizan → bug a corregir de paso.
2. **Tendencia:** se calcula sobre **4 semanas cerradas**.
3. **Colchón:** **20%** por defecto, **editable por zona** (aplica a todos los productos de esa zona), y el resultado **se redondea hacia arriba** (25.1 → 26 = `ceil`).
4. **Valor de referencia + tendencia INFORMATIVA:** la `esperada` se calcula con el **pico de la ÚLTIMA semana** (ej. Ajinomoto: última semana = 21 → se usa 21). La **tendencia NO proyecta** un número: es solo una **etiqueta informativa** (creciente / decreciente / estable / nula) que le dice al admin si ese número subirá o bajará a futuro, para que decida (promocionar, mejorar, anular, etc.). → `esperada = ceil(pico_última_semana × (1 + colchón_zona))`.
5. **Costo de compra externa:** NO lo construye RIZ. Se registra por la **guía de ingreso de ME** (cada zona tiene esa opción): compra exclusiva de zona → guía de ingreso directa a la zona; conducto regular → admin compra → entra a almacén → almacén mueve a la zona. En ambos, el **módulo Almacén/Operaciones** ya muestra los costos ingresados para el ajuste de precios. RIZ solo enlaza ahí.
6. **Rotación / comportamiento = MATRIZ BCG (visual):** los 4 casos se mapean a la matriz BCG con íconos y bordes animados — ⭐ Estrella, 🐄 Vaca, ❓ Interrogante, 🐕 Perro — y un botón **"Matriz BCG"** que abre un layout 2×2 animado con los productos como burbujas que interactúan al hover. Es **informativo** (no dispara cambios en catálogo). Ver Parte 3.10.

# DECISIONES RONDA 2 (2026-06-17)

7. **Rotación = la de MI zona** (no la de almacén). La rotación que usa RIZ (pico, tendencia, eje volumen de la BCG) = **lo que la zona mueve a la venta** (`me.ventas` de esa zona, normalizado por factor). Ej.: si vendí máximo 21 Ajinomoto en el día, esa fue mi rotación. La **rotación semanal de almacén** (`wh.rotacion_semanal`, ej. 100/sem) es OTRA cosa: vive en el catálogo para que el jefe/admin haga **pedidos a almacén** → RIZ NO la usa. De `wh.rotacion_semanal` solo se reutiliza la **técnica de pivote por semana ISO** como patrón de código, NO su data.
8. **De almacén, RIZ solo toma el STOCK** (`wh.stock`) → para decidir si pide a almacén o a proveedor externo. Nada más.
9. **BCG es POR ZONA y relativa a esa zona**: el admin elige una zona y todo se mide contra esa zona (corte alto/bajo = mediana de la propia zona). Un producto puede ser 🐕 Perro en una zona y ⭐ Estrella en otra — cada zona/admin ve la suya.
10. **Capacidad / tope físico: DESCARTADO.** El objetivo es satisfacer la demanda; el admin distribuye sus espacios. No se limita la esperada por capacidad.
11. **LOTIZACIÓN / FIFO en zona (perecibles) — SE AGREGA:** WH ya lotiza (`wh.lotes_vencimiento`, `wh.guia_detalle.id_lote` + `fecha_vencimiento`, sale FIFO). Cuando almacén despacha a zona por guía, la zona **hereda el lote + vencimiento**. Zona vende FIFO (primero lo que llegó primero). En el card: alerta de vencimiento del stock + al click, **historial de ingresos** del producto (cada ingreso con su lote, vencimiento y cantidad restante). (El cruce "no sobre-stockear perecibles por la esperada" se ve DESPUÉS; esto es solo herencia de lote + alerta + historial.) Requiere: tabla nueva **[E] me.zona_lotes** (ver 1.4) + que el despacho WH→zona propague `id_lote`/`fecha_vencimiento`.

---
---

# PARTE 1 — ARQUITECTO DE SISTEMAS / INFORMACIÓN (diagramas)

## 1.1 Glosario / modelo conceptual

```
 PRODUCTO BASE (skuBase) ── tiene varios ─▶ CÓDIGOS DE BARRA (propio + equivalentes)
       │                                         (todos = el mismo producto)
       └── tiene ─▶ PRESENTACIONES (tripack, caja...) ── factor_conversion ─▶ unidades base
                                                          (tripack factor=3 → 3 un base)

 ZONA (mos.zonas) ── contiene ─▶ ESTACIONES (cajas)        ZONA ⇄ ALMACÉN  (único canal)
       │                                                    (NUNCA zona ⇄ zona)
       └── tiene por producto ─▶ { stock_zona, ESPERADO, tendencia, rotación }

 ESPERADO = pico_proyectado(tendencia) × (1 + colchón%)      [el "espacio deseado"]
 BRECHA   = ESPERADO − stock_zona                            [lo que falta conseguir]
 COBERTURA= de la brecha:  almacén cubre min(brecha, stock_almacen);  resto → compra externa
```

## 1.2 Fórmula del esperado (detallada)

```
 Para cada (producto_base P, zona Z):

 1. Ventas normalizadas por día de negocio (TZ Lima), sumando TODAS las presentaciones×factor
    y TODOS los códigos de barra/equivalentes → unidades_base(P, Z, día).

 2. Pico semanal = MAX sobre los 7 días de cada semana CERRADA (lun–dom ISO).
       semana_k.pico = max_d( unidades_base(P, Z, d) )      d ∈ semana_k

 3. Serie de picos de las últimas N semanas cerradas (N configurable, default 4):
       picos = [p1, p2, p3, p4]

 4. Pico proyectado según TENDENCIA (regresión simple / pendiente):
       pendiente = tendencia(picos)
       ASCENDENTE  → proyecta el siguiente punto (p4 + pendiente) o último pico, el mayor
       DESCENDENTE → proyecta a la baja (no quedarse en el máximo histórico)
       ESTABLE     → promedio o mediana de la banda
       NULA        → 0  (rotación cero)

 5. ESPERADO = ceil( pico_proyectado × (1 + COLCHON) )      COLCHON default = 0.20
```

```
        unidades
   26 ┤                                   ● ESPERADO (21×1.2 redondeado)
   21 ┤                          ╭──● pico s4
   18 ┤                  ╭──●  pico s3                tendencia ASCENDENTE
   16 ┤          ╭──● pico s2                          → esperado sube
   15 ┤   ●  pico s1
      └───┴────┴────┴────┴───────────────▶ semanas cerradas
         s1   s2   s3   s4   (proyección)
```

## 1.3 Clasificador de tendencia (árbol de decisión)

```
                 ┌─ ventas en zona en N semanas == 0 ? ──SÍ──▶ [4] NULA ROTACIÓN
                 │                                              (promocionar/rematar/eliminar)
   serie picos ──┤
                 └─NO─▶ pendiente p de los picos
                          ├─ p ≳ +umbral           ──▶ [1] ASCENDENTE   (esperado ↑)
                          ├─ p ≲ −umbral            ──▶ [2] DESCENDENTE  (esperado ↓)
                          └─ |p| < umbral / zigzag  ──▶ [3] ESTABLE      (esperado banda)
   umbral = % configurable (ej. ±10% del pico medio) para no reaccionar a ruido.
```

## 1.4 Modelo de datos (qué existe vs qué se agrega) — conceptual, sin DDL

```
 EXISTE (reusar):
 ├─ mos.productos            (catálogo: skuBase, codigo_barra, factor_conversion, stock_min/max, ...)
 ├─ mos.equivalencias        (códigos de barra alias del mismo skuBase)
 ├─ mos.zonas / mos.estaciones (zona ↔ estaciones; politica_json para parámetros por zona)
 ├─ me.stock_zonas           (cod_barras, zona_id, cantidad)   ← AQUÍ vive el stock de zona
 ├─ me.ventas / me.ventas_detalle (fecha, estacion→zona, sku, cod_barras, cantidad)
 ├─ wh.stock                 (cod_producto, cantidad_disponible) ← stock de almacén
 ├─ wh.pickups               (id_pickup, estado, items jsonb, id_zona) ← canal pedido a almacén
 └─ wh.rotacion_semanal()    (pivote unidades por semana ISO — patrón a clonar para ventas ME)

 SE AGREGA (nuevo):
 ├─ [A] me.zona_esperado     (zona_id, sku_base, esperado, pico_proyectado, tendencia,
 │                            colchon_pct, fuente['auto'|'manual'], actualizado_ts)
 │        → el "espacio deseado" calculado. 1 fila por producto×zona. Materializado por cron.
 ├─ [B] me.zona_ticket_dia   (zona_id, fecha, lote_dia, items jsonb[A..E], estado, impreso_ts)
 │        → la cola del proceso manual diario (los ~10 productos/día). Idempotente por (zona,fecha,lote).
 ├─ [C] me.zona_compra_externa (zona_id, semana, sku_base, cantidad, estado, costo?, resuelto_ts)
 │        → la lista de compras del lunes (lo que almacén no cubrió y sí se vende).
 ├─ [D] me.zona_ajuste_log   (zona_id, sku_base, stock_antes, stock_despues, usuario, ts)
 │        → auditoría de ajustes de stock hechos desde el card (dinero/inventario → trazable).
 └─ [E] me.zona_lotes        (zona_id, sku_base, id_lote, fecha_vencimiento, cant_ingresada,
                              cant_restante, fecha_ingreso, id_guia_origen)
          → "libro de lotes" de la zona (perecibles). Cada ingreso desde almacén crea una fila
            heredando id_lote+fecha_vencimiento de wh.guia_detalle. Venta en zona consume FIFO
            (vencimiento más próximo primero) descontando cant_restante. Alimenta la alerta de
            vencimiento del card y su historial de ingresos. (me.stock_zonas sigue siendo el total;
            zona_lotes es el desglose por lote — la suma de cant_restante debe cuadrar con stock_zona.)

 NOTA factor: TODO cálculo de "unidades" se hace en UNIDADES BASE (cantidad × factor del cod_barra
 vendido), agregando todas las presentaciones/equivalentes a su skuBase. (Ver Parte 2, gap crítico.)
```

## 1.5 Flujo semanal completo (el "motor")

```
 ┌──────────────────────────────────────────────────────────────────────────────────┐
 │  DOMINGO 23:00 (pg_cron)  — RECOMPUTE SEMANAL                                       │
 │  1. Cierra la semana ISO. Para cada (producto_base, zona):                          │
 │     · normaliza ventas a unidades base (factor + equivalentes)                      │
 │     · pico semanal, serie de N picos, tendencia, pico proyectado                    │
 │     · ESPERADO = ceil(pico_proy × 1.2)  → upsert en me.zona_esperado                │
 │  2. Arma la COLA del proceso manual: lista de productos con brecha>0 o tendencia    │
 │     relevante, partida en lotes de ~10 → me.zona_ticket_dia (lun..sáb)              │
 │  3. Arma la LISTA DE COMPRA EXTERNA (lo que almacén no cubre y sí rota) →           │
 │     me.zona_compra_externa (semana nueva)                                           │
 └──────────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
 ┌──────────────────────────────────────────────────────────────────────────────────┐
 │  LUNES..SÁBADO al ABRIR TIENDA  — TICKET DIARIO (PrintNode 80mm, auto)              │
 │  Imprime el lote del día (~10 productos) con A..E.                                  │
 │  Admin: lee A · verifica B (ajusta si está mal) · evalúa C · pide con D/E o ajusta. │
 │  Cada ajuste/pedido actualiza stock_zona y/o dispara pickup a almacén EN VIVO.      │
 └──────────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
 ┌──────────────────────────────────────────────────────────────────────────────────┐
 │  LUNES (pg_cron, tras recomputar con stock ya actualizado)  — LISTA DE COMPRAS      │
 │  Imprime 80mm la lista de externos: productos que almacén NO cubrió y que SÍ rotan. │
 │  Admin compra con caja de zona durante la semana.                                   │
 └──────────────────────────────────────────────────────────────────────────────────┘
```

> Por qué el recompute es **domingo noche** y la lista de compras **lunes**: durante lun→dom el stock de zona y de almacén fluctúa (ventas, pickups, ajustes diarios). Recomputar al final con el stock real evita pedir de más/de menos.

## 1.6 Flujo del card "pedir a almacén" (reusa pickup existente)

```
 [card producto] brecha=22, almacén=18
        │  admin toca "Pedir 18 a almacén"
        ▼
   optimista: card marca "pedido 18 ✓ (pendiente almacén)"   + toast + sonido + vibración
        │
        ▼  (directo Supabase → reusa canal pickup)
   wh.pickups  ← inserta {id_zona, items:[{skuBase, cantidad:18}], estado:PENDIENTE, fuente:'RIZ'}
        │
        ▼  almacén despacha lo que puede (ya trackea su "debe" por item)
   los 4 restantes (22−18) → me.zona_compra_externa (lista del lunes)
```

## 1.7 Máquina de estados del "esperado" de un producto×zona

```
        ┌─────────────┐  venta sube N sem    ┌─────────────┐
        │  ESTABLE    │ ───────────────────▶ │ ASCENDENTE  │ esperado↑ (auto, informa)
        │ esperado=   │ ◀─────────────────── │             │
        │  banda      │  se aplana            └─────────────┘
        └─────┬───────┘
              │ venta baja N sem
              ▼
        ┌─────────────┐  rotación 0 en zona  ┌─────────────┐
        │ DESCENDENTE │ ───────────────────▶ │ NULA ROTAC. │ → promo / góndola / remate / baja
        │ esperado↓   │                       │ esperado=0  │
        └─────────────┘                       └─────────────┘
```

---
---

# PARTE 2 — INGENIERO DE SISTEMAS SENIOR (integración crítica)

## 2.1 Mapa de reutilización (qué NO reinventar)

| Necesidad del módulo | Ya existe | Acción |
|---|---|---|
| Stock de zona por producto | `me.stock_zonas(cod_barras, zona_id, cantidad)` | Reusar. El `esperado` va en tabla nueva **[A]** (no ensuciar stock_zonas). |
| Stock de almacén | `wh.stock(cod_producto, cantidad_disponible)` | Reusar (lectura). |
| Ventas por producto/zona/día | `me.ventas` + `me.ventas_detalle` (TZ Lima) | Reusar; agregar **normalización por factor** (gap 2.2). |
| Tendencia por semana ISO | `wh.rotacion_semanal()` (pivote semanal) | **Clonar el patrón** para ventas ME por zona → nueva RPC `me.tendencia_zona()`. |
| Pedir a almacén | `forwardWHPickup` → `wh.pickups` | Reusar como canal del botón "pedir". |
| Stock objetivo | `mos.productos.stock_minimo/maximo` (manual, global) | **No alcanza**: es global y manual. El `esperado` es **por zona y dinámico**. Tabla nueva [A]. |
| Impresión 80mm | `imprimirCostosGuia` (ESC/POS builder) + `listarImpresorasPN` | Reusar builder; nuevos formatos (ticket diario, lista lunes). |
| IA sugerencias | Edge `supabase/functions/ia` (Claude, JWT-gated) | Reusar; nuevo prompt con parámetros del módulo. |
| Analítica producto | `mos.analitica_producto()` (ya tiene serie + proyección) | Reusar para el detalle/expand del card. |
| UI (modales, cards, efectos) | `openModal/closeModal`, patrón Catálogo, `toast`, `_catSfx`, vibrate, pulse/shake | Reusar 1:1. |

## 2.2 🔴 GAP CRÍTICO #1 — normalización por factor (presentaciones)

Las RPCs actuales (`rotacion_productos`, `catalogo_stock_resumen`, etc.) **suman `cantidad` cruda** de `ventas_detalle` sin aplicar `factor_conversion`. Si ME registra "1 tripack" con `cantidad=1`, contar crudo subcuenta; si registra `cantidad=3`, sobrecuenta. **Para RIZ esto es decisivo** (toda la lógica de pico/esperado se basa en unidades base correctas).

```
 Decisión de diseño: TODO se calcula en UNIDADES BASE.
   unidades_base = cantidad_vendida × factor_del_codigo_vendido
   y se agrega al skuBase (resolviendo cod_barra propio + equivalentes → skuBase).
 Prerrequisito: confirmar EXPERIMENTALMENTE cómo ME registra cantidad de una presentación
 (1 tripack vs 3 un). De eso depende si factor multiplica o no. ← VALIDAR ANTES DE CODEAR.
```

## 2.3 🔴 GAP CRÍTICO #2 — "stock de zona confiable"

El módulo asume que `me.stock_zonas` refleja la realidad física. Hoy puede estar mal (de ahí el paso manual de "verificar B y ajustar"). El módulo **es a la vez la herramienta que corrige eso** (ajuste desde el card → log [D]). Pero ojo: la sombra `me.stock_zonas` se alimenta del sync ME→Supabase; si se ajusta directo en Supabase hay que **dual-write** (espejar a la Hoja ME) para no desincronizar — mismo patrón seguro que ya definimos para escrituras (ver `PENDIENTES_cutover_GAS.md`). **El ajuste de stock NO debe ir por escritura-directa-pura.**

## 2.4 Componentes nuevos (100% Supabase)

```
 ┌─ pg_cron (Supabase) ────────────────────────────────────────────┐
 │  job  riz-recompute-semanal   (DOM 23:00 Lima)                   │
 │  job  riz-cola-diaria         (alimenta tickets lun..sáb)        │
 │  job  riz-lista-compras       (LUN, tras recompute)              │
 └──────────────────────────────────────────────────────────────────┘
 ┌─ RPCs nuevas (mos./me.) ────────────────────────────────────────┐
 │  me.tendencia_zona(zona, skuBase?, semanas)  → serie picos+clase │
 │  me.zona_panel(zona, filtros)                → cards del módulo   │
 │  me.zona_esperado_recompute(zona|all)        → materializa [A]   │
 │  me.zona_ajustar_stock(zona, skuBase, nuevo) → ajusta + log [D]  │
 │  me.zona_pedir_almacen(zona, items)          → inserta pickup    │
 │  me.zona_ticket_dia(zona, fecha)             → lote del día (A..E)│
 │  me.zona_lista_compras(zona, semana)         → externos del lunes│
 └──────────────────────────────────────────────────────────────────┘
 ┌─ Edge IA (reusa /functions/ia) ─────────────────────────────────┐
 │  prompt con {producto, stock, esperado, brecha, tendencia,       │
 │  stock_almacen, rotación} → sugerencia en lenguaje natural       │
 └──────────────────────────────────────────────────────────────────┘
 ┌─ PrintNode (reusa builder ESC/POS) ─────────────────────────────┐
 │  ticket_diario_80mm(lote)     · lista_compras_80mm(semana)       │
 └──────────────────────────────────────────────────────────────────┘
 ┌─ Frontend MOS (vista nueva 'zona') ─────────────────────────────┐
 │  loadZona() → me.zona_panel → render cards + filtros + modales   │
 └──────────────────────────────────────────────────────────────────┘
```

## 2.5 Seguridad / RLS / multironda

- Todas las RPCs nuevas: `security definer`, `search_path=''`, gate `mos._claim_ok()` (app='MOS'), grants `service_role, authenticated`, `revoke public` — **idéntico patrón** a las 56 RPCs ya en prod.
- IA: el Edge `/functions/ia` ya verifica JWT (claim app). Agregar 'MOS' a su whitelist si no está (hoy admite warehouseMos/mosExpress).
- Escrituras (ajuste de stock, pedir): **dual-write-frontend** (GAS verdad + espejo Supabase), NUNCA directo-puro con sync apagado (lección 2026-06-15).
- El ajuste de stock toca inventario → **log [D] obligatorio** + (opcional) PIN admin para ajustes grandes.

## 2.6 Riesgos / decisiones abiertas (honestidad senior)

```
 R1  factor de presentación: confirmar cómo ME registra cantidad (gap 2.2). BLOQUEANTE del cálculo.
 R2  N semanas y umbral de tendencia: parametrizar en mos.zonas.politica_json por zona (no hardcode).
 R3  colchón 20%: parametrizable por zona y/o por producto (un perecible quizá quiere menos).
 R4  "pico del día" vs evento atípico: un pico único gigante (mayorista que no vuelve) inflaría
     el esperado. Mitigación: recortar outliers (winsorizar) o marcar ventas mayoristas aparte.
 R5  productos nuevos sin historia: no hay picos → arranque manual o con stock_min del catálogo.
 R6  frescura sombra: me.stock_zonas y wh.stock dependen del sync; si está stale, el panel debe
     marcar _fresh=false (mismo gate que el resto) y avisar "datos con retraso".
 R7  capacidad física del andamio: esperado alto puede no caber. Campo opcional 'tope_fisico' por
     producto×zona para no sugerir más de lo que entra.
 R8  perecibles/vencimiento: esperado alto + baja rotación = merma. Cruzar con vencimientos (ya hay
     alertas_operativas) para no sobre-stockear lo que se vence.
```

---
---

# PARTE 3 — DISEÑADOR SENIOR (UI/UX, mockups, efectos)

> Paleta MOS: fondo slate-950 `#020817`, acentos indigo `#6366f1` / violet `#8b5cf6`, nav oro `#ffd700`.
> Estados: verde `#86efac` ok · ámbar `#f59e0b` atención · rojo `#fca5a5` crítico.
> Efectos base reusados: `toast()`, `_catSfx()` (WebAudio iOS-safe), `navigator.vibrate`, `pulse`/`shake`, cierre optimista.

## 3.1 Entrada al módulo (nav)

```
 Sidebar / bottom-nav:  [ 🏪 Zona ]   (item nuevo, ícono andamio/estantería)
   - Al tocar: nav('zona') → loadZona() → spinner "Analizando tu zona…" (skeleton cards)
   - Efecto: transición slide-up suave (mismo patrón de las otras vistas)
```

## 3.2 Encabezado del módulo (resumen + filtros)

```
 ┌────────────────────────────────────────────────────────────────────────┐
 │  🏪 Zona 2 · Reposición            [ ⟳ ]      _fresh ● (verde/ámbar)     │
 │  ┌──────────┬──────────┬──────────┬──────────┐                          │
 │  │ Faltan   │ Pedir a  │ Comprar  │ Rotación │   (KPIs tappables = filtro)│
 │  │  pedir   │ almacén  │ externo  │  CERO    │                          │
 │  │   32 ▲   │   210un  │  18 prod │  7 prod  │                          │
 │  └──────────┴──────────┴──────────┴──────────┘                          │
 │  Filtros:  [Tendencia ▾ ↑↓~∅]  [Brecha>0]  [Sin rotación]  [🔎 buscar]   │
 │  Orden:    [Brecha ▾] [Tendencia] [Rotación] [A-Z]                       │
 └────────────────────────────────────────────────────────────────────────┘
```
- KPIs son **chips-filtro**: tocar "Rotación CERO" filtra esos 7. Animación count-up al cargar.
- Chip `_fresh`: verde = sombra fresca; ámbar pulsante = "datos con retraso" (sync stale).

## 3.3 Card de producto (el corazón del módulo)

```
 ┌────────────────────────────────────────────────────────────────────────┐
 │  Ajinomoto 1kg                                        [ ↑ ASCENDENTE ]   │ ← badge tendencia (color)
 │  ────────────────────────────────────────────────────────────────────  │
 │   STOCK ZONA      ESPERADO        BRECHA            ALMACÉN              │
 │      5  [✎]          26            ▲ 21             14                   │ ← ✎ = ajustar inline
 │   ───────────────────────────────────────────────────────────────────  │
 │   Tendencia (picos):   15 ▁  16 ▂  18 ▄  21 █     ← sparkline 4 semanas  │
 │   ───────────────────────────────────────────────────────────────────  │
 │   💡 IA: "Te faltan 21 para estar listo para el miércoles. Almacén       │
 │       cubre 14 → pídelos. Los 7 restantes van a tu lista del lunes."     │
 │   ───────────────────────────────────────────────────────────────────  │
 │   [ Pedir 14 a almacén ]   [ + Lista compras (7) ]   [ Ver detalle ]     │
 └────────────────────────────────────────────────────────────────────────┘
```

**Variantes por tendencia (borde + badge):**
```
 ↑ ASCENDENTE  → borde indigo, badge "▲ subiendo", IA enfatiza "consigue más"
 ↓ DESCENDENTE → borde ámbar,  badge "▼ bajando",  IA "no sobre-stockees, baja a X"
 ~ ESTABLE     → borde slate,  badge "≈ estable",   card tranquila
 ∅ NULA ROTAC. → borde rojo tenue, badge "∅ sin rotar", acciones distintas:
                 [ Promocionar ]  [ Mover a góndola ]  [ Rematar ]  [ Dar de baja ]
```

## 3.3-bis Lote / vencimiento en el card (perecibles, FIFO)

El card muestra el vencimiento más próximo de su stock + badge por días restantes. Al click → historial de ingresos (FIFO).
```
 │ ... (card normal) ...                                                  │
 │ 🗓️ Vence: lote más próximo 05/07 (en 18 días)        [● ámbar] [ver]  │ ← badge color por días
 └────────────────────────────────────────────────────────────────────────┘
        tap [ver] → timeline de ingresos (FIFO, el de arriba se vende primero):

        ┌── Historial de ingresos · Ajinomoto 1kg · Zona 2 ──────────┐
        │  ▼ Lote A   ingresó 20/06  ·  vence 05/07  ·  restan 5un    │ ← se vende primero
        │  ▼ Lote B   ingresó 28/06  ·  vence 20/07  ·  restan 5un    │
        │  ─────────────────────────────────────────────────────────  │
        │  Total en zona: 10un   (cuadra con stock_zona)              │
        │  Origen: guía G-1234 (almacén)                              │
        └─────────────────────────────────────────────────────────────┘
```
- Badge vencimiento: verde (>30d) · ámbar (8–30d) · rojo pulsante (≤7d). Hereda el criterio de `alertas_operativas`.
- La sugerencia IA del card suma la alerta: *"te faltan 16 — pídelos; ⚠️ además tienes 5un que vencen el 05/07, véndelos primero."*
- Efectos: timeline entra con stagger (cada lote desliza), el lote FIFO-activo resaltado, badge rojo con pulse si crítico.
- Fuente: tabla **[E] me.zona_lotes** (hereda `id_lote`+`fecha_vencimiento` de `wh.guia_detalle` al despachar). FIFO descuenta `cant_restante`.

## 3.4 Micro-interacción: ajustar stock inline (✎)

```
   tap ✎  →  el número "5" se vuelve input con stepper:   [ − ]  4  [ + ]   [✓]
   ✓ →  OPTIMISTA: card actualiza brecha al instante (5→4 ⇒ brecha 21→22),
        recalcula la IA local, toast "Stock ajustado a 4", sonido suave, vibración corta.
        En background: me.zona_ajustar_stock (dual-write) + log [D].
        Si falla: shake + revertir + toast rojo.
```

## 3.5 Acción "Pedir a almacén" (optimista)

```
   tap [Pedir 14 a almacén]
     → botón colapsa a "Pidiendo…" (spinner inline) ~250ms
     → OPTIMISTA: aparece chip "✓ Pedido 14 (pendiente almacén)" + pulse verde en el card
     → sonido "ok" + vibración [80,60,80]
     → background: me.zona_pedir_almacen → wh.pickups
     → si falla: chip se cae, shake, toast "No se pudo pedir, reintenta"
   El resto (brecha−almacén) muestra botón [+ Lista compras (7)] → agrega a [C] con toast.
```

## 3.6 Ticket diario 80mm (PrintNode, auto al abrir tienda)

```
        ════════════════════════════
              MOS · ZONA 2
           REPOSICIÓN DEL DÍA
          Lun 17/06  ·  Lote 1/7
        ════════════════════════════
        1) AJINOMOTO 1KG
           Zona: 5    Esperado: 26
           Tend: 15 16 18 21  (SUBE)
           Faltan: 21   Almacen: 14
           [ ] verificado  [ ] pedido
        ----------------------------
        2) ACEITE PRIMOR 1L
           Zona: 12   Esperado: 10
           Tend: 14 11 9 8   (BAJA)
           Faltan: 0    Almacen: 30
           [ ] verificado
        ----------------------------
        ... (hasta ~10)
        ════════════════════════════
         Verifica stock real, ajusta
         en la app y pide lo que falte
        ════════════════════════════
```
- Casillas `[ ]` para marcar a mano (el admin trabaja en papel + app).
- Reusa `_buildEscPos…` (ancho 32, `_norm` sin tildes, separadores).

## 3.7 Lista de compras del lunes 80mm (PrintNode, auto)

```
        ════════════════════════════
            MOS · ZONA 2
        LISTA DE COMPRA EXTERNA
        Semana 25  ·  Lun 17/06
        (almacen NO cubrio + SI rota)
        ════════════════════════════
        AJINOMOTO 1KG ........  7 un
        SILLAO KIKKO 1L ......  4 un
        FILETE ATUN ..........  12 un
        ----------------------------
        TOTAL ITEMS: 3   UNID: 23
        Comprar con caja de zona.
        Marca lo conseguido en la app.
        ════════════════════════════
```

## 3.8 Panel de sugerencias IA (modal o sección)

```
 ┌──────────────────────────────────────────────────────────────┐
 │  💡 Sugerencias para Zona 2                          [ ✕ ]    │
 │  ──────────────────────────────────────────────────────────  │
 │  🔴 URGENTE (3)                                               │
 │   • Ajinomoto 1kg: pide 14 a almacén HOY (cliente pico mié).  │
 │   • Atún Filete: brecha 12, almacén 0 → compra externa.       │
 │  🟡 AJUSTAR (5)                                               │
 │   • Aceite Primor: venta bajando, reduce esperado 14→8.       │
 │  ⚫ ROTACIÓN CERO (7)  → remate / góndola / baja              │
 │   • Salsa X (0 ventas 4 sem, 18un parados): promociona/baja.  │
 │  ──────────────────────────────────────────────────────────  │
 │  [ Aplicar pedidos sugeridos ]   [ Imprimir resumen 80mm ]    │
 └──────────────────────────────────────────────────────────────┘
```
- La IA recibe los parámetros estructurados (no texto libre) → respuesta accionable.
- "Aplicar pedidos sugeridos" = batch de pickups (con confirmación + PIN si supera umbral).
- Streaming opcional (efecto "escribiendo") si el Edge lo soporta; si no, skeleton.

## 3.9 Inventario de efectos (sonoro + visual + háptico)

| Acción | Visual | Sonoro | Háptico |
|---|---|---|---|
| Cargar módulo | skeleton → count-up KPIs, fade-in cards | — | — |
| Ajustar stock ✓ | número anima, brecha recalcula, pulse verde | tono suave "tick" | vibrate 30ms |
| Pedir a almacén ✓ | botón→chip, pulse verde card | "ok" 2 notas | vibrate [80,60,80] |
| Agregar a lista | chip "+lista", toast | "tick" | vibrate 20ms |
| Error (cualquiera) | shake + borde rojo + revertir | "error" grave | vibrate [120,40,120] |
| Tendencia ascendente | borde indigo glow sutil | — | — |
| Rotación cero | borde rojo tenue pulse lento | — | — |
| Ticket impreso | toast "🖨️ Ticket del día listo" | "print" | — |
| IA sugiriendo | typing/skeleton | — | — |

## 3.10 MATRIZ BCG — clasificación visual del comportamiento (idea del dueño)

Cada producto se ubica en la matriz BCG según **2 ejes**:
```
   eje Y = CRECIMIENTO (tendencia de los picos: sube / baja)
   eje X = PARTICIPACIÓN / VOLUMEN (cuánto rota en la zona: unidades base vendidas)

                    ALTA participación        BAJA participación
                 ┌────────────────────────┬────────────────────────┐
   ALTO          │  ⭐ ESTRELLA            │  ❓ INTERROGANTE        │
   crecimiento   │  sube + vende mucho     │  sube + vende poco      │
                 │  "producto rey, tenlo   │  "vigílalo: ¿lo impulso?│
                 │   siempre disponible"   │   ¿promoción?"          │
                 │  borde dorado + glow ✨ │  borde violeta pulse     │
                 ├────────────────────────┼────────────────────────┤
   BAJO          │  🐄 VACA LECHERA        │  🐕 PERRO               │
   crecimiento   │  estable + vende mucho  │  baja/nula + vende poco │
                 │  "genera caja, mantén   │  "rematar / góndola /   │
                 │   sin sobre-invertir"   │   dar de baja"          │
                 │  borde verde sólido     │  borde rojo tenue, gris  │
                 └────────────────────────┴────────────────────────┘
```

**En cada card:** ícono BCG (⭐🐄❓🐕) arriba a la derecha + estilo de borde por cuadrante (reemplaza/enriquece el badge de tendencia). Efectos elegantes:
- ⭐ Estrella: borde dorado con shimmer sutil (como el logo MOS), micro-brillo al cargar.
- 🐄 Vaca: borde verde estable, sin animación (es el tranquilo, "ordeñar").
- ❓ Interrogante: borde violeta con pulse lento (decisión pendiente).
- 🐕 Perro: borde rojo tenue + leve desaturado (gris) → visualmente "apagado", invita a sacarlo.

**Botón "Matriz BCG"** (en el encabezado del módulo) → abre un **layout 2×2 animado a pantalla**:
```
 ┌──────────────────────────── Matriz BCG · Zona 2 ───────────────────────────┐
 │  crecimiento ▲                                                              │
 │      │   ⭐ESTRELLAS              │   ❓INTERROGANTES                        │
 │      │     ◯Ajinomoto(grande)    │     ◦Salsa nueva                         │
 │      │       ◯Atún               │        ◦Té premium                       │
 │      ├───────────────────────────┼─────────────────────────────────────────│
 │      │   🐄VACAS                  │   🐕PERROS                              │
 │      │     ◯Arroz(grande)        │     ◦Producto X (0 rot)                  │
 │      │       ◯Aceite             │        ◦Salsa vieja                      │
 │      └───────────────────────────┴──────────────────────────────▶ volumen  │
 │   • burbujas: tamaño = volumen/valor · color = cuadrante                     │
 │   • hover/tap burbuja → tooltip (stock, esperada, brecha, tendencia) + late  │
 │   • entrada animada: las burbujas "caen" a su cuadrante (stagger) con bounce  │
 │   • tap un cuadrante → filtra el módulo a esos productos                      │
 └────────────────────────────────────────────────────────────────────────────┘
```
- Transiciones: fade+scale al abrir, burbujas con `stagger` (aparecen una tras otra), hover = lift + glow del color del cuadrante, sonido suave al tap.
- Es **informativo**: tocar una burbuja lleva al card; tocar un cuadrante filtra. No cambia el catálogo.

> Mapeo a los 4 casos originales: ASCENDENTE→⭐ o ❓ (según volumen) · ESTABLE→🐄 · DESCENDENTE/NULA→🐕. La BCG es la versión "2 ejes" (crecimiento × volumen) que enriquece la tendencia simple.

---
---

# PARTE 4 — SUGERENCIAS (multironda senior · arquitecto, ingeniero, diseñador)

## 4.1 Arquitecto de información
1. **`esperado` en tabla aparte [A]**, no como columna de `me.stock_zonas` (separa "lo físico" de "lo deseado calculado"; permite versionar/auditar el cálculo).
2. **Todo en unidades base**: define una *vista canónica de ventas normalizadas* (factor + equivalentes → skuBase×zona×día) y que TODAS las RPCs (RIZ y las que ya existen) la usen → una sola fuente de verdad, fin de la inconsistencia de factor.
3. **Parámetros por zona** en `mos.zonas.politica_json`: `{ semanas_tendencia, colchon_pct, umbral_tendencia, dia_lista_compras, lote_diario }`. Nada hardcodeado.
4. **Idempotencia** en tickets/cola/listas por clave determinista (zona+fecha+lote / zona+semana) → reimprimir no duplica.
5. **Modela el "evento atípico"**: marca ventas mayoristas o winsoriza el pico para que un pedido único no infle el esperado por semanas (R4).

## 4.2 Ingeniero de sistemas senior
6. **Reusar `wh.rotacion_semanal` como plantilla** de `me.tendencia_zona` (mismo pivote ISO, distinta fuente). No reinventar el cálculo de semanas.
7. **Reusar el canal pickup** (`wh.pickups`) para "pedir a almacén" — no crear un canal nuevo (almacén ya sabe procesarlo y trackea su "debe").
8. **Escrituras por dual-write-frontend** (ajuste de stock, pedir, marcar comprado): GAS verdad + espejo Supabase. NUNCA directo-puro+sync-off (incidente 2026-06-15).
9. **Gate `_fresh`** en el panel: si la sombra (stock zona/almacén) está stale, mostrar banner "datos con retraso" y no dejar pedir a ciegas.
10. **pg_cron, no GAS**, para recompute/cola/lista → no consume cuota urlfetch (justo el problema que acabamos de sufrir) y es 100% Supabase.
11. **IA como capa de presentación, no de verdad**: la IA *redacta* la sugerencia, pero los números (brecha, esperado, pedir-X) salen de las RPCs determinísticas. Así la IA no inventa cantidades de dinero/inventario.
12. **Cruzar con vencimientos** (`alertas_operativas` ya existe): no sugerir sobre-stock de perecibles próximos a vencer (R8).
13. **Tope físico opcional** por producto×zona (R7) para no pedir más de lo que cabe en el andamio.

## 4.3 Diseñador senior
14. **Papel + app espejados**: el ticket 80mm tiene las MISMAS 5 columnas A–E que el card → el admin no se pierde entre lo impreso y lo digital.
15. **Una acción primaria por card** (el botón "Pedir" destacado); lo secundario (lista, detalle) en menor jerarquía. Evita parálisis.
16. **Color = significado** (verde listo / ámbar ajustar / rojo urgente o sin-rotar) consistente en KPIs, badges, bordes y ticket (negrita/símbolo en papel).
17. **Optimismo en todo**: toda acción cierra/confirma al instante con rollback si falla (patrón ya estándar en MOS) → se siente instantáneo aun con red lenta.
18. **Progreso del proceso semanal visible**: "Día 3/7 · 28 de 70 productos revisados" → el admin siente avance y no abandona el hábito.
19. **Modo una-mano / tablet**: cards grandes, stepper de ajuste con `+/−` gordos (se usa parado frente al andamio, en celular).
20. **Accesible iOS/Safari**: WebAudio con resume en gesto, sin `dvh`, fechas numéricas — ya es regla del ecosistema.

## 4.4 Cosas que faltan decidir (te las dejo como preguntas para después)
- ¿`factor` multiplica o no? → **validar cómo ME registra una presentación** (bloqueante del cálculo).
- ¿`N` semanas para tendencia: 3 o 4? ¿`umbral` para clasificar sube/baja? ¿`colchón` 20% fijo o por producto?
- ¿El esperado se aplica **automático** o el admin **aprueba** el cambio sugerido? (tu texto dice "casi automático informando" → propongo: auto para ascendente/estable, y para descendente/nula que confirme, por seguridad de no quedarse corto).
- ¿La compra externa registra **costo** (para P&L de zona) o solo la cantidad?
- ¿"Rematar/baja" dispara algo en catálogo (marca producto) o es solo informativo?

---

## Resumen de 1 línea
RIZ = una vista 'Zona' en MOS que calcula por pg_cron el **stock deseado** (pico×tendencia×1.2) por producto×zona, lo compara con el stock real, y **informa** al admin (card + IA + ticket 80mm diario + lista de compras del lunes) qué pedir a almacén (reusa pickup), qué comprar externo y qué rematar — 100% Supabase, reusando ~80% de lo ya construido. Falta validar el **factor de presentación** antes de codear.
