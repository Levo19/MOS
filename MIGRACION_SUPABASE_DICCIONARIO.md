# 📒 Diccionario de Datos — Migración Supabase

> Compañero de `MIGRACION_SUPABASE.md`. Mapea cada hoja/columna a su tabla/columna Postgres, con tipo, PK/FK, índices y la conversión de backfill.
> **Estado:** ✅ ME completo y verificado contra código · ⬜ WH andamiaje · ⬜ MOS andamiaje.
> **Última actualización:** 2026-06-07

---

## Convenciones globales (aplican a todas las tablas)

- **Nombres Postgres:** `snake_case`. El header legacy (camel/Pascal) se mapea aquí; **el endpoint GAS debe devolver al frontend las keys legacy** (ver §25 del plan — fidelidad de forma).
- **PK:** el **ID legacy es la PRIMARY KEY** (`id_venta text PRIMARY KEY`) — las FKs apuntan a él y evita ambigüedad en PostgREST/ORM. Opcional una columna interna `id bigserial UNIQUE` (NO PK). Esto evita colisiones de `"V-"+timestamp` (Postgres rechaza el duplicado en vez de aceptarlo en silencio como Sheets).
- **Idempotencia (merge-duplicates):** PostgREST `resolution=merge-duplicates` **SOLO funciona si la clave tiene constraint `UNIQUE`/PK**. Sin ella, inserta duplicado en silencio. La clave de dedup de la doble escritura es el **ID legacy** (server-generado, estable para esa escritura), no campos opcionales.
- **Columnas comunes RLS-ready** (agregar a toda tabla transaccional, aunque la hoja no las tenga): `zona_id text`, `dispositivo_id text`, `created_at timestamptz default now()`, `updated_at timestamptz`, `created_by text`. Índice en `zona_id` y `dispositivo_id`.
- **Tipos estándar:** códigos/IDs/documentos = `text`; montos = `numeric(12,2)`; cantidades = `numeric(12,3)`; fechas = `timestamptz` (inyectar TZ `America/Lima` en backfill); flags = `boolean`; JSON de celda = `jsonb`.
- **Conversión de booleanos legacy:** `'1'|1|'SI'|'true'|true → true`; `'0'|0|'NO'|'false'|''|null → false`; valor inesperado → log en `backfill_audit`.
- **`historialCambios`** (columna JSON presente en varias tablas) → `jsonb`; el front la usa como array de `{usuario, ts, source, accion, cambios[], autorizadoPor, ref, motivo}` (máx 200 entradas).

---

# ME — MosExpress (esquema `me`) ✅

## me.ventas  ← VENTAS_CABECERA (transaccional, alto volumen)

| # | Header Sheet | Columna Postgres | Tipo | Clave/Índice | Conversión / Nota |
|---|---|---|---|---|---|
| 0 | ID_Venta | id_venta | text UNIQUE NOT NULL | PK natural | `"V-"+ts`; conservar como text |
| 1 | Fecha | fecha | timestamptz | idx (fecha) | inyectar TZ Lima |
| 2 | Vendedor | vendedor | text | | FK lógica → mos.personal.nombre (Fase 2) |
| 3 | Estacion | estacion | text | | id estación (catálogo MOS) |
| 4 | Cliente_Doc | cliente_doc | text | idx | DNI(8)/RUC(11)/'' — conservar ceros |
| 5 | Cliente_Nombre | cliente_nombre | text | | |
| 6 | Total | total | numeric(12,2) | | |
| 7 | Tipo_Doc | tipo_doc | text (enum) | | NOTA_DE_VENTA · BOLETA · FACTURA |
| 8 | FormaPago | forma_pago | text (enum) | idx | **⚠ VERIFICAR set exacto** (ver nota enum abajo) — fuente de verdad del estado |
| 9 | Correlativo | correlativo | text | | `SERIE-000000` |
| 10 | ID_Caja | id_caja | text | FK → me.cajas.id_caja, idx | |
| 11 | ID_Dispositivo | dispositivo_id | text | idx | UUID |
| 12 | Estado_Envio | estado_envio | text (enum) | | COMPLETADO · ANULADO · HUERFANA_LIMPIADA |
| 13 | Ref_Local | ref_local | text | idx | ⚠ OPCIONAL — solo se llena si `data_sync.last_sync` viene del front (vacío en offline). NO sirve como clave de idempotencia. |
| 14 | Obs | obs | text | | |
| 15 | Tipo_Doc_Cliente | tipo_doc_cliente | smallint | | 0=sin doc · 1=DNI · 6=RUC |
| 16 | NF_Estado | nf_estado | text (enum) | | NA·EMITIENDO·EMITIDO·ERROR·RECHAZADO_SUNAT·PENDIENTE |
| 17 | NF_Hash | nf_hash | text | | NubeFact |
| 18 | NF_Enlace | nf_enlace | text | | URL CPE |
| 19 | historialCambios | historial_cambios | jsonb | | |

