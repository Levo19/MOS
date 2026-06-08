-- ============================================================
-- 04_schema_mos.sql — Tablas TRANSACCIONALES de MOS (app maestra) · Fase 1
-- ============================================================
-- El CATÁLOGO (10 tablas: productos/equivalencias/categorias/personal/zonas/
-- estaciones/impresoras/series_documentales/dispositivos/config) ya existe en `mos`
-- desde Fase 0 (01_schema_compartido.sql). Esto agrega las 17 hojas transaccionales.
--
-- Decisiones (verificadas con dumpHeadersMOS + chequearPKsMOS contra datos reales):
--   · numeric SIN precisión fija → cero overflow.
--   · jsonb SOLO en JSON real (horarioJson/datos_extra_json/controlChecks/items/meta-like).
--     Campos ambiguos/CSV (admins_libres, visto_csv, audiencia_*, datos) → text (no perder datos).
--   · liquidaciones_pagos: idPago NO único (1 pago = N días) → PK (id_pago,id_personal,fecha).
--   · liquidaciones_dia: idDia con 1 dup real → PK idDia (dedup keeps-last, migra 178/179).
--   · NO migra (no existen): LIQUIDACIONES legacy, ADHESIVOS_PLANTILLAS, ICONOS_BITMAPS_ADH.
--   · NO migra (espía, queda en GAS): audio_*/rtc_signaling/push_tokens/auditoria_espia.
--   · Diferido (operacional/vigilancia): ubicaciones_historial, notificaciones_log, etc.
--   · proveedores = GAP de Fase 0 (WH/ME lo leen de MOS) → se crea aquí.
-- ============================================================

-- ---------- PROVEEDORES (maestro; WH/ME lo leen de MOS) ----------
create table if not exists mos.proveedores (
  id_proveedor       text primary key,
  nombre             text,
  ruc                text,
  imagen             text,
  telefono           text,
  banco              text,
  numero_cuenta      text,
  cci                text,
  email              text,
  dia_pedido         text,
  dia_pago           text,
  dia_entrega        text,
  forma_pago         text,
  plazo_credito      text,
  responsable        text,
  categoria_producto text,
  estado             text
);

-- ---------- HISTORIAL_PRECIOS ----------
create table if not exists mos.historial_precios (
  id               text primary key,
  sku_base         text,
  codigo_barra     text,
  descripcion      text,
  precio_anterior  numeric,
  precio_nuevo     numeric,
  usuario          text,
  motivo           text,
  app_origen       text,
  fecha            timestamptz
);

-- ---------- PEDIDOS_PROVEEDOR ----------
create table if not exists mos.pedidos_proveedor (
  id_pedido        text primary key,
  id_proveedor     text,
  items            jsonb,
  monto_estimado   numeric,
  estado           text,
  fecha_creacion   timestamptz,
  fecha_estimada   timestamptz,
  usuario          text,
  notas            text
);

-- ---------- PAGOS_PROVEEDOR ----------
create table if not exists mos.pagos_proveedor (
  id_pago         text primary key,
  id_proveedor    text,
  monto           numeric,
  fecha           timestamptz,
  numero_factura  text,
  estado          text,
  observacion     text,
  registrado_por  text
);

-- ---------- JORNADAS (jornales diarios de personal) ----------
create table if not exists mos.jornadas (
  id_jornada     text primary key,
  fecha          timestamptz,
  id_personal    text,
  nombre         text,
  rol            text,
  app_origen     text,
  zona           text,
  monto_jornal   numeric,
  observacion    text,
  registrado_por text,
  fuente         text
);

-- ---------- GASTOS ----------
create table if not exists mos.gastos (
  id_gasto        text primary key,
  fecha           timestamptz,
  categoria       text,
  tipo            text,
  descripcion     text,
  monto           numeric,
  comprobante     text,
  registrado_por  text
);

