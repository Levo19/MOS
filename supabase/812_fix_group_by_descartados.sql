-- 812: el 811 metió el momento de escritura dentro de un SELECT agrupado (la lista de costos
-- descartados), así que hay que sumarlo a la clave de agrupación.
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'curva_guia_detalle' order by p.oid limit 1;
  if position('group by h.valor, h.sku_base, h.id_guia, h.ts, h.source' in v_def) = 0 then
    raise exception '[812] no encontré el group by de costosDescartados';
  end if;
  v_new := replace(v_def,
    'group by h.valor, h.sku_base, h.id_guia, h.ts, h.source',
    'group by h.valor, h.sku_base, h.id_guia, h.ts, h.source, coalesce(wh._ts_safe(h.meta->>''registradoEl''), h.ts)');
  execute v_new;
end $$;