- **PK:** `id_venta text PRIMARY KEY`. **Idempotencia de la doble escritura = `id_venta`** (server-generado, estable; la misma operación escribe el mismo `id_venta` a Sheets y a Postgres → upsert idempotente). `ref_local` es opcional y NO sirve de clave. *(Nota: el reintento cross-request que genera un id_venta NUEVO es un tema pre-existente de la app, no de la migración; el GAS ya dedup por ref_local en las últimas filas.)*
- **FK:** `id_caja → me.cajas`. **Índices:** `fecha`, `forma_pago`, `cliente_doc`, `id_caja`, `dispositivo_id`.
- **Atomicidad:** se inserta junto con `me.ventas_detalle` → función Postgres `me.registrar_venta(cabecera jsonb, detalle jsonb[])`.

## me.ventas_detalle  ← VENTAS_DETALLE (transaccional, el más voluminoso)

| # | Header | Postgres | Tipo | Clave/Índice | Nota |
|---|---|---|---|---|---|
| 0 | ID_Venta | id_venta | text | FK → me.ventas.id_venta, idx | |
| 1 | SKU | sku | text | idx | |
| 2 | Nombre | nombre | text | | |
| 3 | Cantidad | cantidad | numeric(12,3) | | |
| 4 | Precio | precio | numeric(12,2) | | con IGV |
| 5 | Subtotal | subtotal | numeric(12,2) | | |
| 6 | Cod_Barras | cod_barras | text | idx | |
| 7 | Valor_Unitario | valor_unitario | numeric(12,4) | | sin IGV (SUNAT) |
| 8 | Tipo_IGV | tipo_igv | smallint (enum) | | 1=gravado·2=exonerado·3=inafecto |
| 9 | Unidad_Medida | unidad_medida | text | | NIU/KGM/LTR… |

- **⚠ Idempotencia (no hay nº de línea persistente hoy):** agregar columna `linea int` (1-based) y `UNIQUE(id_venta, linea)`. **Requiere cambio de código** en `Ventas.gs` (`detalleRows.map(function(item, idx){ … idx+1 })`) y en el backfill (`row_number() OVER (PARTITION BY id_venta)`). Sin esto, un reintento duplica el detalle sin poder dedupir.
- **FK:** `id_venta → me.ventas ON DELETE CASCADE`. **Huérfanos:** detalle sin cabecera → reportar en `backfill_audit`.

## me.cajas  ← CAJAS (diaria)

| # | Header | Postgres | Tipo | Clave/Índice | Nota |
|---|---|---|---|---|---|
| 0 | ID_Caja | id_caja | text UNIQUE | PK natural | |
| 1 | Vendedor | vendedor | text | | |
| 2 | Estacion | estacion | text | | |
| 3 | Fecha_Apertura | fecha_apertura | timestamptz | idx | TZ Lima |
| 4 | Monto_Inicial | monto_inicial | numeric(12,2) | | |
| 5 | Estado | estado | text (enum) | idx | ABIERTA · CERRADA · CERRADA_AUTO |
| 6 | Monto_Final | monto_final | numeric(12,2) | | null si abierta |
| 7 | Fecha_Cierre | fecha_cierre | timestamptz | | null si abierta |
| 8 | Zona_ID | zona_id | text | idx | |
| 9 | PrintNode_ID | printnode_id | text | | conservar formato |

