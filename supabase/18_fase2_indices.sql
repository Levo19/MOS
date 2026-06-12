-- 18_fase2_indices.sql — Índices que Fase 2 (escritura directa) REQUIERE. Versionados para que un
-- re-provisioning/staging/DR que corre solo los .sql los tenga. Idempotentes.
-- CRÍTICO: el predicado DEBE ser IDÉNTICO al `on conflict (ref_local) where ...` de crear_venta_directa,
-- sino el ON CONFLICT lanza 42P10 o deja de deduplicar (= ventas/filas duplicadas).
create unique index if not exists ux_me_ventas_ref_local
  on me.ventas (ref_local)
  where ref_local is not null and ref_local <> '';
