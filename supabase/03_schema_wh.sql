-- ============================================================
-- 03_schema_wh.sql — Esquema wh (warehouseMos) · Fase 1 migración Supabase
-- ============================================================
-- Requisitos previos: 01_schema_compartido.sql ya corrido (crea schema wh).
-- Tras correr esto: exponer el esquema `wh` en Settings → API → Exposed schemas.
--
-- Decisiones (verificadas con datos reales vía chequearPKsWH/inspeccionarRestoWH):
--   · numeric SIN precisión fija → cero overflow (lección de ME numeric(12,3)).
--   · timestamptz para fechas; text para horas (time-serial 1899) y CSV (fotos).
--   · jsonb SOLO en columnas JSON reales: items, payload, resultado, itemsJson, snapshotAviso.
--   · guia_detalle: idDetalle NO es único (1684 dups) → PK (id_guia, linea) determinista.
--   · auditorias: idAuditoria SÍ es único (1067) → PK simple (a diferencia de me.auditorias).
--   · NO se migran PRODUCTOS/PROVEEDORES/PERSONAL/ZONAS/CATEGORIAS: no existen en WH (los lee de mos.*).
--   · SYNC_LOG omitido (log de idempotencia/replay, se purga solo).
-- ============================================================

create schema if not exists wh;

-- ---------- GUIAS (cabecera) ----------
create table if not exists wh.guias (
  id_guia               text primary key,
  tipo                  text,
  fecha                 timestamptz,
  usuario               text,
  id_proveedor          text,
  id_zona               text,
  numero_documento      text,
  comentario            text,
  monto_total           numeric,
  estado                text,
  id_preingreso         text,
  foto                  text,
  ocr_estado            text,
  ocr_tipo              text,
  ocr_ruc_emisor        text,
  ocr_razon_social      text,
  ocr_serie             text,
  ocr_numero            text,
  ocr_fecha_comprobante text,
  ocr_total             numeric,
  ocr_subtotal          numeric,
  igv_recuperable       numeric,
  ocr_confidence        numeric,
  ocr_notas             text,
  ocr_fecha_proceso     timestamptz
);

-- ---------- GUIA_DETALLE (PK compuesta con linea determinista) ----------
create table if not exists wh.guia_detalle (
  id_guia            text not null,
  linea              int  not null,
  cod_producto       text,
  cant_esperada      numeric,
  cant_recibida      numeric,
  precio_unitario    numeric,
  id_lote            text,
  observacion        text,
  id_producto_nuevo  text,
  primary key (id_guia, linea)
);

-- ---------- STOCK ----------
create table if not exists wh.stock (
  id_stock              text primary key,
  cod_producto          text,
  cantidad_disponible   numeric,
  ultima_actualizacion  timestamptz
);

-- ---------- STOCK_MOVIMIENTOS ----------
create table if not exists wh.stock_movimientos (
  id_mov          text primary key,
  fecha           timestamptz,
  cod_producto    text,
  delta           numeric,
  stock_antes     numeric,
  stock_despues   numeric,
  tipo_operacion  text,
  origen          text,
  usuario         text
);

-- ---------- LOTES_VENCIMIENTO ----------
create table if not exists wh.lotes_vencimiento (
  id_lote            text primary key,
  cod_producto       text,
  fecha_vencimiento  timestamptz,
  cantidad_inicial   numeric,
  cantidad_actual    numeric,
  id_guia            text,
  estado             text,
  fecha_creacion     timestamptz
);

-- ---------- MERMAS ----------
create table if not exists wh.mermas (
  id_merma                text primary key,
  fecha_ingreso           timestamptz,
  origen                  text,
  cod_producto            text,
  id_lote                 text,
  cantidad_original       numeric,
  cantidad_pendiente      numeric,
  motivo                  text,
  usuario                 text,
  id_guia                 text,
  estado                  text,
  responsable             text,
  cantidad_reparada       numeric,
  cantidad_desechada      numeric,
  foto                    text,
  fecha_resolucion        timestamptz,
  observacion_resolucion  text,
  id_guia_salida          text
);

-- ---------- AUDITORIAS (PK simple: idAuditoria único) ----------
create table if not exists wh.auditorias (
  id_auditoria      text primary key,
  fecha_asignacion  timestamptz,
  cod_producto      text,
  usuario           text,
  stock_sistema     numeric,
  stock_fisico      numeric,
  diferencia        numeric,
  resultado         text,
  observacion       text,
  estado            text,
  fecha_ejecucion   timestamptz
);

-- ---------- AJUSTES ----------
create table if not exists wh.ajustes (
  id_ajuste        text primary key,
  cod_producto     text,
  tipo_ajuste      text,
  cantidad_ajuste  numeric,
  motivo           text,
  usuario          text,
  id_auditoria     text,
  fecha            timestamptz
);

