# Rediseño del Módulo Configuración — MOS · Documentación de implementación (VIVA)

> Doc de trabajo (para el implementador — no es para mostrar). Objetivo: **no olvidar NINGÚN
> requerimiento, color, efecto, ícono, función o botón** al codear. Se actualiza en cada iteración.
> Mockups navegables: `scratchpad/config_modulo.html` (5→4 tabs) · `scratchpad/infra_rediseno.html`.
> Estado: **DISEÑO en revisión con el dueño**. NO codear producción hasta aprobación explícita.

---

## 0) DECISIONES DE ARQUITECTURA (dueño)
- **FUSIÓN Infraestructura + Personal → una sola pestaña zona-céntrica.** Motivo: horario, metas,
  comisiones, tarifas, auditorías, series — **todo es POR ZONA** y ya se muestra en Infra. Personal solo
  aportaba los usuarios (que son pocos). → Los **usuarios viven dentro de cada zona** (icono 👥 desplegable).
- **Tabs resultantes:** `🏗️ Infraestructura` (zonas+equipos+usuarios) · `🏷️ Categorías` · `🔔 Notificaciones` · `🏦 Bancarios`. (Personal deja de ser tab propia.)
- **Ciclo de vida de dispositivos** (auto-declutter): En línea (<5min) → Inactivo (<2d) → **Suspendido (2d sin uso, auto)** → **Archivado/Cancelado (7d sin uso, auto, sale de la vista)**. Cancelado ≠ bloqueado: reactivable, reabre solo si el equipo reconecta. Umbrales 2d/7d **por confirmar**.
- **Todo clickeable/editable in-situ**: dispositivos y usuarios se abren desde la zona (no hay que ir a otra pantalla).
- **Full responsive** mobile/tablet/PC (Android/iOS/Windows), intuitivo.
- **Nada se pierde**: cada botón/función actual debe existir en el rediseño (ver §5 inventario).

---

## 1) SISTEMA DE DISEÑO (tokens)
**Paleta (navy MOS):**
- `--bg:#070e1c` · `--surf:#0d1f3a` · `--line:#1c2b45` · `--line2:#26375a`
- Tinta: `--ink:#eaf1fb` · `--ink2:#9fb2ce` · `--ink3:#5f7290`
- Marca/interactivo: `--brand:#4aa8ff` · secundarios `--gold:#f5b849` · `--viol:#a78bfa`
- **Semántica de estado** (separada del acento): en línea `--on:#10b981` (glow `rgba(16,185,129,.55)`) · inactivo `--idle:#f5b849` · suspendido `--susp:#f97316` · archivado `--arch:#64748b` · alerta `--alert:#ef4444`
- **App:** ME `--me:#7dd3fc` · WH `--wh:#fbbf24` · MOS `--mos:#c4b5fd`
- Radio base `--r:16px`. Fondo con 2 radial-gradients navy (arriba-der + izq).

**Tipografía:** system stack (`ui-sans-serif,system-ui,Segoe UI,Roboto`) + mono (`ui-monospace,SF Mono,Menlo`) para IDs/correlativos/latencias. Números con `font-variant-numeric:tabular-nums`. Labels uppercase con letter-spacing .08–.12em.

**Efectos/animaciones:**
- `pulse` (2.4s) en el punto “en línea”. `breathe` (3s, opacity .5↔.95) en el halo verde de equipos online.
- Hover cards: `translateY(-3px)` + borde `--brand`. Botones: `scale`/`translateY(-1px)`.
- `fade` (.25s) al cambiar de tab. **Respetar `prefers-reduced-motion:reduce` → apaga todo.**
- Tab activa: gradiente `#68b6ff→#4aa8ff`, texto `#04121f`, sombra azul.

**Responsive (breakpoints):**
- `≤860px`: estaciones y grids a 1 columna.
- `≤600px`: tabs con scroll horizontal (no wrap, sin scrollbar), cmd-right full width, equipos 2-por-fila (`calc(50%-6px)`), ciclo de vida en columna (flecha `↓`), notas 1 col, prow wrap.
- `601–900px`: equipos 120px.
- Todo con `flex-wrap` + `grid auto-fill minmax()`; nada de anchos fijos que rompan.

---

## 2) DISPOSITIVOS DIBUJADOS (el dueño los ama — conservar)
Silueta CSS por tipo (NO emoji), tipo detectado del **User_Agent** (no del nombre):
- `phone` 64×104 con notch · `tablet` 90×102 · `laptop` tapa+base · `pc` monitor+pie.
- La “pantalla” (`.face`) muestra: avatar con inicial (color por persona) + nombre usuario + micro-estado (“en caja”, “envasando”, “MASTER”).
- **Online:** `.halo` verde que respira + pill `● live`/`🔴 live`. **Suspendido:** `filter:grayscale(.85)` + pill naranja + `.lastchip` “🕘 último: X · hace Nd”. **Inactivo:** pill ámbar `◐`.
- Badge de app arriba-der (ME/WH/MOS). Caption: `nombre · rol · hace X` (**rol siempre visible**, color por rol).
- **Botones de monitoreo por equipo (hover/inline):** ver §5. Card entera clickeable → editar.

**Detección tipo (User_Agent):** `/Mobi|Android|iPhone/`→phone · `/iPad|Tablet/`→tablet · `/Macintosh.*Safari|laptop|notebook/`→laptop · resto→pc. (Hoy usa el nombre → frágil; migrar a UA.)

