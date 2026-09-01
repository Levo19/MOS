# Manual operativo · MOS (panel de administración)

MOS es el panel web del negocio: cajas, stock, precios, créditos, personal, finanzas, dispositivos y seguridad. Lo usan los ADMIN y el MASTER. Las apps hermanas son MosExpress (ME, punto de venta de los cajeros/vendedores) y WarehouseMos (WH, almacén).

## Sesión y claves
Se entra a MOS con tu usuario y PIN. Las acciones sensibles piden la **clave admin de 8 dígitos**: son 4 dígitos de la clave GLOBAL + tus 4 dígitos personales. Esa clave autoriza anulaciones, cierres forzados, retomas de caja, extras de caja, ediciones de venta, etc., y todo queda en auditoría con tu nombre. Si el sistema dice "Clave incorrecta" revisa primero que estés escribiendo los 8 dígitos completos (global + personal), sin espacios.

## Cajas · ver el estado de las cajas
En el módulo **Cajas** ves cada caja del día por zona: cajero, hora de apertura y cierre, monto inicial, tickets, anulados, créditos, efectivo esperado y salud. Una caja ABIERTA es un turno en curso; CERRADA ya tiene arqueo. Dentro de la card puedes ver **Tickets del turno** (todas las ventas de esa caja) y **💸 Extras** (ingresos/egresos manuales registrados en esa caja, con quién los registró; puedes editarlos o eliminarlos con clave admin — eliminar es definitivo y queda en auditoría con el registro completo).

## Cajas · cierre forzado
Si un cajero dejó su caja abierta (se fue, perdió el equipo, etc.), en la card de la caja usa **Cerrar caja forzado** (pide clave admin, acción crítica). El monto final se calcula automático (inicial + efectivo de ventas + ingresos − egresos). ⚠ IMPORTANTE: los tickets **POR COBRAR** de esa caja se ANULAN con el cierre forzado — el confirm te muestra cuántos son. Si los clientes ya pagaron o van a pagar, primero cóbralos o pide al cajero retomar la caja; ciérrala forzado solo si de verdad se abandona el turno.

## Cajas · retomar caja (equipo que perdió la sesión)
Si a un cajero se le "escondió" la sesión pero su caja sigue ABIERTA en el servidor, en su equipo aparece el modal **"Tu caja sigue abierta"** con el botón **Retomar (requiere PIN admin)**. Se ingresa la clave admin de 8 dígitos (sirve la de cualquier admin o master) y la sesión vuelve con la misma caja, sin perder tickets ni movimientos. La retoma queda auditada.

## Tickets fantasma (flotante rojo del Master)
Si a un cajero se le rechaza o rescata una venta ya cobrada, al MASTER le llega un push y aparece un **chip rojo flotante "⛔ Tickets fantasma"** (abajo a la izquierda, solo cuando hay algo). Muestra monto, hora, vendedor, zona, motivo del servidor y — si fue rescatado — a qué caja/correlativo entró como POR_COBRAR. "🛟 RESCATADO" significa que el sistema ya lo re-registró solo; los demás son dinero cobrado SIN registro y hay que re-registrarlos a mano. Con **✓ Revisado** los sacas de la lista.

## Ventas y tickets del día
En **Tickets del día** (y en Finanzas) ves todas las ventas por fecha/zona con su correlativo, forma de pago y estado. Desde ahí un admin puede **anular un ticket** (clave admin; repone el stock) o **editar cliente/forma de pago** de una venta (clave admin; queda en historial). Los tipos: NOTA_DE_VENTA (ticket interno), BOLETA y FACTURA (comprobantes SUNAT vía NubeFact).

## Comprobantes SUNAT (boletas/facturas · NubeFact)
Las boletas y facturas se emiten desde ME al cobrar; MOS muestra su estado fiscal (EMITIDO, PENDIENTE, RECHAZADO). "PENDIENTE" en una boleta es normal por un rato: el reconciliador (cada 15 min) las consulta y actualiza solo. Para convertir una NOTA_DE_VENTA en comprobante se usa "Convertir" (la caja de origen debe seguir ABIERTA). Anular un CPE genera la reversa del pago y la baja del comprobante.

## Créditos y POR COBRAR
Un ticket **POR_COBRAR** es una venta de vendedor pendiente de que el cajero cobre; un **CRÉDITO** es fiado autorizado. En la **mesa de créditos** ves los pendientes por zona; un crédito cobrado queda con sello COBRADO. El cobro de un crédito se hace en ME (el cajero) o desde MOS con "cobro directo" eligiendo la caja receptora. Regla: el crédito de un trabajador se asigna al TURNO (caja abierta), nunca por nombre suelto.

