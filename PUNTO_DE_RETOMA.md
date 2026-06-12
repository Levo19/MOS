# 📍 Punto de retoma — migración ME → Supabase (actualizado 2026-06-12)

> Dónde nos quedamos, para retomar después. (Detalle completo en la memoria de Claude:
> `architecture_mos_sync_triggers_mueren` y en `ROADMAP_SUPABASE_TOTAL.md`.)

## ✅ LIVE en producción (flota)
- **Escritura directa de ventas NV** — `ME_ESCRITURA_DIRECTA=1` (mos.config). Fleet-wide.
- **Impresión vía Edge Function** — `ME_IMPRESION_DIRECTA=1`. Validada en prod.
- **Movimientos de caja directos** — activos (usan el flag de escritura).
- **Red de seguridad del cierre** — reconciliación cada 10min + al inicio del cierre.
- Frontend **v2.7.94**. Interruptor central de flags en `mos.config`.

## 🔴 KILL-SWITCH (si algo se ve raro)
```sql
update mos.config set valor='0' where clave='ME_ESCRITURA_DIRECTA';
```

## 🟢 Listo pero INERTE (esperando algo)
- **CPE directo (boleta/factura)** — TODO cableado, `ME_CPE_DIRECTO=0`. Falta: token NubeFact
  (el usuario aún no lo tiene) → setear secrets + verificar serie + flag + test 1 boleta.

## ⏳ Cabos abiertos
1. **Validar el PRIMER cierre** con ventas directas (la red se desplegó pero no se ejecutó aún).
   → Cuando un cajero cierre caja, verificar que el monto cuadra + que corrió la reconciliación.
2. **Activar CPE** cuando haya token NubeFact (4 pasos en el roadmap).
3. **Lectura directa** (`ME_LECTURA_DIRECTA=0`): aún NO segura (un GAS-venta que se caiga del shadow
   → cajero la pierde → re-emite → duplicada). Habilitar recién cuando el shadow sea 100% confiable.

## 📇 Tarjeta de presentación (estado 2026-06-12)
- ✅ **HECHA en ME** (v2.7.95): Herramientas → "📇 IMPRIMIR TARJETA" → modal Cliente/Proveedor → imprime
  tarjeta térmica con QR a WhatsApp (mensaje pre-escrito + Ref) por la infra Edge. Plan B: muestra QR en pantalla.
- 🔢 **Números dinámicos** en `mos.config` (`TARJETA_WA_COMERCIAL`, `TARJETA_WA_COMPRAS`, `TARJETA_MARCA`).
  Placeholders `51000000000` → **falta poner los reales** (`update mos.config set valor='51...' where clave='...'`).
  Al cambiarlos, las tarjetas se actualizan solas (se leen al abrir el modal).
- ✅ **EDICIÓN EN MOS HECHA** (MOS v2.43.199 @397): MOS → Config → Infraestructura → "Tarjeta de presentación":
  2 números + marca editables. `guardarTarjetaWA` escribe CONFIG_MOS **y** upserta mos.config en el acto →
  las tarjetas toman el número nuevo al instante. `getTarjetaWA` (router) lee de mos.config.
- ✅ **Número de teléfono debajo del QR** (ME v2.7.96): número legible bajo el QR (sin +51, 987 654 321 grande).
- ✅ **Tarjeta bitmap diferenciada** (ME v2.8.4): cabecera = UN solo raster nítido (`_cabeceraTarjeta`): ícono
  (carrito/camión) + banda negra sólida con palabra CLIENTE/PROVEEDOR en **blanco** (papel sin imprimir); proveedor
  lleva marco blanco interior. Antes la banda era texto invertido doble-alto → borroso; ahora canvas→raster filoso.
  Pipeline binario (`_b64Bytes`/`Sraw`) porque `b64ESC` normaliza y corrompería imagen + bytes binarios del QR.
  RIESGO: si el printer no soporta GS v 0, la cabecera sale basura → fallback a ASCII (avisar). Edición de números:
  MOS→Config→Infraestructura (modal +51 fijo).
- ✅ **Tema de color por módulo** (ME v2.8.4): `colorModulo` computed (POS verde #10b981 / CAJA azul #3b82f6 /
  TOOLS naranja #ea580c). Header + botones/barras del nav adoptan el color activo → cohesión con la barra Pro.
- ✅ **Modo Pro** (ME v2.8.2): barra inferior auto-oculta (colores marca + dots alerta, ~5s) + atajos de teclado
  PC (ME v2.8.1: Espacio=cobrar/imprimir, Esc=cerrar/limpiar granel, /, Alt+1/2/3). Autodetect PC + toggle en Herramientas.
- ⏸️ **PARKEADO**: **Port a WH** (warehouseMos) — build aparte porque WH imprime vía GAS, no por Edge como ME.
  Piezas ubicadas: `imprimirBienvenida` (Code.gs, envío PrintNode), `_imprimirQR` (Reporte.gs, QR ESC/POS), Supabase.gs.

## 🔜 Lo que estábamos por construir (interrumpido por un paréntesis)
- **Créditos/cobros directo** — siguiente write-entity sistemático (patrón movimientos: RPC + mirror +
  flag + frontend). Ya leído el flujo: `gas/Creditos.gs` (`asignarCobroACajero` L63, `_dualWriteCobroME`
  L149, `confirmarCobroAsignado` L224); spec `creditos_cobro_asignado` en MigracionME.gs. **No empezado aún.**