**Roles (badge color):** master `#fcd34d` · cajero `#7dd3fc` · vendedor `#8fd0ff` · almacenero/envasador `#fdba74`.

---

## 3) PESTAÑA 1 · INFRAESTRUCTURA (fusionada con Personal)
Orden: **Command bar → Acciones → Zona VIP → Pendientes → Zonas → Ciclo de vida/Archivados.**

### 3.1 Command bar
Contadores en vivo: `en línea` (punto que late) · `dispositivos` · `zonas` · `estaciones`. Derecha: buscador (persona/equipo) · toggle `⏸ suspendidos` · toggle `🔥 heatmap` (antes suelto).

### 3.2 Acciones (los 8 botones sueltos, AGRUPADOS)
- **Impresión:** 🔧 Calibrar impresora (`MembreteSystem.abrirCalibrador`) · 📋 Lotes de impresión (`MembreteSystem.abrirHistorialLotes('')`) · 🚨 Alertas de precio (`MembreteSystem.abrirAlertasPrecio`)
- **Operación:** 🌙 Cierre nocturno (`abrirCronStatus`) · 🗺 Proyección (`abrirProyeccion`) · 🔐 Auditoría admin (`abrirAuditoriaAdmin`)
- **Marca:** 🎨 Editor de avisos (`abrirEditorAdhesivos`) · 📇 Tarjeta / WhatsApp del QR (`abrirTarjetaModal`)
- (extra del header Personal a reubicar: 🔔 notif · 🛡️ integridad `abrirModalIntegridad`)
- Nota PrintNode: “Las API keys viven en Script Properties; aquí solo los PrintNode IDs.” (conservar).

### 3.3 Zona VIP · Admins & Master (dorada)
- `_renderInfraPremium` — dispositivos MOS del panel. Contadores: online/activos/off.
- **Fusión Personal:** aquí van los **admins como usuarios** (Luis MASTER, Javier ADMIN) con: estado (🟢/🔴 inactivo Nd) + **última acción** (“03:55 pm · COBRAR_VENTA · V-...”) + botones 💬 📜 🔑 ✏️ 🕐 (ver §5).
- Los 20 Desktop MOS muertos → **archivado**.

### 3.4 Pendientes (esperando aprobación)
Card roja. Cada uno: equipo dibujado + nombre + `nº id8` + app + **`👤 solicita: <Ultima_Sesion> · hace Xs`** (ya implementado, SQL 512) + `✓ Aprobar` (`aprobarDispositivo`) · `✎` (`aprobarDispositivoConNombre`) · `✕` (`rechazarDispositivo`).

### 3.5 Zona (card) — TODO lo de la zona en un lugar
**Header:** ícono 🏬/🏭 · nombre · chip `N en línea` · **chip app** (🛒 MosExpress / 🏭 warehouseMos) · **chip horario** (🕐 07:00–19:00 · dom 16:00) · `zid` mono · toggle activa (`toggleZonaActiva`) · ✏️ editar (`abrirModalZona`).
**Fila Series DCPE:** chips NOTA_VENTA/BOLETA/FACTURA con serie+correlativo (`abrirModalSerieZona`) + “+ serie”.
**Fila Política (todo POR ZONA):** 💰 Meta venta /día · 🎯 Comisión % excedente · 📋 Auditorías /día · **🕐 Horario** (L-S/Dom, con “👑 admins libres · actualizado por X · ⚙ Editar”). Almacén: 💵 Envasado /und · 📦 Meta guías · 📋 Auditorías. (Se editan vía ✏️ zona / ⚙ Editar horario.)
**Estaciones (grid):** cada estación 🛒/🏭 · nombre · app badge · `idEstacion` · toggle (`toggleEstacionActiva`) · ✏️ (`abrirModalEstacion`).
  - **Impresoras:** ícono 🖨️/🏷️/📄 · nombre · **estado PrintNode (11 diagnósticos:** ONLINE 🟢 · PC_OFFLINE 🔌 · PRINTER_OFFLINE · SIN_PAPEL · SIN_TINTA · ATASCO · TAPA_ABIERTA · PAUSED · DISABLED · ERROR · SIN_ID · ID_INVALIDO ❓) · `PN <id> · TIPO · MODELO` · toggle (`toggleImpresoraActiva`) · ✏️ (`abrirModalImpresora`). + impresora.
  - **📱 Equipos en esta estación:** equipos dibujados (§2) con monitoreo (§5). Trails “📍 movido” cuando un equipo cambia de estación (animación fantasma 5s).
  - + estación a esta zona (`abrirModalEstacion(null,zona)`).
**👥 USUARIOS de la zona (NUEVO — absorbe Personal):** icono/acordeón que despliega los usuarios registrados de esa zona (cajeros/vendedores en POS; almaceneros/envasadores en almacén). Cada usuario = card compacta (avatar+inicial, nombre, **rol color**, estado 🟢/🟡/🔴 + hace X, pago S/./día si aplica, aud x/30, ventas semana). **Al click → despliega moderno sus botones** (§5): 🕵️ espía · 💬 push · 📜 historial · 🔑 permisos/clave · ✏️ editar · 🕐 horario · toggle activo. + agregar usuario a la zona (`abrirModalPersonal`).

