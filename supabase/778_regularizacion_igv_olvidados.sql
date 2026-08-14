-- 778 · Regularización IGV — segunda pasada (14-ago-2026): los "olvidados" que cazó
-- el re-análisis pedido por el dueño. Misma regla ya aprobada: entero/natural =
-- exonerado. Todos pertenecen a familias que el dueño ya clasificó en el pase 777:
-- ajonjolí (blanco granel ya exo) · canela entera/china/partida (canelas enteras exo)
-- · hongos secos (hongo y laurel exo) · nueces (pecanas/castañas exo) · nuez moscada
-- ENTERA (especias enteras exo) · quinua tricolor (quinuas exo) · linaza (como la
-- chía exo) · trigo entero (como el morón exo).
-- Pendientes para el contador (NO tocados): MERI COMINO CHICO sobre (probable molido)
-- y los salvados de trigo (subproducto de molienda).
update mos.productos set tipo_igv = 2
 where coalesce(nullif(factor_conversion,0),1) = 1
   and coalesce(nullif(btrim(codigo_producto_base),''),'') = ''
   and descripcion in (
   'AJONJOLI BLANCO PREMIUM 50GR',
   'AJONJOLI ENTERO 15UN SARTA (0.5)',
   'AJONJOLI NEGRO GRANEL',
   'CANELA CHINA 12UN SARTA (0.3)',
   'CANELA PARTIDA GRANEL',
   'CHAN FU KEE CANELA CHINA 100GR SOBRE',
   'FURONG CANELA CHINA 100GR SOBRE',
   'FURONG CANELA CHINA 10GR SOBRE',
   'FURONG CANELA CHINA 400GR BOLSA',
   'FURONG CANELA CHINA 500GR BOLSA',
   'HONGO GRANEL',
   'HONGO WEN YI OREJA DE RATON 50GR',
   'TAI BRAND HONGO WENYI SECO 1KG',
   'NUEZ ENTERA CON CASCARA GRANEL',
   'NUEZ PELADA ECONOMICO GRANEL',
   'NUEZ PELADA PREMIUM GRANEL',
   'NUEZ MOSCADA ENTERA GRANEL',
   'QUINUA TRICOLOR PREMIUM',
   'LINAZA PREMIUM GRANEL',
   'LINAZA PREMIUM 50GR',
   'TRIGO ENTERO GRANEL');

-- herencia a presentaciones/derivados/pres-de-derivados
update mos.productos sat
   set tipo_igv = ca.tipo_igv
  from mos.productos ca
 where ca.sku_base = sat.sku_base
   and coalesce(nullif(ca.factor_conversion,0),1) = 1
   and coalesce(nullif(btrim(ca.codigo_producto_base),''),'') = ''
   and sat.id_producto <> ca.id_producto
   and coalesce(sat.tipo_igv,1) is distinct from coalesce(ca.tipo_igv,1);

-- rebuild del catálogo POS
delete from mos.catalogo_cache where fn like 'catalogo%';
select mos.bump_catalogo_version_manual();