- **Cierre = operación compuesta** (guía salida + cuadre + movimientos) → función Postgres atómica `me.cerrar_caja(...)`.

## me.movimientos_extra  ← MOVIMIENTOS_EXTRA

| # | Header | Postgres | Tipo | Nota |
|---|---|---|---|---|
| 0 | ID_Extra | id_extra | text UNIQUE (PK) | |
| 1 | ID_Caja | id_caja | text FK→me.cajas, idx | |
| 2 | Timestamp | ts | timestamptz | TZ Lima |
| 3 | Tipo | tipo | text (enum) | INGRESO·INGRESO_VIRTUAL·EGRESO·EGRESO_VIRTUAL |
| 4 | Monto | monto | numeric(12,2) | |
| 5 | Concepto | concepto | text | |
| 6 | Obs | obs | text | |
| 7 | Registrado_Por | registrado_por | text | |
| 8 | historialCambios | historial_cambios | jsonb | col dinámica (la crea auditLog, no el appendRow inicial) |

## me.clientes_frecuentes  ← CLIENTES_FRECUENTES (maestra)

| # | Header | Postgres | Tipo | Nota |
|---|---|---|---|---|
| 0 | Documento | documento | text UNIQUE (PK) | DNI/RUC, conservar ceros |
| 1 | Nombre | nombre | text | header puede ser `Nombre` o `Nombre_RazonSocial` — mapear ambos |
| 2 | Tipo_Doc | tipo_doc | smallint | 1=DNI·6=RUC |
| 3 | Fecha_Registro | fecha_registro | timestamptz | |
| 4 | Direccion | direccion | text | de APISPeru |
| 5 | historialCambios | historial_cambios | jsonb | |

## me.guias_cabecera  ← GUIAS_CABECERA

| # | Header | Postgres | Tipo | Nota |
|---|---|---|---|---|
| 0 | ID_Guia | id_guia | text UNIQUE (PK) | |
| 1 | Fecha | fecha | timestamptz | TZ Lima |
| 2 | Vendedor | vendedor | text | |
| 3 | Zona_ID | zona_id | text idx | |
| 4 | Tipo | tipo | text (enum) | SALIDA_VENTAS·SALIDA_JEFA·SALIDA_MOVIMIENTO·ENTRADA_ALMACEN·ENTRADA_TRASLADO·ENTRADA_LIBRE |
| 5 | Observacion | observacion | text | cajaId para SALIDA_VENTAS |
| 6 | Zona_Destino | zona_destino | text | traslados |
| 7 | Estado | estado | text (enum) | CONFIRMADO·PENDIENTE |

## me.guias_detalle  ← GUIAS_DETALLE

| # | Header | Postgres | Tipo | Nota |
|---|---|---|---|---|
| 0 | ID_Guia | id_guia | text FK→me.guias_cabecera, idx | |
| 1 | Cod_Barras | cod_barras | text idx | |
| 2 | Cantidad | cantidad | numeric(12,3) | |

## me.stock_zonas  ← STOCK_ZONAS (snapshot mutable — ver §28 estrategia stock)

| # | Header | Postgres | Tipo | Nota |
|---|---|---|---|---|
| 0 | Cod_Barras | cod_barras | text | parte de PK compuesta |
| 1 | Zona_ID | zona_id | text | parte de PK compuesta |
| 2 | Cantidad | cantidad | numeric(12,3) | snapshot |
| 3 | Usuario | usuario | text | cols 3-4 dinámicas (⚠ verificar `_ensureStockZonasAuditCols` — una verificación no la halló) |
| 4 | Fecha_Ultimo_Registro | fecha_ultimo_registro | timestamptz | idem |

- **PK:** `UNIQUE(cod_barras, zona_id)`. **Backfill:** snapshot a cutoff; deltas posteriores por doble escritura. Agregar log `me.stock_movimientos` (no existe hoy) para trazabilidad.

## me.correlativos  ← CORRELATIVOS (maestra — atómico)

| # | Header | Postgres | Tipo | Nota |
|---|---|---|---|---|
| 0 | Serie | serie | text PK | NV·B·F |
| 1 | Siguiente | siguiente | bigint | usar **`UPDATE me.correlativos SET siguiente=siguiente+1 WHERE serie=$1 RETURNING siguiente`** bajo transacción. ⚠ NO usar SEQUENCE: deja huecos en rollback y SUNAT exige numeración contigua. |

