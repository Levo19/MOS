-- 80_mos_proveedores_local_id.sql — [MIGRACIÓN MOS · FASE 2 · LOTE PROVEEDORES/PEDIDOS/PAGOS]
-- Cimiento de idempotencia para las RPCs de escritura del lote: agrega columna `local_id` + índice único
-- parcial a las 4 tablas sombra (proveedores / pedidos_proveedor / pagos_proveedor / proveedores_productos).
--
-- ⚠️ POR QUÉ ──────────────────────────────────────────────────────────────────────────────────────────
--   Los originales de GAS (gas/Proveedores.gs) NO tienen idempotencia: cada crear/registrar es un
--   appendRow crudo, sin lock ni dedup → doble-tap / reintento de cola offline = fila duplicada.
--   Eso es tolerable en una hoja editable a mano, pero INACEPTABLE para mos.pagos_proveedor (DINERO):
--   un pago NO se puede duplicar jamás. La Fase 2 (PWA → RPC directo) introduce reintentos automáticos,
--   así que el local_id es la red de seguridad. Patrón idéntico a architecture_muelle_idempotencia
--   (índice único parcial + insert ... on conflict (local_id) do nothing).
--
--   `local_id` = clave de idempotencia generada por el CLIENTE (estable entre reintentos del mismo gesto),
--   NO la PK de negocio. El índice es PARCIAL (where local_id is not null) para que las filas heredadas
--   del backfill (local_id NULL) no choquen entre sí ni con escrituras futuras.
--
-- ⚠️ INERTE: solo agrega una columna nullable + un índice. No cambia ninguna lectura ni el comportamiento
--   de GAS (que ni siquiera escribe esta columna). Idempotente (add column if not exists / create index if not exists).

alter table mos.proveedores            add column if not exists local_id text;
alter table mos.pedidos_proveedor      add column if not exists local_id text;
alter table mos.pagos_proveedor        add column if not exists local_id text;
alter table mos.proveedores_productos  add column if not exists local_id text;

-- Índices únicos PARCIALES (solo filas con local_id no nulo). Dedup real por gesto de cliente.
create unique index if not exists ux_mos_proveedores_localid
  on mos.proveedores (local_id) where local_id is not null;
create unique index if not exists ux_mos_pedidosprov_localid
  on mos.pedidos_proveedor (local_id) where local_id is not null;
create unique index if not exists ux_mos_pagosprov_localid
  on mos.pagos_proveedor (local_id) where local_id is not null;
create unique index if not exists ux_mos_provprod_localid
  on mos.proveedores_productos (local_id) where local_id is not null;
