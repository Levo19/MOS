-- 773 · Backfill de márgenes-contrato (14-ago-2026, cierre del modelo del dueño).
-- "El margen debe guardarse; si el costo lo afecta, se alerta y se ajusta." Los caminos
-- B/C (costo sube/baja → alerta + sugerencia que respeta el margen) solo funcionan si
-- el margen ESTÁ guardado — las presentaciones/derivados históricos no lo tenían (solo
-- se guarda al publicar desde 777). Se toma la foto del margen REAL de hoy: el precio
-- vigente es la decisión consciente del dueño → ese es su contrato inicial.
-- Costo por nivel: presentación = canónico×fc · derivado = canónico×fcb ·
-- pres-de-derivado = canónico×fcb(padre)×fc. Guardas: precio>0, costo>0, margen −99..99.
-- Si un costo de catálogo está podrido, la guarda anti-ZOMBI (778) protege igual.

-- (1) canónicos sin margen: margen real = 1 − costo/precio
update mos.productos
   set margen_pct = round((1 - precio_costo / precio_venta) * 100, 1)
 where margen_pct is null
   and coalesce(nullif(factor_conversion,0),1) = 1
   and coalesce(nullif(btrim(codigo_producto_base),''),'') = ''
   and precio_venta > 0 and precio_costo > 0
   and (1 - precio_costo / precio_venta) * 100 between -99 and 99;

-- (2) presentaciones directas del canónico (cpb='', fc≠1): costo = canónico × fc
update mos.productos pr
   set margen_pct = round((1 - (ca.precio_costo * pr.factor_conversion) / pr.precio_venta) * 100, 1)
  from mos.productos ca
 where ca.sku_base = pr.sku_base
   and coalesce(nullif(ca.factor_conversion,0),1) = 1
   and coalesce(nullif(btrim(ca.codigo_producto_base),''),'') = ''
   and pr.margen_pct is null
   and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = ''
   and coalesce(nullif(pr.factor_conversion,0),1) <> 1
   and pr.precio_venta > 0 and ca.precio_costo > 0
   and (1 - (ca.precio_costo * pr.factor_conversion) / pr.precio_venta) * 100 between -99 and 99;

-- (3) derivados base (cpb≠'', fcb>0, fc=1): costo = canónico × fcb
update mos.productos pr
   set margen_pct = round((1 - (ca.precio_costo * pr.factor_conversion_base) / pr.precio_venta) * 100, 1)
  from mos.productos ca
 where ca.sku_base = pr.sku_base
   and coalesce(nullif(ca.factor_conversion,0),1) = 1
   and coalesce(nullif(btrim(ca.codigo_producto_base),''),'') = ''
   and pr.margen_pct is null
   and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') <> ''
   and coalesce(pr.factor_conversion_base,0) > 0
   and coalesce(nullif(pr.factor_conversion,0),1) = 1
   and pr.precio_venta > 0 and ca.precio_costo > 0
   and (1 - (ca.precio_costo * pr.factor_conversion_base) / pr.precio_venta) * 100 between -99 and 99;

-- (4) presentaciones de derivado (cpb=cod del derivado, fc≠1): costo = canónico × fcb(padre) × fc
update mos.productos pr
   set margen_pct = round((1 - (ca.precio_costo * pd.factor_conversion_base * pr.factor_conversion) / pr.precio_venta) * 100, 1)
  from mos.productos pd
  join mos.productos ca on ca.sku_base = pd.sku_base
   and coalesce(nullif(ca.factor_conversion,0),1) = 1
   and coalesce(nullif(btrim(ca.codigo_producto_base),''),'') = ''
 where upper(btrim(pd.codigo_barra)) = upper(btrim(pr.codigo_producto_base))
   and coalesce(pd.factor_conversion_base,0) > 0
   and pr.margen_pct is null
   and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') <> ''
   and coalesce(nullif(pr.factor_conversion,0),1) <> 1
   and pr.precio_venta > 0 and ca.precio_costo > 0
   and (1 - (ca.precio_costo * pd.factor_conversion_base * pr.factor_conversion) / pr.precio_venta) * 100 between -99 and 99;