## me.reservas_correlativos  ← RESERVAS_CORRELATIVOS (transaccional temporal)

| # | Header | Postgres | Tipo | Nota |
|---|---|---|---|---|
| 0 | idReserva | id_reserva | text UNIQUE (PK) | |
| 1 | serie | serie | text | |
| 2 | numero | numero | bigint | |
| 3 | vendedor | vendedor | text | |
| 4 | deviceId | dispositivo_id | text | |
| 5 | reservadoAt | reservado_at | timestamptz | |
| 6 | estado | estado | text (enum) | ACTIVA·USADA·CANCELADA·EXPIRADA |
| 7 | usadoAt | usado_at | timestamptz | |
| 8 | idVenta | id_venta | text FK→me.ventas | |

- Retención: purga de EXPIRADA/USADA viejas (cron). Hoy se limpia por hora.

## me.creditos_cobro_asignado  ← CREDITOS_COBRO_ASIGNADO

| # | Header | Postgres | Tipo | Nota |
|---|---|---|---|---|
| 0 | ID_Cobro | id_cobro | text UNIQUE (PK) | |
| 1 | ID_Venta | id_venta | text FK→me.ventas, idx | |
| 2 | Caja_Destino | caja_destino | text | |
| 3 | Vendedor_Dest | vendedor_dest | text | |
| 4 | Metodo_Sug | metodo_sug | text | |
| 5 | Estado | estado | text (enum) | ASIGNADO·COBRADO·RECHAZADO·CANCELADO·**EXPIRADO** (no VENCIDO) |
| 6 | Admin_Asignador | admin_asignador | text | |
| 7 | Fecha_Asig | fecha_asig | timestamptz | |
| 8 | Fecha_Res | fecha_res | timestamptz | |
| 9 | Razon | razon | text | |
| 10 | ID_Caja_Origen | id_caja_origen | text | |
| 11 | Monto | monto | numeric(12,2) | |
| 12 | Cliente_Nombre | cliente_nombre | text | |
| 13 | Correlativo | correlativo | text | |
| 14 | Fecha_Vencimiento | fecha_vencimiento | timestamptz | |
| 15 | Horas_TTL | horas_ttl | int | TTL del cobro (1/2/4/6h) |
| 16 | Mensaje_Admin | mensaje_admin | text | |
| 17 | Reasignaciones | reasignaciones | int | contador de reasignaciones |

> ✅ Verificado contra `_CREDITO_COBRO_HEADERS` (Creditos.gs:22-29): **18 columnas exactas** (orden arriba). Estado real = **EXPIRADO** (el código en escalarCobrosVencidos escribe EXPIRADO, no VENCIDO/TIMEOUT).

## me.ventas_fantasma  ← VENTAS_FANTASMA (auditoría de rechazos, retención ≥1 año)

| # | Header | Postgres | Tipo |
|---|---|---|---|
| 0 | ts | ts | timestamptz |
| 1 | vendedor | vendedor | text |
| 2 | zona | zona_id | text |
| 3 | estacion | estacion | text |
| 4 | deviceId | dispositivo_id | text |
| 5 | monto | monto | numeric(12,2) |
| 6 | metodo | metodo | text |
| 7 | tipoDoc | tipo_doc | text |
| 8 | docCliente | doc_cliente | text |
| 9 | nombreCliente | nombre_cliente | text |
| 10 | correlativoLocal | correlativo_local | text |
| 11 | cajaIdEnviada | caja_id_enviada | text |
| 12 | motivo | motivo | text (enum) | PAYLOAD_INVALIDO·NO_CAJA_ACTIVA_EN_ZONA·… |
| 13 | mensaje | mensaje | text |
| 14 | estado_revision | estado_revision | text (enum) | PENDIENTE·APROBADO·RECHAZADO |
| 15 | revisadoPor | revisado_por | text |
| 16 | fechaRevision | fecha_revision | timestamptz |
| 17 | accionTomada | accion_tomada | text (enum) | REPLICAR·IGNORAR·REEMBOLSAR |
| 18 | payload_json | payload_json | jsonb | truncado a 5000 en Sheets — validar JSON en backfill |

