# 🧭 ESTADO DE LA MIGRACIÓN — léeme primero (handoff)

> **Punto de entrada único.** Si retomas esta conversación o cambiaste de modelo (p. ej. a Fable 5),
> lee SOLO este archivo para saber dónde vamos. Está escrito para ser autocontenido: no necesitas la
> memoria de Claude ni el historial. Última actualización: **2026-06-12**.

---

## 0. En una frase
Estamos sacando a **MosExpress (ME)** de Google Apps Script (GAS) y pasándolo a **Supabase**, paso a paso,
sin apagar nada en producción. Visión final del usuario: **"todo en Supabase, GAS ya no existirá"**.

- **Apps del ecosistema:** MOS (admin/master), warehouseMos (WH/almacén), MosExpress (ME/punto de venta).
- **Foco actual de la migración:** ME. WH y MOS migran después con el mismo patrón.
- **Stack:** Vue 3 (CDN, sin build) + GAS + Google Sheets → migrando a Supabase (Postgres + Edge Functions Deno).

## 1. Estrategia (cómo migramos sin romper)
Patrón **strangler-fig** con interruptores (feature flags):
1. **Sheets sigue siendo la fuente de verdad.** Supabase es una "sombra" que se llena en tiempo real (dual-write).
2. Cada responsabilidad de GAS se reescribe como **RPC de Supabase** o **Edge Function**, detrás de un **flag**.
3. Se prende el flag → la app escribe/lee directo a Supabase, con **fallback a GAS** si algo falla.
4. Cuando la sombra es 100% confiable, se retira GAS para esa pieza.

**Flags centrales** viven en la tabla `mos.config` (clave-valor). El frontend los lee por RPC `me.get_flags()`
(anónimo, sin token). Prender/apagar = un UPDATE en SQL. Patrón en frontend: `serverFlag || localStorage`.

## 2. ✅ LO QUE YA ESTÁ LIVE EN PRODUCCIÓN (flota completa)
- **Escritura directa de ventas NV** → `me.crear_venta_directa` (RPC). Flag `ME_ESCRITURA_DIRECTA=1`.
- **LECTURA directa de ventas** → `me.ventas_hoy_zona_auth` (RPC). Flag **`ME_LECTURA_DIRECTA=1`** (activado
  2026-06-12 tras gate de paridad: 0 huecos Sheets↔Supabase en 7 días). El frontend lee de Supabase con
  **fallback automático a GAS→Sheets** si el read directo falla. Gate re-corrible:
  `GET ?accion=verificar_paridad_lectura&dias=7` (verificarParidadLectura en Fase2Auth.gs).
- **Impresión vía Edge Function** (PrintNode) → `supabase/functions/imprimir`. Flag `ME_IMPRESION_DIRECTA=1`.
  Validada en prod (impresiones reales, 0 duplicados).
- **Movimientos de caja directos** → `me.crear_movimiento_directo`. Usan el flag de escritura.
- **Red de seguridad del cierre** → reconciliación cada 10 min + al iniciar el cierre (rescata ventas que el
  dual-write best-effort pudo perder). **Primer cierre real con ventas directas VALIDADO (2026-06-12):**
  la sombra cuadró 100% (incluido un cobro de crédito vía el flujo Lote1-A, idempotente, una sola vez).
- **Numeración de correlativo** atómica e idempotente en Supabase (`me.siguiente_correlativo`).
- **Lecturas operativas** (estado de cajas, ventas del día por zona, cobros, créditos) ya leen de Supabase.
- ⚠️ **KILL-SWITCH lectura:** `update mos.config set valor='0' where clave='ME_LECTURA_DIRECTA';` (vuelve a
  leer de Sheets vía GAS al instante). Con esto + escritura + impresión directas, **Sheets pasó a ser la
  sombra/respaldo del camino operativo de ME** (rol invertido vs. el inicio).
- **Frontend ME en producción: v2.8.4.**

### 🔴 KILL-SWITCH (si algo se ve raro en ventas)
```sql
update mos.config set valor='0' where clave='ME_ESCRITURA_DIRECTA';
```
Eso devuelve TODA la escritura de ventas a GAS al instante (sin redeploy). Para impresión:
`update mos.config set valor='0' where clave='ME_IMPRESION_DIRECTA';`

