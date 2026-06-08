-- ============================================================
-- MIGRACIÓN SUPABASE — FASE 1 · MosExpress (esquema me)
-- 02: Tablas transaccionales de ME + índices + grants
-- Ejecutar en: Supabase → SQL Editor (después de 01_schema_compartido.sql)
-- Idempotente (IF NOT EXISTS). Status como text (sin enum rígido) para
-- no romper el backfill con valores legacy; valores válidos en comentarios.
-- ============================================================

-- ---------- me.ventas  ← VENTAS_CABECERA ----------
-- forma_pago: EFECTIVO · POR_COBRAR · CREDITO · VIRTUAL · MIXTO_EFE:x_VIR:y
-- tipo_doc:   NOTA_DE_VENTA · BOLETA · FACTURA
-- estado_envio: COMPLETADO · ANULADO · HUERFANA_LIMPIADA
-- nf_estado:  NA · EMITIENDO · EMITIDO · ERROR · RECHAZADO_SUNAT · PENDIENTE
create table if not exists me.ventas (
  id_venta          text primary key,
  fecha             timestamptz,
  vendedor          text,
  estacion          text,
  cliente_doc       text,
  cliente_nombre    text,
  total             numeric(12,2),
  tipo_doc          text,
  forma_pago        text,
  correlativo       text,
  id_caja           text,
  dispositivo_id    text,
  estado_envio      text,
  ref_local         text,
  obs               text,
  tipo_doc_cliente  smallint,
  nf_estado         text,
  nf_hash           text,
  nf_enlace         text,
  historial_cambios jsonb,
  zona_id           text,                 -- RLS-ready
  created_at        timestamptz default now(),
  updated_at        timestamptz default now()
);
create index if not exists ix_me_ventas_fecha    on me.ventas (fecha);
create index if not exists ix_me_ventas_caja     on me.ventas (id_caja);
create index if not exists ix_me_ventas_forma    on me.ventas (forma_pago);
create index if not exists ix_me_ventas_cli      on me.ventas (cliente_doc);
create index if not exists ix_me_ventas_disp     on me.ventas (dispositivo_id);
create index if not exists ix_me_ventas_estado   on me.ventas (estado_envio);
create index if not exists ix_me_ventas_zona     on me.ventas (zona_id);

-- ---------- me.ventas_detalle  ← VENTAS_DETALLE ----------
-- `linea` lo genera el backfill (row_number por id_venta). PK compuesta = idempotencia.
create table if not exists me.ventas_detalle (
  id_venta       text not null,
  linea          int  not null,
  sku            text,
  nombre         text,
  cantidad       numeric(12,3),
  precio         numeric(12,2),
  subtotal       numeric(12,2),
  cod_barras     text,
  valor_unitario numeric(12,4),
  tipo_igv       smallint,   -- catálogo SUNAT (1=gravado, 8=IVAP, 9=exonerado, 11=inafecto…); sin CHECK p/ no rechazar legacy
  unidad_medida  text,
  primary key (id_venta, linea)
);
create index if not exists ix_me_vdet_sku     on me.ventas_detalle (sku);
create index if not exists ix_me_vdet_cb      on me.ventas_detalle (cod_barras);

-- ---------- me.cajas  ← CAJAS ----------
-- estado: ABIERTA · CERRADA · CERRADA_AUTO
create table if not exists me.cajas (
  id_caja        text primary key,
  vendedor       text,
  estacion       text,
  fecha_apertura timestamptz,
  monto_inicial  numeric(12,2),
  estado         text,
  monto_final    numeric(12,2),
  fecha_cierre   timestamptz,
  zona_id        text,
  printnode_id   text,
  dispositivo_id text,                  -- RLS-ready
  created_at     timestamptz default now(),
  updated_at     timestamptz
);
create index if not exists ix_me_cajas_zona   on me.cajas (zona_id);
create index if not exists ix_me_cajas_estado on me.cajas (estado);
create index if not exists ix_me_cajas_apert  on me.cajas (fecha_apertura);

-- ---------- me.movimientos_extra  ← MOVIMIENTOS_EXTRA ----------
-- tipo: INGRESO · INGRESO_VIRTUAL · EGRESO · EGRESO_VIRTUAL
create table if not exists me.movimientos_extra (
  id_extra          text primary key,
  id_caja           text,
  ts                timestamptz,
  tipo              text,
  monto             numeric(12,2),
  concepto          text,
  obs               text,
  registrado_por    text,
  historial_cambios jsonb,
  zona_id           text,               -- RLS-ready (deriva de la caja)
  dispositivo_id    text,
  created_at        timestamptz default now(),
  updated_at        timestamptz
);
create index if not exists ix_me_movext_caja on me.movimientos_extra (id_caja);

