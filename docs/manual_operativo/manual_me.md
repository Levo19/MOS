# Manual operativo · MosExpress (ME, punto de venta)

MosExpress es la app de las tiendas: la usan CAJEROS (cobran y cierran caja) y VENDEDORES (emiten tickets POR COBRAR). Corre en tablets/celulares como PWA instalada.

## Entrar a trabajar (wizard)
Al abrir la app: elegir tu nombre → zona → caja/impresora → monto inicial (cajero). Con eso se abre tu CAJA del día y sale el ticket de bienvenida. Un vendedor entra igual pero sin caja (vende POR COBRAR). Regla: **una sola caja por zona**; si ya hay cajero activo, entras como vendedor. Si hay una **actualización pendiente**, la app se actualiza ANTES de dejarte abrir el turno (espera unos segundos y reintenta).

## Vender
Escanea o busca el producto → carrito → COBRAR → forma de pago (EFECTIVO, VIRTUAL/Yape, MIXTO, CRÉDITO con autorización, o POR COBRAR si eres vendedor). El ticket se imprime al confirmar. Para boleta/factura elige el tipo de documento y los datos del cliente; el comprobante se emite a SUNAT solo (si sale "en proceso de envío", se regulariza en minutos). El granel se vende por peso (kg) al precio del catálogo.

## POR COBRAR y cobros asignados
Los tickets de los vendedores quedan POR COBRAR hasta que el cajero los cobra (lista de la caja, o el aviso de "cobro asignado" que suena en la pantalla del cajero). Al cobrar eliges la forma de pago real. Si la caja cierra con POR COBRAR pendientes, se ANULAN — cóbralos antes del cierre.

## Movimientos extra (ingresos/egresos)
El botón de movimientos registra plata que entra o sale de la caja fuera de las ventas (pago a proveedor, gasto, ingreso). ⚠ NUNCA registres "el cierre" como egreso: el cierre YA descuenta lo que entregas — registrarlo además lo resta DOS veces y la caja sale negativa. Si un egreso dejaría la caja en rojo, la app te avisa con el monto exacto.

## Cerrar caja (Ticket Z)
Al cerrar: la app calcula el arqueo real (inicial + efectivo + ingresos − egresos), muestra el resumen y — al confirmarse el cierre en el servidor — imprime el Ticket Z. Si el Z sale con el aviso "RESUMEN PARCIAL · LA CAJA SIGUE ABIERTA" es que el cierre aún no aterrizó: no entregues caja con ese papel, espera el definitivo. El cierre también descuenta el stock vendido y genera la guía de ventas del día.

## Sesión "escondida" / retoma
Si la app vuelve al inicio pero tu caja seguía abierta, aparece **"Tu caja sigue abierta"**: con **Retomar (PIN admin)** un admin/master pone su clave de 8 dígitos y recuperas TODO el turno. Nunca abras una caja nueva si el modal te ofrece retomar, salvo que el admin lo decida.

## Tickets fantasma y rescate
Si una venta ya cobrada no se pudo registrar (se cayó la red y luego la caja original cerró), la app la **rescata sola**: entra como POR COBRAR a la caja abierta de la zona y avisa con "🛟 Ticket rescatado". Si no hay caja abierta, queda EN COLA y se registra al abrir una. El banner rojo "ventas rechazadas" lista las que necesitan revisión del admin (muestra el motivo del servidor); el Master también las ve en MOS.

## Ventas sin señal (offline)
Sin internet la venta se imprime con correlativo LOCAL y queda en cola; al volver la señal se sincroniza sola con su correlativo definitivo. No borres datos de la app con ventas en cola.

## Guías de zona (mercadería)
Desde Guías registras ingresos/salidas de mercadería de tu zona (traslados, devoluciones, recepción del almacén). Una guía manual nace ABIERTA (solo papel) y el stock se aplica al CERRARLA. Las líneas de una guía se pueden editar con clave admin (queda historial). El borrador de guía se guarda solo aunque cierres la app.

## Clientes frecuentes y DNI
Puedes guardar clientes frecuentes (doc + nombre). El DNI puede empezar con 0 — se escribe completo. Para factura, el RUC del cliente es obligatorio.

## Impresora
El estado real de la impresora se ve en la app (online/offline). Si el ticket no salió: revisa que el agente PrintNode esté abierto en la PC y el cable USB; luego usa Reimprimir. La reimpresión de etiqueta/góndola usa el precio VIGENTE del catálogo.

## Extensión (2º equipo)
Un segundo equipo puede unirse a la caja escaneando el QR de extensión: espeja la caja del principal (misma sesión). Si el principal cierra, la extensión se cierra sola. La extensión no cierra la caja.

## Horario y bloqueo
Fuera del horario de la tienda la app se bloquea sola. Si necesitas trabajar más tarde, el admin autoriza una **extensión de horario** con su clave (vale solo por hoy). El equipo también se bloquea si el dispositivo no está aprobado o fue suspendido.