### 3.6 Sin zona asignada (usuarios) — grupo aparte, tenue
Los cajeros “🔒 bloqueado / ⚫ sin sesión” (ej. Orlando, Carlos). Card + 🕵️ 💬 · muestran 0d · 0/0 aud · S/0.00. (Como el “🌫 Sin zona asignada · 3 cajeros” real.)

### 3.7 Ciclo de vida + Archivados
Diagrama de 4 pasos (§0). `<details>` “🗄️ Archivados (138)” colapsado = reemplaza “Sin estación asignada (118)” + admins viejos (20). Cada uno: silueta gris + nombre + `nº · último · hace Nd` + `↻ reactivar`. + nueva zona.

---

## 4) OTRAS PESTAÑAS
### 4.1 🏷️ Categorías (`renderCategorias`)
Tarjetas por categoría: nombre · **modo de venta** (margen % / precio tope) · nº productos · ✏️ (`abrirModalCategoria`) · 🗑️. + nueva categoría. Conservar gate de auth admin (overlay “⛔ Operación bloqueada” con contexto: usuario/idSesión/dispositivo/app/plataforma/hora) que aparece si falla la clave.

### 4.2 🔔 Notificaciones (`renderNotifsPanel`)
Tarjeta por evento: ícono · nombre · **prioridad** (🚨 ALTA / MEDIA, `_notifSetPrioridad`) · descripción · toggle activa (`_notifToggleActiva`) · expand (`_notifToggleExpand`). Controles: 👥 Audiencia por rol (`_notifToggleRol`) · ➕ Usuarios extra (`_notifSetExtra`) · ⚡ Prioridad · 🚫 Excluir origen (`_notifSetExcluir`) · 🔕 Silenciar temporal (`_notifSilenciar`) / ↺ Quitar silencio · ↺ Restaurar default (`_notifRestaurarDefault`) · 🧪 Probar a mí (`_notifProbar`) · 🔄 Reenviar (`_notifReenviar`). Mostrar “✓ N entregadas · último ok hace X”. Chips de rol (audiencia) + extra.

### 4.3 🏦 Bancarios (`renderBancarios`)
- **Cuentas** (`bancAgregar`/`bancQuitar`/`bancSet`/`bancGuardar`): banco · moneda · nº cuenta · CCI · **QR** (📷 `bancSubirQR`) · ✏️/🗑️.
- **Facturación CPE** (`facGuardarConfig`/`facGuardarSeries`/`facAlinear`): RUC emisor · razón social · proveedor (NubeFact) · **series por documento** (Boleta B001/Factura F001/Nota NC01 + correlativo) · 🖨 Alinear impresión · 💾 Guardar config · 💾 Guardar series.

---

## 5) INVENTARIO DE BOTONES/FUNCIONES (100x — NADA se pierde)
**Tabs:** `setCfgTab('infra'|'categorias'|'notifs'|'bancarios')` · `refresh` (↺).
**Infra sueltos (8):** ver §3.2. **Header:** 🔥 `infraToggleHeatmap` · 🔔 notif · 🛡️ `abrirModalIntegridad`.
**Zona:** `abrirModalZona`(+/editar) · `toggleZonaActiva` · `abrirModalSerieZona` · ⚙ Editar horario.
**Estación:** `abrirModalEstacion`(+/editar) · `toggleEstacionActiva`.
**Impresora:** `abrirModalImpresora`(+/editar) · `toggleImpresoraActiva`.
**Dispositivo (equipo):** 🛡️ `abrirDetalleDispositivo` (permisos/acciones) · 🕵️ `abrirEspiaDispositivo` (espía clásico audio+GPS) · 🛰️ `abrirEspiaV2` (WebRTC live, **solo master**) · 📼 `abrirTimelineBufferEspia` (12h, **solo master**) · ✏️/card `abrirModalDispositivo` (editar).
**Usuario (persona):** 🕵️ `abrirEspiaPorUsuario` · 💬 `abrirModalEnviarPush` · 📜 historial · 🔑 permisos/clave · ✏️ `abrirModalPersonal`(+/editar) · 🕐 horario individual · toggle `toggleVendedorME` · meta inline `guardarMetaChip`.
**Pendientes:** `aprobarDispositivo` · `aprobarDispositivoConNombre` · `rechazarDispositivo` · (identidad `identificar_solicitante`, SQL 512).
**Categorías:** `abrirModalCategoria` · `auditResolver` (gate).
**Notifs:** `_notifToggleActiva/_notifToggleExpand/_notifToggleRol/_notifSetExtra/_notifSetPrioridad/_notifSetExcluir/_notifSilenciar/_notifRestaurarDefault/_notifProbar/_notifReenviar`.
**Bancarios:** `bancAgregar/bancQuitar/bancSet/bancGuardar/bancSubirQR` · `facGuardarConfig/facGuardarSeries/facAlinear`.
**Tarjeta:** `abrirTarjetaModal` (WhatsApp QR clientes/proveedores).

---

## 6) BACKEND NECESARIO (nuevo)
- **Cron ciclo de vida** (pg_cron): `ACTIVO/INACTIVO` con `ultima_conexion < now()-2d` → `SUSPENDIDO`; `< now()-7d` → `CANCELADO_AUTO`. NO tocar con sesión abierta. (Hoy solo caduca pendientes >20h.)
- **Detección de tipo por User_Agent** (frontend) para dibujar el equipo correcto.
- (Ya hecho: `identificar_solicitante` SQL 512, buzón muestra quién pide.)