## Stock por zonas y almacén
El stock vive por ZONA (tiendas) y ALMACÉN (WH). En **Zonas → (zona) → Stock** ves el stock actual por producto; el **historial/kardex** muestra cada movimiento (ventas, guías, ajustes, envasados, traslados) con saldo antes/después. El módulo **Almacén** está dentro de Zonas (o en el botón "Más" del menú inferior). Ajustar stock a mano = **Ajuste** (fija el valor contado, con motivo y usuario; queda en kardex). Si el kardex "no cuadra" con lo físico, primero cuenta (auditoría), no ajustes a ciegas.

## Reposición e insights (RIZ)
El módulo RIZ sugiere qué reponer por zona con prioridades e insights (rotación, quiebres, sobre-stock). El semáforo del pickup y los "considerados" muestran qué pidió la zona y qué está atendiendo WH en vivo (vista Zona → Pickup / 🎯 Considerados).

## Precios y costos
Los precios se publican desde el catálogo (por producto o con sugerencias). Cambiar un precio manda **push a las tablets de ME** (agrupado: una carga masiva = un solo aviso). La sugerencia de precio usa el costo FIFO + la política de margen por categoría. Los costos entran por **Compras** (guías de ingreso de proveedor); la percepción NO es parte de la base del IGV.

## Compras y proveedores
En **Compras** registras la compra por producto (paso 2 por producto). La compra aplica costo y stock al confirmar. En **Proveedores** ves historial por proveedor y productos asociados. El chip de monto muestra lo acumulado; el costo NO se cambia retroactivamente desde ahí.

## Finanzas y tributos
**Finanzas** muestra el día/rango por zona: ventas, formas de pago, extras y rentabilidad. **Tributos** calcula IGV emitido (por CPE), IGV a favor (compras con factura) y renta MYPE. El **📥 Buzón IGV** sirve para subir la foto de una factura de compra que no tuvo guía: el OCR la valida (debe estar emitida a nuestro RUC 20610714057) y suma su IGV a favor; detecta duplicadas.

## Yape / pagos virtuales
Los pagos Yape se validan contra el capturador (YapeCaptor): un Yape puede cubrir 2-3 tickets (combinación global). Si un ticket queda con Yape "pendiente de anuncio" revisa el módulo de Yapes del día.

## Personal del día y liquidaciones
**Personal del día** muestra quién trabajó (por zona), su asistencia, ventas cobradas, envasados y su liquidación (fijo + bonos − sanciones). El día se sella PAGADA/VETADA al liquidar. La base diaria es por ZONA. La meta y comisión tienen vigencia configurada. Un MEX:NOMBRE|ZONA es una identidad virtual de ME (cajero/vendedor que no está en la planilla de MOS).

## Dispositivos y seguridad
Cada equipo (tablet/celular) se registra y el admin lo **aprueba** en Dispositivos (o in-situ con clave). Un equipo inactivo 48 h se suspende solo; se reactiva desde el panel. **Extensión de horario**: cuando una tienda va a trabajar más tarde, se autoriza con clave admin (hasta hoy a cierta hora; expira sola). El "espía" es monitoreo de seguridad (ver/escuchar un equipo autorizado); las grabaciones viven en Storage.

## Notificaciones push
Los avisos llegan por push (app instalada): caja abierta, cierres, alertas de precio, buzón, tickets fantasma, Yape, resumen diario. Si a alguien no le llegan: revisar que instaló la PWA, aceptó notificaciones, y que su token esté registrado (Config → notificaciones → probar).

## Buzón Directo (reportes de admins al Master)
Botón flotante 📮: los admins crean tickets de 4 tipos — 🔧 Falla, 📊 Operativa (descuadres/conteos), ❓ Consulta, 🎓 Capacitación — con fotos/video. El Master los ve en su bandeja con badge, responde en hilo (texto y adjuntos), cambia el estado (En proceso / Resuelto) y solo el autor recibe el aviso. El botón **🤖 Sugerir respuesta** redacta un borrador con IA usando este manual y respuestas anteriores del Master; el Master siempre lo edita antes de enviar.

## Membretes y adhesivos
Los membretes (etiquetas de góndola con precio) se encolan por producto/zona y se imprimen en lote; el precio impreso es el VIGENTE del catálogo. Los adhesivos térmicos (Caserito/TSPL2) se imprimen desde WH con plantillas del editor.

## Auditoría de acciones
Toda acción con clave admin (anular, cerrar forzado, extras, ediciones, retomas, migraciones) queda en **auditoría** con fecha, quién autorizó, app de origen y detalle. Si algo "apareció cambiado", la auditoría es el primer lugar donde mirar.
