# PENDIENTES — Modo "reparaciones" (UI/UX, cero GAS)

Lista viva de las reparaciones que vamos haciendo. Lo grande (ventas/auth/madrugada) queda para el FINAL.
Regla: 100% Supabase, sin GAS. Revisión 40x. Graneles se identifican por **unidad_medida = KGM** (NO por precio).

## 🔧 PENDIENTES
- **Test de calibración del adhesivo de granel:** hacer 1 despacho con graneles y verificar el layout impreso (posiciones TSPL2 estimadas). Ajustar coordenadas si hace falta.

## ✅ HECHO en esta sesión (referencia)
- **WH pickup UX "faltan N" (v2.13.347):** la barra/conteo del operador se mide contra lo que falta HOY (objetivo = solicitado − baseline rezagado), arranca en 0 → muestra "faltan 5" en vez del confuso 1/6. Baseline capturado en empezarPickup; renders inline + sheet + control +/-. Logica de guia/cart sin cambios.
- **Wizard ME iOS/adaptable (v2.8.69):** el botón de entrada nunca se deshabilita (permisos opcionales) → el operador SIEMPRE puede entrar en iPhone; antes el GPS en 'prompt' lo atrapaba. + feedback claro al tocar GPS (éxito / cómo activarlo en iOS / es opcional).
- **Adhesivo granel automático al despachar (WH v2.13.346 + Edge):** al emitir la guía, en paralelo imprime 1 adhesivo por ítem KGM (nombre+peso+barcode+fecha+badge WH). Edge `print-adhesivo` mode `granel-despacho` + `buildTSPLGranelDespacho`. `API.imprimirAdhesivoGranel`. Drift auto por etiqueta. PENDIENTE: test de calibración del layout en la impresora real.
- **Códigos sin nombre en verificación despacho MOS (v2.43.342):** los productos catalogados que salían como código pelado ahora muestran su nombre, resuelto desde Supabase (`mos.nombres_por_codigos`) en `trasVerGuia`. Nuevo `API.zona.nombresPorCodigos`. El "[N] caja" del ticket WH (ALSABOR catalogado) ya lo cubre la Edge `ticket-guia`. No catalogados (sobrantes) siguen mostrando el código.
- **Tramos MOS (v2.43.341):** RAÍZ = `_segCargarDesdeCard` chequeaba `window.S` (S es const de módulo, NO está en window) → SIEMPRE caía al doble modal. Confirmado con diagnóstico en vivo (`hallado=false, S.productos=?`). Fix: usar `S` directo → modal único + botón eliminar visible. + el mini de la card muestra el precio canónico (S/X/kg) en la banda base + leyenda.
- **Auto-update redes lentas (v2.43.339):** el banner vacía el caché del SW y recarga al detectar versión nueva (antes el timeout de 2.5s servía el index viejo en redes lentas → el usuario quedaba pegado en versiones anteriores). Falta portar el mismo patrón a ME (con cuidado: ME es POS, no forzar reload mid-venta).
- Ticket venta ME: graneles "Peso: 100g/5kg" + nombres largos en 2 renglones (v2.8.67).
- Ticket guía ME: nombres 100% Supabase (RPC `mos.nombres_por_codigos`) — fix devolución sin nombre (v2.8.68).
- WH Edge `ticket-guia`: catálogo manda sobre producto_nuevo — fix "[n] arroz 565656" + 9 filas fantasma borradas.
- MOS: `mos.listar_dispositivos` estampa frescura (panel dispositivos 100% Supabase, SQL 170) + meta/favicon (v2.43.337).
