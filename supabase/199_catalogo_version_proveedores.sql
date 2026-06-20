-- 199_catalogo_version_proveedores.sql — Propaga RÁPIDO los proveedores nuevos/editados de MOS a WH.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PROBLEMA: WH lee proveedores 100% de Supabase (mos.catalogo_wh_rls → out.proveedores) y re-descarga el
-- catálogo SOLO cuando el poller detecta que `mos.catalogo_version()` cambió (cada ~50s o al enfocar).
-- El trigger de versión (176_catalogo_version_propagacion.sql) vivía SOLO en mos.productos y mos.equivalencias,
-- así que crear/editar un proveedor en MOS NO bumpeaba la versión → WH no se enteraba → tardaba demasiado.
--
-- FIX (additivo, money-safe): agrega triggers STATEMENT-LEVEL que reusan la función existente
-- `mos._bump_catalogo_version()` en:
--   • mos.proveedores            → propaga alta/edición/baja de proveedores.
--   • mos.proveedores_productos  → propaga los productos-por-proveedor que alimentan el panel ALMACÉN
--                                  (RPC mos.zona_proveedores) y la asociación proveedor↔producto.
-- Statement-level → un upsert masivo del sync bumpea 1 sola vez (no por fila). NO toca datos, solo incrementa
-- un contador. Idempotente (drop trigger if exists). NO modifica WH ni escrituras de stock/dinero.
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

-- Trigger en proveedores (alta/edición/baja propagan a WH vía bump de versión).
drop trigger if exists tg_bump_catversion_proveedores on mos.proveedores;
create trigger tg_bump_catversion_proveedores
  after insert or update or delete on mos.proveedores
  for each statement execute function mos._bump_catalogo_version();

-- Trigger en proveedores_productos (asociación proveedor↔producto que alimenta panel ALMACÉN / zona_proveedores).
drop trigger if exists tg_bump_catversion_provprod on mos.proveedores_productos;
create trigger tg_bump_catversion_provprod
  after insert or update or delete on mos.proveedores_productos
  for each statement execute function mos._bump_catalogo_version();
