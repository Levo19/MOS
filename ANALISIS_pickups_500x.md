# Revisión 500x · Pickups, acumulado, listas sombra y seguimiento en MOS

**Última actualización**: 2026-08-12 — **C1–C9 CERRADOS**. Queda solo la paridad de horas en el rezagado (opcional, ver §3).
Documento de trabajo: reglas del dueño + qué está corregido + qué falta. **Leer entero antes de tocar nada de este sector.**

---

## 1. LAS REGLAS DEL DUEÑO (fuente de verdad — Luis, 11-ago)

### R1 · Al operador de WH, SALDO. A MOS, la historia completa.
> "solo debería aparecerle al operador **lo que falta**, no lo que fue despachado"
> "yo quiero que el json del acumulado tenga **todo**, lo pedido y lo despachado, sea entendible el producto o no. Así en MOS puedo ver cuándo me pidieron y cuánto, e igual cuándo y cuánto se despachó"

### R2 · Nunca viaja un negativo. Deuda es deuda.
> "supongamos que de los 10 pedidos escanea 15, entonces **no debe nada**. No quiero que viaje un negativo. ¿Por qué? Facil: **no quiero que ese −5 mate una deuda de días atrás**"

Piso 0 **por producto**. Un exceso no acredita, no compensa otro producto y no toca días anteriores.
El operador **siempre** puede enviar más de lo que le piden si quiere — eso se registra, pero no genera saldo a favor.

### R3 · Cuándo entra una lista sombra al acumulado
| caso | cuándo |
|---|---|
| escaneó **y emitió** la salida | **en ese momento** el acumulado se actualiza |
| escaneó pero la dejó jalada +1h **sin emitir** | se devuelve y queda **como no escaneado** (nunca hubo salida) |
| **no escaneó nada** | al **cierre del día (~11pm)** se va al acumulado |
| el operador se equivocó de lista | la **elimina** antes: así nunca entra al ciclo |

### R4 · El acumulado se despacha N VECES
> "la lista acumulada tiene nakamito y zuko; despacho nakamito, emito guía, no despacho nada de zuko → el acumulado **al toque** se actualiza y me aparece **solo zuko**"

Al soltar y volver a jalar, solo debe aparecer zuko. Se despacha de a pocos, sin límite de veces.

### R5 · "No se entiende" viaja también al acumulado
Lo que la IA no pudo cruzar con el catálogo se conserva **con el nombre tal como lo pidieron**.
> "pusieron **siyau**, obviamente no lo encuentra porque el producto se llama **siyao**; normal que quede en la sección *no se entiende*. Así en MOS el registro dice que solicitaron *siyau*, y si el operador despacha *siyao* que sí existe, igual dirá qué día y hora despachó"

Nunca suma deuda ni KPIs: es **constancia** del pedido.

### R6 · Trazabilidad con HORA REAL
> "cuando escaneo un producto se guarda la hora y día, pero cuando pasa a emitirse la guía **parece que se chanca con la hora de la cabecera**. En MOS zonas debo poder ver la hora en que fueron despachados esos 15"

Cada línea con **su** hora de escaneo. Y la hora en que se **pidió** (para una sombra: cuándo la leyó la IA).
En MOS → Zonas → pickups: *"me solicitaron tal día y hora 10, se despachó tal día y hora 15"*.

**También en WH**, en el detalle de las guías de salida ya registradas: la **cabecera** lleva la hora de
emisión, y **cada producto** su propia hora de escaneo. No solo en MOS.

### R7 · Un solo acumulado por zona · candado que se suelta a la hora
> "no puede haber dos acumulados, solo uno por zona" · "si el usuario tiene una lista atorada simplemente se desatora a la 1 hora de la última actividad"

### R8 · TODO EN TIEMPO REAL
> "si un operador tomó una lista pickup **todos** los operadores de WH deben enterarse en tiempo real. Lo mismo si algo cambió en el acumulado. Los datos que viajan a MOS/zona/pickup también"

### R9 · El refresco NO interrumpe al operador
> "si de golpe el servidor envía nueva data, simplemente avisa al que está con el pickup abierto **'esta lista fue actualizada'** con un efecto bien llamativo, pero el operador puede seguir atendiendo. Si debía 20 nakamitos y escaneó 20, y en el nuevo pickup le piden 5, su barra aparece que **faltan 5**: visualmente se ajusta la deuda"

Reusar el aviso llamativo que ya existe cuando entra un pickup. **Jamás perder el avance del operador.**

### R10 · Ante un choque de copias, manda el SERVIDOR (avisando) · una lista, un operador a la vez.

