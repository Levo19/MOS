# Revisión 500x · Pickups, acumulado y listas sombra

**Fecha**: 2026-08-11 · **Estado**: diagnóstico cerrado · parte corregida (SQL 741), parte pendiente (front WH).

---

## 1. Las escenas del 10–11 de agosto, organizadas

| # | Lo que se vio | Causa |
|---|---|---|
| E1 | A **Jorgenis** el acumulado de zona1 le salía en **0 productos**; a **Jesús** también 0; a **Luis** sí le aparecían | C3 + C4 |
| E2 | A **Sergio** se le quedó **atorada** la lista de ayer; entró en otro dispositivo y ahí sí la vio | C1 + C2 |
| E3 | "A ratos se ponía en cero y otras veces sí había productos" | C3 (cada refresco traía la copia de otro dispositivo) |
| E4 | **ZONA-02 con dos acumulados vivos** (02-ago 200 items + 09-ago 113) | C2 |
| E5 | Sergio despachó parcial, **emitió la guía**, y al retomar **reaparecían los ya despachados** como si estuvieran separados otra vez | **C4** |
| E6 | Miedo real a **duplicar productos en la guía de salida** → se paró todo y se trabajó con listas sombra | consecuencia de E5 |

---

## 2. Las causas (cadena, no cinco bugs sueltos)

### C1 · El candado nunca vencía  — CORREGIDO (741)
El TTL es `ultima_actividad < now() - 1 hora`, pero **el propio consolidador estampaba
`ultima_actividad = now()`** en el acumulado, en los rezagados y hasta al liberar — cada vez que
corría, por cualquier zona. El reloj se reiniciaba solo, sin que nadie tocara nada. Por eso la
pantalla mostraba "hace 2m" en listas que nadie había abierto, y por eso a Sergio no se le soltaba.

### C2 · El consolidador se rendía ante el candado — CORREGIDO (741)
`consolidar_pickup_zona` hacía `return skip EN_PROCESO`. Con la lista tomada:
no se absorbían los cierres de caja nuevos **y** no moría el acumulado de la semana anterior.
De ahí los dos acumulados de ZONA-02 y la sensación de "vendió zona1 y no llegó la lista".

### C3 · El autosave pisaba la lista entera — CORREGIDO (741)
`guardar_progreso_pickup` hacía `items = <lo que manda el dispositivo>`. Si a un operador le
llegaron productos mientras tenía la lista abierta, **su copia vieja los borraba para todos**.
Eso es exactamente E1 y E3: cada dispositivo imponía su versión, y el último en guardar ganaba.

### C4 · DOS FUENTES DE VERDAD — **PENDIENTE, es la raíz que queda**
El front guarda el pickup completo en `localStorage['wh_despacho_pickup_activo']` y lo **rehidrata
al arrancar sin contrastarlo con el servidor** (`js/app.js:12327`, `12455`).

Existe una reconciliación (`_reconciliarPickupActivo`, `js/app.js:14635`) pero es **heurística por
fechas**: suelta la copia local solo si el pickup desapareció de la lista o si `fechaAtendido` es
posterior a cuando lo tomé. **El acumulado semanal nunca desaparece** — por diseño de cuenta
corriente [603] queda PENDIENTE y visible. Basta que el refresco no llegue, que la respuesta tarde,
o que se retome sin pasar por ese refresco, para que la copia local sobreviva **con los despachados
ya convertidos en guía**. Eso es E5, y el riesgo de duplicar de E6.

Y con C3 corregido el daño cambia de forma pero no desaparece: el autosave ya no borra productos,
pero **sí puede reimponer un `despachado` zombi** sobre la deuda real.

---

## 3. La regla de negocio que hay que respetar (Luis, textual)

> "se supone que para que se despache parcial o todo, esto se resta y solo debería aparecerle al
> operador **lo que falta**, no lo que fue despachado"

> "si en la lista sombra me piden 20 nakamito pero yo despacho 10, entonces debo 10. Esos 3 datos se
> agregan al acumulado. Si en el acumulado dice que ayer me pidieron 5 y hoy 20 y hoy despacharon
> 10 → **en el acumulado el operador solo debe ver: debes 15**. La trazabilidad (5 de ayer + 10 que
> faltó despachar) va en el **JSON que se muestra en MOS**."

Es decir: **al operador, saldo. A MOS, historia completa.**

---

## 4. Plan de reparación

### Ya aplicado (SQL 741 + cron) — 15/15 pruebas propias + 17/17 de la suite de regresión
- el candado se suelta solo a la hora de inactividad **real** (`wh.cron_liberar_pickups_atorados`, cada 15 min)
- consolidar y rezagar ya **no** tocan el reloj del candado
- el consolidador ya no se rinde: absorbe y mata la semana vieja aunque la lista esté tomada
- el autosave **fusiona por producto**: no borra lo que su copia no traía, y el botón − sigue pudiendo corregir hacia abajo

### Pendiente — C4, el cruce de las dos fuentes de verdad
1. **Versión de lista (`rev`)**: cada escritura del servidor sobre `wh.pickups.items` incrementa un
   contador. El front manda el `rev` que tiene; si el servidor está más adelantado, **su copia local
   se descarta y se recarga** (avisando al operador), en vez de imponerse.
2. **Al emitir la guía, la copia local muere**: hoy depende de una heurística de fechas. Debe ser
   explícito: cerrado con éxito → `_clearPickup()` sin condiciones.
3. **El checklist muestra el SALDO**, no el histórico: lo despachado en guías anteriores no vuelve a
   aparecer como pendiente. La trazabilidad (pedido, despachado, fecha, guía) viaja en el JSON y se
   ve en MOS.
4. **Guard anti-duplicado en la emisión**: si una guía ya cubrió esas líneas, no se puede volver a
   emitir sobre el mismo tramo.

### Cómo se va a probar (antes de tocar producción)
- **SQL**: pruebas en transacción + rollback (ya hay `_test_741_pickup.mjs` y la suite de 17).
- **Multi-operador con Playwright**: tres navegadores con copias distintas de la misma lista
  (uno viejo con 0 items, uno con despachados zombis, uno al día) → verificar que ninguno borra ni
  resucita nada, con capturas de cada pantalla.
- **Estrés**: autosaves concurrentes de varios dispositivos sobre la misma lista + consolidación
  entrando en medio, verificando que la deuda final cuadre exactamente con `pedido − despachado`.
- **Ciclo completo**: cierre de caja → acumulado → despacho parcial → guía → retomar → confirmar que
  solo aparece el saldo y que la guía no repite líneas.
