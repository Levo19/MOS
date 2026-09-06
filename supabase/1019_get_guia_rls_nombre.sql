-- ============================================================================
-- 1019_get_guia_rls_nombre.sql — get_guia_rls resuelve el NOMBRE del producto (06-sep)
-- ----------------------------------------------------------------------------
-- PROBLEMA: wh.guia_detalle NO guarda el nombre del producto (solo cod_producto). El nombre se
-- resolvía SOLO en el cliente con el catálogo cacheado; si ese cache no está cargado en el dispositivo,
-- la guía mostraba el CÓDIGO crudo. Este parche resuelve `descripcion_producto` en el SERVIDOR (join a
-- mos.productos por codigo_barra o id_producto, y a mos.equivalencias→producto base), así el nombre
-- aparece SIEMPRE, aunque el cache del cliente falle. El front igual mantiene su fallback al cache/código.
-- ============================================================================

create or replace function wh.get_guia_rls(p_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_guia jsonb;
  v_det  jsonb;
begin
  if not wh._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if p_id is null or btrim(p_id) = '' then
    return jsonb_build_object('ok', false, 'error', 'FALTA_ID_GUIA');
  end if;
  select to_jsonb(g) into v_guia from wh.guias g where g.id_guia = p_id limit 1;
  if v_guia is null then
    return jsonb_build_object('ok', false, 'error', 'Guía no encontrada: ' || p_id);
  end if;

  select coalesce(jsonb_agg(
           to_jsonb(d) || jsonb_build_object('descripcion_producto', wh._nombre_por_cod(d.cod_producto))
           order by d.linea), '[]'::jsonb)
    into v_det
    from wh.guia_detalle d where d.id_guia = p_id;

  return jsonb_build_object('ok', true, 'guia', v_guia, 'detalle', v_det);
end;
$fn$;
revoke all on function wh.get_guia_rls(text) from public;
grant execute on function wh.get_guia_rls(text) to service_role, authenticated;

-- Resolvedor de nombre por código (mismo criterio que el prodMap del cliente):
--   1) productos.codigo_barra  2) productos.id_producto  3) equivalencias.codigo_barra → producto base (o desc del equiv)
create or replace function wh._nombre_por_cod(p_cod text)
returns text language sql stable security definer set search_path = '' as $fn$
  select nullif(btrim(x.nombre), '')
  from (
    select coalesce(
      (select p.descripcion from mos.productos p
        where btrim(p.codigo_barra) = btrim(p_cod) and nullif(btrim(p.descripcion),'') is not null
        order by (case when coalesce(p.factor_conversion,1)=1 then 0 else 1 end) limit 1),
      (select p.descripcion from mos.productos p
        where p.id_producto::text = btrim(p_cod) and nullif(btrim(p.descripcion),'') is not null limit 1),
      (select pb.descripcion from mos.equivalencias e
         join mos.productos pb on upper(btrim(pb.sku_base)) = upper(btrim(e.sku_base)) and coalesce(pb.factor_conversion,1)=1
        where btrim(e.codigo_barra) = btrim(p_cod) and nullif(btrim(pb.descripcion),'') is not null limit 1),
      (select e.descripcion from mos.equivalencias e
        where btrim(e.codigo_barra) = btrim(p_cod) and nullif(btrim(e.descripcion),'') is not null limit 1)
    ) nombre
  ) x;
$fn$;
revoke all on function wh._nombre_por_cod(text) from public;
grant execute on function wh._nombre_por_cod(text) to service_role, authenticated;

select '1019 get_guia_rls nombre listo' ok;