## me.auditorias  ← AUDITORIAS (conteo físico de stock)

| # | Header | Postgres | Tipo |
|---|---|---|---|
| 0 | ID_Auditoria | id_auditoria | text UNIQUE (PK) |
| 1 | Fecha | fecha | timestamptz |
| 2 | Vendedor | vendedor | text |
| 3 | Zona_ID | zona_id | text |
| 4 | Cod_Barras | cod_barras | text |
| 5 | Cant_Sistema | cant_sistema | numeric(12,3) |
| 6 | Cant_Real | cant_real | numeric(12,3) |
| 7 | Diferencia | diferencia | numeric(12,3) |

## me.caja_alertas_efectivo  ← CAJA_ALERTAS_EFECTIVO (estado, pocas filas)

| # | Header | Postgres | Tipo | Nota |
|---|---|---|---|---|
| 0 | idCaja | id_caja | text UNIQUE (PK) | |
| 1 | bandera | bandera | text (enum) | NORMAL·BAJO·CRITICO·EXCESO |
| 2 | montoUltimo | monto_ultimo | numeric(12,2) | |
| 3 | fechaActualizada | fecha_actualizada | timestamptz | |

## me.pickups_pendientes_envio  ← PICKUPS_PENDIENTES_ENVIO

| # | Header | Postgres | Tipo | Nota |
|---|---|---|---|---|
| 0 | idGuiaME | id_guia_me | text UNIQUE (PK) | |
| 1 | payload | payload | jsonb | items + zona + vendedor |
| 2 | intentos | intentos | int | |
| 3 | ultimoIntento | ultimo_intento | timestamptz | |
| 4 | ultimoError | ultimo_error | text | |
| 5 | estado | estado | text (enum) | PENDIENTE·ENVIADO·ERROR_PERSISTENTE·CANCELADO |

## me.radio_config  ← RadioConfig (config; clave-valor por tipo)

| # | Header | Postgres | Tipo | Nota |
|---|---|---|---|---|
| 0 | Tipo | tipo | text | playlist·ticker·destacado·image·cat·config |
| 1 | Key | key | text | |
| 2 | Valor | valor | text | |

## me.jornadas  ← JORNADAS (estructura inferida de Ventas.gs:397-431)

> ME escribe la jornada al abrir caja con turno. **No hay array de headers explícito**; estructura inferida del `appendRow` y de los índices que se leen (cols 1 y 3). Columnas 2/6/8 van vacías. **Confirmar headers reales contra la hoja antes del DDL.**

| # | Postgres (propuesto) | Valor que escribe ME | Nota |
|---|---|---|---|
| 0 | id_jornada (text PK) | `'JOR'+getTime()` | |
| 1 | fecha | fecha | se lee para dedup del día |
| 2 | (vacío) | `''` | sin etiqueta |
| 3 | vendedor | nombreVendedor | se lee para dedup |
| 4 | tipo | `'VENDEDOR'` | |
| 5 | origen | `'mosExpress'` | |
| 6 | (vacío) | `''` | |
| 7 | monto_base | monto | |
| 8 | (vacío) | `''` | |
| 9 | estado | `'AUTO'` | |
| 10 | fuente | `'AUTO_VENTA'` | |

> ⚠ Es la **misma hoja JORNADAS de MOS** (ME escribe vía bridge). Coordinar el modelo con el esquema de MOS para no duplicar — probablemente `mos.jornadas` compartida, no `me.jornadas`.

---

## me.zonas_config  ← ZONAS_CONFIG (híbrida — generada desde MOS, persistida en ME)

> Hueco detectado en verificación: ME tiene esta hoja PROPIA (Creditos.gs:782), generada dinámicamente en `Catalogo.gs:190` a partir de ESTACIONES/IMPRESORAS/SERIES_DOCUMENTALES de MOS. Confirmar columnas reales antes del DDL. Columnas probables: `Zona_ID, Estacion_Nombre, idEstacion, PrintNode_ID, Serie_Nota, Serie_Boleta, Serie_Factura, Admin_PIN`.
> **Decisión de modelado:** como es derivada del catálogo MOS, NO migrar como tabla propia → reconstruirla como **vista** sobre `mos.estaciones`/`mos.impresoras`/`mos.series_documentales`, o regenerarla como hoy. Evitar drift.

