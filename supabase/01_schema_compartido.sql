-- ============================================================
-- MIGRACIÓN SUPABASE — FASE 0
-- 01: Esquemas, helpers, catálogo compartido (mos.*) y auditoría de backfill
-- Ejecutar en: Supabase → SQL Editor (proyecto Pro)
-- Idempotente: usa IF NOT EXISTS / CREATE OR REPLACE.
-- ============================================================

-- ---------- Esquemas ----------
create schema if not exists mos;
create schema if not exists me;
create schema if not exists wh;

-- ⚠ IMPORTANTE: en Supabase → Settings → API → "Exposed schemas",
--    agregar  mos, me, wh  (además de public) para que PostgREST los sirva.
--    Sin esto, las llamadas REST a estos esquemas devuelven 404/406.

-- ---------- Helper de zona horaria Perú ----------
create or replace function mos.hoy_lima() returns date
  language sql stable
  set search_path = ''            -- endurecimiento: no depende del search_path del caller
  as $$ select (now() at time zone 'America/Lima')::date $$;
-- Higiene "cero PUBLIC" del proyecto: `language sql` sin revoke deja EXECUTE a PUBLIC (anon incluido).
-- hoy_lima es un helper puro (sin acceso a datos ni side-effects) → impacto de datos nulo, pero cerramos el
-- grant para mantener el estándar del ecosistema (ver fix análogo en 77_/78_). Lo usan RPCs definer y GAS.
revoke all on function mos.hoy_lima() from public;
grant execute on function mos.hoy_lima() to service_role;

-- ---------- Enums ----------
do $$ begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'producto_tipo' and n.nspname = 'mos'
  ) then
    create type mos.producto_tipo as enum ('CANONICO','PRESENTACION','DERIVADO');
  end if;
end $$;

-- ============================================================
-- CATÁLOGO / MAESTRAS COMPARTIDAS (leídas por ME y WH)
-- ============================================================

-- ---------- mos.productos ----------
create table if not exists mos.productos (
  id_producto            text primary key,
  sku_base               text,
  codigo_barra           text,
  descripcion            text,
  marca                  text,
  id_categoria           text,
  unidad                 text,
  precio_venta           numeric(12,2),
  precio_costo           numeric(12,2),
  cod_tributo            text,
  igv_porcentaje         numeric(5,2),
  cod_sunat              text,
  tipo_igv               smallint check (tipo_igv in (1,2,3)),
  unidad_medida          text,
  estado                 boolean default true,
  es_envasable           boolean default false,
  codigo_producto_base   text,            -- self-ref (FK se agrega tras backfill)
  factor_conversion      numeric(12,4),
  factor_conversion_base numeric(12,4),
  merma_esperada_pct     numeric(5,2),
  stock_minimo           numeric(12,3),
  stock_maximo           numeric(12,3),
  zona                   text,
  fecha_creacion         timestamptz,
  creado_por             text,
  modo_venta             text,            -- MARGEN/FIJO/COMPETITIVO/LIBRE
  margen_pct             numeric(5,2),
  precio_tope            numeric(12,2),
  foto_url               text,
  historial_cambios      jsonb,
  segmentos_precio       jsonb,
  tipo_producto          mos.producto_tipo,   -- calculado en backfill
  -- columnas RLS-ready / auditoría
  created_at             timestamptz default now(),
  updated_at             timestamptz default now()
);
create index if not exists ix_productos_codigo_barra on mos.productos (codigo_barra) where codigo_barra is not null and codigo_barra <> '';
create index if not exists ix_productos_sku_base     on mos.productos (sku_base);
create index if not exists ix_productos_categoria    on mos.productos (id_categoria);
create index if not exists ix_productos_estado       on mos.productos (estado);
create index if not exists ix_productos_base         on mos.productos (codigo_producto_base) where codigo_producto_base is not null and codigo_producto_base <> '';
create index if not exists ix_productos_tipo         on mos.productos (tipo_producto);

-- ---------- mos.equivalencias ----------
create table if not exists mos.equivalencias (
  id_equiv      text primary key,
  sku_base      text,
  codigo_barra  text,
  descripcion   text,
  activo        boolean default true,
  created_at    timestamptz default now()
);
create index if not exists ix_equiv_codigo_barra on mos.equivalencias (codigo_barra) where activo is true;
create index if not exists ix_equiv_sku_base     on mos.equivalencias (sku_base);

-- ---------- mos.categorias ----------
create table if not exists mos.categorias (
  id_categoria   text primary key,
  nombre         text,
  modo_venta     text,
  margen_pct     numeric(5,2),
  precio_tope    numeric(12,2),
  descripcion    text,
  estado         boolean default true,
  fecha_creacion timestamptz
);

-- ---------- mos.personal ----------
create table if not exists mos.personal (
  id_personal     text primary key,
  nombre          text,
  apellido        text,
  tipo            text,        -- OPERADOR / VENDEDOR
  app_origen      text,        -- warehouseMos / mosExpress / MOS
  rol             text,        -- ALMACENERO/ENVASADOR/VENDEDOR/ADMINISTRADOR/MASTER
  pin             text,        -- ⚠ Fase 1: tal cual (sin hashear); hashear en Fase 2
  color           text,
  tarifa_hora     numeric(12,2),
  monto_base      numeric(12,2),
  estado          boolean default true,
  fecha_ingreso   timestamptz,
  foto            text,
  ultima_conexion timestamptz
);

