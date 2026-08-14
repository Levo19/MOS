-- 771 · Backfill FIJO para presentaciones con precio manual sin marca (14-ago-2026).
-- Caso destapado por el dueño (orégano 25gr S/1.00 con auto=0.65 y modo null): las
-- presentaciones precitadas a mano ANTES de que existiera la marca FIJO quedaron con
-- modo_venta null → el chip del catálogo las mostraba "⚙ auto" Y, mucho peor, la
-- cascada del canónico las PISARÍA en la próxima publicación (solo respeta FIJO/LIBRE).
-- Doctrina del dueño: "precio manual = FIJO". Censo: 271 filas divergentes ≥ S/0.01
-- del auto (canónico × factor) sin marca. Se marcan FIJO — el precio que hoy cobra el
-- negocio queda protegido; si alguna debía seguir al canónico, se libera en su editor.
update mos.productos pr
   set modo_venta = 'FIJO'
  from mos.productos ca
 where ca.sku_base = pr.sku_base
   and coalesce(nullif(ca.factor_conversion, 0), 1) = 1
   and coalesce(nullif(btrim(ca.codigo_producto_base), ''), '') = ''
   and coalesce(nullif(pr.factor_conversion, 0), 1) <> 1
   and upper(coalesce(pr.modo_venta, '')) not in ('FIJO', 'LIBRE')
   and pr.precio_venta > 0
   and ca.precio_venta > 0
   and abs(pr.precio_venta - ca.precio_venta * pr.factor_conversion) >= 0.01;