## 7) DECISIONES ABIERTAS (confirmar con dueño)
1. Umbrales ciclo de vida 2d/7d.  2. Zona VIP: ¿dorada arriba o zona normal? 3. Heatmap: ¿se mantiene?
4. Nombre de la pestaña fusionada (¿“Infraestructura”, “Zonas”, “Operación”?).  5. ¿Profundizar Categorías/Notifs?

## 8b) ITERACIÓN 2 — hallazgos verificados + nuevos requerimientos (2026-07-18)
**Series (VERIFICADO en prod):**
- `mos.series_documentales` = series POR ZONA (col `id_zona`, `tipo_documento`, `serie`, `correlativo`), **incluye `MOS-VIP` como zona**. Datos: ZONA-01 NV01/BBB1/FFF1 · ZONA-02 NVa2/BBB1/FFF1 · ALMACEN BBB1/FFF1 · MOS-VIP BBB1/FFF1.
- `fac.series` (contador CPE real, cols serie/tipo/correlativo/activa) + `fac.serie_de_zona(zona,tipo)` (SQL 322) → la emisión CPE **ya escoge serie por zona**. `fac.comprobantes.app` ∈ {mosExpress, MOS} → **VIP (MOS) también emite CPE**.
- **HOY = demo**: todas las zonas comparten BBB1 (boleta) / FFF1 (factura); solo NV difiere. A futuro cada zona (incl. VIP) su propia serie real. La arquitectura ya lo soporta.
- **BUG datos:** `mos.series_documentales` tiene FILAS DUPLICADAS (ZONA-01/02 boleta/factura/NV repetidas) → **deduplicar** al implementar.

**ADMINS DUAL (ascenso `acceso_mos`) — CRÍTICO:**
- Un operador ascendido (ej. **Jorgenis** OP001, ALMACENERO + `acceso_mos=true`) tiene **DOBLE presencia**: aparece en su zona real (Almacén, como almacenero, cobra como almacenero) **Y** en la Zona VIP/Admins (acceso al panel MOS). El rol REAL queda intacto (pago/asistencia); el efectivo es ADMIN. → En el mockup mostrarlo en ambos, con etiqueta “ascendido · rol real: almacenero” en VIP. Ver [[architecture_clave_admin_acceso_mos_y_extension_remota]].

**ZONA VIP (MOS) — completar:**
- Le faltaba el **chip de app: 🖥️ MOS** (agregado). VIP **hace facturación** → mostrar su fila **Series DCPE** (BBB1/FFF1, demo-compartida) + que emite CPE. VIP = zona con su propia serie, igual que zona1/zona2.

**MODALES (nuevo requerimiento):** CADA modal que abre CADA botón también debe rediseñarse (mismo lenguaje visual). Inventario de modales a rediseñar (por botón §5):
- Zona: modalZona (crear/editar zona + política + horario + vigencia). Estación: modalEstacion. Impresora: modalImpresora. Serie: modalSerieZona.
- Dispositivo: modalDispositivo (editar) · abrirDetalleDispositivo (permisos/acciones) · espía (audio+GPS) · espíaV2 (WebRTC) · timeline buffer.
- Usuario: modalPersonal (crear/editar) · enviarPush · integridad · historial · permisos/clave · horario individual.
- Acciones: calibrador · editor de avisos · alertas precio · lotes · cronStatus (cierre nocturno) · auditoríaAdmin · proyección · tarjeta WhatsApp.
- Categoría: modalCategoria (+ gate auth con contexto). Notif: expand/audiencia/prioridad/etc. Banco: modal cuenta + subir QR. Fac: config + series + alinear.
- **Regla:** modales con tokens §1, botón primario claro, cierre visible, responsive, sin `alert/confirm/prompt` (usar modales optimistas modernos — ver [[feedback_modales_optimistas_modernos]]).

**FUSIÓN Personal (implementada en mockup):** usuarios dentro de cada zona (`<details>` 👥 → cada usuario `<details>` → acciones). Sin-zona = grupo tenue. Admins en VIP. Tabs: 4.

## 8c) FACTURACIÓN / CORRELATIVOS (VERIFICADO en prod — corrección crítica)
- **Correlativo VIVO = `me.correlativos` (= `public.correlativos`)**, keyed por SERIE (no zona): NV01→1631 (Zona01 nota venta), NVa2→2127 (Zona02), NV02→324, **BBB1→421 (boleta, COMPARTIDA)**, FFF1→43 (factura, compartida), B001→2 (vieja), CAJA→timestamp.
- **`fac.series`** (nuevo contador CPE cero-GAS) = B001/F001/BBB1/FFF1 en **0 · go-live PENDIENTE** (`fac.comprobantes` VACÍO). La migración fac.* está inerte.
- **Quién factura:** ME cajas (NV con serie de su zona + boleta/factura BBB1/FFF1) → CPE NubeFact vía `fac.emitir_cpe`. **MOS (panel/VIP) convierte NV→CPE** (`MOS_CONVERT_NV_DIRECTO`+`FAC_CPE_DIRECTO`). **ALMACÉN NO FACTURA** (no vende → sin serie ni correlativo).
- **BUGS a corregir al implementar:** (1) `mos.series_documentales` tiene fila **ALMACEN** (boleta/factura) que NO debe existir. (2) filas DUPLICADAS ZONA-01/02. (3) VIP/MOS comparte BBB1/FFF1 (demo) — a futuro serie propia.
- **En el mockup:** Almacén = sin Series DCPE ni facturación (corregido). Bancarios muestra series por zona con correlativo real; Almacén marcado “sin facturación”.
- Ver [[architecture_fac_cpe_centralizado]] · [[project_facturacion_nubefact]] · [[architecture_me_clientes_frecuentes_keys]].