-- ---------- mos.zonas ----------
create table if not exists mos.zonas (
  id_zona       text primary key,
  nombre        text,
  descripcion   text,
  direccion     text,
  responsable   text,
  estado        boolean default true,
  politica_json jsonb
);

-- ---------- mos.estaciones ----------
create table if not exists mos.estaciones (
  id_estacion text primary key,
  id_zona     text,
  nombre      text,
  tipo        text,        -- CAJA / ALMACEN
  app_origen  text,
  admin_pin   text,
  activo      boolean default true,
  descripcion text
);
create index if not exists ix_estaciones_zona on mos.estaciones (id_zona);

-- ---------- mos.impresoras ----------
create table if not exists mos.impresoras (
  id_impresora text primary key,
  nombre       text,
  printnode_id text,
  tipo         text,        -- TICKET / ADHESIVO
  id_estacion  text,
  id_zona      text,
  app_origen   text,
  activo       boolean default true,
  descripcion  text
);
create index if not exists ix_impresoras_estacion on mos.impresoras (id_estacion);

-- ---------- mos.series_documentales ----------
create table if not exists mos.series_documentales (
  id_serie       text primary key,
  id_estacion    text,
  id_zona        text,
  tipo_documento text,      -- NOTA_VENTA / BOLETA / FACTURA
  serie          text,
  correlativo    bigint,    -- atómico vía UPDATE...RETURNING (NO sequence)
  activo         boolean default true
);

-- ---------- mos.dispositivos ----------
create table if not exists mos.dispositivos (
  id_dispositivo      text primary key,
  nombre_equipo       text,
  app                 text,
  estado              text,   -- ACTIVO/INACTIVO/PENDIENTE_APROBACION/CANCELADO_AUTO/SUSPENDIDO
  ultima_conexion     timestamptz,
  ultima_zona         text,
  ultima_estacion     text,
  ultima_sesion       text,
  permisos_json       jsonb,
  permisos_lastupdate timestamptz,
  forzar_wizard       boolean default false,
  suspendido_desde    timestamptz,
  forzar_logout       boolean default false,
  logout_auto_ts      timestamptz,
  forzar_push         boolean default false,
  forzar_reverify     boolean default false,
  inactivo_alerta_ts  timestamptz,
  cancelado_auto_ts   timestamptz,
  user_agent          text
);
create index if not exists ix_dispositivos_estado on mos.dispositivos (estado);
create index if not exists ix_dispositivos_app    on mos.dispositivos (app);

-- ---------- mos.config (clave-valor) ----------
create table if not exists mos.config (
  clave       text primary key,
  valor       text,
  descripcion text
);

-- ============================================================
-- AUDITORÍA DE BACKFILL (común a todas las apps)
-- ============================================================
create table if not exists mos.backfill_audit (
  id          bigserial primary key,
  app         text,
  hoja        text,
  fila        int,
  columna     text,
  tipo_issue  text,   -- TRUNCATED_JSON/ORPHAN_ROW/HEADER_MISMATCH/BAD_BOOLEAN/BAD_DATE/LOST_ZERO/FK_MISSING
  valor       text,
  resuelto    boolean default false,
  nota        text,
  ts          timestamptz default now()
);

-- ============================================================
-- GRANTS para la Data API (service_role) en esquemas mos/me/wh
-- Sin esto: HTTP 403 "permission denied for schema mos".
-- ============================================================
grant usage on schema mos to service_role, anon, authenticated;
grant usage on schema me  to service_role, anon, authenticated;
grant usage on schema wh  to service_role, anon, authenticated;

grant all on all tables    in schema mos to service_role;
grant all on all sequences in schema mos to service_role;
grant all on all functions in schema mos to service_role;
grant all on all tables    in schema me  to service_role;
grant all on all sequences in schema me  to service_role;
grant all on all functions in schema me  to service_role;
grant all on all tables    in schema wh  to service_role;
grant all on all sequences in schema wh  to service_role;
grant all on all functions in schema wh  to service_role;

alter default privileges in schema mos grant all on tables to service_role;
alter default privileges in schema mos grant all on sequences to service_role;
alter default privileges in schema mos grant all on functions to service_role;
alter default privileges in schema me  grant all on tables to service_role;
alter default privileges in schema me  grant all on sequences to service_role;
alter default privileges in schema me  grant all on functions to service_role;
alter default privileges in schema wh  grant all on tables to service_role;
alter default privileges in schema wh  grant all on sequences to service_role;
alter default privileges in schema wh  grant all on functions to service_role;

-- ============================================================
-- POST-BACKFILL (ejecutar SOLO después de cargar el catálogo,
-- para que las FKs no fallen por orden de inserción)
-- ============================================================
-- alter table mos.productos
--   add constraint fk_producto_base
--   foreign key (codigo_producto_base) references mos.productos(id_producto)
--   on delete restrict;
-- alter table mos.estaciones        add constraint fk_estacion_zona  foreign key (id_zona)     references mos.zonas(id_zona);
-- alter table mos.impresoras        add constraint fk_impresora_est  foreign key (id_estacion) references mos.estaciones(id_estacion);
-- alter table mos.series_documentales add constraint fk_serie_est    foreign key (id_estacion) references mos.estaciones(id_estacion);
-- (codigo_producto_base / id_* vacíos deben quedar NULL en el backfill para que la FK valide)
