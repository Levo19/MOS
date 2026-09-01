# Manual operativo · WarehouseMos (WH, almacén)

WarehouseMos es la app del almacén central: recibe mercadería de proveedores, la envasa/etiqueta, despacha a las zonas y controla el stock del almacén.

## Preingreso y Producto Nuevo (PN)
Cuando llega mercadería se registra el **preingreso** (proveedor, guía/factura, cajas). Un producto que no existe en el catálogo entra como **PN (Producto Nuevo)** con su foto (la foto se comprime sola); el PN pasa por aprobación (código, precio, categoría) antes de venderse — corregir el código de un PN se hace desde su ficha, y al aprobarse avisa por notificación. El comentario del preingreso se conserva al reabrirlo. Los preingresos duplicados se combinan solos por un rato (merge).

## Ingreso de proveedor (costos + IGV)
El ingreso de proveedor registra cantidades y costos; de ahí salen el costo del catálogo y el crédito fiscal (IGV a favor). El OCR puede leer la guía/factura con foto y precargar los ítems — revisa cantidades antes de confirmar. La factura debe estar emitida a nuestro RUC para contar el IGV.

## Despacho a zonas (pickup)
Las zonas piden reposición; WH ve el **pickup** con checklist por producto: escaneas o marcas +1 por unidad despachada, con barra de avance. El semáforo del panel de la zona se actualiza EN VIVO mientras despachas. El contador se puede editar tocando el número (con validaciones). Al terminar se cierra el pickup y la zona recibe su guía. Los pedidos de MosGo salen con despacho restringido y guía de remisión.

## Guías (remisión / traslados)
Toda salida de mercadería genera guía (SALIDA a zona, traslados, ventas del día de cada caja). Una guía CONFIRMADA ya movió stock. El wizard de guías permite elegir zona y reconciliar diferencias; el ticket de la guía se imprime desde la app.

## Stock del almacén, conteos y auditoría
El stock del almacén se cuenta con la app (escaneo + cantidad). En un conteo, si el sistema no te pide reconteo es que tu número coincidió. La **auditoría de cuadre** compara lo contado contra el kardex y lista diferencias; los reconciliadores solo corrigen alertas frescas (las viejas se descartan). Ajustar sin contar está prohibido: primero conteo, luego ajuste con motivo.

## Mermas
Producto dañado/vencido va a **Mermas** (con o sin foto según el flujo). Resolver una merma la descuenta definitivamente. Las mermas vencidas escalan solas al panel.

## Envasado y etiquetas
El granel se **envasa** en presentaciones (paquetes) — cada envasado mueve stock (granel → empaquetado) y paga al envasador por tarifa. Las etiquetas/adhesivos térmicos se imprimen en lote desde la app (impresora Caserito/TSPL2); si deshaces un envasado, su lote de etiquetas se cancela.

## Cargadores del día
El módulo de **cargadores** registra los bultos que cada cargador llevó (con termómetro de avance y fotos); el resumen del día se comparte/imprime.

## Vencimientos y lotes
Los productos con vencimiento llevan lote; el sistema avisa lo que está por vencer (días para vencer en hora de Perú). El despacho sale FEFO (lo que vence primero, primero).

## Etiqueta de escaneo
Si el lector escribe un guion o caracteres raros al escanear, es la distribución del teclado (ES-LATAM): la app ya lo corrige, pero el código en pantalla debe coincidir con el físico antes de confirmar.

## Semana y acumulados
Los acumulados semanales van de LUNES a DOMINGO. La rotación (ventas de las últimas 8 semanas) alimenta las sugerencias de reposición y los mínimos/máximos automáticos.