## 3. 🟢 LISTO PERO APAGADO (esperando algo del usuario)
- **CPE directo (boleta/factura electrónica)** → todo cableado: RPC `crear_cpe_directo`/`set_cpe_nf`
  (SQL 21 + **kill-switch SQL 24 ya aplicado y verificado live**) + Edge `emitir-cpe`. Flag `ME_CPE_DIRECTO=0`.
  **Falta:** el **token de NubeFact**. ⚠️ **El código endurecido de la Edge `emitir-cpe` (kill-switch +
  regex correlativo) está en el repo pero NO desplegado** — el deploy falló repetidamente (el CLI de
  Supabase se cuelga al empaquetar, probable Docker no corriendo / entorno non-TTY). NO es problema de
  seguridad: el kill-switch REAL vive en las RPC/DB (SQL 24) y la función no emite sin token.
  **PROCEDIMIENTO COMPLETO el día de NubeFact (en terminal normal, con Docker Desktop arrancado):**
  ```
  cd C:\Users\ISO\ProyectoMOS
  supabase functions deploy emitir-cpe --project-ref rzbzdeipbtqkzjqdchqk
  supabase functions deploy imprimir   --project-ref rzbzdeipbtqkzjqdchqk   # (A7/M5, opcional, verificar impresión)
  supabase secrets set NUBEFACT_TOKEN=xxx NUBEFACT_RUC=xxx --project-ref rzbzdeipbtqkzjqdchqk
  -- update mos.config set valor='1' where clave='ME_CPE_DIRECTO';   (prender)
  -- probar 1 boleta + verificar QR
  ```
  (Login CLI ya hecho con token personal — `supabase login --token` / dashboard/account/tokens.)
  Insight: en **boletas** NubeFact devuelve el QR **al instante** → el CPE puede ser casi tan rápido como la NV.

## 3.4 ✅ REMEDIACIÓN LOTE 1 (2026-06-12) — estado
- **Lote1-A HECHO** (ME GAS @203): lock global reentrante `_conLockCred` en TODO el flujo de
  cobro de créditos (confirmar/cobrar/escalar/rechazar/cancelar + cobrarVentaExistente/creditar).
  UrlFetch fuera del lock. + id_extra con sufijo uuid + PATCH inmediato de FormaPago a la sombra.
- **Lote1-C HECHO** (ME frontend v2.8.5): mutaciones de dinero confiables (validación + cola
  persistente + merge reconvergente con guard in-flight 20s) + lock procesarPago + e.repeat +
  res.idVenta en cola + rollback por idCobro + timeouts path directo + 3 returns + playBeepError.
- **Lote1-B HECHO** (aplicado a prod 2026-06-12): `supabase/23_fase2_endurecer_venta_directa.sql`
  — claim sub + total=Σ (validado contra 155 ventas reales de 7 días: 0 violaciones) + caja
  ABIERTA + zona_id. Smoke tests OK (APP_NO_AUTORIZADA / TOTAL_NO_CUADRA / CAJA_NO_ABIERTA).
  La password de la DB quedó en `supabase/.pgpass` (gitignoreado) para futuros SQL.
- Fixes urgentes previos del mismo día: WH reabrir-guía cache (v2.13.192) + MOS reactivar
  dispositivo suspendido shape/UC/clave (GAS @398).

## 3.3 ✅ REMEDIACIÓN LOTE 2 (2026-06-12) — seguridad de superficie pública
- **Lote2-C HECHO** (WH GAS @409-413, los 5 IDs): `crearAjuste`/`reconciliarStockProducto` bajo
  `_conLock` (race de STOCK) + IDOR `clienteEstadoPedido` (guard de token del dueño).
- **Lote2-A HECHO** (MOS GAS @399): `_gateDispositivoMOS` en `setConfig` + `guardarTarjetaWA` —
  exige dispositivo MOS registrado y ACTIVO (deviceId vía `_audit`). Cierra el C1 (cualquiera con
  la URL podía cambiar el PIN admin / el WhatsApp de las tarjetas). Smoke prod: rechaza sin auth.
  ⚠️ Pendiente menor: las acciones de dispositivos (aprobar/rechazar/bloquear) NO se gatearon
  por-device (el modal de seguridad centralizado las enruta desde WH/ME) → su fix correcto es
  `verificarClaveAdmin` por-endpoint.
- **Lote2-B HECHO (SQL) / Edge pendiente de deploy** (SQL 24 aplicado a prod + smoke tested):
  kill-switch server-side de la capa CPE — `me._cpe_directo_on()` leído en `crear_cpe_directo`/
  `set_cpe_nf`; máquina de estados nf_* (solo BOLETA/FACTURA, whitelist, no degrada EMITIDO).
  La Edge `emitir-cpe` tiene el código listo (flag + regex correlativo) pero **su deploy se
  bundlea con la activación del token NubeFact** (la feature está inerte hasta entonces).

