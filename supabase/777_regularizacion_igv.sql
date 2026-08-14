-- 777 · REGULARIZACIÓN IGV del catálogo (14-ago-2026) — decisiones del dueño sobre el
-- informe de clasificación (artifact igv_catalogo_mos). Regla aplicada: entero/natural
-- = exonerado (9 NubeFact) · procesado = gravado · arroz pilado reventa = inafecto (11).
-- Interno: 1=Gravado · 2=Exonerado · 3=Inafecto (conv 776: 2→9, 3→11).

-- ═══ (1) De EXONERADO → GRAVADO (procesados que sí llevan IGV) ═══════════════
update mos.productos set tipo_igv = 1
 where coalesce(nullif(factor_conversion,0),1) = 1
   and coalesce(nullif(btrim(codigo_producto_base),''),'') = ''
   and descripcion in (
   'GALLETA MOLIDA GRANEL EXO',
   'SABINA GALLETA DE AGUA AZUL 250GR BOLSA EXO',
   'SABINA GALLETA DE AGUA ROJO 500GR BOLSA EXO',
   'SABINA TOSTADA VARIOS 545GR PAQUETE EXO',
   'PAN BLANCO MOLIDO GRANEL EXO',
   'PAN MOLIDO OSCURO GRANEL EXO',
   'PALILLO PURO POLVO GRANEL EXO',
   'DULCE NISPERO TAPER',
   'EMOLIENTE CHICO BOLSA EXO',
   'EMOLIENTE GRANDE BOLSA EXO');

-- ═══ (2) De GRAVADO → EXONERADO (enteros/naturales, decisión: "exonera todos") ═
update mos.productos set tipo_igv = 2
 where coalesce(nullif(factor_conversion,0),1) = 1
   and coalesce(nullif(btrim(codigo_producto_base),''),'') = ''
   and descripcion in (
   'HUEVO A GRANEL',
   'AJI PANCA ENTERO GRANEL',
   'CANELA ENTERA GRANEL','CANELA ENTERA 10GR','CANELA ENTERA 20GR','CANELA ENTERA 50GR',
   'CANELA ENTERA 100GR','CANELA ENTERA 250GR','CANELA ENTERA 500GR',
   'CANELA ENTERA 15UN SARTA (0.50)','CANELA ENTERA 15UN SARTA (1.0)','CANELA ENTERA 20UN SARTA (0.3)',
   'ANIS EN GRANO ENTERO 0.30','ANIS EN GRANO IMPORTADO GRANEL','ANIS ENTERO 15UN SARTA (0.50)',
   'ANIS ESTRELLA ENTERA 15UN SARTA (1.0)','ANIS ESTRELLA ENTERO 5GR','ANIS ESTRELLA ENTERO GRANEL',
   'COMINO ENTERO 20GR','COMINO ENTERO GRANEL',
   'OREGANO ENTERO 15UN SARTA (0.5)','OREGANO ENTERO 20UN SARTA (0.30)',
   'KIWICHA REAL GRANEL',
   'HOJAS LAUREL ESPAÑOL GRANEL',
   'HONGO Y LAUREL 5GR SOBRE','HONGO Y LAUREL 10GR SOBRE',
   'HONGO Y LAUREL 15UN SARTA (0.5)','HONGO Y LAUREL 15UN SARTA (1.00)','HONGO Y LAUREL 20UN SARTA (0.3)',
   'PAPA SECA ENTERA GRANEL');

-- ═══ (3) ARROZ pilado en reventa → INAFECTO (IVAP pagado en la primera venta) ═
update mos.productos set tipo_igv = 3
 where coalesce(nullif(factor_conversion,0),1) = 1
   and coalesce(nullif(btrim(codigo_producto_base),''),'') = ''
   and descripcion in (
   'COSTEÑO ARROZ 750GR BOLSA EXO',
   'arroz pilado miyako',
   'ARROZ GLUTINOSO ENTERO GRANEL',
   'ARROZ GLUTINOSO ENTERO 250GR',
   'EXCEL RICE ARROZ GLUTINOSO BLANCO');
-- (ARROZ GLUTINOSO MOLIDO = harina → GRAVADO, no se toca. Fideo/papel/vinagre de arroz → GRAVADOS.)

-- ═══ (4) categorías rotas detectadas en el informe ════════════════════════════
update mos.productos
   set categoria_ia = coalesce(categoria_ia,'{}'::jsonb) || jsonb_build_object('categoria','MENESTRAS','subcategoria','Cereales')
 where descripcion in ('MORON ENTERO GRANEL EXO','MORON PARTIDO GRANEL EXO');
update mos.productos
   set categoria_ia = coalesce(categoria_ia,'{}'::jsonb) || jsonb_build_object('categoria','ESPECIAS','subcategoria','Hierbas y hojas')
 where descripcion = 'HOJAS LAUREL ESPAÑOL GRANEL';

-- ═══ (5) HERENCIA: presentaciones, derivados y pres-de-derivados = su canónico ═
update mos.productos sat
   set tipo_igv = ca.tipo_igv
  from mos.productos ca
 where ca.sku_base = sat.sku_base
   and coalesce(nullif(ca.factor_conversion,0),1) = 1
   and coalesce(nullif(btrim(ca.codigo_producto_base),''),'') = ''
   and sat.id_producto <> ca.id_producto
   and coalesce(sat.tipo_igv,1) is distinct from coalesce(ca.tipo_igv,1);

-- ═══ (6) el catálogo POS cachea por huella de datos → forzar rebuild ══════════
delete from mos.catalogo_cache where fn like 'catalogo%';
select mos.bump_catalogo_version_manual();
