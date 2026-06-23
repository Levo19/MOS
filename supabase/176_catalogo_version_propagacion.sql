-- 176_catalogo_version_propagacion.sql — Propagación rápida de cambios del catálogo maestro a ME/MOS/WH.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- IDEA: un contador de versión único que se incrementa AUTOMÁTICAMENTE cada vez que cambia el maestro
-- (mos.productos / mos.equivalencias). Cada app consulta `mos.catalogo_version()` (1 valor, barato) cada ~minuto
-- + al volver el foco; si la versión > la cacheada, re-descarga el catálogo completo. No hay push/websocket:
-- es poll de UN entero (no del catálogo), así que es eficiente y propaga en ~1 min (o al instante al enfocar).
-- Trigger a nivel STATEMENT (no por fila) → un upsert masivo del sync bumpea 1 sola vez, no 2368.
-- Additivo: NO toca datos de productos, solo incrementa un contador. SECURITY DEFINER, search_path='', sin gate
-- (es solo un número de versión, no dato sensible), grant authenticated → las 3 apps lo leen con su token.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists mos;

-- tabla de 1 sola fila con la versión
create table if not exists mos.catalogo_meta (
  id         int primary key default 1,
  version    bigint not null default 1,
  updated_at timestamptz not null default now(),
  constraint mos_catalogo_meta_single check (id = 1)
);
insert into mos.catalogo_meta (id, version) values (1, 1) on conflict (id) do nothing;

-- bump (statement-level): incrementa la versión una vez por sentencia de cambio en el maestro
create or replace function mos._bump_catalogo_version()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  update mos.catalogo_meta set version = version + 1, updated_at = now() where id = 1;
  return null;
end; $fn$;

drop trigger if exists tg_bump_catversion_productos on mos.productos;
create trigger tg_bump_catversion_productos
  after insert or update or delete on mos.productos
  for each statement execute function mos._bump_catalogo_version();

drop trigger if exists tg_bump_catversion_equiv on mos.equivalencias;
create trigger tg_bump_catversion_equiv
  after insert or update or delete on mos.equivalencias
  for each statement execute function mos._bump_catalogo_version();

-- RPC barata que cada app pollea: devuelve la versión actual del catálogo.
create or replace function mos.catalogo_version(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select jsonb_build_object('ok', true, 'version', version, 'updated_at', updated_at)
  from mos.catalogo_meta where id = 1;
$fn$;
revoke all on function mos.catalogo_version(jsonb) from public;
grant execute on function mos.catalogo_version(jsonb) to authenticated, service_role;
