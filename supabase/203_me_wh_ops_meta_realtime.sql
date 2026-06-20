-- 203_me_wh_ops_meta_realtime.sql — PUSH instantáneo (0s) WH/ME → MOS vía contadores de versión por dominio.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- CONTEXTO: SQL 200 dio push 0s para el CATÁLOGO (mos.catalogo_meta). Esta tanda espeja ESE patrón para que MOS
-- vea AL INSTANTE los cambios operativos de las apps hijas:
--   ME (MosExpress): ventas, cajas, stock por zona.
--   WH (warehouseMos): guías, preingresos, stock, mermas, envasados, vencimientos.
--
-- DECISIÓN DE DISEÑO (del análisis 40x): NO publicamos las tablas de DINERO por Realtime. Hacerlo exigiría
-- GRANT SELECT a authenticated/anon sobre montos, clientes, costos, etc. → fuga. En su lugar publicamos solo
-- CONTADORES (enteros) por dominio. MOS escucha el contador, y cuando sube, re-descarga vía sus RPCs SECURITY
-- DEFINER de siempre (que ya validan permisos). El contador no es dato sensible → SELECT abierto es seguro.
--
-- ESTE ARCHIVO ES PURO BACKEND, ADDITIVO, IDEMPOTENTE, MONEY-SAFE:
--   • NO toca ninguna tabla de dinero (me.ventas / wh.guias / etc.): solo les CUELGA un trigger AFTER que
--     bumpea un contador en OTRA tabla. El trigger no modifica la fila fuente.
--   • NO publica ninguna tabla de dinero por Realtime.
--   • Los contadores son de SOLO LECTURA para las apps (RLS ON + solo política SELECT; sin INSERT/UPDATE/DELETE).
--     Las únicas escrituras al contador vienen de funciones SECURITY DEFINER (bypassan RLS+grant).
--   • Triggers STATEMENT-LEVEL: un upsert/batch de N filas = 1 solo bump (no N). Evita ruido.
--
-- QUÉ HACE:
--   1) Crea me.ops_meta y wh.ops_meta (dominio text PK, version bigint, updated_at). Siembra filas por dominio.
--   2) Crea funciones bump SECURITY DEFINER search_path='' : me._bump_ops(p_dominio) y wh._bump_ops(p_dominio).
--   3) Crea funciones de trigger genéricas que leen el dominio de TG_ARGV[0] y llaman al bump del schema.
--   4) Cuelga triggers statement-level en las tablas fuente (idempotente drop-if-exists), cada uno con SU dominio.
--   5) Publica me.ops_meta y wh.ops_meta en supabase_realtime (idempotente) + replica identity full.
--   6) RLS ON + GRANT SELECT a authenticated, anon + política SELECT using(true) en ambos contadores.
--
-- AUTH REALTIME: las apps abren el canal con el JWT minteado por la Edge (role 'authenticated') o con la apikey
-- anon. La política de SELECT cubre ambos. Realtime RESPETA RLS → sin esta política no entregaría eventos.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;
create schema if not exists wh;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) TABLAS CONTADOR (espejo de mos.catalogo_meta, pero clave por DOMINIO).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
create table if not exists me.ops_meta (
  dominio    text primary key,
  version    bigint      not null default 1,
  updated_at timestamptz not null default now()
);

create table if not exists wh.ops_meta (
  dominio    text primary key,
  version    bigint      not null default 1,
  updated_at timestamptz not null default now()
);

-- Sembrar filas iniciales por dominio (idempotente).
insert into me.ops_meta (dominio) values
  ('ventas'), ('cajas'), ('stock_zonas')
on conflict (dominio) do nothing;

insert into wh.ops_meta (dominio) values
  ('guias'), ('preingresos'), ('stock'), ('mermas'), ('envasados'), ('vencimientos')
on conflict (dominio) do nothing;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) FUNCIONES BUMP (security definer, search_path='' → calificación de schema obligatoria).
--    upsert: crea la fila si no existe (defensa), o incrementa la versión.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me._bump_ops(p_dominio text)
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  insert into me.ops_meta (dominio, version, updated_at)
  values (p_dominio, 1, now())
  on conflict (dominio) do update
    set version = me.ops_meta.version + 1, updated_at = now();
end; $fn$;

create or replace function wh._bump_ops(p_dominio text)
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  insert into wh.ops_meta (dominio, version, updated_at)
  values (p_dominio, 1, now())
  on conflict (dominio) do update
    set version = wh.ops_meta.version + 1, updated_at = now();
end; $fn$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) FUNCIONES DE TRIGGER GENÉRICAS: leen el dominio de TG_ARGV[0] y delegan al bump del schema.
--    SECURITY DEFINER → el bump corre como dueño (bypassa RLS de ops_meta). search_path='' → calificar todo.
--    statement-level → return null.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me._tg_bump_ops()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  perform me._bump_ops(tg_argv[0]);
  return null;
end; $fn$;

create or replace function wh._tg_bump_ops()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  perform wh._bump_ops(tg_argv[0]);
  return null;