---

## Hojas que ME LEE de MOS (catálogo compartido — NO se duplican en `me`)

> Aclaración (verificación): ME **sintetiza** `PRODUCTO_BASE`/`PRESENTACIONES` en memoria desde `PRODUCTOS_MASTER`+`EQUIVALENCIAS` de MOS (`Catalogo.gs:75-117`); NO son hojas propias. `PERSONAL_MASTER` se lee tanto de MOS como localmente en algunos puntos (Caja.gs:779, Ventas.gs:413) — unificar a `mos.personal`. `ESTACIONES` se accede a veces local (Caja.gs:802,903): unificar a `mos.estaciones`.

Se consumen de `mos.*` (migradas temprano, §3 del plan). ME deja de tener copias locales (`PRODUCTO_BASE`, `PRESENTACIONES`).

| Hoja MOS | Columnas que ME usa |
|---|---|
| PRODUCTOS_MASTER → `mos.productos` | skuBase, idProducto, estado, esEnvasable, unidad, Unidad_Medida, precioVenta, factorConversion, descripcion, codigoBarra, Tipo_IGV, Cod_SUNAT |
| EQUIVALENCIAS → `mos.equivalencias` | codigoBarra, skuBase, activo |
| ESTACIONES → `mos.estaciones` | idEstacion, nombre, idZona, appOrigen, adminPin, activo |
| IMPRESORAS → `mos.impresoras` | tipo, idEstacion, printNodeId, appOrigen, activo |
| SERIES_DOCUMENTALES → `mos.series_documentales` | idZona, tipoDocumento, serie, activo |
| DISPOSITIVOS → `mos.dispositivos` | (verificación de device autorizado) |

---

## Enums de ME (CREATE TYPE)

```
tipo_doc:           NOTA_DE_VENTA · BOLETA · FACTURA
estado_envio:       COMPLETADO · ANULADO · HUERFANA_LIMPIADA
tipo_igv:           1 · 2 · 3                (smallint con CHECK)
nf_estado:          NA · EMITIENDO · EMITIDO · ERROR · RECHAZADO_SUNAT · PENDIENTE
tipo_mov_extra:     INGRESO · INGRESO_VIRTUAL · EGRESO · EGRESO_VIRTUAL
estado_caja:        ABIERTA · CERRADA · CERRADA_AUTO
tipo_guia_me:       SALIDA_VENTAS · SALIDA_JEFA · SALIDA_MOVIMIENTO · ENTRADA_ALMACEN · ENTRADA_TRASLADO · ENTRADA_LIBRE
estado_guia:        CONFIRMADO · PENDIENTE
estado_cobro:       ASIGNADO · COBRADO · RECHAZADO · CANCELADO · VENCIDO
estado_reserva:     ACTIVA · USADA · CANCELADA · EXPIRADA
bandera_efectivo:   NORMAL · BAJO · CRITICO · EXCESO
estado_pickup:      PENDIENTE · ENVIADO · ERROR_PERSISTENTE · CANCELADO
```

### ✅ `forma_pago` — RESUELTO (verificado en código)
Set EXACTO de valores (Code.gs:122-134 parser MIXTO; Caja.gs:349-395; Ventas.gs:213,359; EditarVenta.gs:70):
```
forma_pago:  EFECTIVO · POR_COBRAR · CREDITO · VIRTUAL · MIXTO_EFE:(n)_VIR:(n)
```
- **5 formas canónicas.** `YAPE/PLIN/TARJETA/TRANSFERENCIA` NO son valores de `forma_pago` — son sub-tipos de **VIRTUAL** (diferenciador de UI, no de backend).
- **MIXTO se codifica como STRING en una sola celda:** `MIXTO_EFE:150.00_VIR:50.00` (parser regex `/EFE:([\d.]+)/i`, `/VIR:([\d.]+)/i`). **No hay columnas aparte.** → en Postgres: guardar el string tal cual + opcional columnas derivadas `mixto_efe numeric`, `mixto_vir numeric` para reportería.
- **Distinción crítica:** `POR_COBRAR` (pre-venta, **se ANULA al cierre**) ≠ `CREDITO` (deuda formal aprobada por admin, **se preserva al cierre**). Reconciliar respetando esta regla.
- Modelar como `text` con `CHECK` (no enum rígido por el MIXTO string).