## 8d) SPEC DE MODALES (a rediseñar — campos por modal, para implementación idéntica)
Cada modal: tokens §1, header con ícono+título, cuerpo con `.field` (label uppercase + input), footer con Cancelar + botón primario claro, cierre visible (×/Esc), **responsive** (full-width en mobile), **sin alert/confirm/prompt** (modales optimistas: sonido+visual+háptico). Campos por modal:
- **modalZona:** nombre · dirección · responsable · **app de la zona (ME/WH/MOS)** · estado · política {meta S/·comisión %·auditorías/día · almacén: tarifa envasado·meta guías} · **horario (apertura/cierre por día + dom)** · **vigencia de política (fecha, §509)** · series DCPE (link).
- **modalEstacion:** nombre · zona · tipo (CAJA/ALMACEN/ENVASADO) · app · estado.
- **modalImpresora:** nombre · estación · tipo (TICKET/ADHESIVO/ZPL) · **PrintNode ID** · estado (muestra diagnóstico live) · calibración (link).
- **modalSerieZona:** zona · tipo doc (NOTA_VENTA/BOLETA/FACTURA) · serie · correlativo. (Almacén NO.)
- **modalDispositivo (editar):** nombre equipo · app · zona/estación asignada · estado.
- **detalleDispositivo (🛡️ permisos):** permisos_json (chips toggle) · acciones (aprobar/suspender/reactivar/logout remoto/extender horario) · último usuario · historial.
- **espía / espíaV2 / timeline:** audio+GPS live · WebRTC (master) · buffer 12h.
- **modalPersonal (usuario):** nombre · rol REAL · app origen · **acceso_mos (ascender/quitar)** · PIN · color/foto · pago/día · zona. Acciones: espía·push·historial·permisos/clave·horario individual.
- **enviarPush:** destinatario · título · cuerpo. **integridad:** reporte. **historial:** log de acciones (COBRAR_VENTA·V-…).
- **Acciones globales:** calibrador (GAPDETECT) · editor de avisos (canvas adhesivos) · alertas precio (lista) · lotes (tabs) · cronStatus (23h + corridas) · auditoríaAdmin (registro tier) · proyección (roadmap) · tarjeta WhatsApp (nº clientes/proveedores +51).
- **modalCategoria:** nombre · modo venta (MARGEN %/PRECIO TOPE) · valor · ícono. **Gate auth** (clave admin con contexto usuario/idSesión/dispositivo/app/plataforma/hora si falla).
- **Notif (por regla):** audiencia por rol (toggles) · usuarios extra · prioridad (ALTA/MEDIA) · excluir origen · silenciar (duración) · probar · reenviar.
- **modalCuentaBanco:** banco · moneda · nº cuenta · CCI · titular · **QR (subir imagen)**. **facConfig:** RUC·razón social·proveedor(NubeFact)·token. **facSeries:** por zona. **facAlinear:** offsets impresión.

## 8e) INVENTARIO COMPLETO DE MODALES (100x vs config real — corrige §8d)
Además de los de §8d, existen (verificado por `id="modal…"` en index.html + handlers):
- Impresora: **modalCrearPN** (crear PrintNode ID). Dispositivo: **modalSelectorDispositivos**, **modalDetalleDispositivo** (permisos).
- Espía/monitoreo: **modalEspia**, **modalAudio** (audio routed), **modalAudioLive** (live), **modalGps**, **modalTimelineBuffer**.
- Notif: **modalNotificaciones** (campana `abrirModalNotificaciones`) + **modalNotifLog** (log de envíos).
- Seguridad/config global: **modalAdminAuth** (gate clave), **modalClaveGlobal** (ver/rotar PIN global 30d), **modalConfigEval** (metas/auditorías/tarifas GLOBALES de config), **modalIntegridad**, **modalHistorialAudit**.
- Otros: **modalTarjetaWA** (WhatsApp QR), **modalEcosistema** (estado ecosistema), **modalCronStatus**, **modalAuditoriaAdmin**.
- Bancarios: sección `bancariosBody` + `facConfigBody` (RUC/razón/proveedor/token) + emisión.
- Drill-downs de zona (analítica, relacionados): **modalZonaKardex/Guias/Log/Lotes/Sug/Cart/Esp/BCG** — revisar si entran al rediseño o son de otro módulo (RIZ/almacén).
- **TODOS entran al rediseño** (mismo lenguaje de modal §8d). Los 8 dibujados son la referencia de estilo; el resto se implementa igual.

## 9) DECISIONES CERRADAS (dueño, 2026-07-18)
1. Ciclo de vida **2 días → suspendido · 7 días → archivado** (aprobado).
2. Pestaña fusionada se llama **"🏗️ Infraestructura"** (engloba personal).
3. Zona VIP **dorada arriba** (aprobado).
4. **Heatmap ELIMINADO** (no se usa) — quitar `infraToggleHeatmap` + toda su lógica (`_infraHeatmapActivo`, `_heatmapColor`, botón).
5. Modales: los 8 mostrados aprobados; **el resto se rediseña dentro del plan** (misma referencia).

