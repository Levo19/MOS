# PUNTO DE RETOMA · Notificaciones entre apps (MOS ↔ ME ↔ WH)

**Estado**: ✅ **IMPLEMENTADO Y EN PROD (2026-08-12, autorizado por Luis "continuamos con el punto 2")**.
- Duplicado ME/WH: muerto — ME 2.8.281 + WH 2.13.555 (mismo fix que MOS 740; ME lee el deep-link
  también del shape `FCM_MSG` del SDK).
- Preingreso → push a `apps:['mosExpress']` ("📦 Llegó mercadería al almacén"), además del ticket
  y del aviso a MASTER/ADMIN — SQL 755 (`wh.crear_preingreso` con cuerpo calculado una vez).
- Precios → cola `mos.notif_precio_pendiente` + trigger best-effort sobre `mos.historial_precio_costo`
  (SOLO tipo='PRECIO') + `mos.cron_avisar_precios()` cada 5 min con el texto aprobado y dedup por
  producto. Verificado en tx+rollback: 5 cambios → "4 productos: A, B, C… y 1 más"; COSTO no encola.
- HALLAZGO colateral (no causado por esto): los push a Luis NO llegan desde la mañana del 12-ago —
  su Chrome perdió la suscripción FCM (mismo evento que cerró sus pestañas); la instancia re-minta
  tokens que nacen muertos (566 en el día). Remedio: re-registrar desde el navegador (MOS →
  probar notificación / re-permitir). La Edge `push` NO desactiva tokens `unregistered` (wart menor;
  se autocura porque la audiencia toma el último token por device).

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

### Decisiones YA TOMADAS por Luis (2026-08-11) — no volver a preguntar

1. **Aviso de precios: AGRUPADO cada ~5 min**, con los nombres de los productos y corte con
   "…y N más". Texto aprobado:
   ```
   💲 Precios actualizados
   9 productos: ARROZ COSTEÑO 5KG, ACEITE PRIMOR 1L, AZUCAR RUBIA… y 6 más
   ```
   Un cambio suelto debe llegar igual (en ≤5 min), no solo las ráfagas.
2. **PN: SOLO al aprobarse** — que es lo que ya funciona hoy (`wh.marcar_producto_nuevo_aprobado`
   → `apps:['warehouseMos']`). **No** se agrega aviso a todo WH al registrar; el registro sigue
   avisando solo a MASTER/ADMIN. Nada que hacer aquí.
3. **Ejecución: nada se implementa por ahora.** Queda apuntado y se retoma cuando Luis lo pida.

Con eso, el trabajo pendiente real se reduce a tres cosas, en este orden:

| # | qué | por qué primero |
|---|---|---|
| 1 | Matar el duplicado en `MosExpress/sw.js` y `warehouseMos/sw.js` (sección A) | si no, cada aviso nuevo llega doble |
| 2 | Preingreso → push a `apps:['mosExpress']` (una línea en `wh.crear_preingreso`) | barato y ya está decidido; el ticket impreso se queda |
| 3 | Precios → `mos.notif_precio_pendiente` + trigger + `mos.cron_avisar_precios()` cada 5 min | el único que necesita obra nueva |

En los tres: probar contra **un token de prueba** (la Edge acepta `tokens:[...]`) antes de abrir la
audiencia real de 13 personas.