-- ---------- LIQUIDACIONES_DIA (materialización de día pagado; 3 cols en blanco ignoradas) ----------
create table if not exists mos.liquidaciones_dia (
  id_dia              text primary key,
  fecha               timestamptz,
  id_personal         text,
  nombre              text,
  rol                 text,
  app_origen          text,
  virtual             text,
  monto_base          numeric,
  pago_envasado       numeric,
  bono_meta           numeric,
  sancion             numeric,
  total_dia           numeric,
  auditado            boolean,
  evaluaciones_count  numeric,
  score_final         numeric,
  tarifa_envasado     numeric,
  presente            boolean,
  estado              text,
  id_pago             text,
  ts_creado           timestamptz,
  ts_actualizado      timestamptz,
  bonificacion        numeric,
  bonificacion_motivo text,
  sancion_motivo      text
);

-- ---------- LIQUIDACIONES_PAGOS (detalle: 1 pago = N días → PK compuesta) ----------
create table if not exists mos.liquidaciones_pagos (
  id_pago            text not null,
  id_personal        text not null,
  fecha              timestamptz not null,
  nombre             text,
  rol                text,
  app_origen         text,
  monto_base         numeric,
  pago_envasado      numeric,
  bono_meta          numeric,
  sancion            numeric,
  total_dia          numeric,
  ticket_job_id      text,
  pagado_por         text,
  pagado_ts          timestamptz,
  estado             text,
  comentario         text,
  id_gasto_generado  text,
  primary key (id_pago, id_personal, fecha)
);

-- ---------- EVALUACIONES (diarias de personal) ----------
create table if not exists mos.evaluaciones (
  id_eval              text primary key,
  fecha                timestamptz,
  id_personal          text,
  rol                  text,
  hora                 text,
  limpieza_pct         numeric,
  limpieza_prof_pct    numeric,
  control_checks       jsonb,
  comentario           text,
  evaluado_por         text,
  aplica_comision      boolean,
  aplica_bono_meta     boolean,
  activo               boolean,
  sancion              numeric,
  sancion_motivo       text,
  bonificacion         numeric,
  bonificacion_motivo  text
);

-- ---------- BLOQUEOS_USUARIO (desbloqueos remotos) ----------
create table if not exists mos.bloqueos_usuario (
  id_bloqueo       text primary key,
  id_personal      text,
  nombre           text,
  app_origen       text,
  motivo           text,
  bloqueado_por    text,
  fecha_bloqueo    timestamptz,
  unlock_hasta     timestamptz,
  desbloqueado_por text
);

-- ---------- SEGURIDAD_ALERTAS ----------
create table if not exists mos.seguridad_alertas (
  id_alerta         text primary key,
  tipo              text,
  id_dispositivo    text,
  id_personal       text,
  fecha             timestamptz,
  descripcion       text,
  prioridad         text,
  estado            text,
  revisada_por      text,
  revisada_en       timestamptz,
  datos_extra_json  jsonb
);

-- ---------- CONFIG_HORARIOS_APPS (horarios de bloqueo por app) ----------
create table if not exists mos.config_horarios_apps (
  app                  text primary key,
  horario_json         jsonb,
  admins_libres        text,
  actualizado_por      text,
  fecha_actualizacion  timestamptz
);

-- ---------- ALERTAS_LOG (datos = text por ambigüedad, no perder) ----------
create table if not exists mos.alertas_log (
  id          text primary key,
  tipo        text,
  urgencia    text,
  mensaje     text,
  app_origen  text,
  datos       text,
  fecha       timestamptz,
  leida       boolean
);

-- ---------- CONEXIONES (registro de las 3 apps del ecosistema) ----------
create table if not exists mos.conexiones (
  id_app       text primary key,
  nombre       text,
  gas_url      text,
  ss_id        text,
  activo       boolean,
  ultima_sync  timestamptz,
  descripcion  text
);

