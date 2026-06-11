-- ============================================================
-- 10_fase1d_wh_stock.sql — Fase 1.D (canary WH) · función server-side de getStock
-- ============================================================
-- Replica getStock(params) (Productos.gs:49-71 de warehouseMos).
-- wh.stock LEFT JOIN mos.productos (por codigo_barra) + enriquecimiento + alerta.
--   · descripcion = producto.descripcion || codigoProducto (fallback)
--   · stockMinimo/Maximo = producto.* || 0 ; unidad = producto.unidad || ''
--   · alertaMinimo = cantidadDisponible (numérico) < stockMinimo del producto
--   · soloAlertas=true → solo filas con alertaMinimo
-- LEFT JOIN LATERAL limit 1 → 1 producto por stock (no multiplica si hay codigo_barra duplicado).
-- Forma: {ok:true, data:[...]} (igual que getStock, NO {status:'success'}).
-- ============================================================

create or replace function wh.stock_enriquecido(solo_alertas boolean default false)
returns jsonb
language sql
stable
as $$
with enr as (
  select
    s.id_stock, s.cod_producto, s.cantidad_disponible, s.ultima_actualizacion,
    coalesce(nullif(p.descripcion,''), s.cod_producto) as descripcion,
    coalesce(p.stock_minimo,0) as stock_minimo,
    coalesce(p.stock_maximo,0) as stock_maximo,
    coalesce(p.unidad,'')      as unidad,
    (s.cantidad_disponible is not null and s.cantidad_disponible < coalesce(p.stock_minimo,0)) as alerta_minimo
  from wh.stock s
  left join lateral (
    select descripcion, unidad, stock_minimo, stock_maximo
    from mos.productos p where p.codigo_barra = s.cod_producto
    order by p.created_at desc nulls last, p.id_producto desc   -- proxy determinista de "último en orden de hoja" (codigo_barra NO es único)
    limit 1
  ) p on true
)
select jsonb_build_object('ok', true, 'data', coalesce((
  select jsonb_agg(jsonb_build_object(
    'idStock',             id_stock,
    'codigoProducto',      cod_producto,
    'cantidadDisponible',  cantidad_disponible,
    'ultimaActualizacion', case when ultima_actualizacion is not null then to_char(ultima_actualizacion at time zone 'America/Lima','YYYY-MM-DD') else '' end,  -- _sheetToObjects corta Date→yyyy-MM-dd en TZ Lima (la celda es Date object)
    'descripcion',         descripcion,
    'stockMinimo',         stock_minimo,
    'stockMaximo',         stock_maximo,
    'unidad',              unidad,
    'alertaMinimo',        alerta_minimo
  ) order by id_stock)
  from enr
  where (not solo_alertas) or alerta_minimo
), '[]'::jsonb));
$$;

grant execute on function wh.stock_enriquecido(boolean) to service_role;
