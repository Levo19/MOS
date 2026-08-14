-- 779 · Herencia IGV por codigo_producto_base (14-ago-2026). El re-análisis del dueño
-- cazó que TRIGO ENTERO 1KG/500GR (derivados con SKU PROPIO, enlazados al granel por
-- codigo_producto_base=LEV147) no heredaron el exonerado: la alineación 777/778 solo
-- cubría familias de MISMO sku_base. Hay DOS parentescos:
--   (a) mismo sku_base  → cubierto en 777/778
--   (b) codigo_producto_base → sku_base/codigo_barra del padre (derivados con sku propio
--       y presentaciones de esos derivados) → ESTE pase, en cascada hasta agotar.
do $do$
declare v_n int; v_total int := 0; v_ronda int := 0;
begin
  loop
    v_ronda := v_ronda + 1;
    -- (b) hijo hereda del padre al que apunta su codigo_producto_base
    update mos.productos hijo
       set tipo_igv = padre.tipo_igv
      from mos.productos padre
     where coalesce(nullif(btrim(hijo.codigo_producto_base),''),'') <> ''
       and ( upper(btrim(padre.sku_base))    = upper(btrim(hijo.codigo_producto_base))
          or upper(btrim(padre.codigo_barra)) = upper(btrim(hijo.codigo_producto_base)) )
       and coalesce(nullif(padre.factor_conversion,0),1) = 1
       and coalesce(hijo.tipo_igv,1) is distinct from coalesce(padre.tipo_igv,1);
    get diagnostics v_n = row_count;
    v_total := v_total + v_n;
    -- (a) y re-alinear mismo-sku por si (b) movió un padre de familia
    update mos.productos sat
       set tipo_igv = ca.tipo_igv
      from mos.productos ca
     where ca.sku_base = sat.sku_base
       and coalesce(nullif(ca.factor_conversion,0),1) = 1
       and coalesce(nullif(btrim(ca.codigo_producto_base),''),'') = ''
       and sat.id_producto <> ca.id_producto
       and coalesce(sat.tipo_igv,1) is distinct from coalesce(ca.tipo_igv,1);
    get diagnostics v_n = row_count;
    v_total := v_total + v_n;
    exit when v_n = 0 and v_ronda >= 2;
    exit when v_ronda >= 6;   -- backstop
  end loop;
  raise notice 'herencia IGV: % filas alineadas en % rondas', v_total, v_ronda;
end;
$do$;

delete from mos.catalogo_cache where fn like 'catalogo%';
select mos.bump_catalogo_version_manual();