-- ---------- ENVASADOS ----------
create table if not exists wh.envasados (
  id_envasado            text primary key,
  cod_producto_base      text,
  cantidad_base          numeric,
  unidad_base            text,
  cod_producto_envasado  text,
  unidades_esperadas     numeric,
  unidades_producidas    numeric,
  merma_real             numeric,
  eficiencia_pct         numeric,
  fecha                  timestamptz,
  usuario                text,
  estado                 text,
  id_guia_salida         text,
  id_guia_ingreso        text,
  observacion            text
);

-- ---------- PREINGRESOS (cargadores nuevo; snapshotAviso jsonb; fotos = CSV text) ----------
create table if not exists wh.preingresos (
  id_preingreso   text primary key,
  fecha           timestamptz,
  id_proveedor    text,
  cargadores      text,
  usuario         text,
  monto           numeric,
  fotos           text,
  comentario      text,
  estado          text,
  id_guia         text,
  snapshot_aviso  jsonb
);

-- ---------- PRODUCTO_NUEVO ----------
create table if not exists wh.producto_nuevo (
  id_producto_nuevo  text primary key,
  id_guia            text,
  marca              text,
  descripcion        text,
  codigo_barra       text,
  id_categoria       text,
  unidad             text,
  cantidad           numeric,
  fecha_vencimiento  timestamptz,
  foto               text,
  estado             text,
  usuario            text,
  fecha_registro     timestamptz,
  aprobado_por       text,
  fecha_aprobacion   timestamptz
);

