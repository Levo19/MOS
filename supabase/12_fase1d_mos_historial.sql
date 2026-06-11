-- ============================================================
-- 12_fase1d_mos_historial.sql — Fase 1.D (canary MOS) · función server-side de getHistorialPrecios
-- ============================================================
-- Replica getHistorialPrecios(params) (Productos.gs:928-934 de MOS):
--   var rows = _sheetToObjects('HISTORIAL_PRECIOS');
--   if (skuBase)     rows = filter(r.skuBase === skuBase);
--   if (codigoBarra) rows = filter(r.codigoBarra === codigoBarra);
--   if (limit)       rows = rows.slice(-limit);   // últimas N en orden de hoja
--   return { ok:true, data: rows };
-- · fecha: _sheetToObjects corta Date → 'yyyy-MM-dd' TZ Lima (date-only).
-- · slice(-limit) = últimas N en orden de hoja → proxy: id (HP+epoch_ms, orden cronológico).
-- Forma: {ok:true, data:[...]} con campos camelCase del header de la hoja.
-- ============================================================

create or replace function mos.historial_precios_lista(p_sku text default null, p_codigo text default null, p_limit int default null)
returns jsonb
language sql
stable
as $$
with filtered as (
  select * from mos.historial_precios
  where (p_sku    is null or p_sku=''    or sku_base    = p_sku)
    and (p_codigo is null or p_codigo='' or codigo_barra = p_codigo)
),
sel as (
  select * from filtered
  order by id desc                                  -- últimas (más recientes) primero
  limit (case when p_limit is not null and p_limit>0 then p_limit else 2147483647 end)
)
select jsonb_build_object('ok', true, 'data', coalesce((
  select jsonb_agg(jsonb_build_object(
    'id',             id,
    'skuBase',        coalesce(sku_base,''),
    'codigoBarra',    coalesce(codigo_barra,''),
    'descripcion',    coalesce(descripcion,''),
    'precioAnterior', precio_anterior,
    'precioNuevo',    precio_nuevo,
    'usuario',        coalesce(usuario,''),
    'motivo',         coalesce(motivo,''),
    'appOrigen',      coalesce(app_origen,''),
    'fecha',          case when fecha is not null then to_char(fecha at time zone 'America/Lima','YYYY-MM-DD') else '' end
  ) order by id)                                     -- salida en orden de hoja ascendente (como slice)
  from sel), '[]'::jsonb));
$$;

grant execute on function mos.historial_precios_lista(text, text, int) to service_role;
