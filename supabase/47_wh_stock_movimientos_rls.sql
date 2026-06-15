-- 47_wh_stock_movimientos_rls.sql — [PASO 5 · B3 backend] Lectura de stock_movimientos con FILTRO server-side.
-- La tabla es grande (~6k filas, big:true) → NO usar leer_tabla_rls (traería todo). Replica getStockMovimientos
-- (Auditoria.gs): con cod → where cod_producto=eq + limit 5000; sin cod → order fecha desc + limit (1000 def).
-- Devuelve filas CRUDAS (snake_case) → el front mapea con _sbRowsToObjsFront('stock_movimientos'). Gate _claim_ok.

create or replace function wh.stock_movimientos_rls(p_cod text default null, p_limit int default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_out jsonb;
  v_cod text := nullif(btrim(coalesce(p_cod, '')), '');
  v_lim int  := greatest(1, least(coalesce(p_limit, case when nullif(btrim(coalesce(p_cod,'')),'') is not null then 5000 else 1000 end), 10000));
begin
  if not wh._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_cod is not null then
    select coalesce(jsonb_agg(to_jsonb(t) order by t.fecha desc), '[]'::jsonb) into v_out
    from (select * from wh.stock_movimientos where cod_producto = v_cod order by fecha desc limit v_lim) t;
  else
    select coalesce(jsonb_agg(to_jsonb(t) order by t.fecha desc), '[]'::jsonb) into v_out
    from (select * from wh.stock_movimientos order by fecha desc limit v_lim) t;
  end if;
  return jsonb_build_object('ok', true, 'data', v_out);
end;
$fn$;

revoke all on function wh.stock_movimientos_rls(text, int) from public;
grant execute on function wh.stock_movimientos_rls(text, int) to service_role, authenticated;