end; $fn$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) TRIGGERS STATEMENT-LEVEL en las tablas fuente. Idempotentes (drop if exists). El trigger NO toca la fila
--    fuente; solo bumpea el contador → cero impacto en la lógica de dinero.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

-- ── ME: ventas (cabecera + detalle) → dominio 'ventas' ──────────────────────────────────────────────────────
drop trigger if exists tg_bump_ops_ventas on me.ventas;
create trigger tg_bump_ops_ventas
  after insert or update or delete on me.ventas
  for each statement execute function me._tg_bump_ops('ventas');

drop trigger if exists tg_bump_ops_ventas_detalle on me.ventas_detalle;
create trigger tg_bump_ops_ventas_detalle
  after insert or update or delete on me.ventas_detalle
  for each statement execute function me._tg_bump_ops('ventas');

-- ── ME: cajas → dominio 'cajas' ─────────────────────────────────────────────────────────────────────────────
drop trigger if exists tg_bump_ops_cajas on me.cajas;
create trigger tg_bump_ops_cajas
  after insert or update or delete on me.cajas
  for each statement execute function me._tg_bump_ops('cajas');

-- ── ME: stock_zonas → dominio 'stock_zonas' ─────────────────────────────────────────────────────────────────
drop trigger if exists tg_bump_ops_stock_zonas on me.stock_zonas;
create trigger tg_bump_ops_stock_zonas
  after insert or update or delete on me.stock_zonas
  for each statement execute function me._tg_bump_ops('stock_zonas');

-- ── WH: guias → dominio 'guias' ─────────────────────────────────────────────────────────────────────────────
drop trigger if exists tg_bump_ops_guias on wh.guias;
create trigger tg_bump_ops_guias
  after insert or update or delete on wh.guias
  for each statement execute function wh._tg_bump_ops('guias');

-- ── WH: preingresos → dominio 'preingresos' ─────────────────────────────────────────────────────────────────
drop trigger if exists tg_bump_ops_preingresos on wh.preingresos;
create trigger tg_bump_ops_preingresos
  after insert or update or delete on wh.preingresos
  for each statement execute function wh._tg_bump_ops('preingresos');

-- ── WH: stock → dominio 'stock' ─────────────────────────────────────────────────────────────────────────────
drop trigger if exists tg_bump_ops_stock on wh.stock;
create trigger tg_bump_ops_stock
  after insert or update or delete on wh.stock
  for each statement execute function wh._tg_bump_ops('stock');

-- ── WH: mermas → dominio 'mermas' ───────────────────────────────────────────────────────────────────────────
drop trigger if exists tg_bump_ops_mermas on wh.mermas;
create trigger tg_bump_ops_mermas
  after insert or update or delete on wh.mermas
  for each statement execute function wh._tg_bump_ops('mermas');

-- ── WH: envasados → dominio 'envasados' ─────────────────────────────────────────────────────────────────────
drop trigger if exists tg_bump_ops_envasados on wh.envasados;
create trigger tg_bump_ops_envasados
  after insert or update or delete on wh.envasados
  for each statement execute function wh._tg_bump_ops('envasados');

-- ── WH: lotes_vencimiento → dominio 'vencimientos' ──────────────────────────────────────────────────────────
drop trigger if exists tg_bump_ops_vencimientos on wh.lotes_vencimiento;
create trigger tg_bump_ops_vencimientos
  after insert or update or delete on wh.lotes_vencimiento
  for each statement execute function wh._tg_bump_ops('vencimientos');

-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 5) PUBLICACIÓN Realtime (idempotente) + replica identity FULL (payload trae fila completa: dominio + version).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
do $do$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='me' and tablename='ops_meta'
  ) then
    alter publication supabase_realtime add table me.ops_meta;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='wh' and tablename='ops_meta'
  ) then
    alter publication supabase_realtime add table wh.ops_meta;
  end if;
end;
$do$;

alter table me.ops_meta replica identity full;
alter table wh.ops_meta replica identity full;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 6) RLS + GRANT SELECT + política SELECT using(true) para authenticated y anon. (Lección SQL 200: el GRANT a
--    nivel tabla es OBLIGATORIO además de la RLS; sin él Realtime no entrega eventos.) Solo SELECT → contadores
--    de solo-lectura para las apps. El bump corre por funciones SECURITY DEFINER (bypassan RLS+grant).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
alter table me.ops_meta enable row level security;
alter table wh.ops_meta enable row level security;

grant select on table me.ops_meta to authenticated, anon;
grant select on table wh.ops_meta to authenticated, anon;

-- ME
drop policy if exists ops_meta_select_authenticated on me.ops_meta;
create policy ops_meta_select_authenticated on me.ops_meta
  for select to authenticated using (true);

drop policy if exists ops_meta_select_anon on me.ops_meta;
create policy ops_meta_select_anon on me.ops_meta
  for select to anon using (true);

-- WH
drop policy if exists ops_meta_select_authenticated on wh.ops_meta;
create policy ops_meta_select_authenticated on wh.ops_meta
  for select to authenticated using (true);

drop policy if exists ops_meta_select_anon on wh.ops_meta;
create policy ops_meta_select_anon on wh.ops_meta
  for select to anon using (true);
