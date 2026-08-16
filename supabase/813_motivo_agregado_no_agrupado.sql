-- 813_motivo_agregado_no_agrupado.sql — remate del 811.
--
-- El 811 metió `h.meta` dentro de la llamada a la regla, y esa llamada aparece en el SELECT de
-- dos consultas AGRUPADAS (las listas de costos descartados). Postgres exige entonces que
-- `h.meta` esté en el GROUP BY. En el 812 lo agregué a la clave de agrupación de
-- `curva_guia_detalle` y eso trajo un efecto colateral: al entrar el momento de escritura en la
-- clave, seis aplicaciones del mismo costo dejaron de agruparse y la lista pasó de 2 filas a 6.
--
-- Lo correcto es lo contrario: el motivo NO debe formar parte de la clave, se calcula sobre una
-- fila del grupo. Se envuelve en `(array_agg(... order by h.id))[1]` — la misma técnica que ya
-- usan `usuario` y `source` en esas mismas consultas — y se devuelve la clave de agrupación a lo
-- que era: (fecha, valor, guía).

do $$
declare v_def text; v_new text; v_n int;
begin
  -- ── curva_guia_detalle ──
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'curva_guia_detalle' order by p.oid limit 1;

  v_new := replace(v_def,
    $viejo$                 'motivo',  mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, v_pv, v_pc, coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts)),$viejo$,
    $nuevo$                 'motivo',  (array_agg(mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, v_pv, v_pc, coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts)) order by h.id))[1],$nuevo$);
  if v_new = v_def then raise exception '[813] no encontré el motivo agrupado en curva_guia_detalle'; end if;

  -- y se devuelve la clave de agrupación a la original (sin el momento de escritura)
  v_new := replace(v_new,
    'group by h.valor, h.sku_base, h.id_guia, h.ts, h.source, coalesce(wh._ts_safe(h.meta->>''registradoEl''), h.ts)',
    'group by h.valor, h.sku_base, h.id_guia, h.ts, h.source');
  execute v_new;

  -- ── historial_precio_costo ──
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'historial_precio_costo' order by p.oid limit 1;

  v_n := (length(v_def) - length(replace(v_def, '''motivo'', mos._costo_anulacion(', '')))
         / length('''motivo'', mos._costo_anulacion(');
  if v_n <> 1 then raise exception '[813] historial_precio_costo: esperaba 1 motivo agrupado y hay %', v_n; end if;

  v_new := replace(v_def,
    $viejo2$'motivo', mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, v_pv, v_pc, coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts)),$viejo2$,
    $nuevo2$'motivo', (array_agg(mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, v_pv, v_pc, coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts)) order by h.id))[1],$nuevo2$);
  if v_new = v_def then raise exception '[813] no encontré el motivo agrupado en historial_precio_costo'; end if;
  execute v_new;
end $$;
