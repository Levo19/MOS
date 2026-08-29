-- [996] Índice para matar el N+1 de wh.stock_enriquecido (y demás lecturas que resuelven producto por código).
--  wh.stock_enriquecido hace, POR CADA fila de stock (~1467), un lateral:
--    select ... from mos.productos where codigo_barra = s.cod_producto
--     order by created_at desc nulls last, id_producto desc limit 1   (codigo_barra no tenía unique constraint)
--  El índice parcial existente (ix_productos_codigo_barra WHERE codigo_barra<>'') NO lo usaba el planner para el
--  ORDER BY…LIMIT 1 → seq scan por fila → 1.37M buffer hits, ~1000 ms.
--  Este índice compuesto (código + recencia) lo vuelve un index scan directo (seek al código, primer row = ganador):
--    ~1006 ms → 33 ms · 1.37M → 4.5K buffers · SALIDA IDÉNTICA (mismo md5, 1467 filas) — solo índice, sin tocar lógica.
--  Beneficia a cualquier RPC con el mismo patrón (dashboard_almacen, insights_stock, catalogo_stock_resumen…).
--  Aplicado en vivo con CREATE INDEX CONCURRENTLY (sin bloquear escrituras de catálogo).
create index concurrently if not exists ix_productos_cb_recencia
  on mos.productos (codigo_barra, created_at desc nulls last, id_producto desc);

analyze mos.productos;

select '996 ix_productos_cb_recencia listo' as ok;