---

## COLUMNAS_TEXTO (forzar `text`, conservar ceros) — copiado de ME Code.gs

```
Cod_Barras, Cod_Barras_Real, SKU_Base, SKU, ID_Dispositivo, ID_Venta, ID_Caja, ID_Guia,
Documento, Documento_Cliente, doc, docCliente, DNI, RUC, numero_documento, Numero_Documento,
Cliente_Doc, Cliente_Documento
+ dinámicas: ID_Extra, idCaja (alertas), idGuiaME (pickups)
```

---

## Tabla de auditoría de backfill (común)

```
backfill_audit(
  id bigserial PK, app text, hoja text, fila int, columna text,
  tipo_issue text,        -- TRUNCATED_JSON · ORPHAN_ROW · HEADER_MISMATCH · BAD_BOOLEAN · BAD_DATE · LOST_ZERO · FK_MISSING
  valor text,             -- primeros 200 chars
  resuelto boolean default false, nota text, ts timestamptz default now()
)
```

---

# WH — warehouseMos (esquema `wh`) ⬜ ANDAMIAJE

> Completar con extracción de headers reales al iniciar la Fase 1 de WH (mismo método que ME). Tablas conocidas (de §16):

`guias` · `guia_detalle` · `stock` · `stock_movimientos` · `lotes_vencimiento` · `preingresos` · `mermas` · `envasados` · `ajustes` · `auditorias` · `producto_nuevo` · `listas_sombra` (items jsonb) · `devoluciones_zona` (payload_zona/payload_almacen/diferencias jsonb) · `pickups` · `sesiones` · `desempeno` · `ops_log` (purga 90d) · `sync_log` (rolling 2000) · `cargadores_log` · `alertas_stock` · `lotes_adhesivo` · `lotes_historial` · `tickets_impresos` · portal: `clientes` · `pedidos_cliente` · `pedidos_cliente_items` · `pedidos_cliente_adj`.

Puntos de atención WH (de las pasadas): FIFO de lotes con `cantidad_inicial`+`cantidad_consumida`; stock snapshot vs movimientos; `_conLock` se mantiene en Fase 1; portal cliente candidato a Realtime (Fase 2); archivos (foto/audio/excel) en Drive con URL.

---

# MOS — master (esquema `mos`) ⬜ ANDAMIAJE

> Completar al iniciar Fase 1 de MOS. **Catálogo compartido se migra TEMPRANO** (`productos`, `equivalencias`, `categorias`, `personal`).

Compartidas/catálogo: `productos` (con `tipo_producto` enum, self-FK `codigo_producto_base`, índices `codigo_barra`/`sku_base`) · `equivalencias` · `categorias` · `personal` · `proveedores` · `zonas` · `estaciones` · `impresoras` · `series_documentales` · `config`.

Resto: `historial_precios` · `pedidos_proveedor` · `pagos_proveedor` · `proveedores_productos` · `jornadas` · `liquidaciones` · `liquidaciones_dia` · `gastos` · `evaluaciones` · `promociones` · `dispositivos` · `device_state` · `auditoria_admin` · `alertas_log` · `bloqueos_usuario` · `horarios_dispositivo` / `config_horarios_apps` · `notificaciones_config` · `notificaciones_log` · `push_tokens` · `etiquetas_pendientes` · `membretes_me_pendientes` · `ubicaciones_historial` (purga 90d) · `audio_sesiones` · `audio_chunks` (purga 30d, blob en Drive) · `purgas_historicas` · `quota_dispositivos_log` · `cierre_noct_log`.

**NO migran a Postgres (se quedan en GAS):** `RTC_SIGNALING`, `DIAGNOSTICO_ESPIA` (efímeros). Secretos (PINs) se migran tal cual en Fase 1 (sin hashear; ver §31).
