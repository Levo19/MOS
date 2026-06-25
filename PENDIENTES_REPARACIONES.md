# PENDIENTES — Modo "reparaciones" (UI/UX, cero GAS)

Lista viva de las reparaciones que vamos haciendo. Lo grande (ventas/auth/madrugada) queda para el FINAL.
Regla: 100% Supabase, sin GAS. Revisión 40x. Graneles se identifican por **unidad_medida = KGM** (NO por precio).

## 🔧 PENDIENTES

### 2. Adhesivo de granel al despachar (WH) — diseño CERRADO
- Idea: al despachar un granel (KGM) desde WH, además de la guía, imprimir 1 adhesivo para pegar en el saco.
- Datos: nombre (2 renglones, **word-wrap sin partir palabras** — solo corta en espacios) · peso inteligente (kg/g) · código con barcode Code128 escaneable · fecha+hora. **1 solo adhesivo** (no por bulto). **Sin** N° de guía (ahorra espacio).
- **Símbolo WH**: badge **caja/bulto + WH** (elegido por el usuario), abajo-derecha encima de la fecha/hora. En TSPL2 = dibujado con BAR/BOX + TEXT "WH" (no SVG directo).
- Formato: el que YA imprimen (50×25mm, `buildTSPLMembreteMe` en `print-adhesivo/index.ts`) — reemplazar precio S/ → PESO, y "ME" → fecha/hora + badge WH.
- Implementación: clonar `buildTSPLMembreteMe` → `buildTSPLGranelDespacho`; disparar por cada ítem KGM en el despacho. Reusa la Edge `print-adhesivo`. Cero GAS.

### 3. Wizard iOS/adaptable (**ME**, no MOS) — GPS sin feedback
- Síntoma: en iPhone, al usar **ME (MosExpress)**, el wizard tiene un botón "activar GPS" → "le doy click y nada"; el usuario siente que no puede entrar.
- ⚠️ CORRECCIÓN: es el wizard de **ME**, NO el de MOS. Falta revisar el flujo de activación/permisos de ME (MosExpress index.html / device-auth.js) — ahí está el botón GPS que bloquea.
- Fix esperado (a confirmar tras revisar ME): (a) no bloquear la entrada por GPS (es opcional); (b) feedback claro al tocar GPS (éxito/denegado/apagado/timeout + cómo activarlo en Ajustes iOS). Objetivo: adaptable Android/Windows/iOS.

## ✅ HECHO en esta sesión (referencia)
- **Tramos MOS (v2.43.338):** quitada la traba `precioVenta>0` en `_segCargarDesdeCard` → granel se identifica por KGM, no por precio. Abre el modal único (botón eliminar + banda base con precio real). Causa: graneles con precio 0 en cache caían al modal viejo (doble).
- Ticket venta ME: graneles "Peso: 100g/5kg" + nombres largos en 2 renglones (v2.8.67).
- Ticket guía ME: nombres 100% Supabase (RPC `mos.nombres_por_codigos`) — fix devolución sin nombre (v2.8.68).
- WH Edge `ticket-guia`: catálogo manda sobre producto_nuevo — fix "[n] arroz 565656" + 9 filas fantasma borradas.
- MOS: `mos.listar_dispositivos` estampa frescura (panel dispositivos 100% Supabase, SQL 170) + meta/favicon (v2.43.337).
