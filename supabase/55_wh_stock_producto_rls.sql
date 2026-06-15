-- 55_wh_stock_producto_rls.sql — [PASO 5 · B3 backend] getStockProducto(cod): cantidad EN VIVO de un producto.
-- Stock = inventario/dinero → leer fresco, no del cache local. Replica _getStockProducto (Guias.gs): cantidad de la fila
-- de wh.stock por cod_producto (índice único ux_wh_stock_cod garantiza 1 fila; 0 si no existe). El FRONT enriquece
-- descripcion/unidad/stockMinimo/alerta con el catálogo cache. Gate wh._claim_ok().

create or replace function wh.stock_producto_rls(p_cod text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_cant numeric;
begin
  if not wh._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  select cantidad_disponible into v_cant
    from wh.stock where cod_producto = p_cod order by id_stock limit 1;
  return jsonb_build_object('ok', true, 'cantidad', coalesce(v_cant, 0));
end;
$fn$;

revoke all on function wh.stock_producto_rls(text) from public;
grant execute on function wh.stock_producto_rls(text) to service_role, authenticated;