-- ---------- SESIONES (hora_inicio/fin = text HH:mm:ss UTC; minutos puede ser #NUM!→null) ----------
create table if not exists wh.sesiones (
  id_sesion        text primary key,
  id_personal      text,
  fecha_inicio     timestamptz,
  hora_inicio      text,
  fecha_fin        timestamptz,
  hora_fin         text,
  minutos_activos  numeric,
  estado           text
);

-- ---------- DESEMPENO ----------
create table if not exists wh.desempeno (
  id_desempeno            text primary key,
  id_personal             text,
  id_sesion               text,
  fecha                   timestamptz,
  minutos_activos         numeric,
  horas_trabajadas        numeric,
  guias_creadas           numeric,
  guias_cerradas          numeric,
  envasados_registrados   numeric,
  unidades_envasadas      numeric,
  mermas_registradas      numeric,
  auditoria_ejecutadas    numeric,
  preingreso_creados      numeric,
  ajustes_realizados      numeric,
  total_actividades       numeric,
  actividades_por_hora    numeric,
  puntuacion              numeric,
  calificacion            text,
  monto_base              numeric,
  monto_bonus             numeric,
  monto_total             numeric,
  estado                  text
);

-- ---------- PICKUPS (items jsonb) ----------
create table if not exists wh.pickups (
  id_pickup        text primary key,
  fuente           text,
  estado           text,
  items            jsonb,
  id_zona          text,
  notas            text,
  creado_por       text,
  fecha_creado     timestamptz,
  fecha_atendido   timestamptz,
  atendido_por     text,
  ultima_actividad timestamptz
);

-- ---------- OPS_LOG (payload/resultado jsonb) ----------
create table if not exists wh.ops_log (
  id_op           text primary key,
  id_guia         text,
  tipo            text,
  payload         jsonb,
  estado          text,
  device_id       text,
  usuario         text,
  fecha_creado    timestamptz,
  fecha_aplicado  timestamptz,
  error           text,
  resultado       jsonb
);

-- ---------- CARGADORES_LOG ----------
create table if not exists wh.cargadores_log (
  id_log       text primary key,
  fecha        timestamptz,
  id_cargador  text,
  nombre       text,
  added_by     text,
  device_id    text,
  ts           timestamptz,
  estado       text
);

-- ---------- LISTAS_SOMBRA (items jsonb) ----------
create table if not exists wh.listas_sombra (
  id_lista          text primary key,
  fecha_creacion    timestamptz,
  usuario_creador   text,
  items             jsonb,
  estado            text,
  usuario_tomada    text,
  fecha_tomada      timestamptz,
  fecha_completada  timestamptz,
  nota              text
);

-- ---------- LOTES_ADHESIVO (itemsJson jsonb; vto = text para preservar formato de etiqueta) ----------
create table if not exists wh.lotes_adhesivo (
  id_lote                  text primary key,
  fecha_creacion           timestamptz,
  fecha_ultimo_update      timestamptz,
  usuario                  text,
  origen                   text,
  codigo_barra             text,
  descripcion              text,
  vto                      text,
  total_etq                numeric,
  completadas              numeric,
  sub_job_size             numeric,
  status                   text,
  ultimo_error             text,
  ultimo_printnode_job_id  text,
  printer_id               text,
  tipo_etiqueta            text,
  items_json               jsonb
);

-- ---------- ALERTAS_STOCK ----------
create table if not exists wh.alertas_stock (
  id_alerta       text primary key,
  fecha           timestamptz,
  cod_producto    text,
  descripcion     text,
  stock_real      numeric,
  stock_teorico   numeric,
  diferencia      numeric,
  revisado        boolean,
  fecha_revision  timestamptz
);

-- ---------- CONFIG (local de WH) ----------
create table if not exists wh.config (
  clave        text primary key,
  valor        text,
  descripcion  text
);

-- ---------- PORTAL CLIENTE ----------
create table if not exists wh.clientes (
  token          text primary key,
  nombre         text,
  telefono       text,
  tipo           text,
  premium        boolean,
  fecha_alta     timestamptz,
  ultimo_pedido  timestamptz
);

create table if not exists wh.pedidos_cliente (
  id_pedido        text primary key,
  token            text,
  ts               timestamptz,
  estado           text,
  id_lista_sombra  text,
  total_estimado   numeric,
  notas            text
);

create table if not exists wh.pedidos_cliente_items (
  id_pedido   text not null,
  idx         int  not null,
  nombre      text,
  cantidad    numeric,
  unidad      text,
  precio_est  numeric,
  duda        text,
  primary key (id_pedido, idx)
);

create table if not exists wh.pedidos_cliente_adj (
  id_pedido      text not null,
  linea          int  not null,
  tipo           text,
  nombre_archivo text,
  url_drive      text,
  ts             timestamptz,
  primary key (id_pedido, linea)
);

-- ============================================================
-- Índices (consultas frecuentes: por producto, por guía, por fecha)
-- ============================================================
create index if not exists ix_wh_guia_detalle_guia      on wh.guia_detalle (id_guia);
create index if not exists ix_wh_guia_detalle_prod       on wh.guia_detalle (cod_producto);
create index if not exists ix_wh_guias_proveedor         on wh.guias (id_proveedor);
create index if not exists ix_wh_guias_fecha             on wh.guias (fecha);
create index if not exists ix_wh_guias_preingreso        on wh.guias (id_preingreso);
create index if not exists ix_wh_stock_prod              on wh.stock (cod_producto);
create index if not exists ix_wh_stockmov_prod           on wh.stock_movimientos (cod_producto);
create index if not exists ix_wh_stockmov_fecha          on wh.stock_movimientos (fecha);
create index if not exists ix_wh_lotes_prod              on wh.lotes_vencimiento (cod_producto);
create index if not exists ix_wh_lotes_estado            on wh.lotes_vencimiento (estado);
create index if not exists ix_wh_mermas_prod             on wh.mermas (cod_producto);
create index if not exists ix_wh_mermas_estado           on wh.mermas (estado);
create index if not exists ix_wh_auditorias_prod         on wh.auditorias (cod_producto);
create index if not exists ix_wh_ajustes_prod            on wh.ajustes (cod_producto);
create index if not exists ix_wh_envasados_base          on wh.envasados (cod_producto_base);
create index if not exists ix_wh_preingresos_proveedor   on wh.preingresos (id_proveedor);
create index if not exists ix_wh_prodnuevo_guia          on wh.producto_nuevo (id_guia);
create index if not exists ix_wh_sesiones_personal       on wh.sesiones (id_personal);
create index if not exists ix_wh_desempeno_personal      on wh.desempeno (id_personal);
create index if not exists ix_wh_pickups_estado          on wh.pickups (estado);
create index if not exists ix_wh_alertas_prod            on wh.alertas_stock (cod_producto);
create index if not exists ix_wh_pedidos_token           on wh.pedidos_cliente (token);

-- ============================================================
-- RLS: habilitado sin políticas → anon bloqueado, service_role bypassa
-- ============================================================
do $$
declare t text;
begin
  for t in
    select tablename from pg_tables where schemaname='wh'
  loop
    execute format('alter table wh.%I enable row level security;', t);
  end loop;
end $$;

-- ============================================================
-- GRANTS para service_role (PostgREST con la legacy service key)
-- ============================================================
grant usage on schema wh to service_role, anon, authenticated;
grant all privileges on all tables in schema wh to service_role;
grant all privileges on all sequences in schema wh to service_role;
grant all privileges on all functions in schema wh to service_role;
alter default privileges in schema wh grant all on tables to service_role;
alter default privileges in schema wh grant all on sequences to service_role;
alter default privileges in schema wh grant all on functions to service_role;