-- ---------- me.clientes_frecuentes  ← CLIENTES_FRECUENTES ----------
create table if not exists me.clientes_frecuentes (
  documento         text primary key,
  nombre            text,
  tipo_doc          smallint,
  fecha_registro    timestamptz,
  direccion         text,
  historial_cambios jsonb
);

-- ---------- me.guias_cabecera  ← GUIAS_CABECERA ----------
create table if not exists me.guias_cabecera (
  id_guia      text primary key,
  fecha        timestamptz,
  vendedor     text,
  zona_id      text,
  tipo         text,   -- SALIDA_VENTAS · SALIDA_JEFA · SALIDA_MOVIMIENTO · ENTRADA_*
  observacion  text,
  zona_destino text,
  estado       text    -- CONFIRMADO · PENDIENTE
);
create index if not exists ix_me_guiac_fecha on me.guias_cabecera (fecha);

-- ---------- me.guias_detalle  ← GUIAS_DETALLE ----------
-- `linea` generado por backfill (row_number por id_guia) → PK compuesta idempotente.
create table if not exists me.guias_detalle (
  id_guia    text not null,
  linea      int  not null,
  cod_barras text,
  cantidad   numeric(12,3),
  primary key (id_guia, linea)
);

-- ---------- me.correlativos  ← CORRELATIVOS (atómico vía UPDATE...RETURNING) ----------
create table if not exists me.correlativos (
  serie     text primary key,
  siguiente bigint
);

-- ---------- me.reservas_correlativos  ← RESERVAS_CORRELATIVOS ----------
-- estado: ACTIVA · USADA · CANCELADA · EXPIRADA
create table if not exists me.reservas_correlativos (
  id_reserva     text primary key,
  serie          text,
  numero         bigint,
  vendedor       text,
  dispositivo_id text,
  reservado_at   timestamptz,
  estado         text,
  usado_at       timestamptz,
  id_venta       text
);
create index if not exists ix_me_reserv_estado on me.reservas_correlativos (estado);

-- ---------- me.creditos_cobro_asignado  ← CREDITOS_COBRO_ASIGNADO (18 cols reales) ----------
-- estado: ASIGNADO · COBRADO · RECHAZADO · CANCELADO · EXPIRADO
-- Headers exactos de _CREDITO_COBRO_HEADERS (Creditos.gs:22-29).
create table if not exists me.creditos_cobro_asignado (
  id_cobro          text primary key,   -- ID_Cobro
  id_venta          text,               -- ID_Venta
  caja_destino      text,               -- Caja_Destino
  vendedor_dest     text,               -- Vendedor_Dest
  metodo_sug        text,               -- Metodo_Sug
  estado            text,               -- Estado
  admin_asignador   text,               -- Admin_Asignador
  fecha_asig        timestamptz,        -- Fecha_Asig
  fecha_res         timestamptz,        -- Fecha_Res
  razon             text,               -- Razon
  id_caja_origen    text,               -- ID_Caja_Origen
  monto             numeric(12,2),      -- Monto
  cliente_nombre    text,               -- Cliente_Nombre
  correlativo       text,               -- Correlativo
  fecha_vencimiento timestamptz,        -- Fecha_Vencimiento
  horas_ttl         int,                -- Horas_TTL
  mensaje_admin     text,               -- Mensaje_Admin
  reasignaciones    int,                -- Reasignaciones
  created_at        timestamptz default now(),
  updated_at        timestamptz
);
create index if not exists ix_me_credito_venta on me.creditos_cobro_asignado (id_venta);
create index if not exists ix_me_credito_estado on me.creditos_cobro_asignado (estado);

-- ---------- me.ventas_fantasma  ← VENTAS_FANTASMA (auditoría de rechazos) ----------
-- id bigserial + clave natural best-effort para idempotencia del backfill.
create table if not exists me.ventas_fantasma (
  id                bigserial primary key,
  ts                timestamptz,
  vendedor          text,
  zona_id           text,
  estacion          text,
  dispositivo_id    text,
  monto             numeric(12,2),
  metodo            text,
  tipo_doc          text,
  doc_cliente       text,
  nombre_cliente    text,
  correlativo_local text,
  caja_id_enviada   text,
  motivo            text,
  mensaje           text,
  estado_revision   text,
  revisado_por      text,
  fecha_revision    timestamptz,
  accion_tomada     text,
  payload_json      jsonb
);
create unique index if not exists uq_me_fantasma_rk
  on me.ventas_fantasma (ts, dispositivo_id, correlativo_local)
  where ts is not null and correlativo_local is not null;  -- evita falsos duplicados con NULLs

