# Plan — ZONA (ME) 100% Supabase: espejo del sistema WH

> Objetivo del dueño: replicar EXACTO el sistema de WH en la zona (ME/MosExpress): tabla stock + tabla AJUSTES (con tiempo+usuario) + kardex + cierre idempotente + autolock 30min + reapertura con auth-admin, sin duplicación. 100% Supabase. Test físico real.
> Ventana limpia: nadie usa las apps → cutover seguro (como WH).

## Flujo objetivo (simple)
1. Almacén emite **guía SALIDA a zona** → imprime ticket con idGuiaWH.
2. **Operario ME** (vendedor/cajero), en ME → Tools → "Guías de almacén": escanea el **código de la guía** → jala el JSON de productos de esa guía → escanea **producto por producto** (no ve cantidad esperada).
3. Lo ESCANEADO entra a zona (no lo enviado). 
4. **El ADMIN ve las DISCREPANCIAS en MOS** (no hace el registro). Si hace falta, hace el AJUSTE del producto (como ya existe).

## UI a corregir (módulo Zona en MOS)
- **Quitar de la vista principal** la lista larga "Traslados por verificar (101)" — estorba.
- **Botón "Guías"** al lado de "Lista compras" → abre layout con TODA la info guía-por-guía, **agrupado por día**, con filtro. Cada card de guía: al click → detalle con **discrepancias en el primer grupo**. Botón "verificado" por guía (marca que el admin lo resolvió). Símbolo de **alerta** en el botón si hay guías con pendientes.
- **Quitar el botón "Ingreso por almacén" de MOS** → ese flujo (escaneo) va en **ME (MosExpress)**, sección Tools → Guías de almacén. MOS solo MUESTRA discrepancias + permite ajuste.
- **Empezar con lista VACÍA**: marcar las ~101 guías actuales como "correctas/verificadas" (línea base), y de ahora en adelante las nuevas entran a verificar.

## Backend a construir (espejo de WH, 100% Supabase)
- **`me.stock_zonas`** ya existe (snapshot). Falta: que ME escriba directo (no sync Hoja).
- **`me.stock_movimientos`** (kardex) — YA creada (SQL 140) pero vacía. Activar el registro real.
- **Tabla de AJUSTES de zona** (NUEVA, como `wh.ajustes`): con tiempo + usuario + motivo. (Hoy NO existe; las correcciones son por auditoría set-absoluto.)
- **Cierre idempotente** de guías de zona (delta = nueva − aplicada; recerrar = 0) — como `wh.cerrar_guia_idempotente`.
- **Autolock 30min** + reapertura con auth-admin, sin duplicar al reabrir (igual que WH `wh-autocierre-inactividad` + `cantidad_aplicada`).
- **Reconciliación** zona ya existe (`mos.reconciliar_stock` ámbito ZONA) + log master.
- El traslado escaneado escribe el kardex + (con gate) el saldo `me.stock_zonas`.

## Migración ME a 100% Supabase (revisar + hacer — ventana limpia)
- Auditar (como WH 50x): ¿ME lee/escribe stock_zonas y guías de la Hoja o de Supabase? ¿hay sync ME que cruce? ¿RPCs de escritura directa ME?
- Escritura directa ME (stock/guías/ajustes/ventas que tocan stock) → RPCs Supabase.
- Apagar el sync ME→Supabase de las tablas de stock/guías (solo tras escritura directa + validar + flota 100%).
- Verificar CERO duplicación (mismo patrón idempotente + clave única ref).

## HALLAZGOS DEL AUDIT ME (2026-06-17) — el sistema YA está construido, falta cablear
**Estado:** ME stock_zonas + guías = **Hoja(GAS) fuente de verdad + sombra por sync batch**. Ventas/cajas SÍ escriben directo a Supabase (`ME_ESCRITURA_DIRECTA=1`), pero **stock y guías NO** (solo GAS→Sheets→sync).
**YA EXISTE en Supabase (orphan, reusar — NO reconstruir):** `me.stock_movimientos` (kardex, 0 filas/inactivo) · `me.zona_ajustar_stock` (ajuste idempotente por localId + log `me.zona_ajuste_log` = tabla de ajustes zona ✓) · `me.zona_kardex_registrar/historial` · `me.zona_recibir_lote` + `me.zona_lotes` (FIFO) · **`me.zona_traslado_cerrar` + `me.zona_traslado_verificacion`** (cierre por escaneo producto-a-producto, idempotente por id_guia, compara enviado vs escaneado = el flujo del QR que pide el dueño) · `me.zona_panel/esperado/lista_compras` · `mos.reconciliar_stock` ya soporta ambito ZONA.
**FALTA (cableo + cutover, ventana limpia):**
1. **Apagar el sync de stock_zonas + guias_cabecera + guias_detalle** (no hay `ME_SYNC_OFF_TABLAS` — crearlo en MigracionME.gs). ANTES de cualquier escritura directa (si no, el batch re-upsertea la Hoja en ≤15min y revierte = el cruce).
2. **Desbloquear el gate** `v_aplicar_stock=false` (hardcodeado OFF) en `me.zona_traslado_cerrar` → UPDATE atómico cantidad±delta (NO read-modify-write).
3. **Cablear las RPCs** en ME: lectura (`zona_panel`/`zona_kardex_historial`), escritura (`zona_ajustar_stock`/`recibir_lote`/`traslado_cerrar`). Hoy ME no llama ninguna `zona_*`.
4. **Reescribir `generarGuiaSalidaVentas`** (Guias.gs, hoy read-modify-write con doble conteo — hay 3 herramientas de limpieza de duplicados = el bug ya pasó) como descuento directo atómico + kardex + idempotencia por id_caja.
5. **Recepción WH→ME por escaneo de guía** (NO EXISTE hoy; `ENTRADA_ALMACEN` es manual sin vínculo a la guía WH): construir `recibirGuiaDeWH(idGuiaWH)` que precargue el detalle del despacho WH + use `zona_traslado_cerrar` con escaneo. La RPC ya existe; falta el endpoint WH→ME + la pantalla de escaneo en ME (Tools→Guías de almacén).
6. **Sanear los 414 negativos** (33%, min −10512 = basura de saldo acumulado + doble conteo). El cutover debe arrancar de **conteo físico** (auditoría) o `zona_ajustar_stock` masivo set-absoluto, NO del saldo actual. (= el "test físico" que el dueño quiere.)
7. **Activar el kardex** (`me.stock_movimientos`) en cada escritura.
**Autolock guías zona:** ME hoy NO tiene cierre/reapertura/autolock (toda guía nace CONFIRMADO). Hay que añadir el modelo estado + autolock 30min + reapertura auth-admin idempotente (espejo de `wh-autocierre-inactividad` + `cantidad_aplicada`).

## Reglas (money-safety)
- Igual que WH: escritura directa + validar ANTES de apagar sync; idempotencia en todo; autolock idempotente; backups; reconciliación nocturna de vigilancia.
- Todo con efectos modernos (optimista, háptico, transiciones) + revisión 40x en cada paso.