## 10) PLAN DE IMPLEMENTACIÓN (por fases)
> Regla transversal: cada fase → tests (rollback/dry-run para dinero), `node --check`, SW bump + `?v=`, browsercheck (0 pageerror + cero-GAS), y **actualizar esta doc**. Money-safe. Cero-GAS. Sin romper lo vivo.

**FASE 0 · Limpieza de datos (backend, money-safe, dry-run→apply)**
- Deduplicar `mos.series_documentales` (Z01/Z02 repetidas) — mantener 1 por (zona,tipo).
- **Quitar la fila ALMACEN** de `mos.series_documentales` (almacén no factura).
- Verificar `me.correlativos` intacto (NO tocar correlativos vivos). Test: series por zona correctas post-limpieza.

**FASE 1 · Ciclo de vida (backend cron)**
- `pg_cron` diario: `ACTIVO/INACTIVO` con `ultima_conexion<now()-2d`→`SUSPENDIDO`; `<now()-7d`→`CANCELADO_AUTO`. Guard: NO tocar con sesión abierta ni PENDIENTE/aprobados manualmente. Reabre solo al reconectar (ya existe). Test rollback: transiciones correctas por umbral.

**FASE 2 · renderInfra fusionado (frontend, el grueso)**
- Reescribir `renderInfra`: command bar (sin heatmap) · acciones agrupadas (Impresión/Operación/Marca + notif/integridad) · Zona VIP dorada (app MOS + series + facturación + admins-usuarios) · pendientes (👤 solicitante) · zonas (header con **app+horario chips**, series DCPE, política, estaciones→impresoras[11 estados]→**equipos dibujados** con 🛡️🕵️🛰️📼✏️, **👥 usuarios desplegables** con acciones) · sin-zona · ciclo de vida + **Archivados** (auto, reemplaza "Sin estación" 118 + admins viejos).
- Detección de tipo por **User_Agent** (dibujo correcto). Rol color en cada equipo/usuario.
- Absorber `renderPersonal` (usuarios dentro de zona; admins en VIP; ascenso dual visible). Quitar tab Personal (`setCfgTab` a 4 tabs).
- **Full responsive** (breakpoints §1). Conservar TODOS los handlers §5 (mapear 1:1).

**FASE 3 · Modales (todos, con el lenguaje §8d)**
- Rediseñar cada modal (§8d+§8e) con el shell común (header/body/`.field`/footer/× /responsive, sin alert/confirm/prompt). Prioridad por uso: Zona → Estacion/Impresora/CrearPN → Dispositivo/Detalle/Espía → Personal/Push/permisos/horario → Serie → Categoria/AdminAuth → Notif → Banco/Fac → resto (cron/auditoría/integridad/clave global/config eval/tarjeta/ecosistema).

**FASE 4 · Otras pestañas**
- Categorías (tarjetas + modo venta + gate) · Notificaciones (reglas ricas) · Bancarios (cuentas+QR + **facturación CPE con series por zona** + Almacén sin facturar).

**FASE 5 · Cierre**
- 100x vs esta doc + 100x vs config actual + browsercheck + screenshots. Deploy MOS (SW+?v=). Actualizar doc/changelog.