-- ---------- me.auditorias  ← AUDITORIAS (conteo físico de stock) ----------
create table if not exists me.auditorias (
  id_auditoria text primary key,
  fecha        timestamptz,
  vendedor     text,
  zona_id      text,
  cod_barras   text,
  cant_sistema numeric(12,3),
  cant_real    numeric(12,3),
  diferencia   numeric(12,3)
);

-- ---------- me.caja_alertas_efectivo  ← CAJA_ALERTAS_EFECTIVO ----------
-- bandera: NORMAL · BAJO · CRITICO · EXCESO
create table if not exists me.caja_alertas_efectivo (
  id_caja           text primary key,
  bandera           text,
  monto_ultimo      numeric(12,2),
  fecha_actualizada timestamptz
);

-- ---------- me.pickups_pendientes_envio  ← PICKUPS_PENDIENTES_ENVIO ----------
-- estado: PENDIENTE · ENVIADO · ERROR_PERSISTENTE · CANCELADO
create table if not exists me.pickups_pendientes_envio (
  id_guia_me     text primary key,
  payload        jsonb,
  intentos       int,
  ultimo_intento timestamptz,
  ultimo_error   text,
  estado         text
);

-- ---------- me.stock_zonas  ← STOCK_ZONAS (snapshot mutable) ----------
create table if not exists me.stock_zonas (
  cod_barras             text not null,
  zona_id                text not null,
  cantidad               numeric(12,3),
  usuario                text,
  fecha_ultimo_registro  timestamptz,
  primary key (cod_barras, zona_id)
);

-- ---------- me.stock_movimientos  (NUEVO — log que ME no tiene hoy) ----------
-- Lo llena la doble escritura (Fase 1.C) para trazabilidad + reconciliación de stock.
create table if not exists me.stock_movimientos (
  id          bigserial primary key,
  cod_barras  text,
  zona_id     text,
  tipo        text,            -- VENTA · AJUSTE · INGRESO · etc.
  delta       numeric(12,3),
  referencia  text,            -- id_venta / id_guia / etc.
  usuario     text,
  ts          timestamptz default now()
);
create index if not exists ix_me_stockmov_cb on me.stock_movimientos (cod_barras, zona_id);

-- ---------- me.radio_config  ← RadioConfig ----------
create table if not exists me.radio_config (
  id    bigserial primary key,
  tipo  text,
  key   text,
  valor text
);
create unique index if not exists uq_me_radio on me.radio_config (tipo, key);

-- ============================================================
-- GRANTS para la Data API (service_role) en el esquema me
-- ============================================================
grant usage on schema me to service_role, anon, authenticated;
grant all on all tables    in schema me to service_role;
grant all on all sequences in schema me to service_role;
grant all on all functions in schema me to service_role;
-- (los alter default privileges del 01 ya cubren objetos futuros)

-- ============================================================
-- POST-BACKFILL opcional (ejecutar tras cargar datos; ver runbook):
--   alter table me.ventas_detalle add constraint fk_vdet_venta
--     foreign key (id_venta) references me.ventas(id_venta) on delete cascade not valid;
--   alter table me.movimientos_extra add constraint fk_movext_caja
--     foreign key (id_caja) references me.cajas(id_caja) not valid;
-- (NOT VALID = aplica a futuros sin fallar por datos legacy)
-- ============================================================

-- ============================================================
-- NOTAS DE DISEÑO (decisiones tomadas en revisión senior)
-- ============================================================
-- · JORNADAS: NO se crea aquí — es la MISMA hoja de MOS (ME escribe vía bridge).
--   Se modela como mos.jornadas (compartida) en la fase de MOS.
-- · ZONAS_CONFIG: NO se crea como tabla — es derivada del catálogo MOS.
--   En Fase 2 se reconstruye como VISTA sobre mos.estaciones/impresoras/series.
-- · `linea` (ventas_detalle / guias_detalle): el BACKFILL debe asignarla de forma
--   DETERMINISTA por id_venta/id_guia (orden de fila de la hoja) y procesar cada
--   documento COMPLETO dentro del mismo chunk (no partir un id entre lotes), para
--   que al reanudar no cambie la numeración y la PK (id, linea) sea idempotente.
-- · Auditar pre-backfill: detalle huérfano (id_venta sin cabecera) antes de activar FKs.
-- · RLS columns completas (created_by, etc.) se agregan en Fase 2 con un ALTER barato.
-- ============================================================
