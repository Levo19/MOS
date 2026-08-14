-- 780 · Cierre de la regularización IGV (14-ago-2026) — decisiones finales del dueño
-- sobre los 6 puntos del contador: (1) MERI es molido → queda gravado ✓ sin cambio;
-- (2) salvados de trigo → EXONERADOS (este pase); (3) zona-gris ya exonerados ✓;
-- (4) glutinoso inafecto ✓; (5) CPEs históricos quedan ✓; (6) declaraciones quedan ✓.
update mos.productos set tipo_igv = 2
 where coalesce(nullif(factor_conversion,0),1) = 1
   and coalesce(nullif(btrim(codigo_producto_base),''),'') = ''
   and descripcion in (
   'la buena salud salvado de trigo 350gr',
   'SUR ANDINO SALVADO DE TRIGO 250GR DOYPACK');

-- herencia (ambos parentescos, cascada)
do $do$
declare v_n int; v_ronda int := 0;
begin
  loop
    v_ronda := v_ronda + 1;
    update mos.productos hijo set tipo_igv = padre.tipo_igv
      from mos.productos padre
     where coalesce(nullif(btrim(hijo.codigo_producto_base),''),'') <> ''
       and (upper(btrim(padre.sku_base)) = upper(btrim(hijo.codigo_producto_base))
         or upper(btrim(padre.codigo_barra)) = upper(btrim(hijo.codigo_producto_base)))
       and coalesce(nullif(padre.factor_conversion,0),1) = 1
       and coalesce(hijo.tipo_igv,1) is distinct from coalesce(padre.tipo_igv,1);
    update mos.productos sat set tipo_igv = ca.tipo_igv
      from mos.productos ca
     where ca.sku_base = sat.sku_base
       and coalesce(nullif(ca.factor_conversion,0),1) = 1
       and coalesce(nullif(btrim(ca.codigo_producto_base),''),'') = ''
       and sat.id_producto <> ca.id_producto
       and coalesce(sat.tipo_igv,1) is distinct from coalesce(ca.tipo_igv,1);
    get diagnostics v_n = row_count;
    exit when v_n = 0 or v_ronda >= 5;
  end loop;
end;
$do$;

delete from mos.catalogo_cache where fn like 'catalogo%';
select mos.bump_catalogo_version_manual();
