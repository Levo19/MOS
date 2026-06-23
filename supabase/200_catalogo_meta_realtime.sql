-- 200_catalogo_meta_realtime.sql — PUSH instantáneo (0s) del contador de versión del catálogo vía Realtime.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- HOY: las 3 apps (MOS/WH/ME) pollean `mos.catalogo_version()` cada ~50s (o al enfocar). Cuando el maestro
-- cambia, `mos._bump_catalogo_version()` (176/199) incrementa `mos.catalogo_meta.version`. El poll de 1 entero
-- detecta el cambio y re-descarga el catálogo. Funciona, pero propaga en ~50s.
--
-- META: en vez de pollear, que las apps reciban un PUSH por Supabase Realtime al INSTANTE cuando la versión
-- sube. El poller queda como respaldo (fail-safe si el websocket cae). Esto es PURO BACKEND: additivo,
-- idempotente, money-safe. NO toca datos, NO toca el RPC `mos.catalogo_version()` (security definer, sigue ok),
-- NO toca escrituras de stock/dinero. Solo expone un CONTADOR (sin datos sensibles) por Realtime.
--
-- QUÉ HACE:
--   1) Publica mos.catalogo_meta en la publicación `supabase_realtime` (idempotente vía pg_publication_tables).
--   2) replica identity FULL en mos.catalogo_meta → el payload del UPDATE trae la fila completa (version nueva).
--   3) RLS: Realtime RESPETA RLS. Sin política de SELECT para el rol de las apps, Realtime NO entrega eventos.
--      → habilita RLS + política permisiva de SELECT para authenticated y anon (es solo un contador; seguro).
--   4) Amplía la cobertura del contador: triggers statement-level en mos.zonas / mos.estaciones / mos.categorias
--      (cambios raros, pero así también propagan al instante).
--
-- AUTH REALTIME: las apps abren el canal con el JWT minteado por la Edge `mint-mos` (claim app + role
-- 'authenticated'). La política de SELECT cubre 'authenticated' (token minteado) y 'anon' (apikey pública,
-- por si suscriben antes de mintear). El contador no es dato sensible → SELECT abierto a ambos es seguro.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists mos;

-- Defensa: garantiza que la infraestructura de versión exista (la creó 176; aquí solo por si se aplica suelto).
create table if not exists mos.catalogo_meta (
  id         int primary key default 1,
  version    bigint not null default 1,
  updated_at timestamptz not null default now(),
  constraint mos_catalogo_meta_single check (id = 1)
);
insert into mos.catalogo_meta (id, version) values (1, 1) on conflict (id) do nothing;

create or replace function mos._bump_catalogo_version()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  update mos.catalogo_meta set version = version + 1, updated_at = now() where id = 1;
  return null;
end; $fn$;

-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 1) PUBLICACIÓN: agrega mos.catalogo_meta a supabase_realtime (idempotente: solo si no está ya).
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
do $do$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'mos'
      and tablename  = 'catalogo_meta'
  ) then
    alter publication supabase_realtime add table mos.catalogo_meta;
  end if;
end;
$do$;

-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 2) REPLICA IDENTITY FULL: para que el payload del UPDATE traiga la fila completa (incl. version nueva).
--    Idempotente: setear FULL repetidamente no tiene efecto adverso.
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
alter table mos.catalogo_meta replica identity full;

-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 3) RLS + política de SELECT (Realtime respeta RLS; sin SELECT no entrega eventos).
--    El contador no es dato sensible → SELECT abierto a authenticated + anon. NO se crean políticas de
--    INSERT/UPDATE/DELETE → con RLS ON, esos roles NO pueden escribir la tabla por PostgREST (más seguro que
--    hoy). El bump sigue funcionando: corre dentro de triggers SECURITY DEFINER (dueño de la tabla, bypassa RLS),
--    y el RPC mos.catalogo_version() es SECURITY DEFINER (también bypassa RLS). Nada operativo se rompe.
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
alter table mos.catalogo_meta enable row level security;

-- GRANT a nivel tabla: Realtime/PostgREST verifican el GRANT *además* de la RLS. Sin SELECT a authenticated/anon,
-- el chequeo RLS de Realtime (corre un SELECT con el rol que conecta) falla → NO entrega eventos. La RLS sola NO
-- basta. Solo SELECT (no INSERT/UPDATE/DELETE) → el contador es de solo-lectura para las apps. El bump sigue por
-- triggers SECURITY DEFINER y el RPC mos.catalogo_version() sigue por SECURITY DEFINER (ambos bypassan RLS+grant).
grant select on table mos.catalogo_meta to authenticated, anon;

drop policy if exists catalogo_meta_select_authenticated on mos.catalogo_meta;
create policy catalogo_meta_select_authenticated
  on mos.catalogo_meta
  for select
  to authenticated
  using (true);

drop policy if exists catalogo_meta_select_anon on mos.catalogo_meta;
create policy catalogo_meta_select_anon
  on mos.catalogo_meta
  for select
  to anon
  using (true);

-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 4) AMPLIAR COBERTURA DEL CONTADOR: triggers statement-level en zonas / estaciones / categorias.
--    Reusan la función existente. Statement-level → un upsert masivo bumpea 1 sola vez. Idempotente.
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
drop trigger if exists tg_bump_catversion_zonas on mos.zonas;
create trigger tg_bump_catversion_zonas
  after insert or update or delete on mos.zonas
  for each statement execute function mos._bump_catalogo_version();

drop trigger if exists tg_bump_catversion_estaciones on mos.estaciones;
create trigger tg_bump_catversion_estaciones
  after insert or update or delete on mos.estaciones
  for each statement execute function mos._bump_catalogo_version();

drop trigger if exists tg_bump_catversion_categorias on mos.categorias;
create trigger tg_bump_catversion_categorias
  after insert or update or delete on mos.categorias
  for each statement execute function mos._bump_catalogo_version();
