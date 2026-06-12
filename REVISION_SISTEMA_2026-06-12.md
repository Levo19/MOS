# 🔍 Revisión exhaustiva del sistema — 2026-06-12

> Auditoría adversarial de todo el ecosistema (ME frontend, ME GAS, Supabase, MOS, WH) hecha con
> 5 revisores en paralelo + verificación manual de los hallazgos críticos. **EN PROGRESO** — las
> secciones se completan a medida que terminan las auditorías.

**Estado:** ✅ COMPLETA — las 5 áreas auditadas; todos los CRÍTICOS y la mayoría de ALTOS
verificados a mano línea por línea (6/6 spot-checks correctos en cada agente).

---

## 1. SUPABASE (SQL + Edge Functions) — ✅ auditada, críticos verificados a mano

### 🔴 CRÍTICOS (verificados línea por línea)

**C1. El flag `ME_CPE_DIRECTO=0` solo apaga el FRONTEND — la capa server está viva**
- `21_fase2_cpe_directo.sql:92-95` (grants a authenticated) + `emitir-cpe/index.ts:60` + config.toml.
- Ni las RPC (`crear_cpe_directo`, `set_cpe_nf`) ni la Edge `emitir-cpe` leen el flag. Cualquier
  dispositivo registrado con JWT válido puede llamarlas HOY.
- **Matiz verificado:** la emisión SUNAT real está bloqueada porque los secrets NubeFact no están
  seteados (la Edge devuelve 500). PERO `crear_cpe_directo` sí puede insertar boletas/facturas
  falsas en `me.ventas`, y `reconciliarDirectasSheets` (que incluye BOLETA/FACTURA) las espejaría
  a VENTAS_CABECERA → filas fiscales falsas en la fuente de verdad.
- **Fix:** kill-switch server-side — las RPC y la Edge deben leer `mos.config.ME_CPE_DIRECTO` y
  rechazar si ≠ '1'. Hacerlo ANTES de cargar el token NubeFact.

**C2. `emitir-cpe` arma el payload SUNAT 100% con datos del cliente**
- `emitir-cpe/index.ts:66-128`. `header.total`, `items[]`, `correlativo` vienen del browser sin
  contrastar contra `me.ventas`. Permite CPE con base imponible/IGV manipulado y "quemar" números
  futuros de la serie (el dedup de NubeFact devolvería el doc del atacante a la venta real).
- **Fix:** la Edge debe leer la venta por `ref_local` de `me.ventas` (service_role) y construir el
  payload desde la DB. Hacer junto con C1, antes de activar CPE.

**C3. `crear_venta_directa` confía identidad y montos del body**
- `17_fase2_crear_venta_directa.sql:45-52`. `vendedor`, `id_caja`, `dispositivo_id`, `total`,
  `items[].precio` salen del payload. No compara `dispositivo_id` con el claim `sub` del JWT, no
  valida `total = Σ subtotales`, no valida precio vs catálogo. El path GAS (procesarVenta) sí
  validaba. **EN PRODUCCIÓN HOY** (flag activo en flota).
- **Fix:** derivar `dispositivo_id` del claim `sub`, validar `total = Σ subtotal` (tolerancia
  0.01), rechazar discrepancias. (Validar precio vs catálogo: deseable, fase 2.)

### 🟠 ALTOS (verificados los 2 primeros)

- **A1. `crear_venta_directa` NO valida caja ABIERTA** (verificado: no hay select a me.cajas).
  `crear_movimiento_directo` (19:29-30) y `crear_cpe_directo` (21:32-33) SÍ lo hacen. Es el gap
  "ventas fantasma" que GAS cerró en v2.7.5. Fix: copiar el bloque `v_caja_ok` (orden
  idempotencia-primero). **Ya estaba anotado como cabo del roadmap; ahora con prioridad.**
- **A2. `set_cpe_nf` reescribe nf_* de CUALQUIER venta** (verificado 21:76-90): sin whitelist de
  estados, sin filtro tipo_doc, sin prohibir EMITIDO→*. Fraude contable posible. Fix junto a C1.
- A3. `ventas_hoy_zona_auth` (16:31-36): `desde`/`prefijos` los pone el cliente → un token de 5min
  puede descargar TODO el historial (PII de clientes). Fix: cap server-side (ej. 7 días).