## 3.2 ✅ REMEDIACIÓN LOTE 3 (2026-06-12) — consistencia y robustez
- **Lote3-A HECHO** (MOS frontend v2.43.201): 4 features muertos por "shape de API"
  revividos (overlay bloqueados Finanzas, Centro Tributario "falló" en éxitos, badge
  tributario al login, foto catálogo) + tarjeta WA robusta (lee `supabaseOk`, no borra
  números a ciegas, confirma borrado).
- **Lote3-B HECHO (SQL)** (SQL 25 aplicado a prod + smoke tested): A3 cap histórico de
  `ventas_hoy_zona_auth` (piso hoy-2d; test 84 vs 1571), A6 validaciones de
  `crear_movimiento_directo` (monto>0, tipo whitelist), M1 `get_flags`/`get_tarjeta`
  whitelist EXACTA de claves. **Pendiente (Edge `imprimir` LIVE, requiere ventana con
  verificación de impresión real):** A7 printer scoping + idempotencia, M5 CORS allowlist.
- **Lote3-C HECHO** (ME GAS @204 / v2.8.6): M2 PATCH inmediato de FormaPago en reverts a
  CREDITO (escalar/cancelar); M8 `lsSet` anti-cuota en procesarCobroPendiente + registrarExtra.

## 3.1 ✅ REMEDIACIÓN LOTE 4 (2026-06-12) — higiene
- **MOS** (v2.43.203 / GAS @400): dvh→vh modal Liquidaciones; voseo→neutral (api.js, editor,
  seguridad-modal, Adhesivos.gs); 2 cases duplicados muertos eliminados; `_route` ya no filtra
  err.stack (solo si `DEBUG_STACK=1`); 4 `confirm()` nativos → `_modalConfirm`.
- **ME** (v2.8.7): AudioContext **singleton** (`_audioCtx`) para los 16 play* (iOS dejaba de
  sonar en ráfagas); voseo→neutral; claves `_` muertas quitadas del return; guard tarjeta sin
  número; `agregarToast` respeta el 4º arg de duración.
- **WH** (v2.13.193 / GAS @414-418): idPedido con sufijo aleatorio (colisión por ms mezclaba
  pedidos); `confirm()` nativo de cancelar lote → confirmación inline.
- **B6-MOS HECHO** (GAS @404): snapshot CONGELADO de la liquidación semanal
  (`snapshotLiquidacionSemanal`, hoja `LIQUIDACION_SEMANAL_SNAPSHOT`). `cerrarSemanaAutomatico`
  congela antes del push; idempotente por (semana, idPersonal), LockService + dedup, nunca pisa
  PAGADO. Getter `getSnapshotsSemanal`. Probado en prod (4 empleados, 0 dups). **Follow-up menor:**
  wire del frontend para PREFERIR el snapshot en semanas pasadas (la semana en curso recalcula).
- **Pendiente menor:** 5 `confirm()` del editor.js standalone (módulo aparte sin `_modalConfirm`).
- **⛔ Deploys de Edge BLOQUEADOS por el clasificador (necesitan tu OK explícito por ser deploy de
  prod de alta severidad):** `emitir-cpe` (código endurecido listo: kill-switch + regex correlativo;
  función inerte sin token NubeFact) y `imprimir` (A7 printer-scoping + M5 CORS, función LIVE).
  Para autorizar: pedírmelo explícito por función, o el usuario corre `supabase functions deploy <fn>
  --project-ref rzbzdeipbtqkzjqdchqk`.

## 3.5 🔍 REVISIÓN EXHAUSTIVA DEL SISTEMA (2026-06-12) — LEER ANTES DE SEGUIR
Se auditó TODO el ecosistema (5 áreas en paralelo + verificación manual). Resultado:
**6 CRÍTICOS · 16 ALTOS** documentados con archivo:línea en `REVISION_SISTEMA_2026-06-12.md`,
con plan de remediación en 4 lotes. Los peores: flujo de cobro de créditos ME sin lock (doble
cobro posible), cobros optimistas del frontend que nunca reconvergen, `crear_venta_directa` sin
validar caja/claims (en prod), router GAS de MOS sin auth en escrituras, capa CPE viva del lado
server con flag apagado. **La remediación de los lotes 1-2 tiene prioridad sobre seguir migrando**
(créditos-directo absorbe el fix del lock como parte del diseño).