---

## 2. LO QUE ESTABA ROTO (diagnóstico cerrado, con evidencia)

| # | Falla | Evidencia | Estado |
|---|---|---|---|
| C1 | **El candado nunca vencía**: el consolidador estampaba `ultima_actividad = now()` en cada corrida, reiniciando el reloj de la hora sin que nadie tocara nada | todo decía "hace 2m"; a Sergio no se le soltaba | ✅ 741 |
| C2 | **El consolidador se rendía ante el candado** (`return skip EN_PROCESO`): con la lista tomada no absorbía cierres de caja ni mataba la semana vieja | ZONA-02 con 2 acumulados (200 + 113) | ✅ 741 |
| C3 | **El autosave pisaba la lista entera** (`items = <copia del celular>`) | Jorgenis y Jesús veían 0; Luis veía productos | ✅ 741 |
| C4 | **El saldo no se restaba al despachar**: se guardaba la lista con los despachados puestos; el colapso esperaba al consolidador | al retomar reaparecía todo marcado | ✅ 743 |
| C5 | **El 2º despacho del día se descartaba**: el anti-duplicado tomaba *cualquier* guía de 90 min como reintento | Sergio despachaba un tramo y el siguiente no se aplicaba | ✅ 744 |
| C6 | El historial nuevo usaba la hora de la guía, no la del escaneo | — | ✅ 745 |
| **C7** | **Una sombra sin escanear se ANULA y su pedido se pierde**: no entra al acumulado | medido con la lista de Sergio: 3 identificados (21 uds) + 19 constancias → acumulado sin cambios (379 → 379) | ✅ 746/747 (vuelca al acumulado al cierre del día 23:00 Lima; aplicado en prod: +21 uds + 19 constancias) |
| **C8** | **Dos fuentes de verdad**: el celular guarda la lista completa y la rehidrata sin contrastar `rev` | cada operador veía algo distinto | ✅ 749/750 + WH 2.13.548 (el payload solo aporta lo despachado; id de guía con firma de contenido; verificado en prod 751) |
| **C9** | La hora por línea no se muestra: ni en MOS ni en el detalle de guías de salida de **WH** (el dato **sí existe**: 36 líneas con 36 horas distintas) | verificado 11-ago | ✅ 12-ago — MOS 2.43.741 (Zonas→pickup: "🕐 pedido → salió" por ítem, tsSolicitud/tsDespacho de la RPC 607; tsDespacho ISO-Z se convierte a Lima) + WH 2.13.549 (cabecera de guía con hora de emisión si el dato la trae; hora también en la tarjeta expandida). Las líneas colapsadas de WH ya la mostraban desde 2.13.524. |

---

## 3. QUÉ FALTA, EN ORDEN

1. **(Opcional) Paridad de horas en el REZAGADO**: `wh.zona_rezagado_detalle` (SQL 295/575) no emite
   `tsSolicitud`/`tsDespacho` ni hora por evento → la vista rezagado de MOS muestra solo el día.
   Si el dueño quiere horas también ahí, hay que tocar la RPC (mismo patrón que 607).
2. **Verificación visual en prod** (pendiente de la próxima jornada): abrir MOS → Zonas → pickup y
   comprobar el renglón "🕐 pedido → salió" con datos reales; abrir en WH el detalle de una guía nueva
   y ver la hora en cabecera y tarjeta expandida.

Pruebas ya corridas: navegadores simultáneos (`_748_pickup_multiusuario.mjs` 15/15), ciclo completo
17/17, candado 15/15, saldo 11/11, prod WH 2.13.548 verificado (`_751_wh_prod.mjs` 6/6, 0 pageerrors).

---

## 4. YA APLICADO Y PROBADO (11-ago)

`741` candado real + cron cada 15 min + consolidador que no se rinde + autosave que fusiona ·
`742` `rev` por lista + historial de movimientos por producto ·
`743` colapso a saldo al despachar (R1, R2, R4) ·
`744` reintento por **contenido**, no por tiempo ·
`745` hora real del escaneo en el historial (R6).

Pruebas: `_test_741_pickup.mjs` **15/15** · `_test_743_saldo.mjs` **11/11** (escenario exacto de Sergio) ·
`_test_ciclo_sombra_acumulado.mjs` **17/17**. Todo en transacción + rollback.

Estado de los datos tras los arreglos: **un solo acumulado por zona**, ningún candado puesto,
ZONA-01 con 379 productos y ZONA-02 con 139, todos con deuda real y sin despachados pegados.
