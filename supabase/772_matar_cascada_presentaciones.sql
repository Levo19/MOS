-- 772 · MUERE LA CASCADA canónico→presentaciones (14-ago-2026, decisión del dueño).
-- Modelo definitivo: una presentación EXISTE porque tiene su propio precio comercial
-- ("2 bolsas de orégano de 1 sol NO es 50g pesados") — TODA presentación es fija por
-- definición, en granel y no-granel. Su precio solo cambia: (a) en COMPRAS, revisando
-- cada card con su último margen registrado, o (b) editándola a mano. Los TRAMOS del
-- granel sí siguen al canónico (recargo % — sin cambio). Los derivados ya eran
-- independientes (el propagador los excluía por codigo_producto_base).
-- Se conserva la firma para el único llamador (mos.actualizar_producto → devuelve 0,
-- 'presentacionesActualizadas' queda en 0 para siempre).
CREATE OR REPLACE FUNCTION mos._propagar_precio(p_sku text, p_id_canon text, p_precio numeric, p_usuario text, p_motivo text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- [772] NO-OP deliberado: el precio del canónico jamás toca a sus presentaciones.
  -- (Cuerpo anterior: recalculaba precio_venta = canónico × factor en las no-FIJO/LIBRE.)
  return 0;
end;
$function$;