## 8) CHANGELOG
- 2026-07-18: doc creada. Fusión Infra+Personal (usuarios por zona). App+horario por zona. Responsive. Rol visible. Inventario 100x. Usuarios-por-zona en mockup.
- 2026-07-18 (iter 3): VERIFICADO facturación/correlativos (§8c) — Almacén SIN facturación (corregido), MOS-VIP comparte BBB1/FFF1, me.correlativos vivo, fac.series pendiente. Admins duales (acceso_mos) en VIP+zona. VIP con app MOS+CPE. Spec de modales (§8d) + galería de modales dibujada (8 principales). 100x visual con Playwright (desktop+mobile+modales, 0 pageerrors). Mockups: config_modulo.html · modales.html · infra_rediseno.html.
- 2026-07-18 (impl FASE 0): SQL 513 — Almacén fuera de mos.series_documentales + dedup (id_zona,tipo) 16→8 filas. me.correlativos intacto. Aplicado prod. cero-GAS.
- 2026-07-18 (impl FASE 1): SQL 514 — mos.cron_dispositivos_inactivos añade paso SUSPENDIDO→CANCELADO_AUTO a +7 días (excluye app MOS/''), reversible (SQL 100 reabre a PENDIENTE al reconectar). Test 5/5. Aplicado prod. Cron 9am Lima.
- 2026-07-18 (impl FASE 2 · inicio, MOS 2.43.560 @461): (1) ELIMINADO heatmap completo (botón 🔥, _infraHeatmapActivo, _heatmapColor, infraToggleHeatmap, rama en _renderInfraEstacion, export) — 0 refs. (2) NUEVA sección "Archivados" colapsable: _dispArchivados() (CANCELADO*), toggleArchivados(), _archExpandido; equipos en gris + badge app + "inactivo Nd" + ↺ Reactivar (reusa aprobarDispositivo, cero-GAS). Fix: _dispMoviles() excluye CANCELADO* (antes un archivado sin estación salía como "móvil"). Verificado browsercheck con device de prueba reactivado: 7 zonas, heatmap ausente, Archivados OK (MOS panel/MosExpress, Cabanossi), responsive sin overflow (390px). Screenshots: f2_infra.png · f2_arch.png.
- 2026-07-18 (impl FASE 2 · chips app+horario, MOS 2.43.561 @462): NUEVO _zonaAppChips(z) en el header de cada zona: chip de APP (derivada: Almacén→🏭 warehouseMos, resto→🛒 mosExpress; Premium→👑 MOS aparte) + chip de HORARIO de HOY en TZ Perú (apertura→cierre / "cerrado hoy", con _horarioHoyTxt via Intl America/Lima). Ambos clickeables → abrirModalHorarioApp(app). renderInfra carga horarios una vez (_cargarHorariosApps, cache 5min). BUG FIX (destapado por screenshot): _renderInfraSeries ahora retorna '' para Almacén (antes ofrecía "+ NOTA_VENTA/BOLETA/FACTURA" en una zona que no factura). Verificado browsercheck real: Almacén "🏭 Almacén · 07h→19h" sin series; Zona 01 "🛒 MosExpress · 06h→23h" CON series (NV01/BBB1/FFF1) + política + estaciones. Sin overflow (390px). Screenshots: f2_zona.png · f2_verify.png. Bump in-app V (estaba 2.43.555).
- 2026-07-18 (impl FASE 2 · fusión usuarios-por-zona, MOS 2.43.562 @463): cada zona de Infraestructura tiene bloque 👥 "Usuarios de la zona" desplegable (colapsado; estado _zonaUsrExpand, toggleZonaUsuarios). Almacén→operadores WH (cards reales _renderPersonaCard con espía/push/historial/toggle/editar/horario); zonas POS→cajeros ME por nombre (_renderCajeroCard con espía/push/toggle bloqueo). REFACTOR DRY (sin duplicar): extraídos del closure de _cfgRenderMeCajeros → módulo _cfgCajerosData() (agrupa cajeros por zona vía device Ultima_Zona) + _renderCajeroCard() + _normNombre(); ambos usados en Personal Y en la fusión. Verificado browsercheck: Almacén 👥=4 operadores expandidos con todos los botones; pestaña Personal intacta (6 person-cards, admins/vendedores/operadores, listMeCajeros OK), 0 pageerror, sin overflow. Screenshot: f2_fusion.png · f2_personal.png. Nota: admins/master van en la zona Premium (pendiente sumarlos ahí como usuarios).
- 2026-07-18 (impl FASE 2 · admins en Premium, MOS 2.43.563 @464): Zona Premium suma bloque 👥 "Administradores" desplegable (adminsMOS via _renderPersonaCard app MOS: push/historial/🔑 clave global/toggle/editar/horario, SIN espía). Rol visible. Cierra la fusión: Premium(admins)+POS(cajeros)+Almacén(operadores) muestran usuarios. Verificado browsercheck: Premium 👥=2 (JV ADMIN, LV MASTER). Screenshot f2_premium.png.
- 2026-07-18 (impl FASE 2 · declutter botones, MOS 2.43.564 @465): los 7 botones sueltos del top de Infra (Calibrar/Editor avisos/Alertas precio/Lotes/Cierre nocturno/Auditoría admin/Proyección) agrupados en <details> nativo "🛠 Herramientas y diagnóstico" (colapsable sin JS, colapsado por defecto; CSS scoped .cfg-tools con caret ▸ rotatorio). Verificado browsercheck: 7 botones dentro del details, 0 pageerror, sin overflow. Screenshot f2_tools.png.
- 2026-07-18 (impl FASE 2 COMPLETA · fusión 5→4 tabs, MOS 2.43.565 @466): pestaña Personal ELIMINADA (tabs: Infraestructura/Categorías/Notificaciones/Bancarios). Reubicado sin pérdida: "+ usuario" por zona (+operador/+cajero/+admin → abrirModalPersonal); metas de Almacén EDITABLES desde Infra (_renderMetaChip inline → guardarMetaChip, +refresh Infra); chip horario 👑 MOS en Premium; hook renderPersonal→renderInfra si vista activa (altas/ediciones aparecen en zonas 👥). Panel #cfgPanelPersonal oculto en DOM (background para guardarMetaChip; setCfgTab usa guards if(btn)/if(panel) → seguro). Verificado browsercheck: 4 tabs, personalTab=false, 4 botones +usuario, metaAlmEditable=true, 0 pageerror, sin overflow. Screenshot f2_tabs.png. **FASE 2 CERRADA.**
- 2026-07-18 (FASE 3 · AUDITORÍA): los modales de config (modalZona/Estacion/Impresora/Personal/Categoria/CrearPN…) YA usan el shell común: `.modal-backdrop`+`.modal-box`, header ícono+título+subtítulo+`.modal-close-x` ×, cuerpo con `.pers-section`/`.lbl`/`.inp`, footer Cancelar+primario, backdrop-click (_validBackdropClose), responsive (max-width/max-height 92vh). modalZona ya trae política+vigencia (§509). **Sin alert/confirm/prompt en config** (grep: 12 matches = 11 comentarios/PWA install-prompt + 1 confirm() nativo REAL en path emisión SUNAT 43775, FUERA de config). ⇒ Fase 3 NO es reescritura: es verificación visual modal-por-modal + pulido de inconsistencias puntuales. Pendiente: barrer los ~30 modales de config abriéndolos en browsercheck, corregir los que difieran del lenguaje, y (opcional) migrar el confirm() SUNAT a _modalConfirm.
- 2026-07-18 (FASE 3 impl, MOS 2.43.566 @467): migrado el ÚNICO confirm() nativo real (SUNAT ≥S/2000 EFECTIVO, facEmitir) → _modalConfirm ⇒ 0 diálogos nativos en TODA la app. modalCategoria: header con ícono 🏷️+subtítulo (uniforma). Verificados en vivo modalZona/Personal/Categoria/Estacion: shell común OK.
- 2026-07-18 (FASE 4 AUDITORÍA): las 3 pestañas restantes YA modernas (verificado browsercheck): Categorías (cards ícono+MARGEN%+estado), Notificaciones (filtros app/estado + cards con toggle por evento), Bancarios (medios de cobro Yape/Plin/cuenta + límite bancarización S/2000). Sin overflow. No requieren rediseño. Facturación por zona = las series DCPE que ya viven como chips en cada zona de Infra (Almacén sin series). fac.series/CPE en 0 (go-live aparte).
- 2026-07-18 (FASE 5, MOS 2.43.567 @468): ELIMINADA sección 'Sin estación asignada' (movHTML) — pedido del usuario. Removidos helpers huérfanos _dispMoviles + _renderDispositivoChip (solo los usaba movHTML). 0 código muerto/duplicado en lo tocado (helpers de fusión únicos; renderPersona closure eliminado; heatmap 0 refs). Verificado Infra 6 zonas, 0 pageerror.
- **REDISEÑO CONFIG COMPLETO** (Fase 0-5). GAS pendiente FUERA de config (pase dedicado facturación-ceroGAS): tribResumenMes (prefetch boot módulo tributario), getHorariosApps/getAuditoriaAdmin (verificar gate _MOS_POST_DIRECTO).

