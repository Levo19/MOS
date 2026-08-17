-- 817_ingreso_linea_es_el_subtotal.sql — [DUEÑO] "el modal de productos vendidos dice que se
-- vendió S/2609.90 pero la vista de finanzas me da otros montos, ¿por qué? El margen, el costo
-- total y el monto vendido también."
--
-- MEDIDO EN EL DÍA DE HOY, sobre las MISMAS ventas cobradas:
--   suma de `subtotal` de las líneas ......... S/ 2616.90   ← cuadra EXACTO con los tickets
--   suma de `precio × cantidad` .............. S/ 2609.90   ← lo que usaba la lista
--   suma de los totales de los tickets ....... S/ 2616.90
--
-- `mos.finanzas_dia` calculaba el ingreso de cada línea como `precio * cantidad`, y esa
-- multiplicación NO reproduce lo cobrado: en 8 tickets de hoy difiere entre −0.90 y +1.10 (venta
-- al peso, donde el precio unitario se guarda redondeado pero el subtotal es el real). Neto: los
-- S/ 7.00 de diferencia que vio el dueño. El campo `subtotal` es el que la caja cobró de verdad.
--
-- FIX: `ingreso_linea = coalesce(d.subtotal, d.precio * d.cantidad)`. Se conserva el producto
-- como respaldo por si alguna línea vieja no tiene subtotal. Con esto:
--   · el total de la lista de productos coincide con Ventas Netas al centavo;
--   · el margen por producto se calcula sobre lo COBRADO, no sobre una multiplicación teórica;
--   · el margen del día deja de mezclar dos ingresos distintos.
-- El costo no se toca: sigue siendo costo_unitario × cantidad, que es lo correcto.

do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'finanzas_dia' order by p.oid limit 1;

  -- (1) el CTE `det` debe arrastrar el subtotal real de la línea
  if position('coalesce(d.precio,0)::numeric as precio,' in v_def) = 0 then
    raise exception '[817] no encontré el select del precio en el CTE det';
  end if;
  v_new := replace(v_def,
    'coalesce(d.precio,0)::numeric as precio,',
    'coalesce(d.precio,0)::numeric as precio,
           coalesce(d.subtotal, d.precio * d.cantidad, 0)::numeric as subtotal_l,   -- [817]');

  -- (2) el ingreso de la línea pasa a ser lo COBRADO
  if position('(dr.precio * dr.cantidad) as ingreso_linea,' in v_new) = 0 then
    raise exception '[817] no encontré el cálculo de ingreso_linea';
  end if;
  v_new := replace(v_new,
    '(dr.precio * dr.cantidad) as ingreso_linea,',
    -- [817] `precio * cantidad` no reproduce lo cobrado en ventas al peso (el precio unitario
    -- va redondeado). `subtotal` es lo que la caja cobró: con él, la lista de productos cuadra
    -- al centavo con Ventas Netas y el margen se calcula sobre plata real.
    'coalesce(dr.subtotal_l, dr.precio * dr.cantidad) as ingreso_linea,');

  execute v_new;
end $$;