- A4. `emitir-cpe:77`: correlativo malformado cae a `numero=1` → duplicado en NubeFact → doc
  equivocado. Fix: rechazar 400 si no matchea `/^[A-Z0-9]+-\d+$/`.
- A5. Idempotencia de emitir-cpe depende del wording del error de NubeFact (regex "ya fue
  informado"). Si cambia el texto + el front cae a fallback GAS → DOS CPE para la misma venta.
  Fix: ante reintento con error ambiguo, `consultar` antes de generar.
- A6. `crear_movimiento_directo`: monto sin validar (>0), tipo sin whitelist (typo lo saca de los
  buckets del cierre), TOCTOU caja entre check e insert. Fix: validaciones + `for share`.
- A7. Edge `imprimir`: cualquier token puede imprimir cualquier contenido en CUALQUIER impresora
  de la cuenta PrintNode + sin idempotencia (reintento = ticket doble). Fix: validar printerId
  por zona del dispositivo + idempotencyKey.

### 🟡 MEDIOS
- M1. `get_flags`/`get_tarjeta_config`: whitelist por PREFIJO (`ME_%`/`TARJETA_%`), no por clave
  exacta — hoy no expone nada sensible (verificado por el auditor), pero una futura clave `ME_*`
  secreta se volvería pública. Fix: `where clave in (...)` explícito.
- M2. `crear_venta_directa`/`crear_cpe_directo` no setean `zona_id` → ventas directas con zona
  NULL → reportes por zona las pierden. Fix: derivar de `me.cajas.zona_id`.
- M3. Detección de anulación inconsistente: `06` usa `estado_envio='ANULADO'`, `13` usa
  `forma_pago`. A CONFIRMAR contra GAS cuál es canónico en ME (en MOS es FormaPago).
- M4. Filtros por día Lima no-sargables (`to_char(...)=hoy`) → seq scans que crecen con la tabla.
  Fix: índice de expresión o rangos `fecha >= X and < Y`.
- M5. CORS `*` en ambas Edge Functions. Fix: allowlist del origin de GitHub Pages.
- M6. Errores que filtran internals (body crudo de PrintNode, e.message, errores SQL de casts).
- M7. `mos.dispositivo_zonas` y `me.correlativos_emitidos` sin RLS (la cerca real es la ausencia
  de grants — verificada — pero rompe el estándar doble-bloqueo del repo).
- M8. `mos.personal.pin` en texto plano (pendiente reconocido de Fase 2).
- M9. estado_cajas: `CERRADA_AUTO` nunca expira del listado de 30 días → payload crece sin tope.

### 🔵 BAJOS
B1 revoke from public faltante en 06-12 (sin fuga real, consistencia) · B2 índice normal extra
sobre ref_local · B3 rama v_ins=0 sin fila → detalle huérfano teórico · B4 placeholders
`51000000000` en tarjeta (ya anotado) · B5 floats JS en IGV de emitir-cpe (centavos, vigilar) ·
B6 dependencia del JWT secret legacy HS256 (plan de rotación A CONFIRMAR).

### ✅ Verificado OK (Supabase)
- `search_path=''` en TODAS las security definer — sin hijack.
- `me.siguiente_correlativo`: atómico e idempotente, diseño sólido.
- Idempotencia de escritura: ventas/CPE por ref_local (índice parcial = predicado exacto del ON
  CONFLICT), movimientos por PK id_extra, detalle por (id_venta,linea). Reintentos no duplican.
- Dinero en `numeric` en toda la DB (cero float).
- RLS + sin grants de tabla a anon/authenticated (doble cerca, salvo M7).
- `me.jwt_app()` fail-closed; anon key sin claim app → bloqueada en Edge y RPC.
- `verify_jwt=true` en ambas Edge Functions (la firma la verifica la plataforma).
- Columnas consistentes con los schemas; secrets solo vía Deno.env (nada hardcodeado).

---

## 2. ME FRONTEND — ✅ auditada, claves verificadas a mano (v2.8.4)

### 🔴 CRÍTICO
**C1-FE. Cobros/anulaciones optimistas con `.catch(()=>{})` y el polling NUNCA reconverge**
(VERIFICADO 14066-14067: `COBRAR_VENTA` fire-and-forget sin validar respuesta; también 12948,
12972, 13000, 15797). Si el POST falla, el dinero queda registrado SOLO en el dispositivo; el
merge del polling (10794) salta el update del server cuando `cobradoMetodo` está seteado local →
el cobro fallido queda "✓ Cobrado" PARA SIEMPRE en la UI con el backend en POR_COBRAR → descuadre
silencioso al cierre. Para ANULACION es al revés: el poll de 3s puede REVERTIR el anulado en
pantalla con el POST en vuelo (misma clase del bug de merge de preingresos de WH). Fix: cola
persistente de mutaciones de dinero (patrón `pendingSales`) con reintento + validación, y guard
in-flight por campo en el merge (TTL), como WH v2.13.173.

### 🟠 ALTOS (verificados a mano 2, 6 y parte de 4)
- **A2-FE. `procesarPago` sin lock de reentrada** (VERIFICADO: sin `if (procesando) return` al
  inicio; `procesando=true` recién en 15235, DESPUÉS de 2 awaits de hasta 1.5s+3s). Doble tap o
  Espacio sostenido (`_atajosPC` no filtra `e.repeat`) en esa ventana = DOS ventas reales con
  localId distintos (la idempotencia no ayuda). Fix: guard al inicio + procesando antes de los
  awaits + ignorar e.repeat.
- **A3-FE. `sincronizarDatos` no valida `res.idVenta`** (8908): la cola puede marcar como subida
  una venta que GAS rechazó con success-sin-id (caso NO_CAJA_ACTIVA al subir con caja cerrada) →
  ticket impreso, fila inexistente, sin banner fantasma. La validación v2.7.4 se aplicó solo en
  `_enviarVentaConReintentos`. Fix: replicar `&& res.idVenta` + rutear a flujo fantasma.
- **A4-FE. `confirmarCobrarAsignado`: rollback con índice stale** (13621-13658): el cobro se
  filtra de la lista a los 1.2s; si GAS rechaza después, el rollback apunta a otro cobro/undefined
  → TypeError → cae al catch de red con toast "se sincroniza al volver red" (FALSO: no hay cola de
  cobros asignados). Fix: rollback por idCobro + separar rechazo de error de red + corregir toast.
- **A5-FE. Path directo a Supabase SIN timeout** (`_crearVentaDirecta` 13825, `_crearCPEDirecto`
  13886, `_mintTokenSB` 13949, `_imprimirDirectoPN` 13794): fetch pelado; si Supabase cuelga, la
  venta no imprime por minutos con el carrito ya limpio (cajero ciego) y sin caer al fallback.
  El guard de 4s solo cubre el path GAS. Fix: reutilizar `_meFetchTimeout` (13458) en los 4.
- **A6-FE. 3 referencias del template ausentes del return del setup** (VERIFICADO por grep):
  `resetearCajero` (botón "← Otro" del modo Cajero MUERTO), `horaActual` (reloj del header vacío),
  `scannerFocused` (animación del logo inerte). Fix: agregarlas al return.

### 🟡 MEDIOS
- M7-FE. `confirmarCredito` (13013): fetch sin validar respuesta, catch vacío — si GAS rechaza,
  la UI igual marca CRÉDITO.
- M8-FE. `localStorage.setItem` crudo (sin `lsSet` seguro) en flujos de dinero (14057, 12969,
  12998, 13751): QuotaExceeded abortaría DESPUÉS de marcar cobrado y ANTES del POST.
- M9-FE. `playError` NO EXISTE (VERIFICADO 15186, 15705, 15709) — la función real es
  `playBeepError`; el evento más grave (venta fantasma) queda sin alarma sonora.
- M10-FE. `:class` duplicado en el botón confirmar pago (4444-4445): el parser HTML descarta el
  segundo → estilo "EMITIR A CRÉDITO" nunca aplica.
- M11-FE. AudioContext nuevo en cada beep, nunca cerrado — en iOS (límite ~4 contextos) ráfagas
  de escaneo pueden enmudecer el audio. Fix: singleton + resume() por gesto.
- M12-FE. Fallback GAS tras directa "fallida" con respuesta perdida → correlativos divergentes /
  posible doble en Sheets hasta reconciliación (A CONFIRMAR contra reconciliarDirectasSheets).
- M13-FE. `inset-0` de Tailwind en overlays críticos (regla iOS/Chromium viejo) — A CONFIRMAR
  con el dispositivo más viejo de la flota.

### 🔵 BAJOS
B14 claves `_` exportadas en el return (filtradas por Vue, trampa futura: 16620, 16720, 16728,
16748) · B15 voseo (9860 "pasá/tocá", 15206, 15218 "Buscá", 15230 "Reintentá", 11524) ·
B16 `agregarToast` ignora el 4° arg duración · B17 tarjeta sin guard si `numero=''` → QR a
wa.me sin número + sin timeout · B18 `confirmarCobrarAsignado` no usa el lock que sí usa el
rechazo · B19 `confirmarMoneda` no suma a `cobradosEnSesion` (desglose por vendedor del cierre).

### ✅ Verificado OK (ME frontend)
sw.js=version.json 2.8.4 · sin template v-for con :key, sin dvh, sin modales nativos · buffer
granel correcto (diseño y foco) · Modo Pro/nav consistente y retornado · colorModulo OK ·
tarjeta: todas las funciones existen y el template está cubierto por el return · idempotencia
localId/idExtra bien diseñada · cierre de caja atómico con reintento idempotente · pollings con
guard de instancia única + mutex cross-tab · codigoBarra como String · error handler global Vue.

## 3. ME GAS — ✅ auditada, críticos confirmados por lectura directa

### 🔴 CRÍTICOS — los 3 son el MISMO agujero: el flujo de cobro de créditos no tiene lock
*(Confirmados de primera mano: leí Creditos.gs y EditarVenta.gs completos — no hay LockService
en todo el camino del cobro.)*

**C1-GAS. `cobrarCreditoConExtra` sin LockService → doble INGRESO** (EditarVenta.gs:42-181).
Scan de venta → validar FormaPago → appendRow MOVIMIENTOS_EXTRA → setValue FormaPago, todo sin
lock ni dedup por idVenta. Dos requests simultáneos = dos INGRESOS por un solo cobro; el
descuadre lo paga el cajero.

**C2-GAS. TOCTOU en `confirmarCobroAsignado`** (Creditos.gs:224-280). Valida estado ASIGNADO,
llama al cobro (lento: incluye reimpresión), y recién al final marca COBRADO. Dos confirmaciones
concurrentes del mismo idCobro ambas ven ASIGNADO → doble cobro. El camino MÁS probable en prod.

**C3-GAS. `escalarCobrosVencidos` puede revertir a CRÉDITO un cobro EN CURSO** (Creditos.gs:643-746).
El guard anti-falso-expirado lee FormaPago, pero el cobro la cambia AL FINAL de su flujo → el
trigger puede expirar + revertir la venta a CREDITO mientras el cajero termina de cobrar →
INGRESO registrado + venta reaparece como crédito → se puede re-asignar y RE-COBRAR.

**Fix común:** un único ScriptLock que abarque `confirmarCobroAsignado` → `cobrarCreditoConExtra`
→ transición a COBRADO; `escalarCobrosVencidos` toma el MISMO lock y re-lee dentro de él.

### 🟠 ALTOS
- **A1-GAS.** IDs `'EX-'+Date.now()` colisionables entre cajas (EditarVenta.gs:108; Caja.gs:1151).
  id_extra es la clave de idempotencia del dual-write: colisión = un movimiento SOBRESCRIBE a
  otro en la sombra Supabase (el cierre sub-contaría al flipear lecturas). Fix: sufijo aleatorio
  como ya hace 'RES-' en Ventas.gs:1024. *(Confirmado: vi el `idExtra = 'EX-' + getTime()`.)*
- **A2-GAS.** El cambio FormaPago CREDITO→pagado del cobro NO hace PATCH inmediato a Supabase
  (solo dirty-sync ≤15min) → con lecturas flipeadas, el crédito cobrado sigue "pendiente" esa
  ventana → riesgo de re-asignación. Fix: `_dualWriteVentaPatchME(idVenta,{forma_pago:...})`.
- **A3-GAS.** Guard de `escalarCobrosVencidos` con fallback de columna hardcodeado (`: 8`) — si
  algún día se inserta una columna antes de FormaPago, expiraría cobros YA pagados en silencio.
  Fix: sin header `FormaPago`, abortar (no adivinar).

### 🟡 MEDIOS
- M1-GAS. `cobrarVentaExistente`/`creditarVenta` (Caja.gs:993-1065) cambian FormaPago sin PATCH
  inmediato (inconsistente con `anularVentaIndividual` que sí). Unificar.
- M2-GAS. Reverts a CREDITO (expirar/cancelar) tampoco PATCHean. Misma unificación.
- M3-GAS. `registrarExtraCaja` legacy muerto sin validaciones (Caja.gs:1143) — trampa si alguien
  lo re-cablea. Eliminar o @deprecated.
- M4-GAS. JWT sin claim de zona: la seguridad recae en que la RLS no confíe en params del
  cliente (cruza con A3-Supabase, que confirma que `ventas_hoy_zona_auth` SÍ confía → ver §1).
- M5-GAS. Fallbacks de índice hardcodeados en cierre (Caja.gs:540-543). Abortar en vez de adivinar.

### 🔵 BAJOS
B1 62 catch{} vacíos (best-effort defendibles; en paths de dinero al menos Logger.log) ·
B2 `ventasHoyZona` corta "hoy" con TZ del servidor, no Lima (Ventas.gs:506) · B3 límite de días
con getDate() local en getCreditosPendientes (aprox., no dinero) · B4 heurística esCajero en
convertirNVaCPE (cosmético).

### ✅ Verificado OK (ME GAS)
Anulación por FormaPago ✅ · POR_COBRAR se ANULA al cierre ✅ · CLIENTES_FRECUENTES headers ✅ ·
procesarVenta rechaza sin caja abierta ✅ · codigoBarra '@STRING@' ✅ · LockService en
correlativo/cierre/mirrors ✅ (falta SOLO en cobro de crédito) · mirrors idempotentes ✅ (salvo
A1-GAS) · cero credenciales hardcodeadas (todo en Script Properties) ✅.

## 4. MOS — ✅ auditada, claves verificadas a mano

### 🔴 CRÍTICO
**C1-MOS. Router GAS sin autenticación server-side en escrituras** (VERIFICADO: `setConfigMos`
Code.gs:547-558 escribe CUALQUIER clave de CONFIG_MOS sin PIN — incluido `ADMIN_GLOBAL_PIN`;
`guardarTarjetaWA` Code.gs:577 tampoco pide PIN). El Web App es "Anyone" y la URL está publicada
en GitHub Pages. Cualquiera con la URL puede rotar el PIN global o cambiar los números de
WhatsApp de las tarjetas (phishing de pagos: clientes/proveedores redirigidos a un número ajeno).
Patrón compartido por decenas de actions de escritura — arquitectural/pre-existente, pero en app
de dinero es CRÍTICO. Fix: whitelist de acciones públicas; el resto exige verificación server-side
(verificarClaveAdmin / token de sesión / HMAC con secreto en ScriptProperties). Mínimo urgente:
gatear setConfig + guardarTarjetaWA + escrituras de dispositivos/bloqueos.

### 🟠 ALTOS (verificados a mano los 3 primeros)
- **A1-MOS. Tarjeta WA: si `_sbUpsert` a mos.config falla, el admin NO se entera** (VERIFICADO:
  Code.gs:601 devuelve `supabaseOk` pero app.js:18249-18251 lo descarta y muestra "¡Listo! Las
  tarjetas ya usan los números nuevos ✅" incondicional). Peor: getTarjetaWA lee PRIMERO de
  Supabase → al reabrir, el modal mostraría el valor viejo. Fix: leer `supabaseOk` y avisar.
- **A2-MOS. Tarjeta WA: carga fallida silenciosa + guardar BORRA los números** (VERIFICADO:
  app.js:18219 catch vacío deja inputs vacíos; guardar con '' pasa la validación `if (comercial
  && ...)` del backend y escribe '' en CONFIG_MOS y mos.config). Admin con red intermitente que
  solo toca la marca y guarda = números borrados en producción. Fix: deshabilitar Guardar si la
  carga falló; confirmar si un campo con valor pasa a vacío.
- **A3-MOS. Shape de API roto: overlay de dispositivos bloqueados en Finanzas MUERTO** (VERIFICADO
  app.js:33684: `rB.ok && rB.data` sobre respuesta ya desempaquetada → siempre cae al else).
  Feature de seguridad inoperante desde que se escribió. Fix: `rB.porNombre || {}`.
- **A4-MOS. Shape de API roto: Centro Tributario reporta "falló" en operaciones EXITOSAS**
  (app.js:30910-30930): riesgo de reenviar CPE a SUNAT por reintentar lo ya hecho.

### 🟡 MEDIOS
- M0a/M0b-MOS. Más shape roto: `_tribPrecargarBoot` muerto (badge tributario nunca aparece,
  app.js:31193) y foto de catálogo no adopta URL de Drive (app.js:4802).
- M1-MOS. Tarjeta WA: asimetría lectura (prioriza Supabase) vs fuente de verdad (CONFIG_MOS).
- M2-MOS. `dvh` en producción (VERIFICADO index.html:20035 `92dvh`, modal Liquidaciones) — y
  app.js:38389 documenta ESTE bug como ya corregido. Fix: `92vh`.
- M3-MOS. `confirm()` nativos vigentes: app.js:6240 (AJUSTES masivos de stock — dinero), 10155,
  12656, 12680, 20919 + editor.js:1031.
- M4-MOS. Editor adhesivos: funciona hoy solo porque `window.MOS_API` nunca se setea (trampa de
  shape latente, editor.js:916-944).
- M5-MOS. Contrato divergente: backend tarjeta acepta 9-15 dígitos sin exigir '51', frontend
  fuerza 9+prefijo.

### 🔵 BAJOS
B1/B5 voseo argentino visible al usuario (api.js:23,49 "Revisá/volvé/Esperá/reintentá",
editor.js:955 "Ponele", seguridad-modal.js:718/817 "Podés") — regla español neutral ·
B2 cases duplicados muertos en router · B3 `_route` devuelve err.stack al cliente ·
B4 normalización '51' server-side faltante · B6 cierre semanal jornales SIGUE sin persistir
snapshot (confirmado — solo push; montos mutables retroactivamente) · B7 forwardWHPickup no
valida payload.

### ✅ Verificado OK (MOS)
sw.js/version.json consistentes 2.43.200 · API.get/post desempaquetan d.data (el wrapper cumple
la regla; los bugs son de los CALLERS) · getConfigPublico filtra secretos por regex ·
verificarClaveAdmin 4+4 con padStart defensivo · SeguridadAlerts: lock reentrante, idempotencia
dentro del lock, cruce medianoche, mutaciones con PIN · editor adhesivos: lock + re-lectura
dentro del lock + validación · forwardWHPickup/Action: whitelist + limpia action (anti "Acción
no reconocida") · tarjeta WA frontend: +51 fijo, 9 dígitos, triple feedback estándar.

## 5. WAREHOUSEMOS — ✅ auditada, ALTO verificado a mano

### 🟠 ALTO
**A1-WH. `crearAjuste` y `reconciliarStockProducto` escriben STOCK SIN `_conLock`** (VERIFICADO:
`Productos.gs:1590` + `Auditoria.gs:562/618`, expuestos desnudos en router `Code.gs:222/:310`;
`_actualizarStock` en `Code.gs:840-857` es read-modify-write sin lock). Si un ajuste corre
concurrente con `cerrarGuia`/`registrarEnvasado` del mismo producto → lost update → stock
corrupto. Nota: `auditarProducto` SÍ la envuelve en `_conLock`; el hueco es el case directo del
router. Fix: envolver ambos cases en `_conLock` (es reentrante, no rompe llamadas anidadas).

### 🟡 MEDIOS
- M1-WH. IDOR de lectura: `clienteEstadoPedido` (ClientePortal.gs:305) no valida token del dueño
  (el fix C6 cubrió confirmar, no estado). idPedido enumerable → leer estado de pedidos ajenos.
- M2-WH. Regresión: el gate admin sobre `clienteRegistrar` (Code.gs:141) rompió el botón
  "Registrarme" público de pedido.html:677. El auto-alta al enviar pedido sigue OK (llamada
  interna). A CONFIRMAR si fue intencional.
- M3-WH. `idPedido='PC'+getTime()` colisionable en el mismo ms → mezcla de items entre pedidos.
  Fix: sufijo aleatorio como ya hace `_logStockMovimiento`.
- M4-WH. `confirm()` nativo en app.js:20337 (cancelar lote de adhesivos) — straggler de la regla
  "sin modales nativos".
- M5-WH. Escrituras del portal cliente sin lock (hojas no-críticas, ventana menor).

### 🔵 BAJOS
- B1-WH. Firebase apiKey en sw.js/app.js (pública por diseño; verificar restricción por dominio).
- B2-WH. `crearListaSombra` falla en silencio → pedido CONFIRMADO sin lista sombra y nadie se
  entera (ClientePortal.gs:288). Loguear/alertar.

### ✅ Verificado OK (WH)
Cobertura `_conLock` completa en Guías/Envasados/Productos/Pickups (salvo A1-WH) · `_conLock`
reentrante correcto · router POST=body · TZ Lima server-side (appsscript.json) · codigoBarra
texto ('@' + filas por nombre) · preingresos con lock+dedup, tarifa de cargador NO reintroducida ·
portal aísla por token (salvo M1-WH) · service_role/PrintNode keys solo en Script Properties ·
guard anti-DELETE-total Supabase · dedup idempotente por localId.

---

## 📋 PLAN DE REMEDIACIÓN PRIORIZADO (definitivo)

> Conteo total: **6 CRÍTICOS · 16 ALTOS · ~25 MEDIOS · ~20 BAJOS**. Los críticos comparten un
> tema: **la migración replicó la funcionalidad pero no todas las defensas** (locks, validaciones
> server-side, reconvergencia). Cada lote = un deploy con su revisión 20× + bump SW.

### LOTE 1 — Dinero que puede descuadrar HOY (urgente)
1. **ME GAS — lock único del flujo de cobro de créditos** (C1+C2+C3-GAS): ScriptLock abarcando
   confirmarCobroAsignado → cobrarCreditoConExtra → transición COBRADO; escalarCobrosVencidos
   toma el MISMO lock. + A1-GAS (sufijo aleatorio en id_extra) + A2-GAS (PATCH FormaPago).
2. **ME frontend — cobros optimistas** (C1-FE): validar respuesta de COBRAR_VENTA/ANULACION +
   guard in-flight en el merge del polling + cola con reintento. + A2-FE (lock procesarPago +
   e.repeat) + A3-FE (res.idVenta) + A4-FE (rollback por idCobro) + A5-FE (timeouts del path
   directo) + A6-FE (3 returns) + M9-FE (playError→playBeepError) en el mismo deploy.
3. **Supabase — `crear_venta_directa` endurecida** (C3+A1-Supabase): claim sub, total=Σ,
   caja ABIERTA. Está en producción fleet-wide.

### LOTE 2 — Seguridad de superficie pública
4. **MOS — gatear el router GAS** (C1-MOS): whitelist de acciones públicas; setConfig,
   guardarTarjetaWA y escrituras de dispositivos exigen verificación server-side.
5. **Supabase — capa CPE con kill-switch server-side** (C1+C2+A2+A4+A5-Supabase): flag leído en
   RPC+Edge, payload desde DB, máquina de estados nf_*, validación de correlativo. **ANTES de
   cargar el token NubeFact.**
6. **WH — `_conLock` en crearAjuste/reconciliarStockProducto** (A1-WH) + IDOR clienteEstadoPedido
   (M1-WH).

### LOTE 3 — Consistencia y robustez
7. MOS tarjeta WA (A1+A2-MOS: supabaseOk + no-borrar-vacíos) + shape API (A3+A4+M0a+M0b-MOS).
8. Supabase: A3 (cap historial), A6 (validaciones movimiento), A7 (printer scoping), M1 (whitelist
   exacta), M2 (zona_id), M5 (CORS).
9. ME: M7-FE (confirmarCredito), M8-FE (lsSet), M1+M2-GAS (PATCH unificado FormaPago).

### LOTE 4 — Higiene (cuando haya hueco)
10. dvh (M2-MOS), confirm() nativos (M3-MOS, M4-WH), voseo (B1/B5-MOS, B15-FE), AudioContext
    singleton (M11-FE), código muerto (M3-GAS, B2-MOS), snapshot cierre semanal (B6-MOS),
    idPedido colisionable (M3-WH), resto de bajos.

### ⚠️ Regla transversal detectada
El patrón de bug más repetido del ecosistema es **"shape de API"** (6 instancias en MOS) y
**"optimismo sin reconvergencia"** (ME cobros, WH preingresos ya corregido). Toda feature nueva
debería: (a) validar la respuesta desempaquetada, (b) tener guard in-flight en el merge de
polling, (c) pasar el grep `r\.data\.|res\.ok` antes del deploy.