## 3.0 🎯 CAMINO A "ACABAR ME" (retirar GAS) — estado 2026-06-12 noche
Con escritura+lectura+impresión directas, **ME ya corre el camino caliente sobre Supabase**. Lo que
todavía ata ME a GAS (y hay que migrar a RPC directa para retirarlo):
- 🔴 **Cierre de caja** (arqueo diario) — LA pieza clave. Progreso:
  - **PASO 1 HECHO:** gate `me.simular_cierre_caja` (SQL 26, read-only). 8 cierres reales: donde no hubo
    override, el simulador reproduce el arqueo EXACTO al centavo (4/4) → matemática portable.
  - **PASO 2 HECHO (INERTE):** RPC `me.cerrar_caja` (SQL 27) — núcleo de dinero atómico: anula POR_COBRAR,
    efectivo+ingresos-egresos, montoFinal (auto/declarado)+descuadre, marca CERRADA, cancela cobros.
    Gateada por `ME_CIERRE_DIRECTO=0` (inerte) + kill-switch server-side. **Validada en tx-rollback contra
    cierre real: monto_final RPC == GAS exacto, idempotente, declarado+descuadre OK.**
  - **PASO 3 HECHO (INERTE, v2.8.8):** wire del frontend. `cierreDirecto()` helper + `_cerrarCajaDirecto()`
    (llama el RPC) + `cerrarCaja` (~index.html:11544): si el flag está ON, intenta el RPC (arqueo instantáneo
    en Supabase) y dispara el cierre GAS existente en BACKGROUND como mirror a Sheets + efectos secundarios
    (guía SALIDA_VENTAS para WH, cobros, push — idempotente, no reimplementado). Fallback a GAS síncrono si
    el RPC falla. Con `ME_CIERRE_DIRECTO=0` el bloque NO corre → comportamiento actual 100% intacto.
  - **ÚNICO PENDIENTE — PASO 4 (validación + flip):** vigilar 1-2 cierres reales con el flag aún en 0, y para
    cada uno comparar lo que el RPC daría vs lo que GAS guardó (en tx-rollback, como el gate del simulador).
    Si coinciden → `update mos.config set valor='1' where clave='ME_CIERRE_DIRECTO';`. Kill-switch: poner '0'.
    Todo el código (SQL 26+27, frontend v2.8.8) ya está committeado y desplegado, solo falta esa validación.
- 🟡 Apertura/retoma de caja, anulación/cobrar/creditar (forma_pago), cobro de créditos → RPCs directas
  (patrón ya probado; bajo/medio riesgo; hoy van por GAS + dual-write, que funciona bien — no urgente).
- ⛔ **CPE** — bloqueado por el token NubeFact (ver §3). Edge endurecida lista, sin desplegar.
> **"Acabar ME" requiere: cierre-directo (paso 2) + CPE (token).** El resto es cleanup incremental.

## 4. ⏳ CABOS ABIERTOS / PRÓXIMOS PASOS
1. **Validar el PRIMER cierre real con ventas directas.** La red de reconciliación está desplegada pero aún no
   se ejecutó en un cierre real. → Cuando un cajero cierre caja, verificar que el monto cuadra.
2. **Activar CPE** cuando haya token NubeFact (paso 3 de arriba).
3. **Cajas-directo (apertura/cierre como RPC)** — es lo más *money-critical*; siguiente write-entity grande.
   Nota: `crear_venta_directa` aún NO valida caja abierta; cerrar ese gap al hacer cajas-directo.
4. **Créditos/cobros directo** — siguiente patrón sistemático (RPC + mirror + flag + frontend). Flujo ya leído
   en `gas/Creditos.gs`. **No empezado.**
5. **Lectura directa de ventas** (`ME_LECTURA_DIRECTA=0`) — aún NO segura (si una venta-GAS se cae de la sombra,
   el cajero la perdería y re-emitiría → duplicada). Habilitar recién cuando la sombra sea 100% confiable.
6. **Retirar GAS** pieza por pieza, y al final hacer a Supabase la fuente de verdad (el corte final).

## 5. 📇 Tarjeta de presentación (feature aparte, ya en prod)
Función para imprimir una tarjeta térmica con QR a WhatsApp (comunicación controlada con clientes/proveedores).
- **En ME (v2.8.4):** Herramientas → "📇 IMPRIMIR TARJETA" → modal Cliente/Proveedor → imprime por la infra Edge.
  Plan B si no hay impresora: muestra el QR en pantalla.
- **Cabecera bitmap diferenciada:** ícono (carrito=cliente / camión=proveedor) + banda negra con la palabra en
  blanco, dibujada en canvas→raster ESC/POS (nítida). Proveedor lleva marco blanco interior.
- **Números dinámicos** en `mos.config`: `TARJETA_WA_COMERCIAL`, `TARJETA_WA_COMPRAS`, `TARJETA_MARCA`.
  ⚠️ **Siguen en placeholder `51000000000` — falta poner los reales** (`update mos.config set valor='51...'`).
