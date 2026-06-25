-- ============================================================================================================
-- 171_mos_nombres_por_codigos.sql — [ME · ticket de guía 100% Supabase] Resolver nombres por código.
-- ------------------------------------------------------------------------------------------------------------
-- ME imprimía el ticket de guía (imprimirGuia) resolviendo el nombre SOLO del catálogo LOCAL descargado y SIN
-- equivalencias → para códigos equivalentes/graneles/recién-catalogados salía "código + cant" sin nombre
-- (ej. devolución SALIDA_DEVOLUCION_WH con 2 productos sin nombre). Esta RPC resuelve el nombre CANÓNICO desde
-- Supabase (mos.productos + mos.equivalencias), misma lógica que la Edge `ticket-guia`:
--   1) código en mos.productos → su sku_base (y desc directa de respaldo)
--   2) si no, código en mos.equivalencias (activo) → sku_base
--   3) nombre = descripción del CANÓNICO (factor=1, estado activo) de ese sku_base; si no hay, la desc directa
--
-- p = { codigos: ["7501...", "01854", ...] }. Devuelve { ok, data: { "<codigo>": "<NOMBRE>", ... } }. Solo
-- incluye los códigos que resolvió (el frontend cae a su catálogo local / al código para los que falten).
-- SECURITY DEFINER (bypassa RLS, lee mos.* qualified, search_path=''). Grants anon+authenticated (ME usa
-- mint-me/anon, Content-Profile: mos). Sin dinero, solo lectura de nombres.
-- ============================================================================================================
create or replace function mos.nombres_por_codigos(p jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  with codes as (
    select distinct btrim(value) as cod
    from jsonb_array_elements_text(coalesce(p->'codigos', '[]'::jsonb)) as value
    where btrim(value) <> ''
  ),
  resolved as (
    select c.cod,
           coalesce(pr.sku_base, eq.sku_base) as sku,
           pr.descripcion                     as desc_directa
    from codes c
    left join mos.productos    pr on pr.codigo_barra = c.cod
    left join mos.equivalencias eq on eq.codigo_barra = c.cod and eq.activo
  ),
  canon as (
    -- desc del canónico (factor=1) por sku_base; prioriza estado activo.
    select distinct on (sku_base) sku_base, descripcion
    from mos.productos
    where factor_conversion = 1
    order by sku_base, (estado is true) desc
  )
  select jsonb_build_object(
    'ok', true,
    'data', coalesce(
      jsonb_object_agg(r.cod, coalesce(cn.descripcion, r.desc_directa))
        filter (where coalesce(cn.descripcion, r.desc_directa) is not null),
      '{}'::jsonb)
  )
  from resolved r
  left join canon cn on cn.sku_base = r.sku;
$fn$;

revoke all on function mos.nombres_por_codigos(jsonb) from public;
grant execute on function mos.nombres_por_codigos(jsonb) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
