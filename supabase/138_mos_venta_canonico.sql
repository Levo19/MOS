-- 138 · mos._venta_canonico — resuelve una línea de venta (cod, cantidad, unidad_medida) al
-- CANÓNICO + cantidad física real. Regla: venta por PESO (KGM/KG/LTR/M…) → cantidad ya es la
-- real (SIN factor); venta por UNIDAD (NIU/null) → cantidad × factor. Resuelve equivalentes.
-- La usan: pickup (reposición), descuento de stock del cierre, y la guía/kardex de salida por venta.
create or replace function mos._venta_canonico(p_cod text, p_cant numeric, p_um text)
returns table(sku_base text, canon_cod text, cant numeric)
language plpgsql stable security definer set search_path = '' as $$
declare v_sku text; v_factor numeric; v_canon text; v_peso boolean;
begin
  -- cod → sku_base + factor (productos directo, luego equivalencias)
  select pr.sku_base, coalesce(nullif(pr.factor_conversion,0),1) into v_sku, v_factor
    from mos.productos pr where pr.codigo_barra = p_cod limit 1;
  if v_sku is null then
    select e.sku_base, 1::numeric into v_sku, v_factor
      from mos.equivalencias e where e.codigo_barra = p_cod and e.activo limit 1;
  end if;
  if v_sku is null then v_sku := p_cod; v_factor := 1; end if;
  -- codigo_barra del CANÓNICO (factor=1, preferir el base nominal)
  select pr.codigo_barra into v_canon
    from mos.productos pr
    where pr.sku_base = v_sku and coalesce(nullif(pr.factor_conversion,0),1) = 1
    order by (coalesce(nullif(btrim(pr.codigo_producto_base),''),'')='') desc, pr.codigo_barra limit 1;
  v_canon := coalesce(nullif(btrim(v_canon),''), p_cod);
  -- ¿venta por peso/volumen? → cantidad ya es canónica; si por unidad → × factor
  v_peso := upper(coalesce(p_um,'')) in ('KGM','KG','LTR','L','MTR','M','GR','GMS','G','GRAMO','GRAMOS','KILO','KILOS','LITRO','LITROS');
  sku_base := v_sku;
  canon_cod := v_canon;
  cant := case when v_peso then p_cant else p_cant * v_factor end;
  return next;
end; $$;
revoke all on function mos._venta_canonico(text,numeric,text) from public;
grant execute on function mos._venta_canonico(text,numeric,text) to anon, authenticated, service_role;