- 2026-07-18 (RECONSTRUCCIÓN REAL, MOS 2.43.569 · git 7abf021): tras crítica del usuario (6 puntos: lo entregado era parche sobre skin viejo, no el mockup), se BOTÓ el render viejo de Infraestructura y se reconstruyó fiel a config_modulo.html: tabs píldora (+personal) · acciones agrupadas Impresión/Operación/Marca (Tarjeta WhatsApp incluida, ya no al fondo) · cmd bar con 🔎 buscador + ⏸ filtro suspendidos · VIP con series DCPE compartidas + fleet SOLO activos/susp≤7d + 👥 admins .ucard desplegables + ascendidos accesoMos (Jorgenis ASCENDIDO→ADMIN con rol real y ⬇ quitar acceso) · zonas .zone/.schip/.pchip/.station/.printer con equipos dibujados (cara usuario·rol, cap equipo/usuario·tiempo, ↻ reactivar en susp) · usuarios .ucard por zona (match id O nombre de Ultima_Zona) · cajeros sin zona · ciclo de vida 4 pasos · 🗄️ Archivados = INACTIVO+CANCELADO+susp>7d. <details> persisten al poll (_cfgOpen). CSS mockup scopeado #cfgPanelInfra/.cfgtabs. Verificado screenshot 390+1280 CONTRA el mockup (no solo "renderiza"). DEPLOY = git push (GitHub Pages), clasp solo para backend .gs.
- PENDIENTE (honesto): (a) modal Editar usuario compacto del mockup (modales.html) — modalPersonal sigue con el diseño anterior; (b) restyle de contenido de Categorías/Notificaciones/Bancarios al lenguaje .group/.catcard/.notif del mockup; (c) borrar FÍSICAMENTE el código GAS inerte de api.js (directriz cero-rastro); (d) resto de la galería de modales.
- 2026-07-18 (MODALES + CERO-GAS, MOS 2.43.570 · git d230128): (1) shell global de modales al lenguaje de modales.html — los ~92 modales modernizados vía CSS .modal-backdrop (navy, labels uppercase, inputs compactos, primario azul, footers wrap móvil); (2) modalPersonal al mockup: ascenso toggle-row dorado 🏆 acceso_mos + ACCIONES RÁPIDAS 🕵️💬📜🔑🕐 (solo editar, persQuickWrap); (3) GAS BORRADO de lecturas: _conFallbackMOS(directo) sin thunk GAS (64 call-sites limpiados por balanceador), warmup ping GAS eliminado, comentarios sincerados. Browsercheck flujo completo: "✅ CERO fetches a GAS". GAS restante SOLO dual-write por diseño (pedidos/pagos/gastos, fuera de config — migración aparte con RPCs propios).
- 2026-07-18 (3 PESTAÑAS + PRESENCIA, MOS 2.43.574 · git 263fb4e): Categorías (cmd+buscador+catcards; FIX colisión .cm calibrador→.cdesc) · Bancarios 2 bloques (medios de cobro con handlers reales + series CPE por zona de mos.series_documentales, Almacén sin facturación, VIP NV→CPE) · Notifs con tokens unificados. ⚡ PRESENCIA Supabase Realtime: canal 'ecos-presencia' (presence key=deviceId) sobre el WS existente — en línea AL SEGUNDO en config, chip "⚡ en vivo", contrato para ME/WH ({deviceId,nombre,rol,app}). GAS restante detectado: getProductosNuevosWH (gate WH_REGISTRAR_PN_DIRECTO no existe en config → RPC OFF → GAS): cutover WH pendiente con nombre. PENDIENTE: ME/WH anunciarse al canal de presencia (deploy de cada app).
