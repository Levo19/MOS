# PUNTO DE RETOMA · Notificaciones entre apps (MOS ↔ ME ↔ WH)

**Estado**: diseñado y medido, sin implementar. Pedido de Luis el 2026-08-11.
**Regla de oro**: nada de esto se activa sin su OK — cada aviso nuevo le suena el celular a gente real.

---

## A. Pendiente heredado: el duplicado en ME y WH

`MosExpress/sw.js:18` y `warehouseMos/sw.js:18` tienen el MISMO bug que se arregló en MOS 2.43.740:
el SDK de Firebase muestra la notificación cuando el payload trae `notification` y **acto seguido**
llama a `onBackgroundMessage`, que la muestra otra vez → llega doble.

**Diferencia con MOS**: ahí el handler SÍ cumple una función real — reenvía los comandos data-only
(`payload.data.action`: audio_start, audio_stop, gps_locate) al cliente. Así que **no se borra el
handler**: se quita únicamente el `showNotification` del camino visible, dejando intacto el `return`
temprano de los comandos.

Cambio exacto en cada `sw.js` (el bloque después del `if (payload.data && payload.data.action) {...return;}`):
borrar el `self.registration.showNotification(...)` y dejar el handler terminando ahí, con el
comentario que explica por qué NO debe volver.

Cuidado en ME: hoy el handler preserva `idNotif/mensajeId` para el deep-link al tocar la
notificación. Al dejar que la muestre el SDK, **verificar que el click sigue navegando** — el SDK
usa `fcmOptions.link` / `click_action`, no el `data` del handler. Si el deep-link se pierde, la
salida es que la Edge mande `webpush.fcmOptions.link` con la URL de destino.

Rituales: ME (var V + sw.js + version.json + 12 scripts `node --check` + grep de verificación ANTES
del bump) · WH (version.json + sw.js + 15 pins).

---

## B. Lo nuevo: interconectividad por notificaciones

Pedido textual: *"cada vez que exista el cambio de un precio se notifique a cajeros + vendedores,
así se les avisa que ya tienen nuevo precio"*, *"al cajero se le imprime un ticket cuando se
registra un preingreso en WH y está bien, pero también quiero que sea notificación"*, *"así como a
WH cuando el PN se registra también debe notificarse a los usuarios de WH"*.

### Hallazgo que cambia el diseño: la audiencia por ROL no sirve para ME

Medido el 2026-08-11 con `mos.push_tokens_para`:

| audiencia | tokens que alcanza |
|---|---|
| `apps: ['mosExpress']` | **13** |
| `apps: ['warehouseMos']` | **6** |
| `roles: ['CAJERO','VENDEDOR']` | **0** ← |
| `roles: ['ALMACENERO']` | 6 |
| `roles: ['MASTER','ADMINISTRADOR','ADMIN']` | 4 |

`push_tokens_para` cruza `mos.push_tokens.usuario` contra **`mos.personal` por nombre**, y los
cajeros/vendedores de ME **no viven en `mos.personal`**: son identidades virtuales `MEX:NOMBRE|ZONA`.
`mos.personal` activo tiene 3 ADMIN, 1 MASTER, 3 ALMACENERO y **1 solo CAJERO**.

→ **Para llegar a cajeros y vendedores hay que dirigir por APP (`apps:['mosExpress']`), no por rol.**
Es además lo correcto conceptualmente: quien tiene ME instalada es quien vende.

Si algún día se quiere segmentar por zona ("solo los cajeros de Zona 1"), hay que **extender
`push_tokens_para` con una clave `zonas`** cruzando contra la sesión viva del día — hoy no existe.

### Estado actual de cada aviso

| evento | hoy | falta |
|---|---|---|
| Preingreso creado (WH) | push a MASTER/ADMIN + **ticket impreso** en las cajas abiertas de ME (Edge `aviso-cajas`) | **push a `apps:['mosExpress']`** |
| PN registrado (WH) | push a MASTER/ADMIN | *(decisión: ¿avisar también a los de WH al registrarse, o solo al aprobarse?)* |
| PN aprobado (MOS) | ya avisa a `apps:['warehouseMos']` ✅ | nada |
| Merma registrada | push a MASTER/ADMIN (ya con nombre, 740) | nada |
| **Cambio de precio** | **nada** | **push a `apps:['mosExpress']`** |

### El problema real del aviso de precios: las ráfagas

Medido en `mos.historial_precio_costo`, últimos 14 días:

| día | cambios | productos | mayor ráfaga en 5 min |
|---|---|---|---|
| 07/08 | 16 | 14 | **9** |
| 10/08 | 6 | 6 | 2 |
| 01/08 | 4 | 4 | 1 |
| el resto | 1–3 | 1–3 | 1–2 |

El volumen normal es bajo (1–6 al día), **pero al aplicar los precios de una compra salen en ráfaga**:
9 cambios en 5 minutos. Un push por cambio serían 9 notificaciones seguidas a 13 personas — el camino
más rápido para que todos silencien las notificaciones de ME y dejen de servir para lo importante.

**Propuesta: agrupar.** Un trigger sobre `mos.historial_precio_costo` (que ya registra TODOS los
caminos de precio — publicar_precio, actualizar_producto, segmentos, compra, jefa, alta) encola en
`mos.notif_precio_pendiente`; un cron cada ~5 min agrupa lo pendiente y manda **una sola**:

> 💲 **Precios actualizados** — 9 productos: ARROZ COSTEÑO 5KG, ACEITE PRIMOR 1L, AZÚCAR RUBIA… *(y 6 más)*

Ventajas: un solo lugar que decide (no hay que tocar las 7 funciones que escriben precio), la ráfaga
se colapsa sola, y si no hubo cambios no se manda nada. El cambio de UNA sola etiqueta sigue llegando
en ≤5 min, que es de sobra para lo que se necesita (que el cajero sepa que ya tiene precio nuevo).

**Alternativa descartada**: push directo desde cada función de precio → simple de escribir, pero
reproduce la ráfaga tal cual.

### Plan de implementación (cuando Luis dé el OK)

1. `mos.notif_precio_pendiente` (sku_base, descripcion, precio_ant, precio_nuevo, ts, enviado_en).
2. Trigger `after insert on mos.historial_precio_costo where tipo like '%PRECIO%'` → encola.
   Best-effort (`exception when others then null`): un fallo de aviso **jamás** puede tumbar el
   guardado de un precio.
3. `mos.cron_avisar_precios()` cada 5 min: agrupa lo no enviado, arma el texto, `mos.emitir_push`
   con `apps:['mosExpress']`, marca enviado. Con tope (si son más de N, dice "N productos" sin listar).
4. Preingreso → añadir el push a `apps:['mosExpress']` en `wh.crear_preingreso` (una línea, junto al
   que ya va a MASTER/ADMIN). El ticket impreso **se queda**: son dos canales distintos y el ticket
   es el que se pega en la caja.
5. Arreglar antes el duplicado de ME/WH (sección A) — si no, cada aviso nuevo llega doble.
6. Verificación: enviar primero **solo al token de prueba** (la Edge acepta `tokens:[...]` explícitos)
   antes de abrir la audiencia real.

### Decisiones pendientes de Luis

- **Agrupación de precios**: ¿una sola cada ~5 min (recomendado) o una por cambio?
- **PN**: ¿avisar a los de WH cuando se REGISTRA (además del aviso a admin) o basta con el aviso que
  ya existe cuando se APRUEBA?
- ¿El aviso de precio debe listar los productos o basta el conteo?