-- ---------- ETIQUETAS_ZONA (etiquetas de precio por zona) ----------
create table if not exists mos.etiquetas_zona (
  id_etiq          text primary key,
  id_zona          text,
  zona_nombre      text,
  id_producto      text,
  descripcion      text,
  codigo_barra     text,
  sku_base         text,
  precio_anterior  numeric,
  precio_nuevo     numeric,
  ts_cambio        timestamptz,
  cambiado_por     text,
  estado           text,
  visto_csv        text,
  ts_impresa       timestamptz,
  impresa_por      text,
  job_id           text,
  ts_pegada        timestamptz,
  pegada_por       text,
  comentario       text
);

-- ---------- PROVEEDORES_PRODUCTOS (relación proveedor↔producto) ----------
create table if not exists mos.proveedores_productos (
  id_pp                 text primary key,
  id_proveedor          text,
  sku_base              text,
  codigo_barra          text,
  descripcion           text,
  precio_referencia     numeric,
  minimo_compra         numeric,
  dias_entrega          numeric,
  ultima_actualizacion  timestamptz,
  activa                boolean,
  notas                 text,
  unidades_por_bulto    numeric
);

-- ---------- NOTIFICACIONES_CONFIG (catálogo de notificaciones; audiencia_* = CSV→text) ----------
create table if not exists mos.notificaciones_config (
  id_notif            text primary key,
  origen              text,
  titulo              text,
  descripcion         text,
  icono               text,
  activa              boolean,
  audiencia_roles     text,
  audiencia_usuarios  text,
  excluir_origen      text,
  prioridad           text,
  silenciada_hasta    timestamptz,
  sonido_custom       text,
  ts_actualizado      timestamptz,
  actualizado_por     text
);

-- ============================================================
-- Índices (consultas frecuentes)
-- ============================================================
create index if not exists ix_mos_histprecios_sku    on mos.historial_precios (sku_base);
create index if not exists ix_mos_histprecios_fecha  on mos.historial_precios (fecha);
create index if not exists ix_mos_jornadas_personal  on mos.jornadas (id_personal);
create index if not exists ix_mos_jornadas_fecha     on mos.jornadas (fecha);
create index if not exists ix_mos_gastos_fecha       on mos.gastos (fecha);
create index if not exists ix_mos_liqdia_personal    on mos.liquidaciones_dia (id_personal);
create index if not exists ix_mos_liqdia_fecha       on mos.liquidaciones_dia (fecha);
create index if not exists ix_mos_liqpagos_personal  on mos.liquidaciones_pagos (id_personal);
create index if not exists ix_mos_eval_personal      on mos.evaluaciones (id_personal);
create index if not exists ix_mos_eval_fecha         on mos.evaluaciones (fecha);
create index if not exists ix_mos_segalertas_disp    on mos.seguridad_alertas (id_dispositivo);
create index if not exists ix_mos_segalertas_estado  on mos.seguridad_alertas (estado);
create index if not exists ix_mos_pagosprov_prov     on mos.pagos_proveedor (id_proveedor);
create index if not exists ix_mos_pedidosprov_prov   on mos.pedidos_proveedor (id_proveedor);
create index if not exists ix_mos_provprod_prov      on mos.proveedores_productos (id_proveedor);
create index if not exists ix_mos_provprod_sku       on mos.proveedores_productos (sku_base);
create index if not exists ix_mos_etiqzona_zona      on mos.etiquetas_zona (id_zona);
create index if not exists ix_mos_bloqueos_personal  on mos.bloqueos_usuario (id_personal);

-- ============================================================
-- RLS + GRANTS (idempotente; el loop cubre también las 10 de catálogo, sin efecto)
-- ============================================================
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname='mos'
  loop
    execute format('alter table mos.%I enable row level security;', t);
  end loop;
end $$;

grant usage on schema mos to service_role;
grant all privileges on all tables in schema mos to service_role;
grant all privileges on all sequences in schema mos to service_role;
alter default privileges in schema mos grant all on tables to service_role;
alter default privileges in schema mos grant all on sequences to service_role;