- **Edición desde MOS** (v2.43.200): MOS → Config → Infraestructura → "Tarjeta de presentación" (modal +51 fijo).
- ⚠️ **Por verificar con el usuario:** que la cabecera bitmap (GS v 0) imprima bien en su impresora. Si sale
  basura → fallback a ASCII.
- ⏸️ **Parkeado:** portar la tarjeta a WH (WH imprime por GAS, no por Edge → es un build aparte).

## 6. ✨ Modo Pro + tema de color (UX, ya en prod ME v2.8.4)
- **Atajos de teclado (PC):** Espacio=Cobrar→Confirmar/Imprimir, Esc=cerrar modal/limpiar granel, /=buscador,
  Alt+1/2/3=módulos. Autodetecta PC. Toggle en Herramientas.
- **Barra inferior auto-oculta:** se colapsa a una línea fina con colores de marca + dots de alerta; se expande
  al pasar el mouse (PC) / tocar (touch); se re-oculta ~5s. Activa también en tablet.
- **Tema de color por módulo:** `colorModulo` (POS verde `#10b981` / CAJA azul `#3b82f6` / TOOLS naranja `#ea580c`).
  El header y el nav adoptan el color del módulo activo.

---

## 7. 🗂️ Mapa de archivos clave
| Qué | Dónde |
|---|---|
| Frontend ME (todo en un archivo, ~16k líneas) | `C:\Users\ISO\Documents\MosExpress\index.html` |
| Service Worker ME (bump VERSION en cada deploy) | `C:\Users\ISO\Documents\MosExpress\sw.js` |
| Backend GAS ME | `C:\Users\ISO\Documents\MosExpress\gas\Code.gs` |
| Frontend/Backend MOS | `C:\Users\ISO\ProyectoMOS\js\app.js`, `gas\Code.gs` |
| SQL de migración (numerados) | `C:\Users\ISO\ProyectoMOS\supabase\*.sql` (último: `22_tarjeta_presentacion.sql`) |
| Edge Functions (Deno) | `C:\Users\ISO\ProyectoMOS\supabase\functions\imprimir` y `\emitir-cpe` |
| Proyecto Supabase (ref) | `rzbzdeipbtqkzjqdchqk` |

### Docs relacionados (este archivo los resume — entra a ellos solo si necesitas el detalle)
- `ROADMAP_SUPABASE_TOTAL.md` — el plan completo "retirar GAS por completo" (cada responsabilidad → su reemplazo).
- `PUNTO_DE_RETOMA.md` — checkpoint corto (versión anterior de este resumen).
- `MIGRACION_FASE2_PLAN.md` / `MIGRACION_FASE2_ROADMAP_READS.md` / `FASE2_WIRING_PENDIENTE.md` — detalle de Fase 2.
- `MIGRACION_WH_FASE2.md` — plan de migración de warehouseMos (Fase 2). Gate de paridad ya hecho.
- `MIGRACION_RUNBOOK.md` — pasos operativos (cómo correr SQL, desplegar Edge Functions, etc.).
- `MIGRACION_SUPABASE.md` / `MIGRACION_SUPABASE_DICCIONARIO.md` — diseño general y diccionario de datos.

---

## 8. ⚠️ Reglas DE ORO al trabajar acá (respétalas siempre)
1. **App de DINERO en producción → máxima cautela.** Toda implementación pasa por una **revisión senior 20×
   adversarial** antes de declararse lista (estándar fijo del usuario).
2. **Vue 3 + prefijo `_`:** una propiedad accedida en el template a nivel raíz que empiece con `_` o `$` queda
   OCULTA por Vue → `ReferenceError` + pantalla en blanco. (Propiedades de objeto `item._x` sí están ok.)
3. **Bump del Service Worker** (`VERSION` en `sw.js` + `version.json`) en CADA cambio de frontend, o los cajeros
   siguen viendo la versión vieja.
4. **Deploy ME = git push** (GitHub Pages sirve estático). Sin `git push`, el usuario ve la versión vieja.
5. **Español NEUTRAL** (el usuario es peruano) — nunca voseo argentino. Vale para UI, toasts, commits y respuestas.
6. **Marca el punto de retoma:** al pausar o cambiar de tema, actualiza ESTE archivo (`ESTADO_MIGRACION.md`).
7. **Flags, no redeploys** para prender/apagar comportamiento: `update mos.config set valor='...' where clave='...'`.
8. **Idempotencia:** las escrituras directas dedupean por clave compartida directo↔GAS (evita filas duplicadas).
