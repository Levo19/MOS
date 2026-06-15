-- 46_wh_leer_tabla_rls.sql — [PASO 5 · B3 backend] Lectura genérica de tablas wh.* para el NAVEGADOR.
-- Devuelve las filas CRUDAS (snake_case) como jsonb_agg → 1 request, SIN el límite db-max-rows de PostgREST
-- (es un scalar jsonb, no un table-read). El FRONT mapea a shape-hoja con _sbRowsToObjs + _WH_SPECS (los
-- MISMOS specs que cuadraron al centavo en PASO 3 → cero divergencia). Gate wh._claim_ok() (B2).
-- Whitelist rígida de tablas de lectura (defensa contra inyección, además del %I de format).
-- NO incluye alertas_stock (revertida a Sheets por huérfanos). NO toca las funciones de escritura.
-- Tablas wh.* puras (sin catálogo MOS): mermas, auditorias, ajustes, envasados, producto_nuevo,
-- preingresos, lotes_vencimiento, guias, guia_detalle, stock_movimientos, pickups, listas_sombra.

create or replace function wh.leer_tabla_rls(p_tabla text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_out jsonb;
  v_pk  text;
begin
  if not wh._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- whitelist + PK por tabla (= primera col de onConflict en _WH_SPECS → ordena igual que _leerTablaWH/pk.asc)
  v_pk := case p_tabla
    when 'mermas'            then 'id_merma'
    when 'auditorias'        then 'id_auditoria'
    when 'ajustes'           then 'id_ajuste'
    when 'envasados'         then 'id_envasado'
    when 'producto_nuevo'    then 'id_producto_nuevo'
    when 'preingresos'       then 'id_preingreso'
    when 'lotes_vencimiento' then 'id_lote'
    when 'guias'             then 'id_guia'
    when 'guia_detalle'      then 'id_guia'
    when 'stock_movimientos' then 'id_mov'
    when 'pickups'           then 'id_pickup'
    when 'listas_sombra'     then 'id_lista'
    else null
  end;
  if v_pk is null then
    return jsonb_build_object('ok', false, 'error', 'TABLA_NO_PERMITIDA', 'tabla', p_tabla);
  end if;
  -- p_tabla/v_pk ya validadas contra la whitelist; %I es defensa redundante.
  execute format('select coalesce(jsonb_agg(to_jsonb(t) order by t.%I), ''[]''::jsonb) from wh.%I t', v_pk, p_tabla)
    into v_out;
  return jsonb_build_object('ok', true, 'data', v_out);
end;
$fn$;

revoke all on function wh.leer_tabla_rls(text) from public;
grant execute on function wh.leer_tabla_rls(text) to service_role, authenticated;
