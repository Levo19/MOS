-- 774 · Presentación de granel = UNIDAD a precio de etiqueta en el POS (14-ago-2026).
-- Regla del dueño: escanear el GRANEL (código canónico) → foco al peso → tramos;
-- escanear una PRESENTACIÓN (su código propio, ej. bolsa orégano 25g a S/1.00) →
-- entra como 1 UNIDAD a SU precio, con +/−, no se parte. ME ya lo soporta desde
-- [628] vía el flag precio_fijo (elegirPresentacion: _esFijo → NIU, cantidad 1,
-- precio propio; el stock igual descuenta los kg reales server-side) y el
-- catálogo POS ya lo expone — solo 7 de 169 presentaciones KGM lo tenían.

-- (1) backfill: toda presentación con precio de una familia GRANEL cobra su etiqueta
update mos.productos pr
   set precio_fijo = true
  from mos.productos ca
 where ca.sku_base = pr.sku_base
   and coalesce(nullif(ca.factor_conversion, 0), 1) = 1
   and coalesce(nullif(btrim(ca.codigo_producto_base), ''), '') = ''
   and upper(coalesce(ca.unidad_medida, '')) = 'KGM'
   and coalesce(nullif(pr.factor_conversion, 0), 1) <> 1
   and coalesce(nullif(btrim(pr.codigo_producto_base), ''), '') = ''
   and pr.precio_venta > 0
   and coalesce(pr.precio_fijo, false) = false;

-- (2) candado para las futuras: crear una presentación en familia KGM → nace con el flag
create or replace function mos._tg_pres_granel_fijo()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if coalesce(nullif(new.factor_conversion, 0), 1) <> 1
     and coalesce(nullif(btrim(new.codigo_producto_base), ''), '') = ''
     and coalesce(new.precio_fijo, false) = false
     and exists (select 1 from mos.productos ca
                  where ca.sku_base = new.sku_base
                    and coalesce(nullif(ca.factor_conversion, 0), 1) = 1
                    and coalesce(nullif(btrim(ca.codigo_producto_base), ''), '') = ''
                    and upper(coalesce(ca.unidad_medida, '')) = 'KGM') then
    new.precio_fijo := true;
  end if;
  return new;
end;
$function$;

drop trigger if exists tg_pres_granel_fijo on mos.productos;
create trigger tg_pres_granel_fijo
  before insert on mos.productos
  for each row execute function mos._tg_pres_granel_fijo();
