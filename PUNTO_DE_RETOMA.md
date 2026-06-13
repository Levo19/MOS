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

## 🏭 WH (warehouseMos) — Fase 2 migración (actualizado 2026-06-12)
- ✅ **Dual-write en tiempo real COMPLETO** en todas las tablas operativas (GAS @444, 5 IDs):
  stock + stock_movimientos + guías(cabecera+ítems) + preingresos (sesiones previas) · **+ Rondas 1-5
  de esta sesión:** lotes_vencimiento (R1) · envasados (R2) · mermas+ajustes (R3) · auditorias+producto_nuevo (R4).
  Patrón: Sheets primero (bajo `_conLock`), luego upsert best-effort (nunca lanza). Red: sync batch 15min.
- ✅ **Gate de paridad re-corrido VERDE** (R5, `verificarParidadWH` universal + stock paginado): 9 tablas con
  `solo_en_sheets_count:0`; stock 1349=1349 sin diffs. Detalle en `MIGRACION_WH_FASE2.md`.
- ✅ **Bug hunt 50x** (`REVISION_50X_BUGHUNT.md`): sin críticos reales (2 falsos positivos de dinero
  verificados); 3 endurecimientos defensivos aplicados (guards `_sbUpdate`/`_dualWritePatchWH` + SQL 27 ABIERTA).
- ✅ **LECTURA DIRECTA DE STOCK WH — ACTIVA** (2026-06-12, GAS @447, 5 IDs): `getStock` lee de Supabase
  (`wh.stock_enriquecido`, 6x más rápida) con fallback automático a Sheets + cache 15s. Control por
  Script Property `FUENTE_DATOS` (global). **Kill-switch:** `?action=desactivarSupabaseWH` (vuelve a Sheets).
  Activar: `?action=activarSupabaseWH`. Estado: `?action=estadoFuenteDatosWH`. Gate: `?action=compararStockWH`
  (paridad EXACTA: 1349=1349, 449 alertas). NOTA: `wh.stock_enriquecido` NO sufre db-max-rows (devuelve 1
  JSONB escalar con jsonb_agg → no se trunca). `getRotacionSemanal` también flipeable (mismo patrón).
- ⚠️ **BUG ENCONTRADO+ARREGLADO esta sesión:** el flip estaba activado prematuramente con la sombra
  `mos.productos` CONGELADA (trigger `syncCatalogoSupabase` muerto — patrón conocido) → `stockMinimo/Maximo`
  viejos → **alertas de stock bajo silenciadas**. Fix: `backfillCatalogo()` (refrescó 2357 productos) +
  `instalarTriggerCatalogo()` (re-instaló el horario). Verificar periódicamente que el trigger siga vivo.
- ✅ **PASO 3 COMPLETO (2026-06-13): 11 lecturas LIVE** (stock, rotación, mermas, auditorias, ajustes, envasados,
  producto_nuevo, preingresos, lotes_vencimiento, stock_movimientos, guias). alertas_stock se quedó en Sheets
  (se purga → huérfanos en sombra). Revisión 100x pasada (bug de fotos preingreso arreglado).
- ✅ **PASO 4 — 7 RPCs atómicas LISTAS (INERTES, flags en 0)**: crear_ajuste, registrar_merma, crear_preingreso,
  actualizar_preingreso, crear_guia, **cerrar_guia (FIFO/lotes)**, reabrir_guia. SQL `30..36_wh_*.sql`, validadas
  (77 casos) + **2 auditorías 40x** (corregido: lost-update→UPDATE atómico, coerción `wh._num`/`wh._ts`, lote legacy).
- ✅ **Integridad wh.stock**: 1 fila por producto + **índice único `ux_wh_stock_cod`** (consolidado el duplicado
  7750243071406). `dedupStockSheet` en GAS (usa clearContent, la hoja bloquea deleteRow).
- 🔑 **ACLARACIÓN CLAVE (no activar escritura aún):** mientras GAS/Sheets viva, toda escritura DEBE ir a Sheets
  (el ecosistema lo lee) → activar las RPCs ahora = doble escritura sin valor. Las 7 RPCs son la FUNDACIÓN del
  **PASO 5** (frontend escribe directo a Supabase sin GAS). El PASO 5 es un REDISEÑO mayor (catálogo+orquestación
  fuera de GAS), no ejecución lineal — requiere decisión estratégica. Docs: `DISENO_orquestadores_paso4.md`,
  `DISENO_cerrar_guia.md`, `architecture_wh_escritura_directa_paso4` (memoria).
- ⏳ **Siguiente WH (menor):** flipear lecturas restantes con su gate (rotación ya lista). Orquestadores
  (envasado/aprobar/auditar) quedan en GAS con dual-write. getGuia (detalle PK compuesta) — diseño aparte.
- 🔧 **Pendiente DB:** aplicar `27_fase2_cerrar_caja.sql` endurecido al proyecto MOS (rzbzdeipbtqkzjqdchqk)
  el día que se valide/active `ME_CIERRE_DIRECTO` (hoy inerte; el classifier bloqueó aplicarlo en un bug-hunt).

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
