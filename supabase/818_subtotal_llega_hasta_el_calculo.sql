-- 818: remate del 817. El CTE intermedio `det_res` se quedaba con cantidad/precio/nombre y
-- descartaba el subtotal, así que el cálculo de abajo no lo veía. Se arrastra. De paso, el COSTO
-- ESTIMADO (para los SKU sin costo real) también se calculaba sobre `precio × cantidad`; pasa a
-- usar lo cobrado, para que la estimación parta del mismo número que el ingreso.
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'finanzas_dia' order by p.oid limit 1;

  if position('select dt.cantidad, dt.precio, dt.nombre_raw,' in v_def) = 0 then
    raise exception '[818] no encontré el select de det_res';
  end if;
  v_new := replace(v_def,
    'select dt.cantidad, dt.precio, dt.nombre_raw,',
    'select dt.cantidad, dt.precio, dt.subtotal_l, dt.nombre_raw,');

  if position('else (dr.precio * dr.cantidad) * (1 - v_margen/100)' in v_new) = 0 then
    raise exception '[818] no encontré el costo estimado';
  end if;
  v_new := replace(v_new,
    'else (dr.precio * dr.cantidad) * (1 - v_margen/100)',
    'else coalesce(dr.subtotal_l, dr.precio * dr.cantidad) * (1 - v_margen/100)');

  execute v_new;
end $$;
